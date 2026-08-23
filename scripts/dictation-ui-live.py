#!/usr/bin/env python3
"""Drives the dictation UI tests against a real `openpaw-host`, to reach the composer the crash test needs.

`DictationEngineSettingsUITests` has one test that cannot do what its name says without a session. The microphone
lives in `ComposerView`, reached through `ChatView` -> `transcript(sessionID)`; with no session the app draws an
empty state, the hold is impossible, and that test skips rather than pretending to cover the crash.

This starts the same daemon `scripts/smoke.py` does, over the same checked-in fixtures, and hands the simulator the
port and a pairing code. The app has matching DEBUG+simulator hooks (`DirectLoopbackForwarder`,
`debugPairIfRequested`) that skip the tunnel — the simulator shares the Mac's loopback — and pair through the app's
own client, so the signer and the host are real.

ONE STEP IS STILL MISSING, and it is a property of the app rather than of this script. `OpenPawModel` only sets
`structuredBackendReady` after `terminal.connect(host:)` succeeds, deliberately: the structured side must not claim
a session is live while the user cannot type into it. So the sessions list stays empty until SSH is up, and SSH to
this machine needs Remote Login enabled and a key authorised, which is a change to the developer's own machine that
this script will not make behind their back.

To finish the loop, point it at a host you can already SSH into:

    python3 scripts/dictation-ui-live.py --ssh-host me@my-mac[:port] --ssh-key ~/.ssh/id_ed25519

Without those, it still does useful work: it proves the daemon comes up, the app pairs against it through its real
client, and the local-engine guard holds on a build wired to a live backend. The hold test reports that it could
not reach the composer instead of quietly passing.

Not part of `scripts/check.sh`: it needs a built daemon and takes minutes.

    python3 scripts/dictation-ui-live.py [--binary path] [--simulator udid]
        [--ssh-host user@host[:port]] [--ssh-key path] [--only-test testMethodName]
        [--audio-file phrase.aiff] [--audio-device "BlackHole 2ch"]

Exit code 0 means every test that could run did.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke import build_home, build_repo, free_port  # reuse, so the fixtures cannot drift apart

REPO = Path(__file__).resolve().parent.parent
CORE_AUDIO_ROUTE = REPO / "scripts" / "coreaudio-route.swift"
TEST_CLASS = "OpenPawUITests/DictationEngineSettingsUITests"


def exit_on_signal(signum: int, _frame: object) -> None:
    raise SystemExit(128 + signum)


def resolve_simulator(requested: str | None, parser: argparse.ArgumentParser) -> tuple[str, tuple[int, int, int]]:
    listed = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"], capture_output=True, text=True
    )
    if listed.returncode != 0:
        parser.error("could not list iOS simulators: " + listed.stderr.strip())
    candidates: list[tuple[tuple[int, int, int], bool, bool, str]] = []
    for runtime, devices in json.loads(listed.stdout)["devices"].items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if match is None:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        for device in devices:
            if device.get("isAvailable"):
                candidates.append(
                    (version, device.get("state") == "Booted", "iPhone" in device.get("name", ""), device["udid"])
                )
    if requested is not None:
        for version, _, _, udid in candidates:
            if udid == requested:
                return udid, version
        parser.error(f"iOS simulator is not available: {requested}")
    if not candidates:
        parser.error("no available iOS Simulator")
    version, _, _, udid = max(candidates)
    return udid, version


def main() -> int:
    # CI cancellation sends SIGTERM. Turning it into normal stack unwinding is what guarantees the `finally` below
    # restores the developer's audio defaults instead of leaving the Mac routed into a silent loopback device.
    signal.signal(signal.SIGTERM, exit_on_signal)
    signal.signal(signal.SIGINT, exit_on_signal)

    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=None)
    parser.add_argument("--simulator", default=None, help="simulator UDID; defaults to the newest available iOS runtime")
    parser.add_argument(
        "--ssh-host",
        default=None,
        help="user@host[:port] the app should connect to. Required to reach the composer, because the app only "
        "marks the structured backend ready once the terminal is up. A nonstandard port can point at an "
        "unprivileged disposable sshd without changing the developer's Remote Login setup.",
    )
    parser.add_argument(
        "--ssh-key", default=None, help="private key for --ssh-host, copied into the app by the simulator-only launch hook."
    )
    parser.add_argument(
        "--only-test",
        default=None,
        help="one method in DictationEngineSettingsUITests. Omit to run the whole class.",
    )
    parser.add_argument(
        "--audio-file",
        default=None,
        help="play this file with afplay once the UI test says the real audio graph is listening.",
    )
    parser.add_argument(
        "--audio-device",
        default=None,
        help="temporarily use this CoreAudio device as both Mac output and input while --audio-file plays. "
        "A loopback such as 'BlackHole 2ch' makes the test deterministic; the original defaults are restored.",
    )
    args = parser.parse_args()
    simulator, simulator_version = resolve_simulator(args.simulator, parser)
    test_target = TEST_CLASS + (f"/{args.only_test}" if args.only_test else "")
    audio_file = Path(args.audio_file).expanduser().resolve() if args.audio_file else None
    if audio_file is not None and not audio_file.is_file():
        parser.error(f"audio file does not exist: {audio_file}")
    if args.audio_device and audio_file is None:
        parser.error("--audio-device requires --audio-file")
    ssh_key = Path(args.ssh_key).expanduser().resolve() if args.ssh_key else None
    if ssh_key is not None:
        try:
            key_data = ssh_key.read_bytes()
        except OSError as error:
            parser.error(f"SSH key cannot be read: {ssh_key}: {error}")
        if not key_data:
            parser.error(f"SSH key is empty: {ssh_key}")
        if not args.ssh_host:
            parser.error("--ssh-key requires --ssh-host")
    if audio_file is not None and simulator_version[:2] == (26, 5):
        print(
            "warning: the installed iOS 26.5 Simulator runtime currently fails every SFSpeechRecognizer request "
            "with kLSRErrorDomain 300. Keep simulator UI coverage here, but use a physical device for required "
            "real Apple Speech evidence until Apple fixes the current simulator runtime.",
            file=sys.stderr,
        )

    import os

    binary = args.binary
    if binary is None:
        # Same target directory and same invocation as scripts/smoke.py, so the two share a build rather than
        # each paying for their own and possibly testing different daemons.
        built = Path("/tmp/opaw-smoke/debug/openpaw-host")
        if not built.exists():
            print("building openpaw-host…")
            build = subprocess.run(
                ["cargo", "build", "-p", "openpaw-host"],
                cwd=REPO / "host",
                env=dict(os.environ, CARGO_TARGET_DIR="/tmp/opaw-smoke"),
            )
            if build.returncode != 0:
                print("build failed", file=sys.stderr)
                return 1
        binary = str(built)

    root = Path(tempfile.mkdtemp(prefix="openpaw-ui-live-"))
    daemon: subprocess.Popen[str] | None = None
    audio_defaults: dict[str, str] | None = None
    try:
        home = build_home(root)
        repo = build_repo(root)
        state = root / "state"
        state.mkdir()
        port = free_port()
        (state / "config.toml").write_text(
            f'bind = "127.0.0.1"\nport = {port}\nrepos = ["{repo}"]\nsession_max_age_days = 36500\n'
        )

        env = dict(os.environ, HOME=str(home), OPENPAW_STATE_DIR=str(state), RUST_LOG="info,openpaw_host=debug")
        daemon = subprocess.Popen(
            [binary, "serve"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        lines: list[str] = []
        threading.Thread(
            target=lambda: [lines.append(line.rstrip()) for line in daemon.stdout or []], daemon=True
        ).start()

        # Wait for it to bind, so the app is not handed a port nothing is listening on.
        import urllib.request

        deadline = time.time() + 30
        ready = False
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=1) as r:
                    if r.status == 200:
                        ready = True
                        break
            except Exception:
                if daemon.poll() is not None:
                    print("daemon exited early:\n" + "\n".join(lines), file=sys.stderr)
                    return 1
                time.sleep(0.2)
        if not ready:
            print("daemon never became healthy", file=sys.stderr)
            return 1

        code_run = subprocess.run([binary, "pairing-code"], env=env, capture_output=True, text=True)
        labelled = re.search(r"Pairing code:\s*(\S+)", code_run.stdout)
        rest = [line.strip() for line in code_run.stdout.splitlines() if line.strip()]
        code = labelled.group(1) if labelled else (rest[-1] if rest else "")
        if not code:
            print("no pairing code:\n" + code_run.stdout + code_run.stderr, file=sys.stderr)
            return 1

        print(f"daemon on 127.0.0.1:{port}, pairing code issued")

        def paired_devices() -> int:
            """How many devices the daemon has written into its own `state.json`.

            Read before and after, because otherwise this script cannot tell two very different outcomes apart:
            the app paired and then found no session to show, or the app never reached the daemon at all. Both
            end in the same skipped test. The daemon recording a device is the evidence that the launch arguments
            were honoured and that the app's real client, with a real signer, completed a real pairing.
            """
            try:
                return len(json.loads((state / "state.json").read_text()).get("devices", []))
            except (OSError, ValueError):
                return 0

        before = paired_devices()

        runner_ssh: dict[str, str] = {}
        if args.ssh_host:
            runner_ssh["TEST_RUNNER_OPENPAW_UITEST_SSH_HOST"] = args.ssh_host
            if ssh_key is not None:
                runner_ssh["TEST_RUNNER_OPENPAW_UITEST_SSH_KEY"] = str(ssh_key)
        else:
            print(
                "no --ssh-host: the app will pair but stay without a session, so the hold test will report that "
                "it could not reach the composer. See this file's docstring."
            )

        runner_audio: dict[str, str] = {}
        audio_markers: list[Path] = []
        if audio_file is not None:
            ready = Path(f"/tmp/openpaw-ui-audio-{port}.ready")
            done = Path(f"/tmp/openpaw-ui-audio-{port}.done")
            transcript = Path("/tmp/dictation-ui-live-transcript.txt")
            audio_markers = [ready, done]
            for path in [ready, done, transcript]:
                path.unlink(missing_ok=True)
            runner_audio = {
                "TEST_RUNNER_OPENPAW_UITEST_AUDIO_READY": str(ready),
                "TEST_RUNNER_OPENPAW_UITEST_AUDIO_DONE": str(done),
                "TEST_RUNNER_OPENPAW_UITEST_AUDIO_TRANSCRIPT": str(transcript),
            }

            if args.audio_device:
                current = subprocess.run(
                    ["swift", str(CORE_AUDIO_ROUTE), "status"], capture_output=True, text=True
                )
                if current.returncode != 0:
                    print("could not read CoreAudio defaults: " + current.stderr.strip(), file=sys.stderr)
                    return 1
                try:
                    audio_defaults = json.loads(current.stdout)
                except (TypeError, ValueError):
                    print("CoreAudio helper returned invalid status: " + current.stdout.strip(), file=sys.stderr)
                    return 1
                routed = subprocess.run(
                    ["swift", str(CORE_AUDIO_ROUTE), "set-all", args.audio_device],
                    capture_output=True,
                    text=True,
                )
                if routed.returncode != 0:
                    print(
                        f"could not route audio through {args.audio_device}: " + routed.stderr.strip(),
                        file=sys.stderr,
                    )
                    return 1
                print(f"temporarily routing Mac input and output through {args.audio_device}")
            def play_when_listening() -> None:
                # The marker is written only after the UI has changed from Start to Stop dictation. Waiting for it
                # is what makes this real audio evidence rather than audio played hopefully during app launch.
                deadline = time.time() + 180
                while time.time() < deadline and not ready.exists():
                    time.sleep(0.1)
                if not ready.exists():
                    print("audio graph never armed; no audio was played", file=sys.stderr)
                    return
                time.sleep(0.75)
                played = subprocess.run(["afplay", str(audio_file)], capture_output=True, text=True)
                if played.returncode != 0:
                    print("afplay failed: " + played.stderr.strip(), file=sys.stderr)
                    return
                # Let the last buffers leave CoreAudio before telling the test it can stop the recogniser.
                time.sleep(0.75)
                done.write_text("done\n")

            threading.Thread(target=play_when_listening, daemon=True).start()

        # `-only-testing` keeps this to the dictation file; the rest of OpenPawUITests wants a different world.
        result = subprocess.run(
            [
                "xcodebuild", "test",
                "-project", "OpenPaw.xcodeproj",
                "-scheme", "OpenPaw",
                "-destination", f"id={simulator}",
                "-derivedDataPath", "/tmp/openpaw-dd",
                "-skipPackagePluginValidation", "-skipMacroValidation",
                f"-only-testing:{test_target}",
            ],
            cwd=REPO / "apps" / "ios",
            capture_output=True,
            text=True,
            # `TEST_RUNNER_`-prefixed variables in xcodebuild's own environment are the documented way to reach
            # the UI test runner's process: xcodebuild strips the prefix and injects the rest. Passing them as
            # build settings on the command line sets them on xcodebuild instead, where the test cannot see them,
            # and the symptom is a test that skips as though no daemon were running at all.
            env=dict(
                os.environ,
                TEST_RUNNER_OPENPAW_UITEST_DIRECT_PORT=str(port),
                TEST_RUNNER_OPENPAW_UITEST_PAIRING_CODE=code,
                **runner_ssh,
                **runner_audio,
            ),
        )
        raw = Path("/tmp/dictation-ui-live.log")
        raw.write_text(result.stdout + "\n=== stderr ===\n" + result.stderr)
        for line in result.stdout.splitlines():
            if re.search(r"Test Case .*(passed|failed|skipped)|\*\* TEST|error:", line):
                print(line)
        print(f"full log: {raw}")
        transcript = Path("/tmp/dictation-ui-live-transcript.txt")
        if audio_file is not None and transcript.exists():
            print("real audio transcript: " + transcript.read_text().strip())

        # Whatever the app wrote about a failed pairing, surfaced here rather than left inside the container.
        # Digging this out by hand cost an afternoon: the visible symptom is a test that skips, and the cause was
        # a spent single-use pairing code, then a dead port from a previous run. Neither is visible from outside.
        try:
            container = subprocess.run(
                ["xcrun", "simctl", "get_app_container", simulator, "dev.openpaw.app", "data"],
                capture_output=True,
                text=True,
                timeout=30,
            ).stdout.strip()
            reported = Path(container) / "tmp" / "pairing-error.txt" if container else None
            if reported is not None and reported.exists():
                print(f"the app reported a pairing failure: {reported.read_text().strip()}", file=sys.stderr)
                # The daemon's side of the same moment, which says whether the request arrived at all.
                print("daemon said:\n  " + "\n  ".join(lines[-25:]), file=sys.stderr)
                reported.unlink()
        except (OSError, subprocess.SubprocessError):
            pass

        gained = paired_devices() - before
        if gained > 0:
            print(f"the app paired for real: the daemon registered {gained} new device(s)")
        else:
            # Not fatal on its own, but it means everything above ran without the app ever reaching the daemon,
            # so any test that passed did so without the live backend this script exists to provide.
            print(
                "WARNING: the daemon registered no new device, so the app did not pair. The launch arguments are "
                "not reaching it (they must be TEST_RUNNER_-prefixed in xcodebuild's own environment).",
                file=sys.stderr,
            )
        if result.returncode != 0:
            print(result.stderr[-2000:], file=sys.stderr)
        for marker in audio_markers:
            marker.unlink(missing_ok=True)
        return result.returncode
    finally:
        if audio_defaults is not None:
            restored = subprocess.run(
                [
                    "swift",
                    str(CORE_AUDIO_ROUTE),
                    "restore",
                    audio_defaults["inputUID"],
                    audio_defaults["outputUID"],
                    audio_defaults["systemOutputUID"],
                ],
                capture_output=True,
                text=True,
            )
            if restored.returncode != 0:
                print("WARNING: could not restore CoreAudio defaults: " + restored.stderr.strip(), file=sys.stderr)
            else:
                print("restored the original Mac audio input and output")
        if daemon is not None:
            try:
                daemon.terminate()
            except Exception:
                pass
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
