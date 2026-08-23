#![cfg(unix)]

use std::process::Command;

#[test]
fn askpass_helper_mode_reads_secret_only_from_fd3() {
    let helper = env!("CARGO_BIN_EXE_openpaw-host");
    let script = r#"
import os, socket, struct, subprocess, sys
helper, secret = sys.argv[1], sys.argv[2]
parent, child = socket.socketpair()
if parent.fileno() == 3:
    parent = socket.socket(fileno=os.dup(parent.fileno()))
if child.fileno() == 3:
    child = socket.socket(fileno=os.dup(child.fileno()))
try:
    os.dup2(child.fileno(), 3)
    os.set_inheritable(3, True)
    proc = subprocess.Popen(
        [helper, 'Password for https://example.invalid/repo.git'],
        env={'OPENPAW_GIT_ASKPASS_MODE':'fd3', 'PATH':'/usr/bin:/bin'},
        pass_fds=(3,),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    child.close()
    hdr = parent.recv(2)
    if len(hdr) != 2:
        raise SystemExit('missing prompt length')
    n = struct.unpack('>H', hdr)[0]
    prompt = parent.recv(n)
    if b'Password' not in prompt:
        raise SystemExit('unexpected prompt')
    parent.sendall(b'\x00' + struct.pack('>H', len(secret)) + secret.encode())
    out, err = proc.communicate(timeout=5)
    if proc.returncode != 0:
        raise SystemExit(f'helper failed: {err!r}')
    if out.decode() != secret:
        raise SystemExit('secret output mismatch')
    if secret.encode() in err:
        raise SystemExit('secret leaked to stderr')
finally:
    parent.close()
"#;
    let secret = "helper-secret-should-not-leak";
    let output = Command::new("python3")
        .arg("-c")
        .arg(script)
        .arg(helper)
        .arg(secret)
        .output()
        .expect("python harness runs");
    assert!(
        output.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn normal_cli_parse_runs_before_secretless_helper_mode_only_when_marker_set() {
    let helper = env!("CARGO_BIN_EXE_openpaw-host");
    let output = Command::new(helper)
        .arg("--help")
        .env_remove("OPENPAW_GIT_ASKPASS_MODE")
        .output()
        .expect("help runs");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("openpaw-host"));
}
