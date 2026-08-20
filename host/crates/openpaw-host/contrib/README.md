# Installing `openpaw-host`

`openpaw-host` runs on the machine your coding agents run on. It never listens on
a public interface, and it has no endpoint that executes a command. The phone
reaches it through an SSH tunnel you already trust.

Contents of this directory:

| File | Purpose |
| --- | --- |
| `claude-code-hooks.json` | Hook wiring so Claude Code asks OpenPaw before running a tool. |
| `openpaw-host.service` | systemd **user** unit for Linux. |

## 1. Build and install the binary

```sh
cd host
cargo install --path crates/openpaw-host
openpaw-host --version
```

## 2. Configure it

The daemon creates `~/.openpaw` on first run at mode `0700`. Set
`OPENPAW_STATE_DIR` to put it somewhere else.

Write `~/.openpaw/config.toml`:

```toml
# Loopback only. Binding anything else refuses to start unless you also pass
# --i-understand-the-risk, and prints a warning explaining why.
bind = "127.0.0.1"
port = 8787

# The ONLY directories the phone can read. Nothing outside these is reachable
# through any route, and a path that tries to climb out is rejected.
repos = [
  "/Users/you/src/openpaw",
  "/Users/you/src/other-project",
]

# Loopback ports the preview proxy may dial. Nothing else is dialable.
preview_ports = [3000, 5173, 8000, 8080]

max_blob_bytes = 2097152    # 2 MiB
max_upload_bytes = 16777216 # 16 MiB
session_max_age_days = 7
poll_interval_ms = 750

# 0 means a hook never blocks. Raise it only if you want the terminal to wait for
# your phone; see "Choosing hook_wait_ms" below.
hook_wait_ms = 0

[agents]
claude_code = true
codex = true
opencode = true
generic = true
```

Check what the daemon will actually use, without starting it:

```sh
openpaw-host doctor
```

## 3. Run it

Foreground, to watch the logs:

```sh
openpaw-host serve
```

### Linux (systemd)

```sh
mkdir -p ~/.config/systemd/user
cp openpaw-host.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now openpaw-host
sudo loginctl enable-linger "$USER"   # keep it running after logout
```

### macOS (launchd)

Save as `~/Library/LaunchAgents/dev.openpaw.host.plist`, replacing `YOU` with your
short username:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>dev.openpaw.host</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOU/.cargo/bin/openpaw-host</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>EnvironmentVariables</key>
  <dict><key>OPENPAW_LOG</key><string>info</string></dict>
  <key>StandardOutPath</key>  <string>/Users/YOU/.openpaw/stdout.log</string>
  <key>StandardErrorPath</key><string>/Users/YOU/.openpaw/stderr.log</string>
</dict>
</plist>
```

```sh
launchctl bootstrap gui/"$(id -u)" ~/Library/LaunchAgents/dev.openpaw.host.plist
launchctl print gui/"$(id -u)"/dev.openpaw.host | head
```

## 4. Open the tunnel

On the phone's side, forward the daemon's port over SSH. Nothing about OpenPaw
needs an inbound port, a relay, or an account:

```sh
ssh -N -L 8787:127.0.0.1:8787 you@workstation
```

## 5. Pair the phone

```sh
openpaw-host pair --name "Pixel 9"
```

```
  Pairing code: K3F2-9QAM-7TDL-2WRX-8HBV-4NCE
  Profile:      Operator
  Valid for:    5 minutes (until 2026-08-20 14:35:00 UTC)
```

Type it into the app while the tunnel is up. The code is single use and expires in
five minutes.

`openpaw-host pairing-code` does the same without pre-declaring a device name, and
`--profile observer` mints a read-only credential: an observer device can watch
sessions, read the inbox and browse repositories, but cannot approve anything,
upload anything, or use the preview proxy.

Both commands talk to the *running daemon* over loopback using
`~/.openpaw/hook-token`. The daemon holds the pending code in memory — never on
disk — which is why it must already be running, and why you never copy a secret by
hand.

## 6. Wire up the agents

### Claude Code

Merge the `hooks` object from `claude-code-hooks.json` into
`~/.claude/settings.json`, or into `.claude/settings.json` for a single project.
Merge it; do not replace the file.

```sh
python3 - <<'PY'
import json, pathlib
settings_path = pathlib.Path.home() / ".claude" / "settings.json"
settings_path.parent.mkdir(parents=True, exist_ok=True)
settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
contrib = json.loads(pathlib.Path("claude-code-hooks.json").read_text())
settings.setdefault("hooks", {}).update(contrib["hooks"])
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"merged OpenPaw hooks into {settings_path}")
PY
```

Verify the ingress by hand:

```sh
curl -sS -X POST http://127.0.0.1:8787/v1/hooks/claude-code \
  -H "X-OpenPaw-Hook-Token: $(cat ~/.openpaw/hook-token)" \
  -H 'content-type: application/json' \
  --data-binary @../../../protocol/fixtures/claude-code/hook-pretooluse-destructive.json
# => {}   (no decision recorded yet, so Claude Code keeps its own prompt)
```

### Codex and OpenCode

Nothing to install. Neither exposes a decision-carrying hook, so OpenPaw reads
their session files directly and you will see their activity in the app within one
poll interval. Approvals for those agents happen in their own terminal.

## Choosing `hook_wait_ms`

This is the one setting with a real trade-off.

`hook_wait_ms = 0` (the default) means a hook never blocks. Claude Code asks
OpenPaw, gets "no decision yet", and shows its own prompt in the terminal. Your
phone still gets the notification and the inbox item, and a decision you make there
is applied to the *next* hook for that request. Nothing can ever wedge.

A non-zero value makes the hook wait that long for your phone. It turns the phone
into the primary approval surface, at the cost that a tool call stalls for up to
that many milliseconds when you are not looking at your phone. If you set it, set
it to seconds, not minutes:

```toml
hook_wait_ms = 20000   # 20s: enough to tap a notification, short enough to shrug off
```

## What lives in the state directory

```
~/.openpaw/
├── config.toml      what you wrote above
├── state.json       0600 — paired devices and adapter cursors
├── hook-token       0600 — the local secret hooks and the CLI present
├── audit.jsonl      0600 — append-only, one line per decision
├── decisions/       0600 files — the handoff agent hooks read back
└── uploads/         0700 — attachments sent from the phone
```

Permissions are verified and repaired every time the daemon boots, so a careless
`chmod -R` cannot silently leave your credentials world-readable.

`state.json` never contains a bearer token, only its SHA-256. A token is displayed
exactly once, at pairing. If a device is lost, delete its entry from
`state.json`'s `devices` array and restart; its token is then worthless.

## Uninstalling

```sh
systemctl --user disable --now openpaw-host        # Linux
launchctl bootout gui/"$(id -u)"/dev.openpaw.host  # macOS
cargo uninstall openpaw-host
rm -rf ~/.openpaw
# and remove the OpenPaw entries from ~/.claude/settings.json
```

## Troubleshooting

**The app cannot see the daemon.** Check the tunnel first — the daemon is
loopback-only by design, so the app cannot reach it without one:

```sh
curl -sS http://127.0.0.1:8787/v1/health
```

`/v1/health` is the only unauthenticated read. It reports the daemon version, the
protocol version, the enabled adapters and their transcript format versions, and
the preview ports.

**Sessions do not appear.** Confirm the adapter is enabled and the transcripts are
where the adapter looks:

```sh
openpaw-host doctor
ls ~/.claude/projects ~/.codex/sessions ~/.local/share/opencode/storage/session
```

Sessions older than `session_max_age_days` are not discovered.

**Approvals do not reach the agent.** A decision is handed over as a file. After
approving from the phone:

```sh
ls -l ~/.openpaw/decisions/
tail -5 ~/.openpaw/audit.jsonl
```

If the file is there but Claude Code still prompts, the hook is not wired up — run
the `curl` check above.

**The preview shows nothing.** The port must be in `preview_ports` *and* something
must be listening on `127.0.0.1` at that port. `403` means the port is not
allowlisted; `502` means nothing answered. Bind your dev server to loopback rather
than `0.0.0.0` and it will work.

## Why there is no remote-exec endpoint

The app already owns an authenticated SSH/PTY channel, which is a better shell than
anything this daemon could offer. Adding remote execution here would widen the
blast radius of a stolen device token from "can approve what an agent already
proposed" to "can do anything", in exchange for no capability the app lacks. It is
listed under `non_capabilities` in `protocol/capability-spec/capabilities.json`, and
`tests/api.rs` asserts the routes stay absent.
