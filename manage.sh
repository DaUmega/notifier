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
#   shell             open a shell on the data dir (edit tokens.txt by hand)
#   help              show usage, examples, and RSS reader info
#   purge [--yes] [--data]  remove container and image (data kept
#                     unless --data is given; without --yes, dry run)
#
# Config (env): NOTIFY_DATA_DIR (default /var/lib/notify),
# NOTIFY_PORT (default 47124, host side, localhost only),
# NOTIFY_TOKEN (required for start, the admin token),
# NOTIFY_DOMAIN (required for start, the public domain; saved at start for add-token).
#
# The container runs only notify.go, as user 10001, read-only,
# with all capabilities dropped. Caddy on the host proxies
# /notifier to 127.0.0.1:$NOTIFY_PORT. Needs docker and root (for
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

clean_domain() {
  local d=${1#https://}
  d=${d#http://}
  d=${d%/}
  printf '%s' "$d"
}

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
  [ -n "${NOTIFY_DOMAIN:-}" ] || die "NOTIFY_DOMAIN is not set (example: NOTIFY_DOMAIN=your-domain.com ./manage.sh start)"
  docker image inspect "$IMG" >/dev/null 2>&1 || build_cmd
  prepare_data
  clean_domain "$NOTIFY_DOMAIN" > "$DATA_DIR/domain" || die "cannot save domain"
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
  local out tok top domain
  out=$(docker run --rm --read-only --cap-drop=ALL --security-opt no-new-privileges:true \
    --user 10001:10001 -v "$DATA_DIR:/data" -w /data "$IMG" add_token "$@" 2>&1) \
    || die "add_token failed"
  echo "$out"
  tok=$(printf '%s\n' "$out" | awk '/^added: /{print $2}')
  top=$(printf '%s\n' "$out" | awk '/^added: /{print $3}')
  domain=${NOTIFY_DOMAIN:-}
  if [ -z "$domain" ] && [ -f "$DATA_DIR/domain" ]; then domain=$(cat "$DATA_DIR/domain"); fi
  domain=$(clean_domain "$domain")
  if [ -n "$tok" ] && [ -n "$top" ] && [ -n "$domain" ]; then
    echo "feed: https://$domain/notifier/feed?token=$tok&topic=$top"
  elif [ -z "$domain" ]; then
    echo "tip: set NOTIFY_DOMAIN=your-domain.com at start or add-token time to print the full feed URL"
  fi
}

shell_cmd() {
  need_docker; need_root
  prepare_data
  docker run --rm -it --read-only --cap-drop=ALL --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid --user 10001:10001 \
    -v "$DATA_DIR:/data" -w /data alpine sh
  local rc=$?
  [ -f "$DATA_DIR/tokens.txt" ] && chmod 600 "$DATA_DIR/tokens.txt" 2>/dev/null || true
  [ "$rc" -ne 0 ] && die "shell exited with status $rc"
  echo "shell closed"
}

help_cmd() {
  cat <<'EOF'
notify: dependency-free self notifier (Go stdlib only).
Monitoring scripts POST alerts; you read them on a page or RSS.

Through your reverse proxy (Caddy maps /notifier to the app):

  POST /notifier/alert   post an alert (needs a token)
  GET  /notifier/alerts  recent alerts as a page
  GET  /notifier/feed    alerts as RSS, optionally by topic
  GET  /notifier/healthz answers ok, for a heartbeat watcher

Post an alert:

  curl -X POST https://your-domain.com/notifier/alert \
    -H 'X-Token: <token>' \
    -d '{"title":"VPS disk alert","message":"Disk at 92%","topic":"self"}'

The token goes in the X-Token header. The admin token
(NOTIFY_TOKEN) works for every topic. A friend token works
only for its listed topics; a post with no topic defaults to
the friend's first listed topic.

Read the feed on your phone:

  https://your-domain.com/notifier/feed?token=<friend-token>&topic=<topic>

No signup, no account: paste that link into any RSS reader.
Two readers that need no account at all:

  Android: Feeder (free, open source, on F-Droid)
  iPhone:  NetNewsWire (free, open source, on the App Store)

Set the reader to refresh on an interval you like (15 minutes
is a good default); it polls, so an alert shows up at most
one refresh interval late. Use a friend token in the link,
never the admin token: anyone with the link can read that
topic's feed, and a friend token only exposes its own topics.

Friends:

  sudo ./manage.sh add-token andy-watch

That prints a token for a new topic. If NOTIFY_DOMAIN was set
at start, or is set now, it also prints the full feed URL
for that token. For a shared topic, run add-token with the
same topic name. Annotate tokens.txt by
hand with ./manage.sh shell; lines starting with # are
comments, and the file is re-read on every request, so no
restart is needed after editing.

Data lives in the data dir (default /var/lib/notify):
alerts.jsonl (the alert log) and tokens.txt (friend tokens).
EOF
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
  shell) shell_cmd ;;
  help) help_cmd ;;
  purge) shift; purge_cmd "$@" ;;
  *) usage ;;
esac
