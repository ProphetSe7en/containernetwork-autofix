#!/bin/bash
# ContainerNetwork AutoFix (CNAF)
# Automatically recreates dependent containers when master container restarts
# https://github.com/buxxdev/containernetwork-autofix

# ============ ENVIRONMENT VARIABLES (with defaults) ============
MASTER_CONTAINER="${MASTER_CONTAINER:-GluetunVPN}"
RESTART_WAIT_TIME="${RESTART_WAIT_TIME:-15}"
LOG_FILE="${LOG_FILE:-/var/log/containernetwork-autofix.log}"
MAX_LOG_LINES="${MAX_LOG_LINES:-1000}"
MAX_RETRIES="${MAX_RETRIES:-10}"
RETRY_DELAY="${RETRY_DELAY:-10}"
# ================================================================

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a ${LOG_FILE}
}

rotate_log() {
    if [ -f "${LOG_FILE}" ]; then
        local lines=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ $lines -gt ${MAX_LOG_LINES} ]; then
            tail -n ${MAX_LOG_LINES} "${LOG_FILE}" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        fi
    fi
}

get_container_id() {
    docker inspect $1 --format "{{.Id}}" 2>/dev/null
}

get_dependent_containers() {
    local master_id=$1
    local dependents=()
    
    for container in $(docker ps -a --format "{{.Names}}"); do
        if [ "$container" != "$MASTER_CONTAINER" ]; then
            network_mode=$(docker inspect $container --format "{{.HostConfig.NetworkMode}}" 2>/dev/null)
            if [[ $network_mode == container:$master_id* ]]; then
                dependents+=("$container")
            fi
        fi
    done
    
    echo "${dependents[@]}"
}

# xml_get: extract text content from a template using xpath, with double
# entity decoding to match how Unraid Apply handles its templates.
# Unraid templates routinely contain double-encoded entities like "&amp;gt;"
# (8 chars representing the literal "&gt;") in fields like ExtraParams.
# Unraid's Apply button decodes these all the way to ">" before passing to
# docker run, which requires two passes:
#   pass 1 (xmlstarlet -T): "&amp;gt;" -> "&gt;"
#   pass 2 (sed):           "&gt;"     -> ">"
# The original sed-based parser did zero decoding, leaving literal "&amp;gt;"
# in --health-cmd strings and breaking healthchecks on every recreated container.
xml_get() {
    local template="$1"
    local xpath="$2"
    xmlstarlet sel -T -t -v "${xpath}" "${template}" 2>/dev/null \
        | sed -e 's/&lt;/</g' \
              -e 's/&gt;/>/g' \
              -e 's/&quot;/"/g' \
              -e "s/&apos;/'/g" \
              -e 's/&amp;/\&/g'
}

recreate_container_from_template() {
    local CONTAINER=$1
    local TEMPLATE="/templates/my-${CONTAINER}.xml"

    if [ ! -f "${TEMPLATE}" ]; then
        log_message "✗ ERROR: Template not found: ${TEMPLATE}"
        return 1
    fi

    log_message "Parsing template for ${CONTAINER}..."

    # Extract container metadata using xmlstarlet (handles XML entity decoding)
    local REPOSITORY=$(xml_get "${TEMPLATE}" "/Container/Repository")
    local NETWORK=$(xml_get "${TEMPLATE}" "/Container/Network")
    local PRIVILEGED=$(xml_get "${TEMPLATE}" "/Container/Privileged")
    local EXTRA_PARAMS=$(xml_get "${TEMPLATE}" "/Container/ExtraParams")
    local POST_ARGS=$(xml_get "${TEMPLATE}" "/Container/PostArgs")
    local ICON=$(xml_get "${TEMPLATE}" "/Container/Icon")
    local WEBUI=$(xml_get "${TEMPLATE}" "/Container/WebUI")
    local SHELL_VAL=$(xml_get "${TEMPLATE}" "/Container/Shell")
    local SUPPORT=$(xml_get "${TEMPLATE}" "/Container/Support")
    local PROJECT=$(xml_get "${TEMPLATE}" "/Container/Project")

    if [ -z "$REPOSITORY" ]; then
        log_message "✗ ERROR: Could not parse Repository from template"
        return 1
    fi

    log_message "Repository: ${REPOSITORY}"
    log_message "Network: ${NETWORK}"

    # Build docker run command
    local DOCKER_CMD="docker run -d --name='${CONTAINER}'"

    # Add Unraid management labels (makes container manageable in Unraid GUI)
    # Upstream only emits icon + managed; we add webui/shell/support/project
    # so right-click WebUI/console menus keep working after rebuild (Bug B fix).
    DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.managed=dockerman"
    if [ -n "$ICON" ]; then
        DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.icon='${ICON}'"
    fi
    if [ -n "$WEBUI" ]; then
        DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.webui='${WEBUI}'"
    fi
    if [ -n "$SHELL_VAL" ]; then
        DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.shell='${SHELL_VAL}'"
    fi
    if [ -n "$SUPPORT" ]; then
        DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.support='${SUPPORT}'"
    fi
    if [ -n "$PROJECT" ]; then
        DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.project='${PROJECT}'"
    fi

    # Add network
    if [ -n "$NETWORK" ]; then
        DOCKER_CMD="${DOCKER_CMD} --net='${NETWORK}'"
    fi

    # Add privileged
    if [ "$PRIVILEGED" = "true" ]; then
        DOCKER_CMD="${DOCKER_CMD} --privileged"
    fi

    # Parse <Config> entries via xmlstarlet xpath iteration. This replaces
    # the upstream grep+sed line-tracking approach which had no Device case
    # (Bug C fix). Logic for Path/Variable/Port/Label is identical to upstream.
    #
    # NOTE: This count() call deliberately does NOT use xml_get / the sed
    # decoding pipeline. count() returns a number, not a string — entity
    # decoding would be a no-op at best and a parse error at worst.
    local config_count=$(xmlstarlet sel -t -v "count(/Container/Config)" "${TEMPLATE}" 2>/dev/null)
    [ -z "$config_count" ] && config_count=0

    local i=1
    while [ "$i" -le "$config_count" ]; do
        local config_type=$(xml_get "${TEMPLATE}" "/Container/Config[${i}]/@Type")
        local target=$(xml_get "${TEMPLATE}" "/Container/Config[${i}]/@Target")
        local mode=$(xml_get "${TEMPLATE}" "/Container/Config[${i}]/@Mode")
        local value=$(xml_get "${TEMPLATE}" "/Container/Config[${i}]")

        i=$((i + 1))

        # Skip if no value or target (matches upstream behavior)
        [ -z "$value" ] && continue

        case "$config_type" in
            "Path")
                [ -z "$target" ] && continue
                if [ -n "$mode" ] && [ "$mode" != "{3}" ]; then
                    DOCKER_CMD="${DOCKER_CMD} -v '${value}':'${target}':'${mode}'"
                else
                    DOCKER_CMD="${DOCKER_CMD} -v '${value}':'${target}':'rw'"
                fi
                ;;
            "Variable")
                [ -z "$target" ] && continue
                DOCKER_CMD="${DOCKER_CMD} -e '${target}'='${value}'"
                ;;
            "Port")
                [ -z "$target" ] && continue
                # Skip port mappings when using container network mode
                if [[ ! "$NETWORK" =~ ^container: ]]; then
                    if [ -n "$mode" ] && [ "$mode" != "{3}" ]; then
                        DOCKER_CMD="${DOCKER_CMD} -p ${value}:${target}/${mode}"
                    else
                        DOCKER_CMD="${DOCKER_CMD} -p ${value}:${target}"
                    fi
                fi
                ;;
            "Label")
                [ -z "$target" ] && continue
                DOCKER_CMD="${DOCKER_CMD} -l '${target}'='${value}'"
                ;;
            "Device")
                # Hardware passthrough: GPU (/dev/dri), DVB tuners, USB.
                # Bug C fix — upstream had no Device case.
                DOCKER_CMD="${DOCKER_CMD} --device='${value}'"
                ;;
        esac
    done
    
    # Add extra params
    if [ -n "$EXTRA_PARAMS" ]; then
        DOCKER_CMD="${DOCKER_CMD} ${EXTRA_PARAMS}"
    fi
    
    # Add repository
    DOCKER_CMD="${DOCKER_CMD} '${REPOSITORY}'"
    
    # Add post args
    if [ -n "$POST_ARGS" ]; then
        DOCKER_CMD="${DOCKER_CMD} ${POST_ARGS}"
    fi
    
    log_message "Docker command: ${DOCKER_CMD}"
    log_message "Executing docker run..."
    
    # Execute the command
    eval ${DOCKER_CMD}
    
    return $?
}

log_message "ContainerNetwork AutoFix (CNAF) starting..."
log_message "Master Container: ${MASTER_CONTAINER}"
log_message "Restart Wait Time: ${RESTART_WAIT_TIME}s"
log_message "Max Retries: ${MAX_RETRIES}"
rotate_log

# Wait for master container to be ready with retry logic
RETRY_COUNT=0
log_message "Waiting for ${MASTER_CONTAINER} to be ready..."

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    CURRENT_MASTER_ID=$(get_container_id ${MASTER_CONTAINER})
    
    if [ -n "$CURRENT_MASTER_ID" ]; then
        log_message "✓ ${MASTER_CONTAINER} found! ID: ${CURRENT_MASTER_ID:0:12}..."
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log_message "Waiting for ${MASTER_CONTAINER}... (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
    sleep ${RETRY_DELAY}
done

if [ -z "$CURRENT_MASTER_ID" ]; then
    log_message "✗ ERROR: ${MASTER_CONTAINER} not found after ${MAX_RETRIES} attempts. Exiting."
    exit 1
fi

# Find initial dependent containers
INITIAL_DEPENDENTS=$(get_dependent_containers ${CURRENT_MASTER_ID})
if [ -n "$INITIAL_DEPENDENTS" ]; then
    log_message "Found dependent containers: ${INITIAL_DEPENDENTS}"
else
    log_message "No dependent containers found (yet)"
fi

# Run the events pipeline as a background job so that bash's main thread
# is free to receive signals. Without this, bash blocks waiting for the
# foreground pipeline and defers SIGTERM until the pipeline returns —
# which never happens because docker events runs forever. Result: docker
# stop has to wait the full --stop-timeout (default 10s) and then SIGKILL.
#
# With background + wait, the trap below fires immediately on SIGTERM
# (because the wait builtin IS signal-interruptible, unlike foreground
# pipelines), kills the pipeline children, and exits cleanly within ~1s.
#
# The pipeline body itself is byte-identical to upstream — only its
# foreground/background mode changes.
docker events --filter "container=${MASTER_CONTAINER}" --filter 'event=start' | while read event
do
    log_message "${MASTER_CONTAINER} restarted, waiting ${RESTART_WAIT_TIME} seconds for VPN to establish..."
    sleep ${RESTART_WAIT_TIME}

    NEW_MASTER_ID=$(get_container_id ${MASTER_CONTAINER})
    log_message "New ${MASTER_CONTAINER} ID: ${NEW_MASTER_ID:0:12}..."

    BROKEN_CONTAINERS=$(get_dependent_containers ${CURRENT_MASTER_ID})

    if [ -z "$BROKEN_CONTAINERS" ]; then
        log_message "No broken containers found. All dependent containers may have auto-reconnected."
    else
        log_message "Found broken containers: ${BROKEN_CONTAINERS}"

        for CONTAINER in ${BROKEN_CONTAINERS}; do
            log_message "Processing ${CONTAINER}..."

            CONTAINER_STATE=$(docker inspect ${CONTAINER} --format "{{.State.Status}}" 2>/dev/null)
            WAS_RUNNING=false
            if [ "$CONTAINER_STATE" == "running" ]; then
                WAS_RUNNING=true
                log_message "${CONTAINER} was running, will restart after rebuild"
            else
                log_message "${CONTAINER} was stopped, will remain stopped after rebuild"
            fi

            docker stop ${CONTAINER} 2>/dev/null
            docker rm ${CONTAINER} 2>/dev/null

            recreate_container_from_template ${CONTAINER}

            if [ $? -eq 0 ]; then
                log_message "✓ ${CONTAINER} recreated successfully!"

                if [ "$WAS_RUNNING" = false ]; then
                    docker stop ${CONTAINER} 2>/dev/null
                    log_message "${CONTAINER} stopped (preserving original state)"
                fi
            else
                log_message "✗ ERROR: Failed to recreate ${CONTAINER}"
            fi
        done
    fi

    CURRENT_MASTER_ID=${NEW_MASTER_ID}
    log_message "All dependent containers processed."
    rotate_log
done &

PIPELINE_PID=$!

# SIGTERM/SIGINT handler: kill the pipeline subshell, which closes the pipe
# to docker events, which then dies. Then exit cleanly.
shutdown_handler() {
    log_message "Shutdown signal received — stopping event watcher..."
    kill "$PIPELINE_PID" 2>/dev/null
    # Also kill any straggling docker events processes (defensive)
    pkill -P $$ -f "docker events" 2>/dev/null || true
    log_message "CNAF stopped cleanly."
    exit 0
}
trap shutdown_handler TERM INT

# wait IS signal-interruptible (unlike foreground pipelines), so SIGTERM
# will return immediately and trigger shutdown_handler.
wait "$PIPELINE_PID"
