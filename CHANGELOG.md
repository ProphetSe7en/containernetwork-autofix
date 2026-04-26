# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] — 2026-04-26

### Fixed

- **Duplicate `--net=` flag in `docker run` for VPN-routed containers.**
  Unraid templates that route a container through a VPN typically carry
  both `<Network>none</Network>` AND a `--net=container:X` entry in
  ExtraParams. CNAF used to emit both, producing two `--net=` flags in
  the recreate command. On Docker ≤ 23 this was a silent "last wins"
  and worked by accident. Docker 24+ (which ships with current Unraid
  releases) validates and returns exit code 125 even though the
  container ID has already been allocated. Result: dependent containers
  ended up in a broken `Created` state with both network modes pinned,
  and Unraid could no longer start them from the GUI ("No such
  container" error in dockerMan).

  CNAF now mirrors Unraid Apply's behavior — when ExtraParams already
  contains `--net=` or `--network=`, the `<Network>` template field is
  skipped (with an info log line for debugging). Detection regex guards
  against false positives on `--net-alias` and on `net=` inside other
  flag values.

  Real-world trigger: VPN gateway image update → master container
  recreated → CNAF tried to recreate dependent containers (sabnzbd,
  qbit-sonarr, qbit-radarr) and emitted `docker run -d ... --net='none'
  ... --net=container:vpn-gateway ...`. All three "succeeded" (container
  IDs printed) but the eval returned non-zero and the containers were
  unstartable.

### Added

- **`test-net-dedup.sh`** — bash regression test for the network
  flag deduplication logic. Eight cases covering the original bug,
  bridge fallback, `--network=` long-form alias, false-positive guards
  for `--net-alias` and string-matching `net=` inside env values, empty
  Network field, and `--net <value>` space-separated form. Run before
  releases or after any change to the network-emit block in
  `entrypoint.sh`. No Docker daemon required.

## [1.1.2] — 2026-04-22

### Changed

- **Alpine base image pinned to `3.21`** (was `alpine:latest`). Each build
  now produces a reproducible image and picks up Alpine security patches
  only when the pin is deliberately bumped. Matches the rest of the
  ProphetSe7en container fleet.

### Added

- **`SECURITY.md`** describing the attack surface (Docker socket mount,
  template parsing, `docker run` argument construction), what's mitigated,
  what's deferred, and how to report a vulnerability privately via GitHub
  security advisories.

## [1.1.1] — 2026-04-08

### Fixed

- **Log timestamps ignored the `TZ` environment variable** and always
  showed UTC. Root cause: the Alpine base image was missing `tzdata`,
  so glibc/musl could not resolve zone names and fell back to UTC
  regardless of what `TZ` was set to. `tzdata` is now installed, and
  the Unraid template exposes a `Timezone` variable (default
  `Europe/Oslo`, blank or `UTC` keeps UTC).

  Existing log format is unchanged — only the displayed clock shifts
  to match the configured zone.

## [1.1.0] — 2026-04-07

First release of the **ProphetSe7en/containernetwork-autofix** fork of `buxxdev/containernetwork-autofix`.

### Fixed

- **Healthchecks broken after rebuild** — `<ExtraParams>` was extracted with
  raw `sed`, which left XML entities undecoded (`&amp;gt;` instead of `>`).
  Containers using `--health-cmd` with shell redirection (`> /dev/null`) ended
  up permanently `unhealthy`. Switched to `xmlstarlet`, which decodes entities
  automatically.
- **WebUI right-click broken in Unraid GUI** ([upstream issue #1]) — recreated
  containers were missing `net.unraid.docker.webui`, `shell`, `support`, and
  `project` labels. The Unraid GUI uses these to render the right-click menu.
  Now all five Unraid management labels are emitted.
- **Hardware passthrough lost on rebuild** ([upstream issue #2]) — the
  template parser only handled `Path`, `Variable`, `Port`, and `Label` config
  types. Containers with GPU (`/dev/dri`), DVB tuners, or USB devices lost
  them after rebuild. Added a `Device` branch that emits `--device` flags.

### Changed

- **Template parser rewritten using `xmlstarlet`** instead of hand-rolled
  `sed`/`grep` regex. Three of the bug classes above are direct consequences
  of the original parser; switching to a real XML parser fixes all of them
  with less code.
- **Improved trigger logging.** Each rebuild cycle now logs a header with
  the master container's old and new IDs and the count of dependents being
  recreated, making it much easier to correlate logs with restart events.
- **Dockerfile** now accepts `ARG VERSION` and emits an
  `org.opencontainers.image.version` label so the running version is visible
  in `docker inspect` and Unraid container info.

### Notes

- The fork keeps the upstream env-var contract intact (`MASTER_CONTAINER`,
  `RESTART_WAIT_TIME`, `LOG_FILE`, `MAX_LOG_LINES`, `MAX_RETRIES`,
  `RETRY_DELAY`) so it works as a drop-in replacement — the only thing that
  needs to change in your Unraid template is the `<Repository>` line.

[upstream issue #1]: https://github.com/buxxdev/containernetwork-autofix/issues/1
[upstream issue #2]: https://github.com/buxxdev/containernetwork-autofix/issues/2
