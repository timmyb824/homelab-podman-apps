#!/usr/bin/env bash
set -euo pipefail

PODLET="/home/tbryant/.local/bin/podlet"
NAME="scrutiny-collector"
UNIT_DIR="/etc/containers/systemd"
UNIT_FILE="${UNIT_DIR}/${NAME}.container"
SERVICE="${NAME}.service"

usage() {
  echo "Usage: $0 {create|delete}"
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

create() {
  require_root

  if [[ -f "$UNIT_FILE" ]]; then
    echo "Unit file already exists at $UNIT_FILE"
    echo "Run '$0 delete' first if you want to regenerate it."
    exit 1
  fi

  echo "Generating quadlet unit file..."
  "$PODLET" podman run \
    --name "$NAME" \
    --cap-add SYS_RAWIO \
    --cap-add SYS_ADMIN \
    --device /dev/sda \
    --device /dev/sdb \
    -e COLLECTOR_API_ENDPOINT=http://localhost:8091 \
    -e COLLECTOR_HOST_ID=scrutiny-collector-pihole2 \
    -e COLLECTOR_RUN_STARTUP=False \
    -e COLLECTOR_RUN_STARTUP_SLEEP=15 \
    -e COLLECTOR_CRON_SCHEDULE="0 * * * *" \
    -v /run/udev:/run/udev:z \
    -v /dev:/dev:z \
    --network=host \
    --privileged \
    ghcr.io/analogj/scrutiny:v0.9.3-collector \
    > "$UNIT_FILE"

  echo "Wrote $UNIT_FILE"

  echo "Reloading systemd daemon..."
  systemctl daemon-reload

  echo "Starting $SERVICE..."
  systemctl start "$SERVICE"

  echo "Status:"
  systemctl status "$SERVICE" --no-pager || true

  echo
  echo "Done. Verify with: podman ps"
}

delete() {
  require_root

  if [[ ! -f "$UNIT_FILE" ]]; then
    echo "No unit file found at $UNIT_FILE, nothing to delete."
    exit 0
  fi

  echo "Stopping $SERVICE..."
  systemctl stop "$SERVICE" || true

  echo "Removing $UNIT_FILE..."
  rm -f "$UNIT_FILE"

  echo "Reloading systemd daemon..."
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE" 2>/dev/null || true

  echo "Done. Verify with: podman ps"
}

[[ $# -eq 1 ]] || usage

case "$1" in
  create) create ;;
  delete) delete ;;
  *) usage ;;
esac
