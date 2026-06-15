#!/usr/bin/env bash
set -euo pipefail

msg_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

msg_ok() {
    echo -e "\033[1;32m[OK]\033[0m $1"
}

msg_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}

msg_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

log() {
    local level="$1"
    local message="$2"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - [$level] $message"
}

REPO="$HOME/DEV/homelab/homelab-podman-apps"
BRANCH="main"
METRICS_STATE="$REPO/deploy/metrics_state"
METRICS_OUT="/var/lib/node_exporter/textfile/podman_gitops.prom"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--config <file>] [--force] [--app <name|path>]

Options:
  --config, -c FILE  Path to the apps config file (default: gitops-apps.conf).
                     Relative paths are resolved from the repo root.
  --force, -f        Deploy every configured app regardless of git changes.
  --app, -a VALUE    Deploy only the specified app (match by config path or basename).
  --help, -h         Show this message.
EOF
}

FORCE_DEPLOY=false
APP_SELECTOR=""
CONFIG_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
    --config | -c)
        if [ $# -lt 2 ]; then
            msg_error "--config requires a value"
            usage
            exit 1
        fi
        CONFIG_ARG="$2"
        shift
        ;;
    --force | -f)
        FORCE_DEPLOY=true
        ;;
    --app | -a)
        if [ $# -lt 2 ]; then
            msg_error "--app requires a value"
            usage
            exit 1
        fi
        APP_SELECTOR="$2"
        shift
        ;;
    --help | -h)
        usage
        exit 0
        ;;
    *)
        msg_error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
done

resolve_app_selector() {
    local selector="$1"
    [ -z "$selector" ] && return 1

    # normalize by trimming trailing slashes
    while [[ "$selector" == */ ]]; do
        selector="${selector%/}"
    done

    local rel_selector="$selector"
    if [[ "$selector" = /* ]]; then
        rel_selector="${selector#"$REPO"/}"
    fi

    for dir in "${app_dirs[@]:-}"; do
        if [ "$dir" = "$selector" ] || [ "$dir" = "$rel_selector" ] || [ "$REPO/$dir" = "$selector" ]; then
            echo "$dir"
            return 0
        fi
    done

    local base_selector
    base_selector="$(basename "$selector")"
    local -a matches=()
    for dir in "${app_dirs[@]:-}"; do
        if [ "$(basename "$dir")" = "$base_selector" ]; then
            matches+=("$dir")
        fi
    done

    if [ "${#matches[@]}" -eq 1 ]; then
        echo "${matches[0]}"
        return 0
    fi

    if [ "${#matches[@]}" -gt 1 ]; then
        msg_error "Ambiguous app selector '$selector' matches: ${matches[*]}"
        return 2
    fi

    return 1
}

# resolve config file path
if [ -n "$CONFIG_ARG" ]; then
    if [[ "$CONFIG_ARG" = /* ]]; then
        CONFIG="$CONFIG_ARG"
    else
        CONFIG="$REPO/$CONFIG_ARG"
    fi
else
    CONFIG="$REPO/gitops-apps.conf"
fi

if [ ! -f "$CONFIG" ]; then
    msg_error "Config file not found: $CONFIG"
    exit 1
fi

# parse app configuration (directory + optional extra config files)
declare -a app_dirs=()
declare -A app_extra_configs=()

while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    if [ -z "${line//[[:space:]]/}" ]; then
        continue
    fi
    read -r -a parts <<<"$line"
    app_dir="${parts[0]}"
    app_dirs+=("$app_dir")

    if [ "${#parts[@]}" -gt 1 ]; then
        extras=""
        for extra_file in "${parts[@]:1}"; do
            [ -z "$extra_file" ] && continue
            extras+="${extra_file}"$'\n'
        done
        app_extra_configs["$app_dir"]="$extras"
    fi
done <"$CONFIG"

SELECTED_APP_DIR=""
if [ -n "$APP_SELECTOR" ]; then
    if ! SELECTED_APP_DIR="$(resolve_app_selector "$APP_SELECTOR")"; then
        msg_error "No configured app matches selector '$APP_SELECTOR'"
        exit 1
    fi
fi

# load existing metrics state if present (shell-style key=value)
if [ -f "$METRICS_STATE" ]; then
    # shellcheck source=/dev/null
    . "$METRICS_STATE"
fi

force_status="no"
[ "$FORCE_DEPLOY" = true ] && force_status="yes"
selected_status="${SELECTED_APP_DIR:-auto}"
log INFO "deploy-agent start (force=$force_status app=$selected_status config=$CONFIG) repo=$REPO branch=$BRANCH"

cd "$REPO"
msg_info "Fetching origin/$BRANCH"
git fetch origin "$BRANCH"

OLD_REV=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$BRANCH")

if [ "$OLD_REV" = "$REMOTE" ] && [ "$FORCE_DEPLOY" != true ] && [ -z "$SELECTED_APP_DIR" ]; then
    log INFO "No new commits on $BRANCH; exiting"
    exit 0
fi

if ! git diff --quiet || ! git diff --quiet --cached; then
    msg_error "Working tree dirty, aborting deploy."
    log ERROR "Working tree dirty; aborting."
    exit 1
fi

msg_info "Pulling origin/$BRANCH"
git pull --ff-only origin "$BRANCH"

NEW_REV=$(git rev-parse HEAD)
log INFO "Pulled changes: $OLD_REV -> $NEW_REV"

redeploy_app() {
    local app_dir="$1"
    local service_name="$2"

    log INFO "Redeploying app=$service_name dir=$app_dir"
    (
        cd "$app_dir" || exit 1

        msg_info "Stopping quadlet service container-${service_name}.service"
        systemctl --user stop "container-${service_name}.service" 2>/dev/null || true

        msg_info "Bringing down containers for $service_name"
        podman-compose -p "$service_name" down || true

        msg_info "Starting containers for $service_name"
        podman-compose --in-pod=0 -p "$service_name" up -d --force-recreate

        msg_info "Deleting existing quadlet for $service_name"
        podman_quadlet.sh delete container "$service_name" 2>/dev/null || true

        msg_info "Creating quadlet for $service_name"
        podman_quadlet.sh create container "$service_name"

        msg_ok "Redeploy complete for $service_name"
        log INFO "Redeploy complete for $service_name"
    ) || {
        msg_error "Redeploy failed for $service_name"
        log ERROR "Redeploy failed for $service_name"
        return 1
    }
}

changed_app_dirs=()
declare -A seen_changed_dirs=()

add_changed_dir() {
    local dir="$1"
    [ -z "$dir" ] && return
    if [ -z "${seen_changed_dirs["$dir"]:-}" ]; then
        changed_app_dirs+=("$dir")
        seen_changed_dirs["$dir"]=1
    fi
}

if [ "$FORCE_DEPLOY" = true ]; then
    # force mode: treat all configured apps as changed
    for app_dir in "${app_dirs[@]}"; do
        add_changed_dir "$app_dir"
    done
elif [ -n "$SELECTED_APP_DIR" ]; then
    add_changed_dir "$SELECTED_APP_DIR"
else
    # determine which app directories have changed files
    mapfile -t changed_paths < <(git diff --name-only "$OLD_REV" "$NEW_REV")

    for app_dir in "${app_dirs[@]}"; do
        for path in "${changed_paths[@]}"; do
            case "$path" in
            "$app_dir"/*)
                add_changed_dir "$app_dir"
                break
                ;;
            esac
        done
    done
fi

# loop over managed apps that actually changed (or all, in force mode)
for app_dir in "${changed_app_dirs[@]}"; do
    [ -z "$app_dir" ] && continue

    service_name="$(basename "$app_dir")"

    # 1) decrypt env
    if [ -f "$app_dir/.app.env" ]; then
        sops --decrypt --input-type dotenv "$app_dir/.app.env" >"$app_dir/.env"
    fi

    extra_configs="${app_extra_configs["$app_dir"]-}"
    if [ -n "$extra_configs" ]; then
        while IFS= read -r extra_file; do
            extra_file="${extra_file#"${extra_file%%[![:space:]]*}"}"
            extra_file="${extra_file%"${extra_file##*[![:space:]]}"}"
            [ -z "$extra_file" ] && continue

            if [[ "$extra_file" = /* ]]; then
                target_path="$extra_file"
            else
                target_path="$app_dir/$extra_file"
            fi

            if [ ! -f "$target_path" ]; then
                msg_warn "Configured config $target_path missing; skipping decrypt"
                continue
            fi

            if rg -q --text 'ENC\[' "$target_path"; then
                msg_info "Decrypting $target_path"
                sops --decrypt --in-place "$target_path"
                msg_ok "Decrypted $target_path"
            else
                msg_info "Skipping decrypt for $target_path (already decrypted)"
            fi
        done <<<"$extra_configs"
    fi

    # 2) redeploy
    if redeploy_app "$app_dir" "$service_name"; then
        # increment per-app deploy counter
        service_safe="${service_name//[^a-zA-Z0-9_]/_}"
        var_key="deploy_count_${service_safe}"
        current="${!var_key:-0}"
        new=$((current + 1))
        printf -v "$var_key" '%s' "$new"
        log INFO "Incremented deploy counter for $service_name (key=$var_key) to $new"
    fi
done

# write metrics state
{
    for app_dir in "${changed_app_dirs[@]}"; do
        [ -z "$app_dir" ] && continue
        service_name="$(basename "$app_dir")"
        service_safe="${service_name//[^a-zA-Z0-9_]/_}"
        var_key="deploy_count_${service_safe}"
        value="${!var_key:-0}"
        [ -z "$value" ] && continue
        echo "${var_key}=${value}"
    done | sort -u
} >"$METRICS_STATE"

# generate Prometheus metrics file
if [ -s "$METRICS_STATE" ]; then
    # shellcheck source=/dev/null
    . "$METRICS_STATE"
    {
        echo "# HELP podman_gitops_deploy_total Number of successful gitops deploys per app"
        echo "# TYPE podman_gitops_deploy_total counter"
        while IFS='=' read -r key value; do
            [ -z "$key" ] && continue
            service_safe="${key#deploy_count_}"
            echo "podman_gitops_deploy_total{app=\"${service_safe}\"} ${value}"
        done <"$METRICS_STATE"
    } >"$METRICS_OUT"
    log INFO "Wrote metrics to $METRICS_OUT"
else
    log INFO "No metrics to write; $METRICS_STATE is empty"
fi

msg_ok "deploy-agent run complete"
log INFO "deploy-agent end"
