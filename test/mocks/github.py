"""Mock of github.com (git smart HTTP) and api.github.com for local tests.

Git requests must authenticate like the gateway does (Basic x-access-token:<PAT>)
and are served by `git http-backend`. API requests must use Bearer <PAT> and
return the login that owns the PAT.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GIT_ROOT = "/srv/git"
PATS = {"mock-pat-alice": "alice", "mock-pat-bob": "bob"}
REPOS = ["acme/demo.git"]


def read_body(handler):
    if handler.headers.get("Transfer-Encoding", "").lower() == "chunked":
        chunks = []
        while True:
            size = int(handler.rfile.readline().split(b";")[0].strip(), 16)
            if size == 0:
                handler.rfile.readline()
                return b"".join(chunks)
            chunks.append(handler.rfile.read(size))
            handler.rfile.readline()
    return handler.rfile.read(int(handler.headers.get("Content-Length") or 0))


def send_json(handler, status, payload, extra_headers=()):
    body = json.dumps(payload).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    for name, value in extra_headers:
        handler.send_header(name, value)
    handler.end_headers()
    handler.wfile.write(body)


class GitHandler(BaseHTTPRequestHandler):
    def login(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            return None
        user, _, pat = base64.b64decode(auth[6:]).decode().partition(":")
        return PATS.get(pat) if user == "x-access-token" else None

    def handle_git(self):
        login = self.login()
        if not login:
            send_json(self, 401, {"message": "bad credentials"},
                      [("WWW-Authenticate", 'Basic realm="mock-github"')])
            return
        body = read_body(self)
        path, _, query = self.path.partition("?")
        env = {
            "PATH": os.environ["PATH"],
            "GIT_PROJECT_ROOT": GIT_ROOT,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REMOTE_USER": login,  # enables git-receive-pack
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "HTTP_CONTENT_ENCODING": self.headers.get("Content-Encoding", ""),
            "GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
        }
        out = subprocess.run(["git", "http-backend"], input=body, env=env,
                             capture_output=True).stdout
        raw_headers, _, payload = out.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in raw_headers.decode().split("\r\n"):
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.split()[0])
            elif name:
                headers.append((name, value.strip()))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = handle_git


class ApiHandler(BaseHTTPRequestHandler):
    def handle_api(self):
        read_body(self)
        auth = self.headers.get("Authorization", "")
        login = PATS.get(auth[7:]) if auth.startswith("Bearer ") else None
        if not login:
            send_json(self, 401, {"message": "Bad credentials"})
        elif self.path == "/graphql":
            send_json(self, 200, {"data": {"viewer": {"login": login}}})
        else:
            send_json(self, 200, {"login": login, "path": self.path})

    do_GET = do_POST = handle_api


def init_repos():
    for repo in REPOS:
        bare = os.path.join(GIT_ROOT, repo)
        if os.path.exists(bare):
            continue
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", bare], check=True)
        with tempfile.TemporaryDirectory() as work:
            git = ["git", "-C", work, "-c", "user.name=mock", "-c", "user.email=mock@example.com"]
            subprocess.run(["git", "init", "-q", "-b", "main", work], check=True)
            with open(os.path.join(work, "README.md"), "w") as f:
                f.write("# demo\n")
            subprocess.run(git + ["add", "."], check=True)
            subprocess.run(git + ["commit", "-q", "-m", "Initial commit"], check=True)
            subprocess.run(git + ["push", "-q", bare, "main"], check=True)


def main():
    init_repos()
    api = ThreadingHTTPServer(("0.0.0.0", 8001), ApiHandler)
    threading.Thread(target=api.serve_forever, daemon=True).start()
    print("mock-github: git on :8000, api on :8001", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), GitHandler).serve_forever()


if __name__ == "__main__":
    main()
