#!/usr/bin/env python3
"""Print an xcodebuild destination for the newest usable iOS simulator."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


RUNTIME_PATTERN = re.compile(r"(?:^|\.)iOS-(\d+)-(\d+)(?:-(\d+))?$")
USABLE_STATES = {"Booted", "Shutdown"}


class DestinationError(ValueError):
    pass


def runtime_version(identifier: str) -> tuple[int, int, int] | None:
    match = RUNTIME_PATTERN.search(identifier)
    if match is None:
        return None
    return tuple(int(part or 0) for part in match.groups())


def select_destination(payload: Any) -> str:
    if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
        raise DestinationError("invalid simctl JSON: expected a devices object")

    candidates: list[tuple[tuple[int, int, int], bool, bool, str, str]] = []
    for runtime, devices in payload["devices"].items():
        if not isinstance(runtime, str) or not isinstance(devices, list):
            continue
        version = runtime_version(runtime)
        if version is None:
            continue
        for device in devices:
            if not isinstance(device, dict) or device.get("isAvailable") is not True:
                continue
            name = device.get("name")
            udid = device.get("udid")
            state = device.get("state")
            if not isinstance(name, str) or not name.strip():
                continue
            if not isinstance(udid, str) or not udid.strip():
                continue
            if state not in USABLE_STATES:
                continue
            candidates.append(
                (
                    version,
                    name.startswith("iPhone"),
                    state == "Booted",
                    name,
                    udid,
                )
            )

    if not candidates:
        raise DestinationError("no available iOS Simulator destination")

    selected = max(candidates)
    return f"platform=iOS Simulator,id={selected[-1]}"


def load_payload(input_path: Path | None) -> Any:
    if input_path is not None:
        try:
            return json.loads(input_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise DestinationError(f"invalid simctl JSON: {error}") from error

    try:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise DestinationError(f"could not run simctl: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise DestinationError(f"simctl failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise DestinationError(f"invalid simctl JSON: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, help="read captured simctl JSON from this file")
    args = parser.parse_args()

    try:
        print(select_destination(load_payload(args.input)))
    except DestinationError as error:
        print(error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
