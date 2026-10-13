#!/usr/bin/env python3
"""Remote MCP server fixture for rv tests (stdlib only, loopback only).

Prints "PORT <n>" on stdout once listening, then logs one line per request
on stderr. Routes:
  POST/DELETE /mcp       streamable HTTP (session id, protocol version header,
                         JSON replies for tools/list, SSE replies for tools/call)
  GET /sse, POST /messages   legacy HTTP+SSE
  GET /sse-foreign       legacy stream whose endpoint is on another origin
With --token T every MCP request needs "Authorization: Bearer T".
"""
import argparse
import json
import queue
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOOLS = [
    {"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
    {"name": "whoami", "description": "Show the credentials this server received", "inputSchema": {"type": "object"}},
    {"name": "delete_all", "description": "Dangerous", "inputSchema": {"type": "object"}},
]

STATE = {"sessions": {}, "legacy": {}, "lock": threading.Lock()}


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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    token = None

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
        if self.token is None or self.headers.get("Authorization") == "Bearer " + self.token:
            return True
        meta = "http://%s/.well-known/oauth-protected-resource/mcp" % self.headers.get("Host")
        self.send(401, b'{"error":"unauthorized"}', extra={"WWW-Authenticate": 'Bearer resource_metadata="%s"' % meta})
        log("REQ %s %s -> 401" % (self.command, self.path))
        return False

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length))

    def do_POST(self):
        path = urlparse(self.path)
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
        path = urlparse(self.path).path
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
    options = parser.parse_args()
    Handler.token = options.token
    server = ThreadingHTTPServer(("127.0.0.1", options.port), Handler)
    server.daemon_threads = True
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
