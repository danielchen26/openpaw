# Threat model

## What we are protecting

Your source code, your credentials, and the ability to make an agent do something destructive. The host runs
arbitrary code by design — that is the point of a coding agent — so the goal is not to sandbox the agent, it is to
make sure **only you** decide what it may do, and that a lost phone or a hostile network cannot decide for you.

## Assets

| Asset | Where it lives | Protection |
| --- | --- | --- |
| SSH private keys | iOS Keychain, `WhenUnlockedThisDeviceOnly`, non-exportable | biometric gate on export, never leaves the device, never written to the host |
| Device bearer token | Keychain on the phone; only its SHA-256 on the host | constant-time comparison, revocable per device |
| Device HMAC key | Keychain on the phone; raw on the host in `state.json` (0600) | signs every request; rotation supported |
| Hook token | `<state_dir>/hook-token`, 0600 | authenticates only the local hook ingress |
| Action tokens | daemon memory | single use, 10-minute TTL, bound to one inbox item |
| Source code and diffs | the host, only | read-only routes, allowlisted roots, canonicalized paths |

## Adversaries and what stops them

**A. Network attacker on the same Wi-Fi.** All traffic is inside SSH. The daemon has no non-loopback listener, so
there is nothing to reach even if the phone's tunnel is absent. Binding to a non-loopback address requires an
explicit `--i-understand-the-risk` flag and logs a warning.

**B. Attacker who steals the phone.** The Keychain items are `WhenUnlockedThisDeviceOnly`; the app gates on Face
ID / Touch ID; key export needs a fresh biometric check. Revoke the device on the host and its bearer token is
dead — the SSH key is separate and independently revocable via `authorized_keys`.

**C. Attacker who captures a push notification.** A notification carries an opaque session id, an event kind and a
one-line preview. It carries no command text, no diff, no transcript and no action token. Approving requires an
authenticated session, the tunnel, the item's one-time action token and, for dangerous actions, an explicit
acknowledgement that the full command was displayed. Push is a hint.

**D. Malicious or confused agent.** This is the interesting one. An agent can propose anything, so the daemon
classifies before you see it: eight risk buckets, highest-severity segment of a compound command wins, and
`requires_detail_expansion` forces the full text on screen before the button works for `rm`, `sudo`, credential
access, `git push --force`, production deploys, database mutations and secret changes. There is no
"approve everything" affordance, and `approve_always` is scoped to a tool plus risk class, never global.

**E. Attacker who reaches the daemon's port through a compromised local process.** They still need a paired
device's bearer token *and* its HMAC key, a timestamp inside a 300-second window and an unused nonce. Capabilities
are per device, so an `observer` token cannot approve, upload or proxy. Every mutating request is audited.

**F. Path traversal / symlink escape.** Client input never becomes a path directly: `Roots::resolve` rejects `..`,
absolute paths, NUL bytes and drive prefixes, then canonicalizes and re-checks containment by path components. A
symlink that escapes a root is listed (so the tree is honest) but never read through. `git` is invoked with `-C`,
`--no-optional-locks`, a `--` separator before any path, and revs validated against a conservative character set
so a rev can never be parsed as a flag.

**G. Replay and confused-deputy.** The canonical string binds method, path with query, timestamp, nonce and a
SHA-256 of the body, so a captured signature cannot be moved to another route or another body. Nonces are cached
for 600 seconds; the skew window is 300.

## Deliberate non-goals

- **We do not sandbox the agent.** It runs as you, on your machine, by your choice.
- **We do not defend against a compromised host.** If the host is owned, the code is owned. OpenPaw's job is to
  avoid *becoming* the way it gets owned.
- **We do not add a remote-exec endpoint** to the structured daemon, no matter how convenient. The app already has
  an authenticated PTY; a second, weaker path to the same power is pure downside.

## Reporting

Open a private security advisory on the repository. Please include the route or file, the input, and what boundary
you crossed.
