import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "quick-pairing-live.py"


def load_harness():
    spec = importlib.util.spec_from_file_location("quick_pairing_live", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load quick-pairing-live.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class QuickPairingLiveContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.harness = load_harness()

    def test_selects_newest_installed_phone_and_honors_an_explicit_udid(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                    {"name": "iPhone 17", "udid": "OLD", "state": "Booted", "isAvailable": True}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    {"name": "iPad Pro", "udid": "IPAD", "state": "Booted", "isAvailable": True},
                    {"name": "iPhone 17 Pro", "udid": "NEW", "state": "Shutdown", "isAvailable": True},
                ],
            }
        }

        self.assertEqual(self.harness.select_simulator(payload).udid, "NEW")
        self.assertEqual(self.harness.select_simulator(payload, requested="OLD").udid, "OLD")

    def test_requires_an_external_jcode_scratch_directory(self) -> None:
        with self.assertRaisesRegex(self.harness.HarnessError, "JCODE_SCRATCH_DIR"):
            self.harness.resolve_scratch_root({}, REPO_ROOT)

        with self.assertRaisesRegex(self.harness.HarnessError, "outside the repository"):
            self.harness.resolve_scratch_root(
                {"JCODE_SCRATCH_DIR": str(REPO_ROOT / ".scratch")}, REPO_ROOT
            )

        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                self.harness.resolve_scratch_root({"JCODE_SCRATCH_DIR": directory}, REPO_ROOT),
                Path(directory).resolve(),
            )

    def test_redacts_all_secret_classes_and_the_secret_bearing_url(self) -> None:
        secrets = self.harness.SecretSet(
            private_key="PRIVATE-KEY-MATERIAL",
            hook_token="hook-token-value",
            pairing_code="ABCD-EFGH-IJKL-MNOP-QRST-UVWX",
            bearer_token="returned-bearer-token",
            hmac_key="returned-hmac-key",
            pairing_url="openpaw://pair#v1.secret-envelope",
        )
        text = "\n".join(
            [
                secrets.private_key,
                secrets.hook_token,
                secrets.pairing_code,
                secrets.bearer_token,
                secrets.hmac_key,
                secrets.pairing_url,
            ]
        )

        redacted = self.harness.redact(text, secrets)

        for value in secrets.values():
            self.assertNotIn(value, redacted)
        self.assertNotIn("openpaw://pair#", redacted)
        self.assertGreaterEqual(redacted.count("<redacted>"), 6)

    def test_builds_disposable_user_sshd_with_only_scratch_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            layout = self.harness.ScratchLayout.create(root / "run")
            config = self.harness.render_sshd_config(layout, port=49152, username="tester")

            self.assertIn("ListenAddress 127.0.0.1", config)
            self.assertIn("Port 49152", config)
            self.assertIn(f"HostKey {layout.ssh_host_key}", config)
            self.assertIn(f"AuthorizedKeysFile {layout.authorized_keys}", config)
            self.assertIn(f"PidFile {layout.sshd_pid}", config)
            self.assertIn("PasswordAuthentication no", config)
            self.assertIn("PermitRootLogin no", config)
            self.assertNotIn(str(REPO_ROOT), config)

    def test_xcuitest_command_uses_dynamic_simulator_and_scratch_derived_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            command = self.harness.xcuitest_command("SIM-UDID", root / "DerivedData")

        joined = " ".join(command)
        self.assertIn("-destination id=SIM-UDID", joined)
        self.assertIn("-derivedDataPath", command)
        self.assertIn(str(root / "DerivedData"), command)
        self.assertIn(self.harness.LIVE_TEST_TARGET, joined)
        self.assertNotIn("openpaw://", joined)

    def test_live_test_environment_contains_paths_and_coordination_only(self) -> None:
        environment = self.harness.live_test_environment(
            base={"PATH": os.environ.get("PATH", "")},
            host="127.0.0.1",
            port=49152,
            host_api_port=49154,
            username="tester",
            nickname="Disposable Mac",
            private_key_path=Path("/scratch/id_ed25519"),
            coordination_port=49153,
        )

        expected = {
            "TEST_RUNNER_OPENPAW_LIVE_HOST",
            "TEST_RUNNER_OPENPAW_LIVE_PORT",
            "TEST_RUNNER_OPENPAW_LIVE_HOST_API_PORT",
            "TEST_RUNNER_OPENPAW_LIVE_USER",
            "TEST_RUNNER_OPENPAW_LIVE_NICKNAME",
            "TEST_RUNNER_OPENPAW_LIVE_KEY",
            "TEST_RUNNER_OPENPAW_QUICK_PAIRING_COORDINATION_PORT",
        }
        self.assertTrue(expected.issubset(environment))
        serialized = json.dumps(environment)
        self.assertNotIn("OPENPAW_QUICK_PAIRING_URL", serialized)
        self.assertNotIn("PAIRING_CODE", serialized)
        self.assertEqual(self.harness.LIVE_NICKNAME, "127")

    def test_coordination_issues_and_opens_the_link_only_when_ready_after_build_start(self) -> None:
        events = []
        secrets = self.harness.SecretSet()
        secret_url = "openpaw://pair#v1.secret-envelope"

        def issue_link():
            events.append("link-issued")
            secrets.pairing_url = secret_url
            secrets.pairing_code = "SECRET-PAIRING-CODE"
            return secret_url

        server = self.harness.CoordinationServer(0, "SIM-UDID", issue_link, secrets)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        events.append("xcodebuild-started")
        self.assertEqual(events, ["xcodebuild-started"])

        completed = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(self.harness.subprocess, "run", return_value=completed) as run:
            response = urllib.request.urlopen(
                f"http://127.0.0.1:{server.server_port}/ready", timeout=5
            )
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read().decode(), secret_url)
            duplicate = urllib.request.urlopen(
                f"http://127.0.0.1:{server.server_port}/ready", timeout=5
            )
            self.assertEqual(duplicate.status, 200)
            self.assertEqual(duplicate.read().decode(), secret_url)

        self.assertEqual(events, ["xcodebuild-started", "link-issued"])
        run.assert_called_once_with(
            ["xcrun", "simctl", "openurl", "SIM-UDID", secret_url],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertIn("/ready", server.events)

    def test_coordination_factory_failure_is_redacted_stable_and_not_retried(self) -> None:
        secret_url = "openpaw://pair#v1.secret-envelope"
        attempts = 0

        def fail_to_issue():
            nonlocal attempts
            attempts += 1
            raise self.harness.HarnessError(f"issuer leaked {secret_url}")

        server = self.harness.CoordinationServer(
            0, "SIM-UDID", fail_to_issue, self.harness.SecretSet()
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        for _ in range(2):
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{server.server_port}/ready", timeout=5
                )
            self.assertEqual(raised.exception.code, 500)

        self.assertEqual(attempts, 1)
        self.assertNotIn(secret_url, server.failure or "")
        self.assertIn("<redacted>", server.failure or "")
        self.assertNotIn("/ready", server.events)

    def test_cleanup_terminates_registered_children_and_removes_the_run_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            run_root = Path(directory) / "run"
            run_root.mkdir()
            registry = self.harness.CleanupRegistry(run_root)
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            registry.register(child)

            registry.cleanup()

            self.assertIsNotNone(child.poll())
            self.assertFalse(run_root.exists())
            self.assertTrue(registry.cleaned)

    def test_replay_request_rejects_the_consumed_pairing_code(self) -> None:
        class Client:
            def json(self, method, path, body):
                self.request = (method, path, body)
                return 403, {"error": "forbidden"}

        client = Client()
        self.harness.assert_pairing_replay_rejected(client, "PAIRING-CODE")
        self.assertEqual(client.request[0:2], ("POST", "/v1/pair"))

    def test_harness_source_contains_real_local_acceptance_steps(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        required = [
            "ssh-keygen",
            "sshd",
            "openpaw-host",
            "pair",
            "--qr",
            "simctl",
            "openurl",
            "/v1/pair",
            "Trust this host key and continue connecting",
            "Confirm SSH credential and connect",
            "real SSH connected",
            "real pairing redeemed once",
            "signer persisted for the selected host",
            "Terminal selected",
            "pairing-code replay rejected",
        ]
        for phrase in required:
            self.assertIn(phrase, source)

    def test_generated_live_test_seeds_the_host_through_the_existing_app_hook(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('"-openpaw-debug-seed-key", keyPath', source)
        self.assertIn('"-openpaw-debug-ssh-host", "\\(username)@\\(host):\\(port)"', source)
        self.assertIn('"-openpaw-debug-direct-port", hostAPIPort', source)
        self.assertIn('"-openpaw-debug-pairing-code", "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"', source)
        self.assertNotIn('app.textFields["Port"]', source)
        self.assertNotIn('app.buttons["Enter SSH details manually"]', source)

    def test_generated_live_test_opens_the_ready_link_through_xctest_without_printing_it(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('func pairingURL() -> URL', source)
        self.assertIn('app.open(pairingURL())', source)
        self.assertNotIn('XCUIApplication(bundleIdentifier: "com.apple.springboard")', source)

    def test_xcodebuild_is_registered_for_signal_cleanup_and_failures_report_checkpoints(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("xcodebuild = cleanup.register(", source)
        self.assertIn("coordination checkpoints reached", source)
        self.assertIn("persisted host device count", source)
        self.assertIn("if coordinator is not None:", source)


if __name__ == "__main__":
    unittest.main()
