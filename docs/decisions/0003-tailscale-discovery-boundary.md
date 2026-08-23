# ADR 0003: Tailscale discovery boundary

**Status:** Accepted
**Gate status:** Recorded

## Context

iOS sandboxing does not expose another application's Tailscale account, peer list, or LocalAPI to OpenPaw. The Tailscale app can make routes available, but route availability does not prove identity or authorize OpenPaw to save a device.

## Decision

OpenPaw uses Tailscale-assisted onboarding, not installed-app account import. The default discovery source is a reachable, already paired OpenPaw host returning sanitized `tailscale status --json` data through the authenticated `devices.read` capability. Manual MagicDNS and `100.64.0.0/10` entry remain available. A future zero-host connector must be explicitly labeled as a tailnet-administrator OAuth workflow and keep its credentials in Keychain.

| Allowed | Forbidden |
| --- | --- |
| Treat an `NWPathMonitor` result as a route hint. | Claim a route hint identifies the user's Tailscale account. |
| Ask a paired host for sanitized candidate metadata. | Read another iOS application's account, peer list, files, or LocalAPI. |
| Require confirmation before saving or trusting a candidate. | Silently import, trust, or connect to every discovered device. |
| Offer manual MagicDNS or Tailscale IP entry and typed preflight. | Treat reachability as host-key trust or credential proof. |
| Offer a clearly labeled advanced admin connector with revoke/delete. | Present an admin-created OAuth client as ordinary Tailscale login. |

## Data boundary

The phone may receive candidate hostname, sanitized addresses, online state, discovery source, and refresh time. It must not receive a Tailscale auth key, OAuth client secret in an API response, raw daemon state, or an assertion that discovery proves account ownership.

## Consequences

The Add Device experience can be convenient and truthful, but cannot automatically copy the account shown in the installed Tailscale app. Every persisted host still passes explicit confirmation, host-key verification, and credential handoff.
