# Security Policy

## Scope

CNAF is a lightweight bash utility that watches Docker events, re-parses Unraid templates with `xmlstarlet`, and invokes `docker run` to recreate dependent containers when a "master" container's ID changes (typical use: GluetunVPN restarts, dependent containers using `--network container:vpn-gateway` need recreation).

**No HTTP server. No API. No authentication surface. No persisted secrets.** The security-relevant attack surface is entirely on the Docker side.

## Attack surface

| Surface | Mitigation |
|---------|------------|
| **Docker socket (`/var/run/docker.sock`)** mounted RW | Unavoidable for the core function (create/remove containers). Container runs with `<Privileged>false</Privileged>` in the Unraid template. Trust boundary is the Unraid host itself — if the host is compromised, CNAF being able to run Docker commands is not additional risk. |
| **Unraid template parsing** | Switched from hand-rolled `sed`/`grep` (upstream) to `xmlstarlet` in v1.1.0. xmlstarlet is a proper XML parser — entity decoding, element traversal, and attribute extraction are safe against the three parser-bug classes we hit in the upstream build. |
| **`docker run` argument construction** | Known `eval`-based quoting issues documented in `dev/PROJECT.md` under "Known issues / deferred hardening" (items #1–#6). Ranges from CRITICAL (template with single quotes in label values could break out of quoting) to LOW. Deferred because: (a) Unraid templates are root-controlled files on a trusted host, and (b) fixing the CRITICAL one requires a larger refactor to an argument-array based `docker run`. Tracked for a future v1.2.0 hardening pass. |
| **Log file writes** | `tee -a ${LOG_FILE}` is unquoted; `LOG_FILE` defaults to a static path. Only exploitable if a user sets it to a path with spaces — low severity, acceptable for upstream-parity. |
| **Base image drift** | Alpine pinned to `3.21` (was `alpine:latest` before v1.1.2). Predictable security-upgrade cadence — bump pin deliberately when upstream ships a patch worth picking up. |

## What CNAF does NOT have

- No authentication (no UI)
- No network listener (no CSRF / SSRF concerns)
- No outbound HTTP (no API keys, no webhook URLs)
- No persisted credentials of any kind
- No database or state file (apart from an optional log file)

The "HTTP-security baseline" that applies to the rest of the ProphetSe7en fleet (Clonarr, Constat, vpn-gateway, tagarr, qui-sync) is **not applicable** to CNAF. The security-hardening plan (`docs/security-hardening-plan.md` in the monorepo) explicitly marks CNAF as *"no HTTP — confirmed safe for now"*.

## Reporting a vulnerability

If you find a security issue in CNAF — especially template-injection scenarios that escape the intended Unraid-template quoting — please open a private security advisory on GitHub:

**https://github.com/prophetse7en/containernetwork-autofix/security/advisories/new**

For non-sensitive issues, regular GitHub issues are fine. We aim to respond within a few days.

## Supported versions

Only the current `:latest` image receives security updates. Older tags are immutable snapshots.
