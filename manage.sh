#!/bin/bash
# manage.sh: build, run, and manage the notify container.
#
# Usage: ./manage.sh <command>
#   build             build the notify image
#   start             build if needed, then start the container
#   stop              stop the container
#   restart           restart the container
#   status            show container and config
#   logs [-f]         show container logs (flags pass through)
#   add-token [topic] mint a friend token (topic defaults to main)
#   purge [--yes] [--data]  remove container and image (data kept
#                     unless --data is given; without --yes, dry run)
#
# Config (env): NOTIFY_DATA_DIR (default /var/lib/notify),
# NOTIFY_PORT (default 47124, host side, localhost only),
# NOTIFY_TOKEN (required for start, the admin token).
#
# The container runs only notify.go, as user 10001, read-only,
# with all capabilities dropped. Caddy on the host proxies
# /notify to 127.0.0.1:$NOTIFY_PORT. Needs docker and root (for
# the data dir ownership); run with sudo like caddy.sh.

set -u
IMG=notify
CONTAINER=notify
DATA_DIR=${NOTIFY_DATA_DIR:-/var/lib/notify}
PORT=${NOTIFY_PORT:-47124}
CDIR=$(cd "$(dirname "$0")" && pwd)

[ "$DATA_DIR" = "/" ] && { echo "error: NOTIFY_DATA_DIR must not be /" >&2; exit 1; }

die() { echo "error: $*" >&2; exit 1; }
need_docker() { command -v docker >/dev/null 2>&1 || die "docker not found"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo or as root"; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# //;s/^#$//'
  exit 1
}

build_cmd() {
  need_docker
  docker build -t "$IMG" "$CDIR" || die "docker build failed"
}

prepare_data() {
  mkdir -p "$DATA_DIR" || die "cannot create $DATA_DIR"
  chown 10001:10001 "$DATA_DIR" || die "cannot chown $DATA_DIR"
  chmod 750 "$DATA_DIR"
}

start_cmd() {
  need_docker; need_root
  [ -n "${NOTIFY_TOKEN:-}" ] || die "NOTIFY_TOKEN is not set (example: NOTIFY_TOKEN=\$(openssl rand -hex 16) ./manage.sh start)"
  docker image inspect "$IMG" >/dev/null 2>&1 || build_cmd
  prepare_data
  if docker ps -f "name=^${CONTAINER}$" --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "already running"
    return 0
  fi
  docker ps -a -f "name=^${CONTAINER}$" --format '{{.Names}}' | grep -q "^${CONTAINER}$" && docker rm "$CONTAINER" >/dev/null
  docker run -d --name "$CONTAINER" --restart unless-stopped \
    --read-only --cap-drop=ALL --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid --memory=128m --cpus=0.5 \
    --user 10001:10001 -p "127.0.0.1:${PORT}:47124" \
    -v "$DATA_DIR:/data" -w /data -e NOTIFY_TOKEN="$NOTIFY_TOKEN" \
    "$IMG" || die "docker run failed"
  echo "started, data in $DATA_DIR, proxied port 127.0.0.1:$PORT"
}

stop_cmd() {
  need_docker
  docker ps -f "name=^${CONTAINER}$" --format '{{.Names}}' | grep -q "^${CONTAINER}$" || { echo "not running"; return 0; }
  docker stop "$CONTAINER" >/dev/null || die "docker stop failed"
  echo "stopped"
}

restart_cmd() {
  need_docker
  docker restart "$CONTAINER" >/dev/null || die "docker restart failed (is it started?)"
  echo "restarted"
}

status_cmd() {
  need_docker
  docker ps -a -f "name=^${CONTAINER}$"
  echo "data dir: $DATA_DIR"
  echo "host port: 127.0.0.1:$PORT"
}

logs_cmd() {
  need_docker
  docker logs "$@" "$CONTAINER" || die "docker logs failed (is it started?)"
}

add_token_cmd() {
  need_docker; need_root
  prepare_data
  docker image inspect "$IMG" >/dev/null 2>&1 || build_cmd
  docker run --rm --read-only --cap-drop=ALL --security-opt no-new-privileges:true \
    --user 10001:10001 -v "$DATA_DIR:/data" -w /data "$IMG" add_token "$@" \
    || die "add_token failed"
}

purge_cmd() {
  need_docker
  local yes=0 data=0
  for a in "$@"; do
    case "$a" in
      --yes) yes=1 ;;
      --data) data=1 ;;
      *) die "unknown purge flag: $a" ;;
    esac
  done
  echo "plan: remove container $CONTAINER (if any), remove image $IMG (if any)"
  if [ "$data" -eq 1 ]; then echo "plan: also delete data dir $DATA_DIR (alerts and friend tokens)"; else echo "plan: keep data dir $DATA_DIR"; fi
  [ "$yes" -eq 1 ] || { echo "dry run, nothing changed (add --yes to execute)"; return 0; }
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker rmi "$IMG" >/dev/null 2>&1 || true
  if [ "$data" -eq 1 ]; then rm -rf "$DATA_DIR"; echo "deleted $DATA_DIR"; fi
  echo "purged"
}

case "${1:-}" in
  build) build_cmd ;;
  start) start_cmd ;;
  stop) stop_cmd ;;
  restart) restart_cmd ;;
  status) status_cmd ;;
  logs) shift; logs_cmd "$@" ;;
  add-token) shift; add_token_cmd "$@" ;;
  purge) shift; purge_cmd "$@" ;;
  *) usage ;;
esac
