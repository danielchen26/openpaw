import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ios-test-destination.py"


class IOSTestDestinationTests(unittest.TestCase):
    def run_selector(self, payload: object) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as fixture:
            json.dump(payload, fixture)
            fixture_path = Path(fixture.name)
        try:
            return subprocess.run(
                ["python3", str(SCRIPT), "--input", str(fixture_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            fixture_path.unlink(missing_ok=True)

    def test_selects_a_phone_from_the_newest_available_runtime(self) -> None:
        result = self.run_selector(
            {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                        {
                            "name": "iPhone 17 Pro",
                            "udid": "OLD-PHONE",
                            "state": "Booted",
                            "isAvailable": True,
                        }
                    ],
                    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                        {
                            "name": "iPad Pro 13-inch",
                            "udid": "NEW-IPAD",
                            "state": "Booted",
                            "isAvailable": True,
                        },
                        {
                            "name": "iPhone 17",
                            "udid": "NEW-PHONE",
                            "state": "Shutdown",
                            "isAvailable": True,
                        },
                    ],
                }
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "platform=iOS Simulator,id=NEW-PHONE")

    def test_accepts_an_available_shutdown_phone(self) -> None:
        result = self.run_selector(
            {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                        {
                            "name": "iPhone 18",
                            "udid": "SHUTDOWN-PHONE",
                            "state": "Shutdown",
                            "isAvailable": True,
                        }
                    ]
                }
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SHUTDOWN-PHONE", result.stdout)

    def test_ignores_unavailable_and_malformed_entries(self) -> None:
        result = self.run_selector(
            {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                        {
                            "name": "iPhone Unavailable",
                            "udid": "NOPE",
                            "state": "Shutdown",
                            "isAvailable": False,
                        },
                        {"name": "iPhone Missing ID", "state": "Booted", "isAvailable": True},
                        {
                            "name": "iPhone Bad State",
                            "udid": "BAD-STATE",
                            "state": "Creating",
                            "isAvailable": True,
                        },
                    ],
                    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                        {
                            "name": "iPad mini",
                            "udid": "VALID-IPAD",
                            "state": "Shutdown",
                            "isAvailable": True,
                        }
                    ],
                    "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [
                        {
                            "name": "Apple Watch",
                            "udid": "WATCH",
                            "state": "Booted",
                            "isAvailable": True,
                        }
                    ],
                }
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "platform=iOS Simulator,id=VALID-IPAD")

    def test_fails_when_no_valid_ios_destination_exists(self) -> None:
        result = self.run_selector({"devices": {}})

        self.assertEqual(result.returncode, 2)
        self.assertIn("no available iOS Simulator", result.stderr)

    def test_fails_on_a_malformed_top_level_shape(self) -> None:
        result = self.run_selector({"devices": []})

        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid simctl JSON", result.stderr)


if __name__ == "__main__":
    unittest.main()
