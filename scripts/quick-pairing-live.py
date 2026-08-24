#!/usr/bin/env python3
"""Acceptance harness for a real local Quick Connect pairing.

The run is deliberately outside the default check suite. It builds or reuses a real
``openpaw-host``, starts a disposable high-port user ``sshd``, generates a fresh key,
issues the real QR/link envelope, and drives a scratch-copy XCUITest through the app's
existing Quick Connect confirmation path. All mutable files live below
``$JCODE_SCRATCH_DIR`` and are removed on success, failure, SIGINT, or SIGTERM.

Secret-bearing values remain in memory or captured pipes. Diagnostics pass through
``redact`` before they are printed. The simulator key enters through the existing
DEBUG+simulator ``-openpaw-debug-seed-key`` hook, which calls the app-owned Keychain
credential implementation. This harness never writes the simulator Keychain itself.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, fields
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Mapping


REPO = Path(__file__).resolve().parent.parent
LIVE_TEST_TARGET = (
    "OpenPawUITests/ConnectFlowUITests/"
    "testLiveQuickPairingURLConnectsSSHAndPersistsSigner"
)
EVIDENCE = (
    "real SSH connected",
    "real pairing redeemed once",
    "signer persisted for the selected host",
    "Terminal selected",
    "pairing-code replay rejected",
)
PAIRING_DEVICE_NAME = "Quick Connect live acceptance"
LIVE_NICKNAME = "127"
PAIR_URL_PATTERN = re.compile(r"openpaw://pair#v1\.[A-Za-z0-9_-]+")
RUNTIME_PATTERN = re.compile(r"(?:^|\.)iOS-(\d+)-(\d+)(?:-(\d+))?$")


class HarnessError(RuntimeError):
    pass


@dataclass(frozen=True)
class Simulator:
    udid: str
    name: str
    version: tuple[int, int, int]
    booted: bool


@dataclass
class SecretSet:
    private_key: str = ""
    hook_token: str = ""
    pairing_code: str = ""
    bearer_token: str = ""
    hmac_key: str = ""
    pairing_url: str = ""

    def values(self) -> list[str]:
        return [str(getattr(self, item.name)) for item in fields(self) if getattr(self, item.name)]


@dataclass(frozen=True)
class ScratchLayout:
    root: Path
    home: Path
    host_state: Path
    workspace: Path
    keys: Path
    client_key: Path
    client_public_key: Path
    ssh_host_key: Path
    ssh_host_public_key: Path
    authorized_keys: Path
    sshd_config: Path
    sshd_pid: Path
    known_hosts: Path
    derived_data: Path
    build_target: Path
    worktree: Path
    xcode_log: Path

    @classmethod
    def create(cls, root: Path) -> "ScratchLayout":
        root = root.resolve()
        home = root / "home"
        keys = root / "keys"
        host_state = root / "host-state"
        workspace = root / "workspace"
        derived_data = root / "DerivedData"
        build_target = root / "cargo-target"
        worktree = root / "source"
        for directory in (root, home, keys, host_state, workspace, derived_data, build_target):
            directory.mkdir(parents=True, exist_ok=True)
        return cls(
            root=root,
            home=home,
            host_state=host_state,
            workspace=workspace,
            keys=keys,
            client_key=keys / "id_ed25519",
            client_public_key=keys / "id_ed25519.pub",
            ssh_host_key=keys / "ssh_host_ed25519_key",
            ssh_host_public_key=keys / "ssh_host_ed25519_key.pub",
            authorized_keys=keys / "authorized_keys",
            sshd_config=root / "sshd_config",
            sshd_pid=root / "sshd.pid",
            known_hosts=root / "known_hosts",
            derived_data=derived_data,
            build_target=build_target,
            worktree=worktree,
            xcode_log=root / "xcodebuild.log",
        )


class CleanupRegistry:
    def __init__(self, run_root: Path) -> None:
        self.run_root = run_root
        self.children: list[subprocess.Popen[Any]] = []
        self.cleaned = False
        self._lock = threading.Lock()

    def register(self, child: subprocess.Popen[Any]) -> subprocess.Popen[Any]:
        self.children.append(child)
        return child

    def cleanup(self) -> None:
        with self._lock:
            if self.cleaned:
                return
            for child in reversed(self.children):
                if child.poll() is None:
                    child.terminate()
            deadline = time.time() + 5
            for child in reversed(self.children):
                if child.poll() is None:
                    try:
                        child.wait(timeout=max(0.05, deadline - time.time()))
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
            shutil.rmtree(self.run_root, ignore_errors=True)
            self.cleaned = True


def resolve_scratch_root(environment: Mapping[str, str], repo: Path = REPO) -> Path:
    raw = environment.get("JCODE_SCRATCH_DIR", "").strip()
    if not raw:
        raise HarnessError("JCODE_SCRATCH_DIR must name an external scratch directory")
    root = Path(raw).expanduser().resolve()
    repository = repo.resolve()
    if root == repository or repository in root.parents:
        raise HarnessError("JCODE_SCRATCH_DIR must be outside the repository")
    root.mkdir(parents=True, exist_ok=True)
    return root


def select_simulator(payload: Any, requested: str | None = None) -> Simulator:
    if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
        raise HarnessError("invalid simctl JSON: expected a devices object")
    candidates: list[tuple[tuple[int, int, int], bool, bool, str, str]] = []
    for runtime, devices in payload["devices"].items():
        match = RUNTIME_PATTERN.search(runtime) if isinstance(runtime, str) else None
        if match is None or not isinstance(devices, list):
            continue
        version = tuple(int(part or 0) for part in match.groups())
        for device in devices:
            if not isinstance(device, dict) or device.get("isAvailable") is not True:
                continue
            name, udid, state = device.get("name"), device.get("udid"), device.get("state")
            if not isinstance(name, str) or not isinstance(udid, str):
                continue
            if state not in {"Booted", "Shutdown"}:
                continue
            candidate = (version, name.startswith("iPhone"), state == "Booted", name, udid)
            if requested == udid:
                return Simulator(udid, name, version, state == "Booted")
            candidates.append(candidate)
    if requested:
        raise HarnessError(f"requested iOS simulator is not available: {requested}")
    if not candidates:
        raise HarnessError("no available iOS Simulator")
    version, _, booted, name, udid = max(candidates)
    return Simulator(udid, name, version, booted)


def installed_simulator(requested: str | None = None) -> Simulator:
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise HarnessError("could not list available iOS simulators: " + result.stderr.strip())
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise HarnessError(f"simctl returned invalid JSON: {error}") from error
    return select_simulator(payload, requested)


def redact(text: str, secrets: SecretSet | None = None) -> str:
    safe = text
    if secrets is not None:
        for value in sorted(secrets.values(), key=len, reverse=True):
            safe = safe.replace(value, "<redacted>")
    safe = PAIR_URL_PATTERN.sub("<redacted>", safe)
    safe = re.sub(
        r"(?i)(pairing[_ -]?code|hook[_ -]?token|bearer[_ -]?token|hmac[_ -]?key)"
        r"(\s*[:=]\s*)([^\s,}\]]+)",
        r"\1\2<redacted>",
        safe,
    )
    safe = re.sub(
        r"-----BEGIN (?:OPENSSH|RSA|EC) PRIVATE KEY-----.*?"
        r"-----END (?:OPENSSH|RSA|EC) PRIVATE KEY-----",
        "<redacted>",
        safe,
        flags=re.DOTALL,
    )
    return safe


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = int(sock.getsockname()[1])
    if port < 49152:
        return free_port()
    return port


def render_sshd_config(layout: ScratchLayout, port: int, username: str) -> str:
    return "\n".join(
        [
            "ListenAddress 127.0.0.1",
            f"Port {port}",
            f"HostKey {layout.ssh_host_key}",
            f"AuthorizedKeysFile {layout.authorized_keys}",
            f"PidFile {layout.sshd_pid}",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "ChallengeResponseAuthentication no",
            "PubkeyAuthentication yes",
            "PermitRootLogin no",
            "UsePAM no",
            "UseDNS no",
            "StrictModes no",
            f"AllowUsers {username}",
            "LogLevel VERBOSE",
            "",
        ]
    )


def xcuitest_command(udid: str, derived_data: Path, project_dir: Path | None = None) -> list[str]:
    project = (project_dir or REPO / "apps" / "ios") / "OpenPaw.xcodeproj"
    return [
        "xcodebuild",
        "test",
        "-project",
        str(project),
        "-scheme",
        "OpenPaw",
        "-destination",
        f"id={udid}",
        "-derivedDataPath",
        str(derived_data),
        "-skipPackagePluginValidation",
        "-skipMacroValidation",
        f"-only-testing:{LIVE_TEST_TARGET}",
    ]


def live_test_environment(
    base: Mapping[str, str],
    host: str,
    port: int,
    host_api_port: int,
    username: str,
    nickname: str,
    private_key_path: Path,
    coordination_port: int,
) -> dict[str, str]:
    environment = dict(base)
    environment.update(
        {
            "TEST_RUNNER_OPENPAW_LIVE_HOST": host,
            "TEST_RUNNER_OPENPAW_LIVE_PORT": str(port),
            "TEST_RUNNER_OPENPAW_LIVE_HOST_API_PORT": str(host_api_port),
            "TEST_RUNNER_OPENPAW_LIVE_USER": username,
            "TEST_RUNNER_OPENPAW_LIVE_NICKNAME": nickname,
            "TEST_RUNNER_OPENPAW_LIVE_KEY": str(private_key_path),
            "TEST_RUNNER_OPENPAW_QUICK_PAIRING_COORDINATION_PORT": str(coordination_port),
        }
    )
    return environment


class PairClient:
    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/")

    def json(self, method: str, path: str, body: object) -> tuple[int, object]:
        raw = json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=raw, method=method)
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                data = response.read()
                status = response.status
        except urllib.error.HTTPError as error:
            data = error.read()
            status = error.code
        try:
            return status, json.loads(data)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return status, {}


def assert_pairing_replay_rejected(client: Any, pairing_code: str) -> None:
    status, _ = client.json(
        "POST",
        "/v1/pair",
        {"pairing_code": pairing_code, "device_name": "replay-check", "platform": "harness"},
    )
    if status not in {403, 410}:
        raise HarnessError(f"consumed pairing code replay returned HTTP {status}, expected rejection")


def run_checked(
    command: list[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    secrets: SecretSet | None = None,
    description: str,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = redact((result.stdout or "") + (result.stderr or ""), secrets).strip()
        raise HarnessError(f"{description} failed with exit {result.returncode}\n{detail[-6000:]}")
    return result


def wait_for_port(port: int, child: subprocess.Popen[Any], description: str, timeout: float = 30) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if child.poll() is not None:
            raise HarnessError(f"{description} exited before listening")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.15)
    raise HarnessError(f"{description} did not listen on 127.0.0.1:{port}")


def wait_for_health(port: int, child: subprocess.Popen[Any], timeout: float = 30) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if child.poll() is not None:
            raise HarnessError("openpaw-host exited before becoming healthy")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=1) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError):
            time.sleep(0.15)
    raise HarnessError("openpaw-host did not become healthy")


def generate_keys(layout: ScratchLayout) -> SecretSet:
    run_checked(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(layout.client_key)],
        description="client key generation",
    )
    run_checked(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(layout.ssh_host_key)],
        description="sshd host key generation",
    )
    layout.authorized_keys.write_bytes(layout.client_public_key.read_bytes())
    os.chmod(layout.client_key, 0o600)
    os.chmod(layout.authorized_keys, 0o600)
    return SecretSet(private_key=layout.client_key.read_text(encoding="utf-8"))


def locate_sshd() -> str:
    candidates = [shutil.which("sshd"), "/usr/sbin/sshd"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise HarnessError("sshd is not installed")


def start_sshd(
    layout: ScratchLayout,
    port: int,
    username: str,
    cleanup: CleanupRegistry,
) -> subprocess.Popen[str]:
    layout.sshd_config.write_text(render_sshd_config(layout, port, username), encoding="utf-8")
    child = cleanup.register(
        subprocess.Popen(
            [locate_sshd(), "-D", "-e", "-f", str(layout.sshd_config)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    )
    wait_for_port(port, child, "sshd")
    return child


def verify_disposable_ssh(layout: ScratchLayout, port: int, username: str, secrets: SecretSet) -> None:
    result = run_checked(
        [
            "ssh",
            "-F",
            "/dev/null",
            "-i",
            str(layout.client_key),
            "-p",
            str(port),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"UserKnownHostsFile={layout.known_hosts}",
            f"{username}@127.0.0.1",
            "printf openpaw-sshd-ready",
        ],
        secrets=secrets,
        description="disposable SSH probe",
    )
    if result.stdout != "openpaw-sshd-ready":
        raise HarnessError("disposable SSH probe returned unexpected output")


def build_fixture_repo(layout: ScratchLayout) -> None:
    layout.workspace.mkdir(parents=True, exist_ok=True)
    environment = dict(
        os.environ,
        GIT_AUTHOR_NAME="quick-pairing-live",
        GIT_AUTHOR_EMAIL="quick-pairing-live@example.invalid",
        GIT_COMMITTER_NAME="quick-pairing-live",
        GIT_COMMITTER_EMAIL="quick-pairing-live@example.invalid",
    )
    run_checked(["git", "init", "-b", "main", str(layout.workspace)], env=environment, description="fixture git init")
    (layout.workspace / "README.md").write_text("# disposable Quick Connect acceptance\n", encoding="utf-8")
    run_checked(["git", "-C", str(layout.workspace), "add", "README.md"], env=environment, description="fixture git add")
    run_checked(["git", "-C", str(layout.workspace), "commit", "-m", "fixture"], env=environment, description="fixture git commit")


def host_binary(layout: ScratchLayout, explicit: str | None) -> Path:
    if explicit:
        binary = Path(explicit).expanduser().resolve()
        if not binary.is_file():
            raise HarnessError(f"openpaw-host binary does not exist: {binary}")
        return binary
    existing = REPO / "host" / "target" / "debug" / "openpaw-host"
    if existing.is_file():
        return existing
    run_checked(
        ["cargo", "build", "-p", "openpaw-host"],
        cwd=REPO / "host",
        env=dict(os.environ, CARGO_TARGET_DIR=str(layout.build_target)),
        description="openpaw-host build",
    )
    binary = layout.build_target / "debug" / "openpaw-host"
    if not binary.is_file():
        raise HarnessError("cargo succeeded but openpaw-host was not produced")
    return binary


def start_host(
    binary: Path,
    layout: ScratchLayout,
    port: int,
    cleanup: CleanupRegistry,
) -> tuple[subprocess.Popen[str], dict[str, str]]:
    (layout.host_state / "config.toml").write_text(
        f'bind = "127.0.0.1"\nport = {port}\nrepos = ["{layout.workspace}"]\nsession_max_age_days = 36500\n',
        encoding="utf-8",
    )
    environment = dict(
        os.environ,
        HOME=str(layout.home),
        OPENPAW_STATE_DIR=str(layout.host_state),
        OPENPAW_LOG="info",
    )
    child = cleanup.register(
        subprocess.Popen(
            [str(binary), "serve"],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    )
    wait_for_health(port, child)
    return child, environment


def decode_pairing_envelope(url: str) -> dict[str, Any]:
    match = PAIR_URL_PATTERN.fullmatch(url.strip())
    if match is None:
        raise HarnessError("openpaw-host did not return an exact openpaw://pair#v1 link")
    payload = url.split("#v1.", 1)[1]
    padding = "=" * ((4 - len(payload) % 4) % 4)
    try:
        value = json.loads(base64.urlsafe_b64decode(payload + padding))
    except (ValueError, json.JSONDecodeError) as error:
        raise HarnessError("openpaw-host returned a malformed pairing envelope") from error
    if not isinstance(value, dict) or not isinstance(value.get("pairing_code"), str):
        raise HarnessError("pairing envelope omitted its one-time code")
    return value


def issue_pairing_link(
    binary: Path,
    environment: Mapping[str, str],
    ssh_port: int,
    username: str,
    secrets: SecretSet,
) -> str:
    result = run_checked(
        [
            str(binary),
            "pair",
            "--name",
            PAIRING_DEVICE_NAME,
            "--qr",
            "--ssh-host",
            "127.0.0.1",
            "--ssh-user",
            username,
            "--ssh-port",
            str(ssh_port),
        ],
        env=environment,
        secrets=secrets,
        description="real pairing QR/link issuance",
    )
    url = result.stdout.strip()
    envelope = decode_pairing_envelope(url)
    secrets.pairing_url = url
    secrets.pairing_code = envelope["pairing_code"]
    hook_path = Path(environment["OPENPAW_STATE_DIR"]) / "hook-token"
    if hook_path.is_file():
        secrets.hook_token = hook_path.read_text(encoding="utf-8").strip()
    return url


def append_live_xcuitest(test_file: Path) -> None:
    source = test_file.read_text(encoding="utf-8")
    marker = "\n}\n"
    index = source.rfind(marker)
    if index < 0:
        raise HarnessError("could not extend the scratch ConnectFlowUITests.swift")
    method = r'''

    /// Generated only in the scratch project by scripts/quick-pairing-live.py.
    func testLiveQuickPairingURLConnectsSSHAndPersistsSigner() throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["OPENPAW_LIVE_HOST"])
        let port = try XCTUnwrap(environment["OPENPAW_LIVE_PORT"])
        let hostAPIPort = try XCTUnwrap(environment["OPENPAW_LIVE_HOST_API_PORT"])
        let username = try XCTUnwrap(environment["OPENPAW_LIVE_USER"])
        let nickname = try XCTUnwrap(environment["OPENPAW_LIVE_NICKNAME"])
        let keyPath = try XCTUnwrap(environment["OPENPAW_LIVE_KEY"])
        let coordinationPort = try XCTUnwrap(environment["OPENPAW_QUICK_PAIRING_COORDINATION_PORT"])

        func notify(_ path: String) {
            let expectation = expectation(description: path)
            let url = URL(string: "http://127.0.0.1:\(coordinationPort)\(path)")!
            URLSession.shared.dataTask(with: url) { _, response, error in
                XCTAssertNil(error)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
                expectation.fulfill()
            }.resume()
            wait(for: [expectation], timeout: 15)
        }

        func pairingURL() -> URL {
            let expectation = expectation(description: "/ready")
            let ready = URL(string: "http://127.0.0.1:\(coordinationPort)/ready")!
            var value: URL?
            URLSession.shared.dataTask(with: ready) { data, response, error in
                XCTAssertNil(error)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                if let data { value = URL(dataRepresentation: data, relativeTo: nil) }
                expectation.fulfill()
            }.resume()
            wait(for: [expectation], timeout: 15)
            return value!
        }

        let seedApp = XCUIApplication()
        seedApp.launchArguments = [
            "-openpaw-debug-seed-key", keyPath,
            "-openpaw-debug-ssh-host", "\(username)@\(host):\(port)",
            "-openpaw-debug-direct-port", hostAPIPort,
            "-openpaw-debug-pairing-code", "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF",
            "-openpaw.settings.biometricGate", "<false/>",
        ]
        seedApp.launch()
        XCTAssertTrue(seedApp.buttons["Connect to Debug daemon"].waitForExistence(timeout: 15), seedApp.debugDescription)
        seedApp.terminate()

        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw-debug-seed-key", keyPath,
            "-openpaw.settings.biometricGate", "<false/>",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Connect to Debug daemon"].waitForExistence(timeout: 15), app.debugDescription)

        app.open(pairingURL())
        XCTAssertTrue(app.staticTexts["Quick Connect to \(nickname)"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.buttons["quick-connect.confirm"].label, "Confirm SSH credential and connect")
        XCTAssertTrue(app.staticTexts["Verify on first connection"].exists)
        XCTAssertTrue(app.staticTexts["Debug daemon · Saved private key"].exists)
        app.buttons["quick-connect.confirm"].tap()

        let trust = app.buttons["Trust this host key and continue connecting"]
        XCTAssertTrue(trust.waitForExistence(timeout: 15), app.debugDescription)
        trust.tap()

        let pager = app.otherElements["root.destination.pager"]
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Terminal"), object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 60), .completed, app.debugDescription)
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        notify("/connected")

        app.terminate()
        app.launchArguments = ["-openpaw.settings.biometricGate", "<false/>"]
        app.launch()
        let connect = app.buttons["Connect to Debug daemon"]
        if connect.waitForExistence(timeout: 10) { connect.tap() }
        let resume = app.buttons["Resume Debug daemon"]
        XCTAssertTrue(resume.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.buttons["Open repository workspace"].waitForExistence(timeout: 30), app.debugDescription)
        notify("/persisted")
    }
'''
    test_file.write_text(source[:index] + method + source[index:], encoding="utf-8")


def prepare_scratch_project(layout: ScratchLayout) -> Path:
    apps = layout.worktree / "apps"
    apps.mkdir(parents=True, exist_ok=True)
    project_dir = apps / "ios"
    shutil.copytree(REPO / "apps" / "ios", project_dir)
    os.symlink(REPO / "packages", layout.worktree / "packages", target_is_directory=True)
    append_live_xcuitest(project_dir / "OpenPawUITests" / "ConnectFlowUITests.swift")
    return project_dir


class CoordinationServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        port: int,
        simulator: str,
        link_factory: Callable[[], str],
        secrets: SecretSet,
    ) -> None:
        super().__init__(("127.0.0.1", port), CoordinationHandler)
        self.simulator = simulator
        self.pairing_url = ""
        self.secrets = secrets
        self.events: set[str] = set()
        self.failure: str | None = None
        self._link_factory: Callable[[], str] | None = link_factory
        self._ready_lock = threading.Lock()

    def open_pairing_link_once(self) -> bool:
        with self._ready_lock:
            if "/ready" in self.events:
                return True
            if self.failure is not None:
                return False

            factory, self._link_factory = self._link_factory, None
            if factory is None:
                self.failure = "pairing link factory was already consumed"
                return False
            try:
                self.pairing_url = factory()
                result = subprocess.run(
                    ["xcrun", "simctl", "openurl", self.simulator, self.pairing_url],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            except Exception as error:  # Keep the HTTP worker alive and the one-shot state stable.
                self.failure = redact(str(error), self.secrets).strip() or type(error).__name__
                return False
            if result.returncode != 0:
                self.failure = redact(result.stdout + result.stderr, self.secrets).strip()
                return False
            self.events.add("/ready")
            return True


class CoordinationHandler(BaseHTTPRequestHandler):
    server: CoordinationServer

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/ready":
            if not self.server.open_pairing_link_once():
                self.send_response(500)
                self.end_headers()
                return
            body = self.server.pairing_url.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in {"/connected", "/persisted"}:
            self.server.events.add(self.path)
            self.send_response(204)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *_args: object) -> None:
        pass


def state_device_count(state_dir: Path) -> int:
    try:
        value = json.loads((state_dir / "state.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return 0
    devices = value.get("devices", []) if isinstance(value, dict) else []
    return len(devices) if isinstance(devices, list) else 0


def pair_audit_count(state_dir: Path) -> int:
    try:
        lines = (state_dir / "audit.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return 0
    count = 0
    for line in lines:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("action") == "device.pair":
            count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", help="reuse an existing openpaw-host binary")
    parser.add_argument("--simulator", help="specific available simulator UDID")
    args = parser.parse_args()

    cleanup: CleanupRegistry | None = None
    coordinator: CoordinationServer | None = None
    coordinator_thread: threading.Thread | None = None
    secrets = SecretSet()
    previous_handlers: dict[int, Any] = {}
    try:
        scratch = resolve_scratch_root(os.environ)
        run_root = scratch / f"openpaw-quick-pairing-live-{os.getpid()}-{int(time.time())}"
        layout = ScratchLayout.create(run_root)
        cleanup = CleanupRegistry(run_root)

        def stop_on_signal(signum: int, _frame: object) -> None:
            raise SystemExit(128 + signum)

        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, stop_on_signal)

        simulator = installed_simulator(args.simulator)
        if not simulator.booted:
            run_checked(["xcrun", "simctl", "boot", simulator.udid], description="simulator boot")
        run_checked(["xcrun", "simctl", "bootstatus", simulator.udid, "-b"], description="simulator boot wait")

        username = getpass.getuser()
        ssh_port = free_port()
        host_port = free_port()
        coordination_port = free_port()
        while len({ssh_port, host_port, coordination_port}) != 3:
            ssh_port, host_port, coordination_port = free_port(), free_port(), free_port()

        secrets = generate_keys(layout)
        start_sshd(layout, ssh_port, username, cleanup)
        verify_disposable_ssh(layout, ssh_port, username, secrets)
        build_fixture_repo(layout)

        binary = host_binary(layout, args.binary)
        _, host_environment = start_host(binary, layout, host_port, cleanup)
        if state_device_count(layout.host_state) != 0:
            raise HarnessError("fresh openpaw-host state unexpectedly contains a paired device")

        project_dir = prepare_scratch_project(layout)
        coordinator = CoordinationServer(
            coordination_port,
            simulator.udid,
            lambda: issue_pairing_link(binary, host_environment, ssh_port, username, secrets),
            secrets,
        )
        coordinator_thread = threading.Thread(target=coordinator.serve_forever, daemon=True)
        coordinator_thread.start()

        command = xcuitest_command(simulator.udid, layout.derived_data, project_dir)
        environment = live_test_environment(
            base=os.environ,
            host="127.0.0.1",
            port=ssh_port,
            host_api_port=host_port,
            username=username,
            nickname=LIVE_NICKNAME,
            private_key_path=layout.client_key,
            coordination_port=coordination_port,
        )
        xcodebuild = cleanup.register(
            subprocess.Popen(
                command,
                cwd=project_dir,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        )
        stdout, stderr = xcodebuild.communicate()
        xcode_output = redact((stdout or "") + (stderr or ""), secrets)
        layout.xcode_log.write_text(xcode_output, encoding="utf-8")

        if coordinator.failure:
            raise HarnessError("simctl openurl failed: " + coordinator.failure)
        if xcodebuild.returncode != 0:
            checkpoints = sorted(coordinator.events)
            errors = "\n".join(
                line for line in xcode_output.splitlines()
                if " error:" in line or "XCTAssert" in line or "failed" in line.lower()
            )[-4000:]
            raise HarnessError(
                f"live Quick Connect XCUITest failed with exit {xcodebuild.returncode}; "
                f"coordination checkpoints reached: {checkpoints}; "
                f"persisted host device count: {state_device_count(layout.host_state)}; "
                f"persisted pairing audit count: {pair_audit_count(layout.host_state)}\n"
                f"{errors}\n{xcode_output[-5000:]}"
            )
        if not {"/ready", "/connected", "/persisted"}.issubset(coordinator.events):
            raise HarnessError(f"live XCUITest missed coordination checkpoints: {sorted(coordinator.events)}")
        if state_device_count(layout.host_state) != 1:
            raise HarnessError("real /v1/pair did not persist exactly one device")

        assert_pairing_replay_rejected(PairClient(f"http://127.0.0.1:{host_port}"), secrets.pairing_code)

        for line in EVIDENCE:
            print(line)
        return 0
    except (HarnessError, OSError, ValueError, SystemExit) as error:
        if isinstance(error, SystemExit) and isinstance(error.code, int):
            code = error.code
        else:
            code = 1
        print(redact(f"quick pairing live acceptance failed: {error}", secrets), file=sys.stderr)
        return code
    finally:
        if coordinator is not None:
            try:
                coordinator.shutdown()
                coordinator.server_close()
            except OSError:
                pass
        if coordinator_thread is not None:
            coordinator_thread.join(timeout=5)
        if cleanup is not None:
            cleanup.cleanup()
            if cleanup.cleaned and not cleanup.run_root.exists():
                print("cleanup verified: child processes stopped and scratch run removed")
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
