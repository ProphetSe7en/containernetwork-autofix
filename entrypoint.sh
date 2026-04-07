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

recreate_container_from_template() {
    local CONTAINER=$1
    local TEMPLATE="/templates/my-${CONTAINER}.xml"
    
    if [ ! -f "${TEMPLATE}" ]; then
        log_message "✗ ERROR: Template not found: ${TEMPLATE}"
        return 1
    fi
    
    log_message "Parsing template for ${CONTAINER}..."
    
    # Extract basic container info using inline sed commands
    local REPOSITORY=$(sed -n "s/.*<Repository>\(.*\)<\/Repository>.*/\1/p" "${TEMPLATE}" | head -1)
    local NETWORK=$(sed -n "s/.*<Network>\(.*\)<\/Network>.*/\1/p" "${TEMPLATE}" | head -1)
    local PRIVILEGED=$(sed -n "s/.*<Privileged>\(.*\)<\/Privileged>.*/\1/p" "${TEMPLATE}" | head -1)
    local EXTRA_PARAMS=$(sed -n "s/.*<ExtraParams>\(.*\)<\/ExtraParams>.*/\1/p" "${TEMPLATE}" | head -1)
    local POST_ARGS=$(sed -n "s/.*<PostArgs>\(.*\)<\/PostArgs>.*/\1/p" "${TEMPLATE}" | head -1)
    local ICON=$(sed -n "s/.*<Icon>\(.*\)<\/Icon>.*/\1/p" "${TEMPLATE}" | head -1)
    
    if [ -z "$REPOSITORY" ]; then
        log_message "✗ ERROR: Could not parse Repository from template"
        return 1
    fi
    
    log_message "Repository: ${REPOSITORY}"
    log_message "Network: ${NETWORK}"
    
    # Build docker run command
    local DOCKER_CMD="docker run -d --name='${CONTAINER}'"
    
    # Add Unraid management labels (makes container manageable in Unraid GUI)
    DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.managed=dockerman"
    if [ -n "$ICON" ]; then
        DOCKER_CMD="${DOCKER_CMD} -l net.unraid.docker.icon='${ICON}'"
    fi
    
    # Add network
    if [ -n "$NETWORK" ]; then
        DOCKER_CMD="${DOCKER_CMD} --net='${NETWORK}'"
    fi
    
    # Add privileged
    if [ "$PRIVILEGED" = "true" ]; then
        DOCKER_CMD="${DOCKER_CMD} --privileged"
    fi
    
    # Parse Config entries - FIXED: avoid subshell by using process substitution
    while IFS=: read -r line_num line_content; do
        # Extract attributes from the Config line
        local config_type=$(echo "$line_content" | sed -n 's/.*Type="\([^"]*\).*/\1/p')
        local target=$(echo "$line_content" | sed -n 's/.*Target="\([^"]*\).*/\1/p')
        local mode=$(echo "$line_content" | sed -n 's/.*Mode="\([^"]*\).*/\1/p')
        
        # Get the value (content between tags)
        local value=$(sed -n "${line_num}s/.*>\([^<]*\)<\/Config>/\1/p" "${TEMPLATE}")
        
        # Skip if no value or target
        [ -z "$value" ] && continue
        [ -z "$target" ] && continue
        
        case "$config_type" in
            "Path")
                if [ -n "$mode" ] && [ "$mode" != "{3}" ]; then
                    DOCKER_CMD="${DOCKER_CMD} -v '${value}':'${target}':'${mode}'"
                else
                    DOCKER_CMD="${DOCKER_CMD} -v '${value}':'${target}':'rw'"
                fi
                ;;
            "Variable")
                DOCKER_CMD="${DOCKER_CMD} -e '${target}'='${value}'"
                ;;
            "Port")
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
                DOCKER_CMD="${DOCKER_CMD} -l '${target}'='${value}'"
                ;;
        esac
    done < <(grep -n "<Config" "${TEMPLATE}")
    
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
done
