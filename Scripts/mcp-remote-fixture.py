#!/usr/bin/env python3
"""Remote MCP server fixture for rv tests (stdlib only, loopback only).

Prints "PORT <n>" on stdout once listening, then logs one line per request
on stderr. Routes:
  POST/DELETE /mcp       streamable HTTP (session id, protocol version header,
                         JSON replies for tools/list, SSE replies for tools/call)
  GET /sse, POST /messages   legacy HTTP+SSE
  GET /sse-foreign       legacy stream whose endpoint is on another origin
With --token T every MCP request needs "Authorization: Bearer T".
With --oauth it is also its own OAuth 2.1 authorization server (RFC 9728
metadata, RFC 8414 metadata, RFC 7591 registration, PKCE S256, refresh
rotation); MCP requests need a token it issued. POST /auth/expire revokes
every access token so the next call must refresh.
"""
import argparse
import base64
import hashlib
import json
import queue
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


def log(text):
    print(text, file=sys.stderr, flush=True)


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
            text = args.get("text", "")
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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    token = None
    oauth = False

    def origin(self):
        return "http://" + self.headers.get("Host")

    def log_message(self, *args):
        pass

    def send(self, status, body=b"", content_type="application/json", extra=None):
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
        if self.oauth and (path.path.startswith("/auth/")):
            return self.oauth_post(path.path)
        if path.path == "/mcp":
            return self.streamable()
        if path.path == "/messages":
            return self.legacy_post(parse_qs(path.query).get("session", [""])[0])
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
        if "id" not in msg:
            return self.send(202)
        reply = answer(msg, self.headers)
        if method == "tools/call":
            note = {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "working"}}
            body = ("event: message\ndata: %s\n\n: keepalive\n\nevent: message\ndata: %s\n\n" % (
                json.dumps(note), json.dumps(reply))).encode()
            return self.send(200, body, content_type="text/event-stream")
        self.send(200, json.dumps(reply).encode())

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
        endpoint = "http://example.invalid/messages?session=" + sid if foreign else "/messages?session=" + sid
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

    def legacy_post(self, sid):
        if not self.authorized():
            return
        with STATE["lock"]:
            outbox = STATE["legacy"].get(sid)
        if outbox is None:
            return self.send(404)
        msg = self.read_json()
        log("REQ POST /messages %s session=%s" % (msg.get("method"), sid))
        if "id" in msg and "method" in msg:
            outbox.put(answer(msg, self.headers))
        self.send(202)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--token")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--oauth", action="store_true")
    options = parser.parse_args()
    Handler.token = options.token
    Handler.oauth = options.oauth
    server = ThreadingHTTPServer(("127.0.0.1", options.port), Handler)
    server.daemon_threads = True
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
