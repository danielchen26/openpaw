#!/usr/bin/env python3
"""Reject signing and unrelated build-setting changes in a project.pbxproj patch."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


PROJECT_PATH = Path("apps/ios/OpenPaw.xcodeproj/project.pbxproj")
ASSIGNMENT_PATTERN = re.compile(
    r'(?:^|[;{])\s*(?:'
    r'"(?P<quoted>[^"\r\n]+)"|'
    r'(?P<object>[A-F0-9]{4,32})(?:\s*/\*[^*\r\n]*\*/)?|'
    r'(?P<bare>[A-Za-z][A-Za-z0-9_.-]*(?:\[[^\]\r\n]+\])?)'
    r")\s*="
)
SENSITIVE_PATTERN = re.compile(
    r"\b(?:DEVELOPMENT_TEAM|DevelopmentTeam|CODE_SIGN[A-Z0-9_\[\]=*.-]*|"
    r"PROVISIONING_PROFILE[A-Z0-9_]*)\b"
)
STRUCTURAL_ASSIGNMENTS = {
    "archiveVersion",
    "buildActionMask",
    "buildConfigurationList",
    "buildPhases",
    "buildRules",
    "buildSettings",
    "children",
    "compatibilityVersion",
    "containerPortal",
    "defaultConfigurationIsVisible",
    "defaultConfigurationName",
    "dependencies",
    "developmentRegion",
    "explicitFileType",
    "fileEncoding",
    "fileRef",
    "files",
    "frameworksBuildPhase",
    "hasScannedForEncodings",
    "includeInIndex",
    "isa",
    "knownRegions",
    "lastKnownFileType",
    "mainGroup",
    "name",
    "objects",
    "packageProductDependencies",
    "packageReferences",
    "path",
    "productName",
    "productRefGroup",
    "productReference",
    "productType",
    "projectDirPath",
    "projectRoot",
    "remoteGlobalIDString",
    "remoteInfo",
    "runOnlyForDeploymentPostprocessing",
    "sourceTree",
    "sourcesBuildPhase",
    "target",
    "targetProxy",
    "targets",
}


def changed_content_lines(diff: str):
    for line_number, line in enumerate(diff.splitlines(), start=1):
        if line.startswith(("+++", "---")) or not line.startswith(("+", "-")):
            continue
        yield line_number, line[1:]


def validate(diff: str) -> list[str]:
    errors: list[str] = []
    for line_number, content in changed_content_lines(diff):
        sensitive = SENSITIVE_PATTERN.search(content)
        if sensitive is not None:
            errors.append(
                f"line {line_number}: staged project diff changes forbidden signing setting "
                f"{sensitive.group(0)}"
            )
            continue

        for assignment in ASSIGNMENT_PATTERN.finditer(content):
            if assignment.group("object") is not None:
                continue
            raw_key = assignment.group("quoted") or assignment.group("bare")
            key = re.sub(r"\[[^\]]+\]$", "", raw_key)
            if key in STRUCTURAL_ASSIGNMENTS:
                continue
            errors.append(
                f"line {line_number}: staged project diff changes unrelated build setting {key}"
            )
    return errors


def staged_diff(repo_root: Path) -> str:
    result = subprocess.run(
        [
            "git",
            "diff",
            "--cached",
            "--no-ext-diff",
            "--unified=0",
            "--",
            str(PROJECT_PATH),
        ],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise RuntimeError(f"could not inspect staged project diff: {detail}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--staged", action="store_true")
    source.add_argument("--diff-file", type=Path)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()

    try:
        if args.staged:
            diff = staged_diff(args.repo_root)
        else:
            diff = args.diff_file.read_text(encoding="utf-8")
    except (OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        return 2

    errors = validate(diff)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
