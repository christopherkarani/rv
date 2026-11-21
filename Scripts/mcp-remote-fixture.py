#!/usr/bin/env python3
"""Remote MCP server fixture for rv tests (stdlib only, loopback only).

Prints "PORT <n>" on stdout once listening, then logs one line per request
on stderr. Routes:
  POST/DELETE /mcp       streamable HTTP (session id, protocol version header,
                         JSON replies for tools/list, SSE replies for tools/call)
  GET /sse, POST /sse        legacy HTTP+SSE; the message endpoint is that same URL
  GET /sse-foreign       legacy stream whose endpoint is on another origin
With --token T every MCP request needs "Authorization: Bearer T".
With --hang-calls a tools/call is never answered: a legacy SSE one is accepted
(202), a streamable HTTP one gets an event stream held open, with nothing on
it, until the client closes it ("CLOSED call <id>" is logged).
With --oauth it is also its own OAuth 2.1 authorization server (RFC 9728
metadata, RFC 8414 metadata, RFC 7591 registration, PKCE S256, refresh
rotation); MCP requests need a token it issued. POST /auth/expire revokes
every access token so the next call must refresh.
With --reset-calls a streamable HTTP tools/call is read and its connection
reset with no reply ("RESET call <id>" is logged). POST /expire-sessions
forgets every streamable HTTP session, so the next request on one gets 404.
With --log-connections every POST is logged as it arrives, before its body is
read ("ENTER POST <path> port=<client port>"), so a request sent again
without its body still shows.
With --stream-notifications a notification after initialized, or a reply,
is answered 202 with a body that never ends, a comment every half second
("CLOSED notification <method>" is logged once the client closes it).
With --drip-notification-heads such a POST's response head is written a
byte every half second and never finished ("CLOSED notification <method>"
once the client closes it).
With --endless-refusals a 401 or 404 has a body that never ends
("CLOSED refusal <status>" once the client closes it).
With --deaf-pings a ping is never answered ("DEAF ping" is logged).
With --hold-replies a call's event-stream reply is sent whole and then
held open ("CLOSED reply <id>" is logged once the client closes it).
With --hang-notes a held call's event stream first carries one comment
line, so the client reads part of a reply that never answers.
With --deaf-over N a POST /mcp whose body is over N bytes is never read
("DEAF POST <length>" is logged) and its connection is held open.
The echo tool's arguments: "text", or "size" (and "char", default "x") for a
text of that many characters; "noise" makes the note sent before a streamable
HTTP answer carry that many bytes; "plain" sends that answer as a JSON body
instead of an event stream.
"""
import argparse
import base64
import hashlib
import json
import queue
import select
import socket
import socketserver
import struct
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

TOOLS = [
    {"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
    {"name": "whoami", "description": "Show the credentials this server received", "inputSchema": {"type": "object"}},
    {"name": "delete_all", "description": "Dangerous", "inputSchema": {"type": "object"}},
]

STATE = {"sessions": {}, "legacy": {}, "lock": threading.Lock(),
         "clients": {}, "codes": {}, "access": set(), "refresh": set()}


LOG_LOCK = threading.Lock()


def log(text):
    # One write per line, under a lock. print() writes the text and the
    # newline separately, so two request threads could interleave into
    # "REQ ...REQ ...\n\n" and a test counting lines would see one request.
    with LOG_LOCK:
        sys.stderr.write(text + "\n")
        sys.stderr.flush()


def answer(msg, headers):
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                  "serverInfo": {"name": "remote-fixture", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        name, args = msg["params"]["name"], msg["params"].get("arguments", {})
        if name == "echo":
            text = args.get("char", "x") * args["size"] if "size" in args else args.get("text", "")
        elif name == "whoami":
            text = "authorization=%s team=%s" % (headers.get("Authorization", "none"), headers.get("X-Team", "none"))
        else:
            text = "deleted everything"
        result = {"content": [{"type": "text", "text": text}]}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # http.server's own bind asks the resolver for this host's name
        # (socket.getfqdn), which nothing here uses and which takes half a
        # minute on a macOS CI runner: three fixtures took 35 s each to
        # report their port.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    token = None
    oauth = False
    hang_calls = False
    hang_notes = False
    hold_replies = False
    stream_notifications = False
    drip_notification_heads = False
    endless_refusals = False
    deaf_pings = False
    reset_calls = False
    log_connections = False
    deaf_over = None

    def origin(self):
        return "http://" + self.headers.get("Host")

    def log_message(self, *args):
        pass

    def send(self, status, body=b"", content_type="application/json", extra=None):
        if status in (401, 404) and self.endless_refusals and self.command == "POST":
            return self.endless(status, extra)
        self.send_response(status)
        if body or status != 202:
            self.send_header("Content-Type", content_type)
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        given = self.headers.get("Authorization", "")
        if self.oauth:
            with STATE["lock"]:
                ok = given.startswith("Bearer ") and given[7:] in STATE["access"]
        else:
            ok = self.token is None or given == "Bearer " + self.token
        if ok:
            return True
        meta = self.origin() + "/.well-known/oauth-protected-resource/mcp"
        challenge_header = 'Bearer resource_metadata="%s", scope="mcp:tools"' % meta
        # The whole request is taken before the refusal, so the client has
        # sent its body (as a real server that reads first would see it).
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.close_connection = True
        self.send(401, b'{"error":"unauthorized"}', extra={"WWW-Authenticate": challenge_header, "Connection": "close"})
        log("REQ %s %s -> 401" % (self.command, self.path))
        return False

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length))

    def send_json(self, status, value, extra=None):
        self.send(status, json.dumps(value).encode(), extra=extra)

    def read_form(self):
        length = int(self.headers.get("Content-Length", "0"))
        return {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode()).items()}

    def oauth_get(self, path, query):
        origin = self.origin()
        if path == "/.well-known/oauth-protected-resource/mcp":
            return self.send_json(200, {"resource": origin + "/mcp", "authorization_servers": [origin + "/auth"],
                                        "scopes_supported": ["mcp:tools"]})
        if path == "/.well-known/oauth-authorization-server/auth":
            return self.send_json(200, {
                "issuer": origin + "/auth", "authorization_endpoint": origin + "/auth/authorize",
                "token_endpoint": origin + "/auth/token", "registration_endpoint": origin + "/auth/register",
                "code_challenge_methods_supported": ["S256"], "response_types_supported": ["code"]})
        if path == "/auth/authorize":
            q = {k: v[0] for k, v in query.items()}
            with STATE["lock"]:
                client = STATE["clients"].get(q.get("client_id"))
            problems = []
            if client is None or q.get("redirect_uri") not in client:
                problems.append("client/redirect")
            if q.get("response_type") != "code" or q.get("code_challenge_method") != "S256" or not q.get("code_challenge"):
                problems.append("pkce")
            if q.get("resource") != origin + "/mcp":
                problems.append("resource")
            if problems:
                log("OAUTH authorize refused %s" % ",".join(problems))
                return self.send(400, b"bad request", content_type="text/plain")
            code = "code-" + uuid.uuid4().hex[:12]
            with STATE["lock"]:
                STATE["codes"][code] = (q["client_id"], q["redirect_uri"], q["code_challenge"], q["resource"])
            log("OAUTH authorize ok scope=%s" % q.get("scope"))
            location = q["redirect_uri"] + "?" + urlencode({"code": code, "state": q.get("state", "")})
            return self.send(302, b"", content_type="text/plain", extra={"Location": location})
        return self.send(404)

    def oauth_post(self, path):
        origin = self.origin()
        if path == "/auth/register":
            body = self.read_json()
            client = "client-" + uuid.uuid4().hex[:8]
            with STATE["lock"]:
                STATE["clients"][client] = body.get("redirect_uris", [])
            log("OAUTH register %s auth=%s" % (client, body.get("token_endpoint_auth_method")))
            return self.send_json(201, {"client_id": client, "redirect_uris": body.get("redirect_uris", [])})
        if path == "/auth/expire":
            with STATE["lock"]:
                STATE["access"].clear()
            log("OAUTH expired every access token")
            return self.send_json(200, {})
        if path != "/auth/token":
            return self.send(404)
        form = self.read_form()
        grant = form.get("grant_type")
        with STATE["lock"]:
            if grant == "authorization_code":
                entry = STATE["codes"].pop(form.get("code"), None)
                ok = (entry is not None and entry[0] == form.get("client_id") and entry[1] == form.get("redirect_uri")
                      and entry[2] == challenge(form.get("code_verifier", "")) and entry[3] == form.get("resource"))
            elif grant == "refresh_token":
                ok = form.get("refresh_token") in STATE["refresh"] and form.get("resource") == origin + "/mcp"
                if ok:
                    STATE["refresh"].discard(form.get("refresh_token"))
            else:
                ok = False
            if ok:
                access, refresh = "at-" + uuid.uuid4().hex, "rt-" + uuid.uuid4().hex
                STATE["access"].add(access)
                STATE["refresh"].add(refresh)
        log("OAUTH token %s %s" % (grant, "ok" if ok else "refused"))
        if not ok:
            return self.send_json(400, {"error": "invalid_grant", "error_description": "secret-ish detail"})
        self.send_json(200, {"access_token": access, "token_type": "Bearer", "expires_in": 3600,
                             "refresh_token": refresh, "scope": "mcp:tools"})

    def do_POST(self):
        path = urlparse(self.path)
        if self.log_connections:
            log("ENTER POST %s port=%s" % (path.path, self.client_address[1]))
        if self.oauth and (path.path.startswith("/auth/")):
            return self.oauth_post(path.path)
        if path.path == "/mcp":
            length = int(self.headers.get("Content-Length", "0"))
            if self.deaf_over is not None and length > self.deaf_over:
                log("DEAF POST %d" % length)
                threading.Event().wait()
            return self.streamable()
        if path.path == "/expire-sessions":
            with STATE["lock"]:
                STATE["sessions"].clear()
            log("EXPIRED every session")
            return self.send_json(200, {})
        if path.path in ("/sse", "/messages"):
            return self.legacy_post(path.path, parse_qs(path.query).get("session", [""])[0])
        self.send(404)

    def do_DELETE(self):
        if urlparse(self.path).path != "/mcp" or not self.authorized():
            return
        sid = self.headers.get("Mcp-Session-Id")
        with STATE["lock"]:
            known = STATE["sessions"].pop(sid, None) is not None
        log("DELETE %s %s" % (sid, "ok" if known else "unknown"))
        self.send(200 if known else 404)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if self.oauth and (path.startswith("/.well-known/") or path.startswith("/auth/")):
            return self.oauth_get(path, parse_qs(parsed.query))
        if path in ("/sse", "/sse-foreign"):
            return self.legacy_stream(foreign=path == "/sse-foreign")
        if path == "/mcp":
            return self.send(405)
        self.send(404)

    def streamable(self):
        if not self.authorized():
            return
        msg = self.read_json()
        method = msg.get("method")
        sid = self.headers.get("Mcp-Session-Id")
        version = self.headers.get("MCP-Protocol-Version")
        log("REQ POST /mcp %s session=%s version=%s" % (method, sid, version))
        if method == "initialize":
            sid = "sess-" + uuid.uuid4().hex[:8]
            reply = answer(msg, self.headers)
            with STATE["lock"]:
                STATE["sessions"][sid] = reply["result"]["protocolVersion"]
            return self.send(200, json.dumps(reply).encode(), extra={"Mcp-Session-Id": sid})
        with STATE["lock"]:
            negotiated = STATE["sessions"].get(sid)
        if negotiated is None:
            return self.send(404, b'{"error":"unknown session"}')
        if version != negotiated:
            return self.send(400, b'{"error":"bad MCP-Protocol-Version"}')
        if "id" not in msg or "method" not in msg:
            log("ACCEPTED %s session=%s" % (method, sid))
            if self.stream_notifications and method != "notifications/initialized":
                self.send_response(202)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.drip(b": keepalive\n\n")
                log("CLOSED notification %s" % method)
                self.close_connection = True
                return
            if self.drip_notification_heads and method != "notifications/initialized":
                for byte in b"HTTP/1.1 202 Accepted\r\n":
                    self.drip_once(bytes([byte]))
                self.drip(b"X")
                log("CLOSED notification %s" % method)
                self.close_connection = True
                return
            return self.send(202)
        if method == "ping" and self.deaf_pings:
            log("DEAF ping")
            return self.hang(msg.get("id"))
        if method == "tools/call" and self.hang_calls:
            return self.hang(msg.get("id"))
        if method == "tools/call" and self.reset_calls:
            log("RESET call %s" % msg.get("id"))
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.close_connection = True
            return
        reply = answer(msg, self.headers)
        arguments = msg.get("params", {}).get("arguments", {}) if method == "tools/call" else {}
        if method == "tools/call" and not arguments.get("plain"):
            data = "x" * arguments["noise"] if "noise" in arguments else "working"
            note = {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": data}}
            body = ("event: message\ndata: %s\n\n: keepalive\n\nevent: message\ndata: %s\n\n" % (
                json.dumps(note), json.dumps(reply))).encode()
            if self.hold_replies:
                return self.hold(msg.get("id"), body)
            return self.send(200, body, content_type="text/event-stream")
        self.send(200, json.dumps(reply).encode())

    def hold(self, mid, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.wait_for_close()
        log("CLOSED reply %s" % mid)
        self.close_connection = True

    def endless(self, status, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.drip(b" ")
        log("CLOSED refusal %d" % status)
        self.close_connection = True

    def drip(self, byte):
        """Writes `byte` every half second until the client closes."""
        while True:
            try:
                self.wfile.write(byte)
                self.wfile.flush()
            except OSError:
                return
            readable, _, _ = select.select([self.connection], [], [], 0.5)
            if readable:
                try:
                    if not self.connection.recv(1, socket.MSG_PEEK):
                        return
                except OSError:
                    return

    def drip_once(self, byte):
        try:
            self.wfile.write(byte)
            self.wfile.flush()
        except OSError:
            pass
        select.select([], [], [], 0.5)

    def wait_for_close(self):
        while True:
            readable, _, _ = select.select([self.connection], [], [], 0.2)
            if not readable:
                continue
            try:
                if not self.connection.recv(1, socket.MSG_PEEK):
                    return
            except OSError:
                return
            select.select([], [], [], 0.2)

    def hang(self, mid):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if self.hang_notes:
            self.wfile.write(b": waiting\n\n")
        self.wfile.flush()
        while True:
            readable, _, _ = select.select([self.connection], [], [], 0.2)
            if not readable:
                continue
            try:
                if not self.connection.recv(1, socket.MSG_PEEK):
                    break
            except OSError:
                break
            select.select([], [], [], 0.2)
        log("CLOSED call %s" % mid)
        self.close_connection = True

    def legacy_stream(self, foreign):
        if not self.authorized():
            return
        sid = uuid.uuid4().hex[:8]
        outbox = queue.Queue()
        with STATE["lock"]:
            STATE["legacy"][sid] = outbox
        log("REQ GET %s session=%s" % (self.path, sid))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        endpoint = "http://example.invalid/messages?session=" + sid if foreign else urlparse(self.path).path
        try:
            self.wfile.write(("event: endpoint\ndata: %s\n\n" % endpoint).encode())
            self.wfile.flush()
            while True:
                try:
                    item = outbox.get(timeout=1)
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                self.wfile.write(("event: message\ndata: %s\n\n" % json.dumps(item)).encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with STATE["lock"]:
                STATE["legacy"].pop(sid, None)
            log("CLOSED legacy %s" % sid)
        self.close_connection = True

    def legacy_post(self, path, sid):
        if not self.authorized():
            return
        with STATE["lock"]:
            if not sid and len(STATE["legacy"]) == 1:
                sid = next(iter(STATE["legacy"]))
            outbox = STATE["legacy"].get(sid)
        if outbox is None:
            return self.send(404)
        msg = self.read_json()
        log("REQ POST %s %s session=%s" % (path, msg.get("method"), sid))
        if "id" in msg and "method" in msg and not (self.hang_calls and msg.get("method") == "tools/call"):
            outbox.put(answer(msg, self.headers))
        self.send(202)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--token")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--oauth", action="store_true")
    parser.add_argument("--hang-calls", action="store_true")
    parser.add_argument("--hang-notes", action="store_true")
    parser.add_argument("--hold-replies", action="store_true")
    parser.add_argument("--stream-notifications", action="store_true")
    parser.add_argument("--drip-notification-heads", action="store_true")
    parser.add_argument("--endless-refusals", action="store_true")
    parser.add_argument("--deaf-pings", action="store_true")
    parser.add_argument("--reset-calls", action="store_true")
    parser.add_argument("--log-connections", action="store_true")
    parser.add_argument("--deaf-over", type=int)
    options = parser.parse_args()
    Handler.token = options.token
    Handler.oauth = options.oauth
    Handler.hang_calls = options.hang_calls
    Handler.hang_notes = options.hang_notes
    Handler.hold_replies = options.hold_replies
    Handler.stream_notifications = options.stream_notifications
    Handler.drip_notification_heads = options.drip_notification_heads
    Handler.endless_refusals = options.endless_refusals
    Handler.deaf_pings = options.deaf_pings
    Handler.reset_calls = options.reset_calls
    Handler.log_connections = options.log_connections
    Handler.deaf_over = options.deaf_over
    server = Server(("127.0.0.1", options.port), Handler)
    server.daemon_threads = True
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
