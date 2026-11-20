# Changelog

All notable changes to this project will be documented in this file.

## [1.3.3] - 2026-11-20

### Fixed

- **A container stranded by one missed cycle is no longer stranded for ever.**
  CNAF only looked for dependents attached to the master's *current* id, so a
  container that missed a cycle, because CNAF was not running, because it was
  stopped at the time, or because a pass was skipped, pointed at a dead
  namespace that CNAF never looked at again. Its network stayed broken until
  someone noticed. CNAF now also finds containers whose namespace target no
  longer exists, and repairs them, both on a master restart and at startup.

  The check is deliberately narrow: a container is only touched when its
  namespace target is gone **and** its Unraid template names the master
  container. A container sharing some other container's namespace is left
  alone, with a line in the log saying so.

### Added

- **`FIX_STALE_ON_START`** (default `true`) repairs stranded containers when
  CNAF starts. They have no network at that point, so reconnecting them can
  only help. Set to `false` to have them reported in the log and left alone.
- **`SKIP_COMPOSE_DEPENDENTS`** (default `true`) to control the compose
  behaviour introduced in 1.3.2. Skipping is the safe default, but if you were
  relying on CNAF recreating a compose container from an accurate
  `my-<name>.xml`, 1.3.2 would have left it stranded instead. Set this to
  `false` to get the previous behaviour back.

### Changed

- **The log now says what actually happened.** Three cases used to be
  misleading or silent:
  - A recreate is verified afterwards. CNAF checks that the container exists,
    whether it is running, and that it is attached to the **current** master
    container, and logs that. It no longer reports success purely because
    `docker run` returned 0.
  - When something else recreated the container first, usually Unraid's own
    dependent rebuild, `docker run` fails on the container name. That was
    logged as `✗ ERROR: Failed to recreate <name>` even though the container
    was fine. CNAF now checks the result and reports it as already handled.
  - A failed `docker rm` was hidden by `2>/dev/null`, and the name conflict it
    caused was reported instead. The removal failure is now logged with
    docker's own message, and CNAF stops working on that container rather than
    running into the conflict.
- **A missing master container now says what to do.** The old message only
  said the container was not found. CNAF now points out a name that differs
  only in capitalisation, which looks correct at a glance, and otherwise lists
  the containers on the host so the right name can be copied. Container names
  are case sensitive, and a single wrong character means CNAF never triggers.

## [1.3.2] - 2026-11-20

### Fixed

- **Containers created by docker compose are no longer removed.** CNAF stopped
  and removed every dependent before checking whether it could recreate it.
  Recreation reads `/templates/my-<name>.xml`, which does not exist for a
  compose container, so those containers were deleted and never came back. If
  an old template was still lying around from before the container moved to
  compose, it was recreated from that stale definition instead, with the wrong
  configuration. CNAF now detects compose containers by their
  `com.docker.compose.project` label and leaves them alone, logging the project
  and service it skipped and what to run instead. Nothing changes for
  containers created through the Unraid Docker tab. Reported in
  [#6](https://github.com/ProphetSe7en/containernetwork-autofix/issues/6) by
  @mr-orange.

  If your master container and its dependents all live in one compose project,
  `network_mode: service:<master>` together with `depends_on` lets compose
  reattach them itself, and `docker compose up -d` is all that is needed.
  Recreating compose dependents from CNAF is planned as an opt-in feature for
  mixed setups, where the master is managed outside compose.

## [1.3.1] - 2026-11-08

### Security

- **Runs on Alpine 3.24.** Alpine 3.21 reached end of life on
  2026-11-01 and no longer receives security fixes. The image now uses
  Alpine 3.24, which is supported until 2028.

## [1.3.0] - 2026-06-06

### Added

- **Option to bring stopped dependents back up when the master restarts.**
  New environment variable `RESTART_STOPPED_DEPENDENTS` (default `false`).
  When `true`, dependents that happen to be stopped at the moment the
  master container restarts get started after the rebuild, alongside the
  ones that were already running. Default behavior is unchanged: stopped
  dependents stay stopped.

  This only triggers on the master-restart event. CNAF still does not
  auto-restart a container that crashes on its own. If a container has a
  real problem you want to investigate, stop it before triggering CNAF
  and it will stay stopped (with the default setting) or get restarted
  next time the master cycles (with the new setting).

  Concept credit: pull request from @conFrituur exploring the same idea.

## [1.2.1] - 2026-06-06

### Security

- **Passwords and API keys are masked in the log file.** When CNAF
  recreates a container, it writes a record of the rebuild to
  `/mnt/user/appdata/containernetwork-autofix/containernetwork-autofix.log`.
  The log shows `-e PASSWORD='***'` instead of the actual value, so
  passwords, tokens, and API keys for your containers (qBittorrent,
  Sonarr/Radarr, Plex Pass, VPN keys, etc.) stay private even if the
  log file is shared or backed up. The container itself still receives
  the real value, and only the on-disk log string is sanitized.

  If you have an existing log file, delete or rotate it once to clear
  any previously-logged plaintext values.

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
