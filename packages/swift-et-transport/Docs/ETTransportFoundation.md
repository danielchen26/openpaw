# OpenPaw ET Transport Foundation

This package is an isolated, non-production foundation for Eternal Terminal protocol-v6 experiments. It is not wired into the app, UI, SSH session code, Tailscale, or voice flows.

## Upstream reference and attribution

Interoperability constants and wire-shape tests were derived by reading Eternal Terminal at `/Users/tianchichen/.jcode/scratch/openpaw-transport-upstreams.Ky1nOI/EternalTerminal`, pinned to `b74a12efc567dbc1360ac0846f889c945a2eba60`.

Reference files consulted: `proto/ET.proto`, `proto/ETerminal.proto`, `src/base/Packet.hpp`, `src/base/SocketHandler.cpp`, `src/base/CryptoHandler.cpp`, `src/base/BackedReader.cpp`, and `src/base/BackedWriter.cpp`.

No GPL Mosh code was copied. This package contains a clean Swift implementation of the minimal codecs, framing, crypto sequencing, replay bookkeeping, and SSH bootstrap model needed for future interop work.

## Dependency SBOM and license notes

- `swift-sodium` `0.11.0`, GitHub `jedisct1/swift-sodium`, ISC license. Used for libsodium `crypto_secretbox_easy` compatible XSalsa20-Poly1305 sealed boxes. Copyright and permission notice: swift-sodium and libsodium are distributed under the ISC license, permitting use, copy, modification, and distribution with the copyright and permission notice retained.
- Transitive native libsodium from swift-sodium, ISC license.

The package manifest pins `swift-sodium` exactly to avoid silent crypto implementation drift.

## Correction notes

The foundation intentionally keeps ET packet framing separate from upstream protobuf message framing. Encrypted ET packets use the reconnect stream's 4-byte network-order packet length, while Connect/Sequence/Catchup and lifecycle protobuf messages use upstream `writeProto`/`readProto` 8-byte host-endian length boundaries with bounded streaming decode. Replay stores full encrypted `ETPacket.serialize()` bytes exactly, evicts oldest packets only under connected upstream semantics, and tracks disconnected-byte caps separately until revive.

## Explicit non-goals and gates

This package does not claim production Eternal Terminal support. Remaining gates are real upstream `etserver` interoperability, reconnect-capable network transport, app integration, and physical-device lifecycle validation.
