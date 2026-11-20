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
RESTART_STOPPED_DEPENDENTS="${RESTART_STOPPED_DEPENDENTS:-false}"
# Compose containers are skipped by default: CNAF cannot recreate them and
# removing them loses them (issue #6). Set to false only if you relied on the
# old behaviour and your my-<name>.xml templates are accurate for them.
SKIP_COMPOSE_DEPENDENTS="${SKIP_COMPOSE_DEPENDENTS:-true}"
# Opt-in: recreate compose dependents with docker compose itself, from the
# compose files recorded in the container's labels. The compose files (and
# their project directory) must be mounted into CNAF at the same paths as on
# the host. A compose container is never recreated from a template on this
# path, whatever fails. Takes precedence over SKIP_COMPOSE_DEPENDENTS.
RECREATE_COMPOSE_DEPENDENTS="${RECREATE_COMPOSE_DEPENDENTS:-false}"
# Containers left pointing at a dead namespace are already without network, so
# repairing them when CNAF starts is safe. Set to false to only log them.
FIX_STALE_ON_START="${FIX_STALE_ON_START:-true}"
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

# is_compose_container reports whether a container was created by docker
# compose. Compose records the project name in a label, and compose owns the
# container's definition: there is no dockerMan template for it, so CNAF must
# not remove it. Before this check, such a container was stopped, removed and
# then lost, because recreation reads /templates/my-<name>.xml which does not
# exist for it. Reported as issue #6.
is_compose_container() {
    local project
    project=$(docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
    [ -n "${project}" ] && [ "${project}" != "<no value>" ]
}

# compose_project_of prints the compose project and service for the log line,
# so the user can see exactly which stack to bring up again.
compose_project_of() {
    local project service
    project=$(docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
    service=$(docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)
    [ "${service}" = "<no value>" ] && service="?"
    echo "${project}/${service}"
}

# compose_label prints one com.docker.compose.* label of a container, or
# nothing. docker inspect prints the literal string "<no value>" for a label
# that is not set, which must never reach a command line.
compose_label() {
    local value
    value=$(docker inspect "$1" --format "{{index .Config.Labels \"com.docker.compose.$2\"}}" 2>/dev/null)
    [ "${value}" = "<no value>" ] && value=""
    printf '%s' "${value}"
}

# valid_compose_name accepts the characters compose allows in project and
# service names. Label values are passed to docker compose as arguments, so
# anything else (empty, whitespace, a leading dash that would read as an
# option) is rejected rather than passed through.
valid_compose_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

# recreate_compose_dependent recreates a compose dependent with docker compose,
# using the project, service, working directory and config files compose
# recorded in the container's labels. It does not stop or remove the container
# first: compose replaces it only once it has everything it needs, so every
# early failure leaves the container exactly as it was. It never falls back to
# a dockerMan template. Returns 0 only when the container is verified running
# (or stopped on purpose) and attached to the current master.
recreate_compose_dependent() {
    local CONTAINER=$1 NEW_MASTER_ID=$2 WAS_RUNNING=$3
    local PROJECT SERVICE WORKDIR FILES f found=0 rc status
    local ARGS=()

    PROJECT=$(compose_label "${CONTAINER}" project)
    SERVICE=$(compose_label "${CONTAINER}" service)
    WORKDIR=$(compose_label "${CONTAINER}" project.working_dir)
    FILES=$(compose_label "${CONTAINER}" project.config_files)

    if ! valid_compose_name "${PROJECT}" || ! valid_compose_name "${SERVICE}"; then
        log_message "✗ ERROR: ${CONTAINER} has an unusable compose project/service label ('${PROJECT}'/'${SERVICE}'), left untouched"
        return 1
    fi
    log_message "${CONTAINER} is managed by docker compose (project ${PROJECT}, service ${SERVICE}), recreating it with compose"

    if ! docker compose version >/dev/null 2>&1; then
        log_message "✗ ERROR: docker compose is not available inside CNAF, ${CONTAINER} left untouched"
        return 1
    fi

    ARGS=(-p "${PROJECT}")
    if [ -n "${WORKDIR}" ]; then
        if [ -d "${WORKDIR}" ]; then
            ARGS+=(--project-directory "${WORKDIR}")
        else
            log_message "  project directory ${WORKDIR} is not mounted into CNAF, relying on the compose files' own location"
        fi
    fi

    local IFS_SAVE=$IFS FLIST=()
    IFS=',' read -ra FLIST <<< "${FILES}"
    IFS=$IFS_SAVE
    for f in "${FLIST[@]}"; do
        [ -z "${f}" ] && continue
        if [ -f "${f}" ]; then
            ARGS+=(-f "${f}")
            found=1
        else
            log_message "  compose file ${f} is not mounted into CNAF, skipped"
        fi
    done
    if [ "${found}" -eq 0 ]; then
        log_message "✗ ERROR: none of the compose files of ${CONTAINER} are mounted into CNAF (${FILES:-no config_files label}), left untouched"
        log_message "  Mount them read-only at the same path as on the host, e.g. -v /path/to/project:/path/to/project:ro"
        return 1
    fi

    log_message "Executing: docker compose ${ARGS[*]} up -d --no-deps --force-recreate ${SERVICE}"
    docker compose "${ARGS[@]}" up -d --no-deps --force-recreate "${SERVICE}" 2>&1 \
        | while IFS= read -r line; do log_message "  compose: ${line}"; done
    rc=${PIPESTATUS[0]}
    if [ "${rc}" -ne 0 ]; then
        log_message "✗ ERROR: docker compose exited with ${rc} for ${CONTAINER}"
    fi

    # Verify whatever compose did, success or not: the container must exist,
    # be attached to the current master and be running.
    if ! verify_dependent "${CONTAINER}" "${NEW_MASTER_ID:0:12}"; then
        log_message "✗ ERROR: ${CONTAINER} is not attached to the current ${MASTER_CONTAINER} after compose"
        return 1
    fi
    status=$(docker inspect "${CONTAINER}" --format "{{.State.Status}}" 2>/dev/null)
    if [ "${status}" != "running" ]; then
        log_message "✗ ERROR: ${CONTAINER} was recreated by compose but is ${status:-missing}, not running"
        return 1
    fi

    if [ "${WAS_RUNNING}" = false ]; then
        docker stop "${CONTAINER}" >/dev/null 2>&1
        log_message "${CONTAINER} stopped (preserving original state)"
    fi
    log_message "✓ ${CONTAINER} recreated with docker compose"
    return 0
}

# verify_dependent checks the result of a recreate instead of trusting the
# exit code. Two things go wrong in practice and both used to be invisible:
# the container can come back attached to the old namespace, and Unraid
# recreates dependents itself, so ours can collide with a container that is
# already correct. Returns 0 when the container is attached to the expected
# master.
verify_dependent() {
    local container=$1 expected_master=$2
    local mode status
    mode=$(docker inspect "${container}" --format "{{.HostConfig.NetworkMode}}" 2>/dev/null)
    status=$(docker inspect "${container}" --format "{{.State.Status}}" 2>/dev/null)
    if [ -z "${status}" ]; then
        log_message "  verify: ${container} does not exist"
        return 1
    fi
    # Docker normally normalises --net=container:<name> to the master's id,
    # which is what CNAF matches on everywhere. Accept the name form too, so a
    # setup where it is not normalised is not reported as a failure.
    case "${mode}" in
        container:${expected_master}*|container:${MASTER_CONTAINER})
            log_message "  verify: ${container} is ${status} and attached to the current ${MASTER_CONTAINER}"
            return 0
            ;;
        container:*)
            log_message "  verify: ${container} is ${status} but still attached to ${mode}, not the current ${MASTER_CONTAINER}"
            return 1
            ;;
        *)
            log_message "  verify: ${container} is ${status} with network mode ${mode:-unknown}"
            return 1
            ;;
    esac
}

get_container_id() {
    docker inspect $1 --format "{{.Id}}" 2>/dev/null
}

# template_targets_master reports whether a container's Unraid template says
# it belongs to our master container. This is the evidence used before
# touching a container whose network namespace target no longer exists: the
# stored network mode only tells us which id it had, not whose it was.
template_targets_master() {
    local template="/templates/my-${1}.xml"
    [ -f "${template}" ] || return 1
    local extra network
    extra=$(xml_get "${template}" "/Container/ExtraParams")
    network=$(xml_get "${template}" "/Container/Network")
    case "${extra} ${network}" in
        *container:${MASTER_CONTAINER}*) return 0 ;;
        *) return 1 ;;
    esac
}

# get_stale_dependents finds containers whose network namespace points at a
# container that no longer exists. Those have no network at all, and CNAF used
# to be blind to them: get_dependent_containers only matches the *current*
# master id, so a container that missed one cycle (CNAF was down, the container
# was stopped, a pass was skipped) stayed broken for ever.
#
# Deliberately conservative. A container is only reported when its namespace
# target is gone AND its template names our master, so containers that share
# another container's namespace are never touched.
get_stale_dependents() {
    local master_id=$1
    local stale=()

    for container in $(docker ps -a --format "{{.Names}}"); do
        [ "$container" = "$MASTER_CONTAINER" ] && continue
        local network_mode target
        network_mode=$(docker inspect $container --format "{{.HostConfig.NetworkMode}}" 2>/dev/null)
        case "${network_mode}" in container:*) ;; *) continue ;; esac
        target=${network_mode#container:}

        # Already on the current master, or stored by name, which verify
        # treats as correct.
        [[ "${master_id}" == ${target}* ]] && continue
        [ "${target}" = "${MASTER_CONTAINER}" ] && continue

        # The namespace target still exists, so this is somebody else's
        # pairing. Leave it alone.
        docker inspect "${target}" >/dev/null 2>&1 && continue

        if template_targets_master "${container}"; then
            stale+=("$container")
        else
            # Note: this function's stdout is captured by the caller, so the
            # log line has to go to stderr or it ends up in the returned list.
            log_message "  ${container} points at a container that is gone, but its template does not name ${MASTER_CONTAINER}, so CNAF leaves it alone" >&2
        fi
    done

    echo "${stale[@]}"
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

    # Add network — but skip if EXTRA_PARAMS already specifies one.
    #
    # Unraid templates that route a container through a VPN container
    # commonly carry both `<Network>none</Network>` AND a `--net=container:X`
    # entry in ExtraParams. Unraid's own Apply button intelligently uses
    # only the ExtraParams value; CNAF used to emit both, producing a
    # docker run with two `--net=` flags.
    #
    # On Docker ≤ 23 this was a silent "last wins" — broken-looking but
    # functional. On Docker 24+ (which ships with current Unraid releases)
    # the daemon validates and returns exit code 125 even though the
    # container ID has already been allocated. The container ends up in
    # a broken Created state with both network modes pinned, and Unraid
    # cannot start it from the GUI ("No such container" via dockerMan).
    #
    # Detection regex matches `--net=`, `--net `, `--network=`, and
    # `--network ` either at the start of EXTRA_PARAMS or following
    # whitespace, so it doesn't false-positive on tokens like `--net-alias`.
    if [ -n "$NETWORK" ]; then
        if echo "$EXTRA_PARAMS" | grep -qE '(^|[[:space:]])--net(work)?(=|[[:space:]])'; then
            log_message "Network field present but ExtraParams contains --net/--network — using ExtraParams value (avoids duplicate --net flag)"
        else
            DOCKER_CMD="${DOCKER_CMD} --net='${NETWORK}'"
        fi
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
    
    # Mask env-var values in the log line. The executed DOCKER_CMD is
    # unchanged; only the log string is sanitized. Keeps passwords,
    # API keys, and tokens out of the log file even if the file is
    # shared or backed up.
    SAFE_CMD=$(echo "${DOCKER_CMD}" | sed -E "s/(-e '[^']+')='[^']*'/\1='***'/g")
    log_message "Docker command: ${SAFE_CMD}"
    log_message "Executing docker run..."
    
    # Execute the command
    eval ${DOCKER_CMD}
    
    return $?
}

# process_dependent recreates one dependent container and reports what
# actually happened. Extracted so both the master-restart trigger and the
# startup check for stranded containers use exactly the same path.
process_dependent() {
    local CONTAINER=$1 NEW_MASTER_ID=$2
    local CONTAINER_STATE WAS_RUNNING RM_OUTPUT

    log_message "Processing ${CONTAINER}..."

    # Opt-in compose path. Handled completely here: whatever happens, a
    # compose container never continues to the stop/remove/template path.
    if [ "${RECREATE_COMPOSE_DEPENDENTS}" = "true" ] && is_compose_container ${CONTAINER}; then
        local compose_was_running=false
        CONTAINER_STATE=$(docker inspect ${CONTAINER} --format "{{.State.Status}}" 2>/dev/null)
        if [ "$CONTAINER_STATE" == "running" ] || [ "$RESTART_STOPPED_DEPENDENTS" = "true" ]; then
            compose_was_running=true
        fi
        recreate_compose_dependent ${CONTAINER} ${NEW_MASTER_ID} ${compose_was_running}
        return 0
    fi

    # Never remove what cannot be recreated. A compose container has
    # no template, and recreating it from a stale one left over from
    # before it moved to compose gives it the wrong configuration.
    # Leave it to compose and say so.
    if [ "${SKIP_COMPOSE_DEPENDENTS}" = "true" ] && is_compose_container ${CONTAINER}; then
        log_message "⊘ ${CONTAINER} is managed by docker compose ($(compose_project_of ${CONTAINER})), left untouched"
        log_message "  CNAF cannot recreate compose containers. Run 'docker compose up -d' for that project, or set network_mode: service:${MASTER_CONTAINER} with depends_on so compose reattaches it itself."
        return 0
    fi

    CONTAINER_STATE=$(docker inspect ${CONTAINER} --format "{{.State.Status}}" 2>/dev/null)
    WAS_RUNNING=false
    if [ "$CONTAINER_STATE" == "running" ]; then
        WAS_RUNNING=true
        log_message "${CONTAINER} was running, will restart after rebuild"
    elif [ "$RESTART_STOPPED_DEPENDENTS" = "true" ]; then
        # Opt-in: pick up dependents that were stopped at trigger time
        # and start them after the rebuild. Only fires during the
        # master-container restart trigger, not as a continuous
        # healthcheck loop.
        WAS_RUNNING=true
        log_message "${CONTAINER} was ${CONTAINER_STATE}, will start after rebuild (RESTART_STOPPED_DEPENDENTS=true)"
    else
        log_message "${CONTAINER} was ${CONTAINER_STATE}, will remain stopped after rebuild"
    fi

    docker stop ${CONTAINER} 2>/dev/null
    RM_OUTPUT=$(docker rm ${CONTAINER} 2>&1)
    if docker inspect ${CONTAINER} >/dev/null 2>&1; then
        # Removal failed, so docker run would only fail on the name.
        # Before this check the failure was hidden by 2>/dev/null and
        # the next step reported a confusing name conflict instead.
        if verify_dependent ${CONTAINER} ${NEW_MASTER_ID:0:12}; then
            log_message "⊘ ${CONTAINER} could not be removed but is already on the current ${MASTER_CONTAINER}, left as is"
        else
            log_message "✗ ERROR: could not remove ${CONTAINER}: ${RM_OUTPUT}"
        fi
        return 0
    fi

    recreate_container_from_template ${CONTAINER}

    if [ $? -eq 0 ]; then
        if verify_dependent ${CONTAINER} ${NEW_MASTER_ID:0:12}; then
            log_message "✓ ${CONTAINER} recreated successfully!"
        else
            log_message "✗ ERROR: ${CONTAINER} was recreated but is not on the current ${MASTER_CONTAINER}"
        fi

        if [ "$WAS_RUNNING" = false ]; then
            docker stop ${CONTAINER} 2>/dev/null
            log_message "${CONTAINER} stopped (preserving original state)"
        fi
    else
        # A name conflict here means something else recreated it first,
        # usually Unraid's own dependent rebuild. That is not a failure
        # if the result is correct, so check before crying wolf.
        if verify_dependent ${CONTAINER} ${NEW_MASTER_ID:0:12}; then
            log_message "⊘ ${CONTAINER} was already recreated by something else, left as is"
        else
            log_message "✗ ERROR: Failed to recreate ${CONTAINER}"
        fi
    fi
}

log_message "ContainerNetwork AutoFix (CNAF) starting..."
log_message "Master Container: ${MASTER_CONTAINER}"
log_message "Restart Wait Time: ${RESTART_WAIT_TIME}s"
log_message "Max Retries: ${MAX_RETRIES}"
log_message "Restart Stopped Dependents: ${RESTART_STOPPED_DEPENDENTS}"
log_message "Skip Compose Dependents: ${SKIP_COMPOSE_DEPENDENTS}"
log_message "Recreate Compose Dependents: ${RECREATE_COMPOSE_DEPENDENTS}"
log_message "Fix Stranded On Start: ${FIX_STALE_ON_START}"
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
    log_message "✗ ERROR: ${MASTER_CONTAINER} not found after ${MAX_RETRIES} attempts."
    # A name that does not match any container is the common cause, and the
    # old message did not help anyone spot it. Show what does exist, and call
    # out a container whose name differs only in capitalisation, which looks
    # correct at a glance.
    CASE_MATCH=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -ix -- "${MASTER_CONTAINER}" | head -1)
    if [ -n "${CASE_MATCH}" ]; then
        log_message "  Did you mean '${CASE_MATCH}'? Container names are case sensitive."
    else
        log_message "  MASTER_CONTAINER is set to '${MASTER_CONTAINER}'. Containers on this host:"
        docker ps -a --format '{{.Names}}' 2>/dev/null | sort | head -25 \
            | while read -r n; do log_message "    ${n}"; done
        log_message "  Set MASTER_CONTAINER to one of those names exactly, including capitalisation."
    fi
    log_message "Exiting."
    exit 1
fi

# Find initial dependent containers
INITIAL_DEPENDENTS=$(get_dependent_containers ${CURRENT_MASTER_ID})
if [ -n "$INITIAL_DEPENDENTS" ]; then
    log_message "Found dependent containers: ${INITIAL_DEPENDENTS}"
else
    log_message "No dependent containers found (yet)"
fi

# Containers stranded on a namespace that no longer exists have no network at
# all, so fixing them at startup can only help: it covers the case where the
# master changed while CNAF was not running. Set FIX_STALE_ON_START=false to
# only report them.
STARTUP_STALE=$(get_stale_dependents ${CURRENT_MASTER_ID})
if [ -n "${STARTUP_STALE}" ]; then
    log_message "Stranded containers found at startup: ${STARTUP_STALE}"
    if [ "${FIX_STALE_ON_START}" = "true" ]; then
        for CONTAINER in ${STARTUP_STALE}; do
            process_dependent ${CONTAINER} ${CURRENT_MASTER_ID}
        done
    else
        log_message "  FIX_STALE_ON_START=false, leaving them as they are"
    fi
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
    # Pick up anything left stranded on a namespace that no longer exists, so
    # one missed cycle is not permanent.
    STALE_CONTAINERS=$(get_stale_dependents ${NEW_MASTER_ID})
    if [ -n "${STALE_CONTAINERS}" ]; then
        log_message "Also found stranded containers from an earlier cycle: ${STALE_CONTAINERS}"
        # The two sets overlap: once the old master is gone, its dependents are
        # stranded by definition. Deduplicate, or each one is torn down and
        # rebuilt twice in the same pass.
        BROKEN_CONTAINERS=$(printf '%s\n' ${BROKEN_CONTAINERS} ${STALE_CONTAINERS} | sort -u | tr '\n' ' ')
    fi

    if [ -z "$BROKEN_CONTAINERS" ]; then
        log_message "No broken containers found. All dependent containers may have auto-reconnected."
    else
        log_message "Found broken containers: ${BROKEN_CONTAINERS}"

        for CONTAINER in ${BROKEN_CONTAINERS}; do
            process_dependent ${CONTAINER} ${NEW_MASTER_ID}
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
