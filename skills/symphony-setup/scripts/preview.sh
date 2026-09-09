#!/usr/bin/env bash
# Start the app from a Symphony workspace for one issue, on a port derived from
# the issue number. Issue #42 always lands on http://localhost:3042.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="${SYMPHONY_WORKSPACES:-$(cd "$SCRIPT_DIR/.." && pwd)/.tmp/workspaces}"

usage() {
  cat >&2 <<'EOF'
usage:
  preview.sh list             running workspaces and their ports
  preview.sh <issue>          start the app for that issue
  preview.sh stop <issue>     stop the compose stack for that issue
EOF
  exit 2
}

resolve_workspace() {
  local issue="$1" ws
  ws="$(find "$WS_ROOT" -maxdepth 1 -type d -name "*_${issue}" -print -quit)"
  if [ -z "$ws" ]; then
    echo "no workspace for issue #${issue} under ${WS_ROOT}" >&2
    exit 1
  fi
  printf '%s\n' "$ws"
}

cmd_list() {
  printf '%-34s %-8s %s\n' WORKSPACE ISSUE URL
  for ws in "$WS_ROOT"/*_[0-9]*; do
    [ -d "$ws" ] || continue
    local name issue
    name="$(basename "$ws")"
    issue="${name##*_}"
    printf '%-34s %-8s %s\n' "$name" "#$issue" "http://localhost:$((3000 + issue))"
  done
}

cmd_stop() {
  local issue="$1" ws
  ws="$(resolve_workspace "$issue")"
  cd "$ws"
  COMPOSE_PROJECT_NAME="symphony-${issue}" docker compose down
}

cmd_start() {
  local issue="$1" ws web api db
  ws="$(resolve_workspace "$issue")"
  web=$((3000 + issue))
  api=$((8000 + issue))
  db=$((5432 + issue))

  cd "$ws"
  echo "workspace : $ws"
  echo "branch    : $(git branch --show-current)"
  echo "web       : http://localhost:${web}"

  if [ -f docker-compose.yml ] || [ -f compose.yaml ]; then
    export COMPOSE_PROJECT_NAME="symphony-${issue}"
    export HOST_FRONTEND_PORT="$web" HOST_API_PORT="$api" HOST_DB_PORT="$db"
    exec docker compose up
  fi

  if [ -f package.json ]; then
    [ -d node_modules ] || pnpm install --frozen-lockfile
    export PORT="$web"
    exec pnpm dev
  fi

  echo "no docker-compose.yml and no package.json in ${ws}" >&2
  exit 1
}

case "${1:-}" in
  "") usage ;;
  list) cmd_list ;;
  stop) [ $# -eq 2 ] || usage; cmd_stop "$2" ;;
  *[!0-9]*) usage ;;
  *) cmd_start "$1" ;;
esac
