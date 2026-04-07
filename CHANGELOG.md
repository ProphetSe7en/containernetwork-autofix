# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] — 2026-04-07

First release of the **ProphetSe7en/cnaf** fork of `buxxdev/containernetwork-autofix`.

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
