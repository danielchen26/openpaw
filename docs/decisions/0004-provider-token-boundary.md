# ADR 0004: Provider token and repository import boundary

**Status:** Accepted
**Gate status:** Recorded

## Context

Repository imports execute on a selected OpenPaw host. Duplicating GitHub or Hugging Face credentials onto the phone would expand the secret surface and encourage a general remote-command API. Public repositories need no credential, and private access should be least privilege and host scoped.

## Decision

Provider authorization is initiated by the phone but completed and stored on the selected host. The host stores tokens in a mode-0600 provider store, returns only sanitized authorization state and repository metadata, and performs imports through a narrow typed HTTPS-only clone operation. Tokens never appear in API responses, SSE events, logs, audit lines, crash or diagnostic artifacts, settings exports, simulator fixtures, snapshots, or command arguments.

| Allowed | Forbidden |
| --- | --- |
| Start host-scoped provider authorization and display a verification URL/code. | Return provider access or refresh tokens to the phone. |
| Browse sanitized repository metadata with least-privilege authorization. | Log, export, snapshot, or include provider secrets in fixtures. |
| Import public repositories without credentials. | Accept a shell command, destination path, Git config fragment, or credential header from the phone. |
| Clone to a fixed host-owned destination through a hardened typed wrapper. | Enable hooks, templates, prompts, local/file/ext protocols, or caller-selected paths. |
| Revoke/delete host-scoped credentials and audit the action. | Reuse one host's credential on another host without explicit authorization. |

## Enforcement map

| Boundary | Implementation task |
| --- | --- |
| Host-only provider authorization and redacted status | Production workspace expansion Task 12 |
| Hardened typed HTTPS clone, fixed destination, limits, and audit | Task 13 |
| Canonical workspace registration after import | Task 14 |
| Secret scanning, export checks, privacy manifest, and release evidence | Tasks 19-20 |

## Import boundary

The API accepts a provider identifier and validated remote repository identity. The host determines the canonical HTTPS URL, authentication header, fixed destination under its state directory, resource limits, and audit record. Successful imports are canonicalized before becoming workspace roots.

## Consequences

The phone remains a control surface and never becomes the credential authority for host clones. Structured repository import is permitted without weakening OpenPaw's no-arbitrary-execution invariant.
