import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "validate-pbxproj-diff.py"


class ValidatePBXProjDiffTests(unittest.TestCase):
    def run_diff(self, diff: str) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".diff", delete=False) as fixture:
            fixture.write(textwrap.dedent(diff))
            fixture_path = Path(fixture.name)
        try:
            return subprocess.run(
                ["python3", str(SCRIPT), "--diff-file", str(fixture_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            fixture_path.unlink(missing_ok=True)

    def test_accepts_structural_file_reference_and_build_phase_changes(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            --- a/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            +++ b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1,2 +1,4 @@
            +\t\tABCD /* DebugScenario.swift in Sources */ = {isa = PBXBuildFile; fileRef = EFGH /* DebugScenario.swift */; };
            +\t\tEFGH /* DebugScenario.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DebugScenario.swift; sourceTree = "<group>"; };
            +\t\t\t\tABCD /* DebugScenario.swift in Sources */,
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_structural_product_file_references(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            --- a/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            +++ b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1 +1 @@
            +\t\tABCDEF01 /* OpenPawUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = OpenPawUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_added_development_team(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1 +1 @@
            +\t\t\t\tDEVELOPMENT_TEAM = 2Z7U3AQV8D;
            """
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("DEVELOPMENT_TEAM", result.stderr)

    def test_rejects_removed_provisioning_profile(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1 +1 @@
            -\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = Personal;
            """
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("PROVISIONING_PROFILE_SPECIFIER", result.stderr)

    def test_rejects_unrelated_build_setting_changes(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1 +1 @@
            +\t\t\t\tSWIFT_VERSION = 6.0;
            """
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("SWIFT_VERSION", result.stderr)

    def test_rejects_quoted_conditional_build_setting_changes(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1 +1 @@
            +\t\t\t\t"SWIFT_VERSION[sdk=iphoneos*]" = 6.0;
            """
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("SWIFT_VERSION", result.stderr)

    def test_rejects_inline_build_setting_changes(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1 +1 @@
            +\t\t\tbuildSettings = { PRODUCT_BUNDLE_IDENTIFIER = com.evil.changed; };
            """
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER", result.stderr)

    def test_rejects_inline_signing_setting_changes(self) -> None:
        result = self.run_diff(
            """
            diff --git a/apps/ios/OpenPaw.xcodeproj/project.pbxproj b/apps/ios/OpenPaw.xcodeproj/project.pbxproj
            @@ -1 +1 @@
            +\t\t\tbuildSettings = { "CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "Apple Development"; };
            """
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("CODE_SIGN_IDENTITY", result.stderr)

    def test_staged_mode_reads_the_selected_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repo = Path(temporary_directory)
            project = repo / "apps" / "ios" / "OpenPaw.xcodeproj" / "project.pbxproj"
            project.parent.mkdir(parents=True)
            project.write_text("// project\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "tests@example.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "OpenPaw Tests"], cwd=repo, check=True)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repo, check=True)
            project.write_text("// project\n\t\t\t\tCODE_SIGN_STYLE = Automatic;\n", encoding="utf-8")
            subprocess.run(["git", "add", str(project.relative_to(repo))], cwd=repo, check=True)

            result = subprocess.run(
                ["python3", str(SCRIPT), "--staged", "--repo-root", str(repo)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("CODE_SIGN_STYLE", result.stderr)


if __name__ == "__main__":
    unittest.main()
