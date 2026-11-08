#!/bin/bash
# diag-lib.sh - Docker preflight, host-side `doctor` checks and `version`.
# Sourced by bin/claude-dockerized. Not executable directly; no `set -e`.

# Is Docker usable? On failure explain the cause and the fix (not one
# generic message for "not installed", "no permission" and "not running").
# Usage: docker_ready (0 ready, 1 not)
docker_ready() {
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker CLI not found."
        print_info "Install Docker Engine (or Docker Desktop): https://docs.docker.com/engine/install/"
        return 1
    fi
    local err
    err=$(docker info 2>&1 >/dev/null) && return 0
    case "$err" in
    *"permission denied"*)
        print_error "No permission to talk to the Docker daemon."
        print_info "Add your user to the 'docker' group and log in again, or use rootless Docker (https://docs.docker.com/engine/security/rootless/)."
        ;;
    *"Cannot connect"* | *"Is the docker daemon running"* | *"connection refused"* | *"failed to connect"* | *"no such file or directory"*)
        print_error "The Docker daemon is not running."
        print_info "Start it (systemctl start docker, systemctl --user start docker for rootless, or open Docker Desktop)."
        ;;
    *)
        print_error "Docker is not usable: $(printf '%s' "$err" | head -n 1)"
        ;;
    esac
    return 1
}

check_docker() {
    docker_ready || exit 1
}

# Claude Code version the next build pins (saved pin, else the Dockerfile ARG).
pinned_claude_version() {
    local v
    v=$(update_saved_claude_version)
    [ -n "$v" ] || v=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$REPO_ROOT/Dockerfile" | head -n 1)
    printf '%s' "$v"
}

# Claude Code version inside the built image ("" when unavailable).
# Usage: image_claude_version [image] (default: $IMAGE_NAME)
image_claude_version() {
    local image="${1:-$IMAGE_NAME}"
    command -v docker >/dev/null 2>&1 || return 0
    docker image inspect "$image" >/dev/null 2>&1 || return 0
    docker run --rm --entrypoint bash "$image" -c "claude --version" 2>/dev/null | cut -d' ' -f1
}

_diag_json_string() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

# `version [--json]`: works without Docker (the image line needs it).
show_version() {
    local json=false
    case "${1:-}" in
    --json) json=true ;;
    "") ;;
    *)
        print_error "Unknown version option: $1 (use --json)"
        return 1
        ;;
    esac
    local describe guard policies pinned image
    describe=$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo "unknown")
    guard=$(grep -oE 'CLAUDE_DOCKERIZED_GUARD_VERSION=[0-9]+' "$REPO_ROOT/hooks/claude-guard-bash.sh" 2>/dev/null | head -n 1 | cut -d= -f2)
    policies=$(cat "$REPO_ROOT/policies/VERSION" 2>/dev/null || echo "unknown")
    pinned=$(pinned_claude_version)
    image=""
    if docker info >/dev/null 2>&1; then
        image=$(image_claude_version)
    fi
    if [ "$json" = true ]; then
        printf '{"wrapper":%s,"checkout":%s,"guard":%s,"policies":%s,"claude_pinned":%s,"claude_image":%s}\n' \
            "$(_diag_json_string "$WRAPPER_VERSION")" "$(_diag_json_string "$describe")" \
            "$(_diag_json_string "${guard:-unknown}")" "$(_diag_json_string "$policies")" \
            "$(_diag_json_string "$pinned")" "$(_diag_json_string "$image")"
        return 0
    fi
    echo "claude-dockerized $WRAPPER_VERSION ($describe)"
    echo "guard v${guard:-unknown} · policies v$policies"
    if [ -n "$image" ]; then
        local note=""
        [ "$image" != "$pinned" ] && note=" (differs from the pin: run 'claude-dockerized build')"
        echo "Claude Code: pinned $pinned · image $image$note"
    else
        echo "Claude Code: pinned $pinned · image not available (Docker unreachable or image not built)"
    fi
}

# Host checks for `doctor`. Fills DIAG_RESULTS with "status|check|detail"
# (status: pass|warn|fail). Usage: doctor_host_checks
doctor_host_checks() {
    DIAG_RESULTS=()
    local docker_ok=false image_ok=false
    if docker info >/dev/null 2>&1; then
        docker_ok=true
        DIAG_RESULTS+=("pass|docker|daemon reachable")
    else
        DIAG_RESULTS+=("fail|docker|daemon not reachable (claude-dockerized build explains the exact cause)")
    fi
    # The image sessions of this profile run (setting.claude_version picks a
    # per-profile one), not just the default tag.
    local session_image
    session_image=$(session_image_name)
    if [ "$docker_ok" = true ] && docker image inspect "$session_image" >/dev/null 2>&1; then
        image_ok=true
        local created age_days
        created=$(docker image inspect -f '{{.Created}}' "$session_image" 2>/dev/null | cut -c1-10)
        age_days=$((($(date +%s) - $(date -d "$created" +%s 2>/dev/null || date +%s)) / 86400))
        if [ "$age_days" -gt 30 ]; then
            DIAG_RESULTS+=("warn|image|$session_image is $age_days days old (rebuild: claude-dockerized build --pull)")
        else
            DIAG_RESULTS+=("pass|image|$session_image built $created")
        fi
    elif [ "$docker_ok" = true ]; then
        DIAG_RESULTS+=("fail|image|$session_image not built (run: claude-dockerized build)")
    fi
    if [ "$image_ok" = true ]; then
        local pinned image
        pinned="${CLAUDE_VERSION:-$(pinned_claude_version)}"
        image=$(image_claude_version "$session_image")
        if [ -n "$image" ] && [ "$image" = "$pinned" ]; then
            DIAG_RESULTS+=("pass|claude-version|$image (pinned)")
        else
            DIAG_RESULTS+=("warn|claude-version|image ${image:-unknown} vs pinned $pinned (run: claude-dockerized build)")
        fi
    fi
    # Every profile carries its own mirror of the layer: check them all.
    local pname drifted=""
    for pname in $(profile_names); do
        if ! (
            # shellcheck disable=SC2034 # read by activate_profile
            PROFILE_FLAG="$pname"
            activate_profile
            parse_config >/dev/null 2>&1 || true
            check_security_layer >/dev/null 2>&1
        ); then
            drifted="$drifted $pname"
        fi
    done
    if [ -z "$drifted" ]; then
        DIAG_RESULTS+=("pass|security-layer|hooks, policies and managed settings match the repo")
    else
        DIAG_RESULTS+=("fail|security-layer|drift detected in profile(s):$drifted (details: claude-dockerized config sync --check)")
    fi
    DIAG_RESULTS+=("pass|profile|active: $PROFILE_NAME ($PROFILE_SOURCE)")
    DIAG_RESULTS+=("pass|policy|security_policy=$SECURITY_POLICY, hardening=$HARDENING")
    if [ "$INTEGRITY_CHECK" = true ]; then
        local last
        last=$(integrity_last_report)
        if [ -n "$last" ]; then
            DIAG_RESULTS+=("warn|integrity|last session changed persistent paths: $last")
        else
            DIAG_RESULTS+=("pass|integrity|no persistent-path changes recorded")
        fi
    else
        DIAG_RESULTS+=("warn|integrity|session integrity check disabled (setting.integrity_check=false)")
    fi
    if update_has_trust; then
        DIAG_RESULTS+=("pass|release-key|update signing key pinned")
    else
        DIAG_RESULTS+=("warn|release-key|no release key pinned: update refuses releases (see: claude-dockerized update --help)")
    fi
    if [ "$DOCKER_SOCKET" = true ]; then
        DIAG_RESULTS+=("warn|docker-socket|mounted: root-equivalent on the host")
    fi
}

# Print DIAG_RESULTS; returns 1 when any check failed.
# Usage: doctor_print_host <json:true|false>
doctor_print_host() {
    local json="$1" r status name detail fails=0 warns=0 passes=0 first=true
    [ "$json" = true ] && printf '{"host":['
    for r in "${DIAG_RESULTS[@]}"; do
        status="${r%%|*}"
        name="${r#*|}"
        name="${name%%|*}"
        detail="${r#*|*|}"
        case "$status" in
        pass) passes=$((passes + 1)) ;;
        warn) warns=$((warns + 1)) ;;
        fail) fails=$((fails + 1)) ;;
        esac
        if [ "$json" = true ]; then
            [ "$first" = true ] || printf ','
            first=false
            printf '{"check":%s,"status":%s,"detail":%s}' "$(_diag_json_string "$name")" \
                "$(_diag_json_string "$status")" "$(_diag_json_string "$detail")"
            continue
        fi
        case "$status" in
        pass) print_success "$name: $detail" ;;
        warn) print_warning "$name: $detail" ;;
        fail) print_error "$name: $detail" ;;
        esac
    done
    if [ "$json" = true ]; then
        printf '],"summary":{"pass":%d,"warn":%d,"fail":%d}}\n' "$passes" "$warns" "$fails"
    else
        echo "host: $passes passed, $warns warning(s), $fails failed"
    fi
    [ "$fails" -eq 0 ]
}
