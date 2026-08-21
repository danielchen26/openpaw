# OpenPaw ET Transport Foundation

This package is an isolated, non-production foundation for Eternal Terminal protocol-v6 experiments. It is not wired into the app, UI, SSH session code, Tailscale, or voice flows.

## Upstream reference and attribution

Interoperability constants and wire-shape tests were derived by reading Eternal Terminal at `/Users/tianchichen/.jcode/scratch/openpaw-transport-upstreams.Ky1nOI/EternalTerminal`, pinned to `b74a12efc567dbc1360ac0846f889c945a2eba60`.

Reference files consulted: `proto/ET.proto`, `proto/ETerminal.proto`, `src/base/Packet.hpp`, `src/base/SocketHandler.cpp`, `src/base/CryptoHandler.cpp`, `src/base/BackedReader.cpp`, and `src/base/BackedWriter.cpp`.

No GPL Mosh code was copied. This package contains a clean Swift implementation of the minimal codecs, framing, crypto sequencing, replay bookkeeping, and SSH bootstrap model needed for future interop work.

## Dependency SBOM and license notes

- `swift-sodium` `0.11.0`, GitHub `jedisct1/swift-sodium`, ISC license. Used for libsodium `crypto_secretbox_easy` compatible XSalsa20-Poly1305 sealed boxes.
- Transitive native libsodium from swift-sodium, ISC license.

The package manifest pins `swift-sodium` exactly to avoid silent crypto implementation drift.

## Explicit non-goals and gates

This package does not claim production Eternal Terminal support. Remaining gates are real upstream `etserver` interoperability, reconnect-capable network transport, app integration, and physical-device lifecycle validation.
