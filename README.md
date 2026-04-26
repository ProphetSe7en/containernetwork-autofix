# ContainerNetwork AutoFix (CNAF) — ProphetSe7en fork

Automatically recreates Docker containers that depend on a master container's network when the master container restarts. Designed for Unraid but works on any Docker host.

![Version](https://img.shields.io/badge/version-1.2.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)

> **About this fork:** This is a fork of [`buxxdev/containernetwork-autofix`](https://github.com/buxxdev/containernetwork-autofix) with the template parser rewritten using `xmlstarlet` instead of hand-rolled `sed` regex. The rewrite fixes three bugs in the upstream parser:
>
> - **Healthchecks broken after rebuild** — `<ExtraParams>` was not XML-entity-decoded, leaving literal `&amp;gt;` instead of `>` in `--health-cmd` strings (containers stuck `unhealthy`).
> - **WebUI right-click broken in Unraid GUI** ([upstream issue #1](https://github.com/buxxdev/containernetwork-autofix/issues/1)) — recreated containers were missing `net.unraid.docker.{webui,shell,support,project}` labels.
> - **Hardware passthrough lost on rebuild** ([upstream issue #2](https://github.com/buxxdev/containernetwork-autofix/issues/2)) — the parser had no `Device` case, so GPU/DVB/USB devices were stripped.
>
> The fork keeps the upstream env-var contract intact (`MASTER_CONTAINER`, `RESTART_WAIT_TIME`, etc.) so it works as a drop-in replacement — only the `<Repository>` line in your Unraid template needs to change. See [CHANGELOG.md](CHANGELOG.md) for full details.

## Problem It Solves

When using Docker's `--net=container:` networking mode (container networking), dependent containers reference the master container by its container ID. When the master container restarts (e.g., after an update), it gets a new container ID, breaking the network connection for all dependent containers.

**Common scenario:** You have containers routing through a VPN container (like GluetunVPN). When the VPN container updates and restarts, dependent containers lose network connectivity until manually recreated.

**CNAF automates that process.**

## Features

- ✅ **Auto-detection** - Automatically finds all containers using the master container's network
- ✅ **State preservation** - Maintains running/stopped state of dependent containers
- ✅ **Smart waiting** - Waits for VPN/master container to fully establish before recreating dependents
- ✅ **Log rotation** - Automatic log management to prevent unbounded growth
- ✅ **Retry logic** - Handles startup race conditions gracefully
- ✅ **Zero configuration** - Just set the master container name and it handles the rest

## Installation

### Unraid (Recommended)

1. Open Unraid Web UI
2. Go to **Apps** tab
3. Search for **"ContainerNetwork AutoFix"** or **"CNAF"**
4. Click **Install**
5. Configure the master container name (default: GluetunVPN)
6. Click **Apply**

### Docker Run (Manual)
```bash
docker run -d \
  --name='ContainerNetwork-AutoFix' \
  --restart=unless-stopped \
  -e MASTER_CONTAINER='GluetunVPN' \
  -e RESTART_WAIT_TIME='15' \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /boot/config/plugins/dockerMan/templates-user:/templates:ro \
  -v /mnt/user/appdata/containernetwork-autofix:/var/log \
  ghcr.io/prophetse7en/containernetwork-autofix:latest
```

### Switching from upstream

Already running `buxxdev/containernetwork-autofix`? Stop the container, change the `<Repository>` in your Unraid template from `buxxdev/containernetwork-autofix:latest` to `ghcr.io/prophetse7en/containernetwork-autofix:latest`, then Apply. All env vars and mounts stay the same — the fork is a drop-in replacement.

## Configuration

All configuration is done via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `MASTER_CONTAINER` | `GluetunVPN` | Name of the master container to monitor |
| `RESTART_WAIT_TIME` | `15` | Seconds to wait after master restarts before recreating dependents |
| `MAX_LOG_LINES` | `1000` | Maximum number of log lines to keep (automatic rotation) |
| `MAX_RETRIES` | `10` | Number of times to retry finding master container on startup |
| `RETRY_DELAY` | `10` | Seconds between retry attempts |

## Volume Mounts

### Required (Unraid)

| Volume | Container Path | Description |
|--------|---------------|-------------|
| `/var/run/docker.sock` | `/var/run/docker.sock` | Access to Docker daemon |
| `/boot/config/plugins/dockerMan/templates-user` | `/templates` | Unraid container templates |

### Optional

| Volume | Container Path | Description |
|--------|---------------|-------------|
| `/mnt/user/appdata/containernetwork-autofix` | `/var/log` | Persistent log storage |

## How It Works

1. **Startup**: CNAF starts and waits for the master container to be available
2. **Detection**: Identifies the master container's ID and finds all dependent containers
3. **Monitoring**: Continuously monitors Docker events for master container restarts
4. **Recreation**: When master restarts:
   - Waits for configured time (default 15s) for master to stabilize
   - Identifies containers still using the old master container ID
   - Records each container's state (running/stopped)
   - Stops and removes each dependent container
   - Recreates from Unraid template
   - Restores original state

## Use Cases

### VPN Containers (Primary Use Case)

Route multiple containers through a VPN:
```bash
# qBittorrent routing through GluetunVPN
docker run -d \
  --name=qBittorrent \
  --net=container:GluetunVPN \
  ...
```

When GluetunVPN updates, CNAF automatically recreates qBittorrent with the new network reference.

**Supported VPN Containers:**
- GluetunVPN
- OpenVPN-Client
- WireGuard
- NordVPN
- Any container using `--net=container:` mode

## Troubleshooting

### "Master container not found"
- Ensure MASTER_CONTAINER name matches exactly (case-sensitive)
- Check master container is running: `docker ps | grep GluetunVPN`
- Increase MAX_RETRIES or RETRY_DELAY

### "Template not found"
- Unraid only: Ensure templates path is correctly mounted
- Check template exists: `ls /boot/config/plugins/dockerMan/templates-user/my-CONTAINERNAME.xml`

### "No broken containers found"
- Normal if no containers are using the master's network
- Or if dependent containers auto-reconnected

### Logs

View real-time logs:
```bash
docker logs -f ContainerNetwork-AutoFix
```

View log file (if using persistent volume):
```bash
tail -f /mnt/user/appdata/containernetwork-autofix/containernetwork-autofix.log
```

## Limitations

- **Unraid specific**: Currently requires Unraid's template system
- **Network mode only**: Only handles `--net=container:` mode
- **Single master**: Monitors one master container at a time

## Roadmap

- [ ] Support for multiple master containers

## Contributing

Issues and pull requests welcome on the fork!

**Fork repository:** https://github.com/prophetse7en/containernetwork-autofix
**Upstream repository:** https://github.com/buxxdev/containernetwork-autofix

## License

MIT License — see [LICENSE](LICENSE). Original copyright © buxxdev, fork copyright © ProphetSe7en.

## Support

- **Fork issues:** https://github.com/prophetse7en/containernetwork-autofix/issues
- **GHCR:** https://github.com/prophetse7en/containernetwork-autofix/pkgs/container/containernetwork-autofix
- **Upstream issues:** https://github.com/buxxdev/containernetwork-autofix/issues
- **Unraid Forums (upstream thread):** https://forums.unraid.net/topic/194313-support-containernetwork-autofix-cnaf-auto-fix-vpn-dependent-containers/

## Credits

Original tool created by [@buxxdev](https://github.com/buxxdev). Fork maintained by [@ProphetSe7en](https://github.com/prophetse7en) with bug fixes for the Unraid template parser. See [CREDITS.md](CREDITS.md).

---

**ContainerNetwork AutoFix (CNAF)** - Keep your container networks healthy, automatically.
