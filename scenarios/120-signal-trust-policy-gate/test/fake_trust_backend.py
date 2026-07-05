#!/usr/bin/env python3
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


class Store:
    def __init__(self, path, store_ref, token):
        self.path = Path(path)
        self.store_ref = store_ref
        self.token = token
        self.force_conflict = False
        self.force_corrupt = False
        self.lock = threading.Lock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self._write({"generation_ref": "", "snapshot": None, "puts": 0})

    def _read(self):
        return json.loads(self.path.read_text())

    def _write(self, value):
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        tmp.replace(self.path)

    def state(self):
        with self.lock:
            return self._read()

    def snapshot_get(self):
        with self.lock:
            state = self._read()
            snapshot = state.get("snapshot")
            if snapshot is None:
                return {"status": "not_found", "generation_ref": state.get("generation_ref", "")}
            return {
                "status": "ok",
                "generation_ref": state.get("generation_ref", ""),
                "snapshot": snapshot,
            }

    def snapshot_put(self, req):
        with self.lock:
            state = self._read()
            if req.get("store_ref") != self.store_ref:
                return 400, {"error": "wrong store"}
            if self.force_conflict:
                self.force_conflict = False
                return 409, {"error": "generation conflict"}
            if req.get("previous_generation_ref", "") != state.get("generation_ref", ""):
                return 409, {"error": "generation conflict"}
            puts = int(state.get("puts", 0)) + 1
            next_state = {
                "generation_ref": f"generation-{puts}",
                "snapshot": req.get("snapshot"),
                "puts": puts,
            }
            self._write(next_state)
            return 200, {"status": "ok", "generation_ref": next_state["generation_ref"]}

    def arm_conflict(self):
        with self.lock:
            self.force_conflict = True

    def arm_corrupt(self):
        with self.lock:
            self.force_corrupt = True

    def consume_corrupt(self):
        with self.lock:
            if not self.force_corrupt:
                return False
            self.force_corrupt = False
            return True


class Handler(BaseHTTPRequestHandler):
    store = None

    def log_message(self, fmt, *args):
        return

    def _send(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _snapshot_auth_ok(self):
        got = self.headers.get("Authorization", "")
        if got != self.store.token:
            self._send(401, {"error": "missing auth"})
            return False
        return True

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self._send(200, {"status": "ok"})
            return
        if parsed.path == "/control/state":
            self._send(200, self.store.state())
            return
        if parsed.path != "/snapshot":
            self._send(404, {"error": "not found"})
            return
        if not self._snapshot_auth_ok():
            return
        query = parse_qs(parsed.query)
        if query.get("store_ref", [""])[0] != self.store.store_ref:
            self._send(400, {"error": "wrong store"})
            return
        if self.store.consume_corrupt():
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"{")
            return
        self._send(200, self.store.snapshot_get())

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/control/conflict":
            self.store.arm_conflict()
            self._send(200, {"status": "armed"})
            return
        if parsed.path == "/control/corrupt":
            self.store.arm_corrupt()
            self._send(200, {"status": "armed"})
            return
        self._send(404, {"error": "not found"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        if parsed.path != "/snapshot":
            self._send(404, {"error": "not found"})
            return
        if not self._snapshot_auth_ok():
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self._send(400, {"error": "bad json"})
            return
        status, value = self.store.snapshot_put(req)
        self._send(status, value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--store-ref", required=True)
    parser.add_argument("--token", required=True)
    args = parser.parse_args()

    host, port = args.listen.rsplit(":", 1)
    Handler.store = Store(args.state, args.store_ref, args.token)
    server = ThreadingHTTPServer((host, int(port)), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
