#!/usr/bin/env bash
#
# Type-checks the iOS app target without Xcode. It exists because `xcodebuild` cannot run on a machine whose Xcode
# first-launch system content is stale, and because no iOS simulator runtime is installed here — but the iOS SDK is,
# and `swiftc` needs neither. `xcodebuild` remains the real gate in CI, where first-launch content is intact.
#
# Steps: build the four local Swift packages plus SwiftTerm for arm64-apple-ios17.0-simulator, type-check every file in
# OpenPawApp against those modules under Swift 6 language mode, then validate the hand-written project file.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
APP_DIR="$PWD"
REPO_ROOT="$(cd ../.. && pwd)"

TRIPLE="arm64-apple-ios17.0-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TOOLCHAIN_BIN="$(dirname "$(xcrun -f swiftc)")"
WORK="${OPENPAW_TYPECHECK_DIR:-${TMPDIR:-/tmp}/openpaw-typecheck-ios}"

mkdir -p "$WORK"

echo "==> iOS SDK:  $SDK"
echo "==> triple:   $TRIPLE"
echo "==> scratch:  $WORK"

# ---------------------------------------------------------------------------
# 1. Cross-compilation destination.
#
# SwiftPM's `--triple`/`--sdk` pair cannot be used here: `--sdk` is applied to the *manifest* build too, and a
# Package.swift cannot be compiled against the iOS SDK ("unable to load standard library for target
# arm64-apple-macosx14.0"). A destination file keeps the host toolchain for the manifest and the iOS SDK for the
# targets, which is the only combination that works.
# ---------------------------------------------------------------------------
DEST="$WORK/ios-simulator.json"
cat > "$DEST" <<JSON
{
  "version": 1,
  "sdk": "$SDK",
  "toolchain-bin-dir": "$TOOLCHAIN_BIN",
  "target": "$TRIPLE",
  "extra-cc-flags": ["-isysroot", "$SDK", "-target", "$TRIPLE"],
  "extra-swiftc-flags": ["-sdk", "$SDK", "-target", "$TRIPLE"],
  "extra-cpp-flags": ["-isysroot", "$SDK"]
}
JSON

# ---------------------------------------------------------------------------
# 2. A harness package that depends on everything the app links.
#
# Building the four packages one at a time would produce four unrelated module caches and would not build SwiftTerm at
# all. One package that imports all five makes SwiftPM resolve SwiftTerm, run its build-tool plugin, and emit every
# .swiftmodule the app needs into a single directory.
# ---------------------------------------------------------------------------
HARNESS="$WORK/harness"
mkdir -p "$HARNESS/Sources/Harness"
cat > "$HARNESS/Package.swift" <<SWIFT
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Harness", targets: ["Harness"])],
    dependencies: [
        .package(path: "$REPO_ROOT/packages/swift-agent-protocol"),
        .package(path: "$REPO_ROOT/packages/swift-terminal-core"),
        .package(path: "$REPO_ROOT/packages/swift-ssh-transport"),
        .package(path: "$REPO_ROOT/packages/swift-openpaw-ui"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        .target(
            name: "Harness",
            dependencies: [
                .product(name: "OpenPawProtocol", package: "swift-agent-protocol"),
                .product(name: "OpenPawTerminalCore", package: "swift-terminal-core"),
                .product(name: "OpenPawSSH", package: "swift-ssh-transport"),
                .product(name: "OpenPawUI", package: "swift-openpaw-ui"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        )
    ]
)
SWIFT
cat > "$HARNESS/Sources/Harness/Imports.swift" <<'SWIFT'
// Forces SwiftPM to build every module the app links. Nothing else lives here.
@_exported import OpenPawProtocol
@_exported import OpenPawSSH
@_exported import OpenPawTerminalCore
@_exported import OpenPawUI
@_exported import SwiftTerm
SWIFT

echo "==> building dependency modules for $TRIPLE"
( cd "$HARNESS" && swift build \
    --scratch-path "$WORK/build" \
    --destination "$DEST" )

MODULES="$WORK/build/arm64-apple-ios-simulator/debug/Modules"
if [ ! -d "$MODULES" ]; then
  echo "error: expected built modules at $MODULES" >&2
  exit 1
fi
echo "==> modules: $(ls "$MODULES"/*.swiftmodule 2>/dev/null | wc -l | tr -d ' ') found"

# NIO and swift-crypto expose C targets (CNIOAtomics, _AtomicsShims, CCryptoBoringSSL, …). Clang finds those only
# through the `module.modulemap` SwiftPM generates beside each one, so every directory containing one goes on the
# header search path. Restricted to the iOS build tree and the checkouts: the macOS build tree also contains
# modulemaps for SwiftTerm's build-tool plugin, and including those redefines `ArgumentParser`.
CLANG_ARGS=()
while IFS= read -r modulemap; do
  CLANG_ARGS+=(-Xcc "-I$(dirname "$modulemap")")
done < <(find "$WORK/build/arm64-apple-ios-simulator" "$WORK/build/checkouts" -name module.modulemap 2>/dev/null)
echo "==> C module maps: $(( ${#CLANG_ARGS[@]} / 2 ))"

# ---------------------------------------------------------------------------
# 3. Type-check the app target.
#
# All files at once, because they are one module and cross-file references have to resolve. `-typecheck` rather than a
# full compile: there is nothing to link against on this machine, and every error the app can have that xcodebuild
# would report is a type-check error.
# ---------------------------------------------------------------------------
echo "==> type-checking OpenPawApp"
set -x
xcrun swiftc \
  -typecheck \
  -swift-version 6 \
  -target "$TRIPLE" \
  -sdk "$SDK" \
  -module-name OpenPawApp \
  -I "$MODULES" \
  "${CLANG_ARGS[@]}" \
  "$APP_DIR"/OpenPawApp/*.swift
set +x

# ---------------------------------------------------------------------------
# 4. Validate the hand-written project file.
#
# The pbxproj is authored by hand, so nothing regenerates it and nothing else notices when an object reference goes
# dangling. This catches that without Xcode.
# ---------------------------------------------------------------------------
echo "==> validating OpenPaw.xcodeproj/project.pbxproj"
plutil -lint "$APP_DIR/OpenPaw.xcodeproj/project.pbxproj" > /dev/null
python3 - "$APP_DIR/OpenPaw.xcodeproj/project.pbxproj" <<'PY'
import json, re, subprocess, sys

path = sys.argv[1]
raw = subprocess.run(
    ["plutil", "-convert", "json", "-o", "-", path],
    capture_output=True, text=True, check=True,
).stdout
project = json.loads(raw)
objects = project["objects"]

identifier = re.compile(r"^[0-9A-F]{24}$")
referenced = set()


def walk(value):
    if isinstance(value, str):
        if identifier.match(value):
            referenced.add(value)
    elif isinstance(value, list):
        for item in value:
            walk(item)
    elif isinstance(value, dict):
        for item in value.values():
            walk(item)


walk(objects)
walk(project["rootObject"])

problems = []
dangling = sorted(referenced - set(objects))
orphaned = sorted(set(objects) - referenced)
if dangling:
    problems.append(f"dangling object references: {dangling}")
if orphaned:
    problems.append(f"objects referenced by nothing: {orphaned}")

root = objects.get(project["rootObject"])
if root is None or root["isa"] != "PBXProject":
    problems.append("rootObject is not a PBXProject")

targets = [objects[t]["name"] for t in root.get("targets", [])]
if sorted(targets) != ["OpenPaw", "OpenPawAppTests"]:
    problems.append(f"unexpected targets: {targets}")

products = {
    objects[d]["productName"]
    for d in objects
    if objects[d]["isa"] == "XCSwiftPackageProductDependency"
}
expected = {"OpenPawProtocol", "OpenPawTerminalCore", "OpenPawSSH", "OpenPawUI", "SwiftTerm"}
if products != expected:
    problems.append(f"package products are {sorted(products)}, expected {sorted(expected)}")

app = next(objects[t] for t in root["targets"] if objects[t]["name"] == "OpenPaw")
if app["productType"] != "com.apple.product-type.application":
    problems.append(f"OpenPaw is a {app['productType']}")

if problems:
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    sys.exit(1)

print(
    f"    {len(objects)} objects, objectVersion {project['objectVersion']}, "
    f"targets {sorted(targets)}, no dangling or orphaned references"
)
PY

echo
echo "OK — OpenPawApp type-checks for $TRIPLE under Swift 6, and the project file is consistent."
