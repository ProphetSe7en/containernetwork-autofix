FROM alpine:latest

ARG VERSION=dev

LABEL maintainer="ProphetSe7en"
LABEL description="ContainerNetwork AutoFix (CNAF) - Automatically recreates dependent containers when master container restarts"
LABEL org.opencontainers.image.source="https://github.com/ProphetSe7en/cnaf"
LABEL org.opencontainers.image.description="Fork of buxxdev/containernetwork-autofix with xmlstarlet-based template parsing"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${VERSION}"

# Install required packages
# - bash:        entrypoint shell
# - docker-cli:  container management
# - xmlstarlet:  proper XML parser (replaces brittle sed-based template parsing)
RUN apk add --no-cache bash docker-cli xmlstarlet

# Create app directory
WORKDIR /app

# Copy the script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Run the script
ENTRYPOINT ["/app/entrypoint.sh"]
