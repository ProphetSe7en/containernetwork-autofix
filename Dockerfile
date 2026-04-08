FROM alpine:latest

ARG VERSION=dev

LABEL maintainer="ProphetSe7en"
LABEL description="ContainerNetwork AutoFix (CNAF) - Automatically recreates dependent containers when master container restarts"
LABEL org.opencontainers.image.source="https://github.com/prophetse7en/containernetwork-autofix"
LABEL org.opencontainers.image.description="Fork of buxxdev/containernetwork-autofix with xmlstarlet-based template parsing"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${VERSION}"

# Install required packages
# - bash:        entrypoint shell
# - docker-cli:  container management
# - xmlstarlet:  proper XML parser (replaces brittle sed-based template parsing)
# - procps:      pgrep for healthcheck (busybox pgrep doesn't support -f)
RUN apk add --no-cache bash docker-cli xmlstarlet procps

# Create app directory
WORKDIR /app

# Copy the script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Healthcheck: verify docker.sock is reachable AND our event watcher is alive.
# Master container being down is NOT a CNAF problem — CNAF should remain healthy
# while waiting for master to come back. We only check things CNAF itself controls.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD pgrep -f "docker events" >/dev/null 2>&1 \
        && docker ps >/dev/null 2>&1 \
        || exit 1

# Run the script
ENTRYPOINT ["/app/entrypoint.sh"]
