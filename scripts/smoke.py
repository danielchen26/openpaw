#!/usr/bin/env python3
"""End-to-end acceptance run against a real `openpaw-host` process.

The Rust integration tests exercise the router in-process. This script exercises the *shipped binary* the way a
phone does: build it, give it a synthetic HOME containing the checked-in agent fixtures and a real git repository,
start it, pair a device, then drive every route over signed HTTP — including the ones that must fail.

No third-party dependencies: standard library only, so it runs anywhere the toolchain does.

    python3 scripts/smoke.py [--binary path] [--keep]

Exit code 0 means every assertion below held.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "protocol" / "fixtures"

PASS = "\033[32m  ok\033[0m"
FAIL = "\033[31mFAIL\033[0m"

failures: list[str] = []
checks = 0


def check(label: str, condition: bool, detail: str = "") -> None:
    global checks
    checks += 1
    if condition:
        print(f"{PASS}  {label}")
    else:
        failures.append(label + (f" — {detail}" if detail else ""))
        print(f"{FAIL}  {label}" + (f"\n      {detail}" if detail else ""))


@dataclass
class Device:
    device_id: str
    token: str
    hmac_key: bytes


class Host:
    """Signed client for the daemon, mirroring `protocol/capability-spec/capabilities.json`."""

    def __init__(self, base: str, device: Device | None = None) -> None:
        self.base = base.rstrip("/")
        self.device = device

    def request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
        sign: bool = True,
        timestamp: int | None = None,
        nonce: str | None = None,
        stream: bool = False,
    ):
        payload = body or b""
        head = dict(headers or {})
        if sign and self.device is not None:
            ts = timestamp if timestamp is not None else int(time.time())
            nn = nonce or secrets.token_hex(8)
            canonical = "\n".join(
                [method.upper(), path, str(ts), nn, hashlib.sha256(payload).hexdigest()]
            )
            signature = hmac.new(self.device.hmac_key, canonical.encode(), hashlib.sha256).hexdigest()
            head.update(
                {
                    "Authorization": f"Bearer {self.device.token}",
                    "X-OpenPaw-Device": self.device.device_id,
                    "X-OpenPaw-Timestamp": str(ts),
                    "X-OpenPaw-Nonce": nn,
                    "X-OpenPaw-Signature": signature,
                }
            )
        request = urllib.request.Request(self.base + path, data=body, method=method.upper())
        for key, value in head.items():
            request.add_header(key, value)
        try:
            response = urllib.request.urlopen(request, timeout=20)
            if stream:
                return response.status, response
            return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()
        except urllib.error.URLError as error:
            return 0, str(error).encode()

    def json(self, method: str, path: str, body: object | None = None, **kwargs):
        raw = None if body is None else json.dumps(body).encode()
        head = {"Content-Type": "application/json"} if raw else {}
        head.update(kwargs.pop("headers", {}))
        status, data = self.request(method, path, raw, head, **kwargs)
        try:
            return status, json.loads(data)
        except Exception:
            return status, data


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def build_home(root: Path) -> Path:
    """A synthetic HOME holding the three real agent layouts, straight from the checked-in fixtures."""
    home = root / "home"
    claude = home / ".claude" / "projects" / "-Users-dev-src-openpaw"
    claude.mkdir(parents=True)
    for src in (FIXTURES / "claude-code").glob("*.jsonl"):
        shutil.copy(src, claude / src.name)

    codex = home / ".codex" / "sessions" / "2026" / "08" / "20"
    codex.mkdir(parents=True)
    for src in (FIXTURES / "codex").glob("*.jsonl"):
        shutil.copy(src, codex / src.name)

    opencode = home / ".local" / "share" / "opencode"
    opencode.mkdir(parents=True)
    shutil.copytree(FIXTURES / "opencode" / "storage", opencode / "storage")
    return home


def build_repo(root: Path) -> Path:
    """A real git repository, because the git routes shell out to real git."""
    repo = root / "workspace"
    repo.mkdir()
    env = dict(
        os.environ,
        GIT_AUTHOR_NAME="smoke",
        GIT_AUTHOR_EMAIL="smoke@example.com",
        GIT_COMMITTER_NAME="smoke",
        GIT_COMMITTER_EMAIL="smoke@example.com",
    )
    run = lambda *args: subprocess.run(["git", "-C", str(repo), *args], check=True, env=env,
                                       capture_output=True)
    subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
    (repo / "README.md").write_text("# smoke\n\nfirst line\nsecond line\n")
    (repo / "src").mkdir()
    (repo / "src" / "main.rs").write_text('fn main() {\n    println!("hello");\n}\n')
    run("add", "-A")
    run("commit", "-m", "initial commit")
    # One staged change and one unstaged change, so status and both diff modes have something to say.
    (repo / "src" / "main.rs").write_text('fn main() {\n    println!("hello, openpaw");\n}\n')
    (repo / "NOTES.md").write_text("staged file\n")
    run("add", "NOTES.md")
    return repo


class Upstream(BaseHTTPRequestHandler):
    """Stands in for a dev server on an allowlisted loopback port."""

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_address[1]}/landed")
            self.end_headers()
            return
        body = b"<!doctype html><title>dev server</title><h1>openpaw preview</h1>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=None, help="path to openpaw-host (default: cargo build output)")
    parser.add_argument("--keep", action="store_true", help="keep the temp directory for inspection")
    args = parser.parse_args()

    binary = args.binary
    if binary is None:
        print("building openpaw-host…")
        build = subprocess.run(
            ["cargo", "build", "-p", "openpaw-host"],
            cwd=REPO / "host",
            env=dict(os.environ, CARGO_TARGET_DIR="/tmp/opaw-smoke"),
        )
        if build.returncode != 0:
            print("build failed", file=sys.stderr)
            return 1
        binary = "/tmp/opaw-smoke/debug/openpaw-host"
    if not Path(binary).exists():
        print(f"no binary at {binary}", file=sys.stderr)
        return 1

    root = Path(tempfile.mkdtemp(prefix="openpaw-smoke-"))
    state = root / "state"
    state.mkdir()
    home = build_home(root)
    repo = build_repo(root)
    port = free_port()
    upstream_port = free_port()

    upstream = ThreadingHTTPServer(("127.0.0.1", upstream_port), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()

    (state / "config.toml").write_text(
        f'bind = "127.0.0.1"\n'
        f"port = {port}\n"
        f'repos = ["{repo}"]\n'
        f"preview_ports = [{upstream_port}]\n"
        f"session_max_age_days = 36500\n"
    )

    env = dict(os.environ, HOME=str(home), OPENPAW_STATE_DIR=str(state), RUST_LOG="info")
    daemon = subprocess.Popen(
        [binary, "serve"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    log_lines: list[str] = []

    def drain():
        assert daemon.stdout is not None
        for line in daemon.stdout:
            log_lines.append(line.rstrip())

    threading.Thread(target=drain, daemon=True).start()

    base = f"http://127.0.0.1:{port}"
    anon = Host(base)
    deadline = time.time() + 30
    while time.time() < deadline:
        status, _ = anon.request("GET", "/v1/health", sign=False)
        if status == 200:
            break
        if daemon.poll() is not None:
            print("daemon exited early:\n" + "\n".join(log_lines), file=sys.stderr)
            return 1
        time.sleep(0.2)

    try:
        status, health = anon.json("GET", "/v1/health", sign=False)
        check("health is public", status == 200, f"status {status}")
        check("health reports the protocol version", isinstance(health, dict)
              and health.get("protocol") == "1", repr(health))

        status, _ = anon.json("GET", "/v1/sessions", sign=False)
        check("unsigned session list is refused", status == 401, f"status {status}")

        # Pairing: the operator reads a code off the host, the phone consumes it once. The CLI puts the human
        # text on stderr and the bare code on stdout, so a script never has to parse prose.
        code_run = subprocess.run([binary, "pairing-code"], env=env, capture_output=True, text=True)
        lines = [line.strip() for line in code_run.stdout.splitlines() if line.strip()]
        labelled = re.search(r"Pairing code:\s*(\S+)", code_run.stdout)
        code = labelled.group(1) if labelled else (lines[-1] if lines else "")
        if code_run.returncode != 0:
            code = ""
        check("pairing code is issued", bool(code),
              (code_run.stderr or code_run.stdout).strip()[:300])
        status, paired = anon.json(
            "POST", "/v1/pair",
            {"pairing_code": code, "device_name": "smoke", "platform": "ios"},
            sign=False,
        )
        check("pairing succeeds", status == 200 and isinstance(paired, dict) and "token" in paired,
              f"status {status} body {paired!r}")
        if status != 200:
            raise SystemExit(1)
        device = Device(paired["device_id"], paired["token"], base64.b64decode(paired["hmac_key_b64"]))
        host = Host(base, device)

        status, again = anon.json(
            "POST", "/v1/pair",
            {"pairing_code": code, "device_name": "replay", "platform": "ios"},
            sign=False,
        )
        check("a pairing code cannot be reused", status >= 400, f"status {status}")

        # Signing.
        status, _ = host.json("GET", "/v1/sessions")
        check("a correctly signed request is accepted", status == 200, f"status {status}")

        bad = Host(base, Device(device.device_id, device.token, b"\x00" * 32))
        status, _ = bad.json("GET", "/v1/sessions")
        check("a wrong signing key is refused", status == 401, f"status {status}")

        nonce = secrets.token_hex(8)
        host.json("GET", "/v1/sessions", nonce=nonce)
        status, _ = host.json("GET", "/v1/sessions", nonce=nonce)
        check("a replayed nonce is refused", status == 401, f"status {status}")

        status, _ = host.json("GET", "/v1/sessions", timestamp=int(time.time()) - 3600)
        check("a stale timestamp is refused", status == 401, f"status {status}")

        # Adapters discovered the fixtures placed in the synthetic HOME.
        for _ in range(40):
            status, sessions = host.json("GET", "/v1/sessions")
            if status == 200 and isinstance(sessions, list) and len(sessions) >= 3:
                break
            time.sleep(0.25)
        agents = sorted({s.get("agent") for s in sessions}) if isinstance(sessions, list) else []
        check("all three adapters discovered their session",
              agents == ["claude-code", "codex", "opencode"], repr(agents))

        # Event replay from the ring buffer.
        target = sessions[0]["session_id"]
        status, response = host.request(
            "GET", f"/v1/events?session={target}&after_seq=0", stream=True
        )
        check("event stream opens", status == 200, f"status {status}")
        payloads = []
        if status == 200:
            deadline = time.time() + 15
            for raw in response:
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("data:"):
                    try:
                        payloads.append(json.loads(line[5:].strip()))
                    except json.JSONDecodeError:
                        pass
                if len(payloads) >= 3 or time.time() > deadline:
                    break
            response.close()
        check("event stream replays the backlog", len(payloads) >= 3, f"got {len(payloads)}")
        check("events carry a content-addressed id and the protocol version",
              all(p.get("version") == "1" and str(p.get("event_id", "")).startswith("evt_")
                  for p in payloads), repr(payloads[:1]))

        # The approval path, including the gate that must refuse.
        hook_token = (state / "hook-token").read_text().strip()
        destructive = json.loads((FIXTURES / "claude-code" / "hook-pretooluse-destructive.json").read_text())
        status, _ = host.json(
            "POST", "/v1/hooks/claude-code", destructive,
            headers={"X-OpenPaw-Hook-Token": hook_token}, sign=False,
        )
        check("hook ingress accepts a PreToolUse payload", status == 200, f"status {status}")

        status, _ = host.json("POST", "/v1/hooks/claude-code", destructive,
                              headers={"X-OpenPaw-Hook-Token": "wrong"}, sign=False)
        check("hook ingress refuses a wrong token", status == 401, f"status {status}")

        item = None
        for _ in range(40):
            status, inbox = host.json("GET", "/v1/inbox?status=pending")
            if status == 200 and isinstance(inbox, list):
                item = next((i for i in inbox if i.get("category") == "permission"), None)
                if item:
                    break
            time.sleep(0.25)
        check("the destructive request reached the inbox", item is not None, repr(inbox)[:400])
        if item:
            risk = item.get("risk") or {}
            check("it is classified destructive",
                  risk.get("class") == "destructive_shell", repr(risk))
            check("it demands the command be expanded first",
                  risk.get("requires_detail_expansion") is True, repr(risk))
            check("it names why", bool(risk.get("reasons")), repr(risk.get("reasons")))
            check("the action token is delivered over the tunnel, not guessed",
                  bool(item.get("action_token")), "missing action_token")

            token = item.get("action_token")
            status, body = host.json(
                "POST", f"/v1/inbox/{item['id']}/resolve",
                {"action": "approve_once", "action_token": token},
            )
            check("approving without acknowledging the detail is refused",
                  status == 400, f"status {status} body {body!r}")

            status, body = host.json(
                "POST", f"/v1/inbox/{item['id']}/resolve",
                {"action": "approve_once", "action_token": token, "detail_acknowledged": True},
            )
            check("approving with the detail acknowledged succeeds",
                  status == 200, f"status {status} body {body!r}")

            status, _ = host.json(
                "POST", f"/v1/inbox/{item['id']}/resolve",
                {"action": "approve_once", "action_token": token, "detail_acknowledged": True},
            )
            check("the action token is single use", status >= 400, f"status {status}")

            decisions = list((state / "decisions").glob("*.json")) if (state / "decisions").is_dir() else []
            check("the decision was handed back to the agent", len(decisions) >= 1,
                  f"{state / 'decisions'} empty")

            status, audit = host.json("GET", "/v1/audit?limit=50")
            check("the decision is audited",
                  status == 200 and isinstance(audit, list)
                  and any("resolve" in json.dumps(entry) for entry in audit),
                  repr(audit)[:300])

        # Repository inspection.
        status, repos = host.json("GET", "/v1/repos")
        check("the allowlisted repository is listed",
              status == 200 and isinstance(repos, list) and len(repos) == 1, repr(repos)[:300])
        name = repos[0]["name"] if isinstance(repos, list) and repos else "workspace"

        status, repo_status = host.json("GET", f"/v1/repos/{name}/status")
        check("git status is readable", status == 200, f"status {status}")

        status, diff = host.json("GET", f"/v1/repos/{name}/diff")
        check("the working-tree diff has the modified file",
              status == 200 and any(f.get("path", "").endswith("main.rs")
                                    for f in (diff or {}).get("files", [])),
              repr(diff)[:300])

        status, staged = host.json("GET", f"/v1/repos/{name}/diff?staged=true")
        check("the staged diff has the staged file",
              status == 200 and any(f.get("path", "").endswith("NOTES.md")
                                    for f in (staged or {}).get("files", [])),
              repr(staged)[:300])

        status, tree = host.json("GET", f"/v1/repos/{name}/tree?ref=HEAD&path=")
        check("the tree lists the repository root", status == 200 and isinstance(tree, list) and tree,
              repr(tree)[:200])

        status, blob = host.json("GET", f"/v1/repos/{name}/blob?ref=HEAD&path=README.md")
        check("a blob is readable at a ref", status == 200, f"status {status}")

        status, _ = host.json("GET", f"/v1/repos/{name}/blob?ref=HEAD&path=../../../etc/passwd")
        check("path traversal out of the root is refused", status >= 400, f"status {status}")

        status, _ = host.json("GET", f"/v1/repos/{name}/diff?commit=--upload-pack%3Devil")
        check("a rev that looks like a flag is refused", status >= 400, f"status {status}")

        # Preview proxy.
        status, page = host.request("GET", f"/v1/preview/{upstream_port}/")
        check("an allowlisted dev-server port is proxied",
              status == 200 and b"openpaw preview" in page, f"status {status}")

        status, _ = host.request("GET", "/v1/preview/9/")
        check("a port outside the allowlist is refused", status >= 400, f"status {status}")

        # Uploads.
        png = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF/lP4jAAAAAElFTkSuQmCC"
        )
        status, uploaded = host.request(
            "POST", "/v1/uploads", png,
            {"X-OpenPaw-Filename": "shot.png", "Content-Type": "image/png"},
        )
        check("an upload is accepted and lands under the state dir", status == 200
              and b"uploads" in uploaded, f"status {status} body {uploaded[:200]!r}")

        status, _ = host.request(
            "POST", "/v1/uploads", png, {"X-OpenPaw-Filename": "../evil.png"}
        )
        check("an upload filename that is not a basename is refused", status >= 400, f"status {status}")

        # The endpoint that must never exist.
        status, _ = host.json("POST", "/v1/exec", {"command": "id"})
        check("there is no remote-command endpoint", status == 404, f"status {status}")

    finally:
        daemon.send_signal(signal.SIGTERM)
        try:
            daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            daemon.kill()
        upstream.shutdown()
        if args.keep:
            print(f"\ntemp dir kept at {root}")
        else:
            shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} of {checks} checks failed:")
        for line in failures:
            print(f"  - {line}")
        if log_lines:
            print("\ndaemon log tail:")
            for line in log_lines[-30:]:
                print(f"  {line}")
        return 1
    print(f"all {checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
