#!/usr/bin/env bash
# Start the app from a Symphony workspace for one issue, on a port derived from
# the issue number. Issue #42 always lands on http://localhost:3042.
#
# A workspace gets its own PostgreSQL and OpenSearch volumes, so it starts with
# an empty database. To make an issue verifiable without re-seeding by hand,
# the data directories are copied from the main checkout's volumes on first
# start. See cmd_sync_data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="${SYMPHONY_WORKSPACES:-$(cd "$SCRIPT_DIR/.." && pwd)/.tmp/workspaces}"

# setup.sh writes preview.conf next to this script with the two facts only it
# knows: where the main checkout is, and what its compose project is called.
# The file assigns with ":=" so an exported variable still wins.
CONF_FILE="${SYMPHONY_PREVIEW_CONF:-$SCRIPT_DIR/preview.conf}"
# shellcheck source=/dev/null
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# docker-compose.yml commonly references `env_file: .env`, which is gitignored
# and so is absent from a fresh workspace clone. Seed it from the main checkout.
# Empty disables seeding.
ENV_SOURCE="${SYMPHONY_ENV_SOURCE:-}"
# Compose project whose data volumes are copied into a new workspace. Empty
# disables copying, and every workspace then starts with an empty database.
SOURCE_PROJECT="${SYMPHONY_SOURCE_PROJECT:-}"
# Data volumes to copy, as <compose volume name>:<path that proves it is seeded>.
# Trim this when a volume is large and cheap to rebuild from the repository's
# own seed command:
#   SYMPHONY_DATA_VOLUMES="postgres_data:PG_VERSION" preview.sh <N>
read -r -a DATA_VOLUMES <<<"${SYMPHONY_DATA_VOLUMES:-postgres_data:PG_VERSION opensearch_data:nodes}"
# Extra .env variable names to drop while seeding, space or comma separated.
# See seed_env_file for the ones dropped unconditionally.
ENV_DROP="${SYMPHONY_ENV_DROP:-}"
# Values that must follow this workspace's ports whatever the workspace .env
# says. Compose resolves ${VAR} from the shell before reading .env, so
# exporting these wins without editing a file the agent also writes to.
#
# Entries are NAME=VALUE, separated by ";" or newlines. The placeholders
# {web} {api} {db} {opensearch} {redis} become this issue's ports. A browser
# facing API base URL is the usual case:
#   SYMPHONY_ENV_OVERRIDE='NEXT_PUBLIC_API_BASE_URL=http://localhost:{api}/api/v1'
ENV_OVERRIDE="${SYMPHONY_ENV_OVERRIDE:-}"

usage() {
  cat >&2 <<'EOF'
usage:
  preview.sh list                running workspaces and their ports
  preview.sh <issue>             start the app for that issue
  preview.sh stop <issue>        stop the compose stack for that issue
  preview.sh sync-data <issue>   re-copy the database from the main checkout
                                 (discards that workspace's own data)

Defaults come from preview.conf next to this script, written by setup.sh.
Environment variables override it.

environment:
  SYMPHONY_ENV_SOURCE       .env to seed a workspace from (empty: no seeding)
  SYMPHONY_SOURCE_PROJECT   compose project to copy data from (empty: no copy)
  SYMPHONY_DATA_VOLUMES     volumes to copy, space separated <volume>:<marker>
                            (default: postgres_data:PG_VERSION opensearch_data:nodes)
  SYMPHONY_ENV_DROP         extra .env names to drop while seeding
  SYMPHONY_ENV_OVERRIDE     NAME=VALUE pairs exported over .env, with the
                            placeholders {web} {api} {db} {opensearch} {redis}
EOF
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
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

# ---------------------------------------------------------------------- env --

# Seed the workspace .env from the main checkout, minus the settings that are
# only correct for the main checkout.
#
# A workspace runs on ports derived from its issue number, so any value that
# pins a host port sends the browser or a service to the wrong stack. The
# symptom is a working page whose API calls fail: the frontend keeps calling
# the port written in the copied .env instead of its own. Dropped here, the
# compose defaults apply and resolve to this workspace's ports.
seed_env_file() {
  [ -f .env ] && return 0
  [ -f "$ENV_SOURCE" ] || return 0

  awk -v extra="$ENV_DROP" '
    BEGIN {
      n = split(extra, a, /[ ,]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") drop[a[i]] = 1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    {
      eq = index($0, "=")
      if (eq == 0) { print; next }
      name = substr($0, 1, eq - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      value = substr($0, eq + 1)
      if (name in drop ||
          name ~ /^HOST_[A-Z0-9_]+$/ ||
          name == "COMPOSE_PROJECT_NAME" ||
          value ~ /(localhost|127\.0\.0\.1):[0-9]+/) {
        printf "# removed by preview.sh (host-port specific): %s\n", name
        removed++
        next
      }
      print
    }
    END { if (removed > 0) printf "# %d line(s) removed\n", removed }
  ' "$ENV_SOURCE" >.env

  local dropped
  dropped="$(grep -c '^# removed by preview.sh' .env || true)"
  echo "env       : copied from $ENV_SOURCE (${dropped} host-port setting(s) removed)"
}

# Export the ENV_OVERRIDE entries with this issue's ports substituted in.
#
# The workspace .env is written by the agent as well as by seed_env_file, and
# an agent picks its own ports. Rather than editing that file on every start —
# which the agent would simply overwrite again — these values are exported, and
# Compose prefers the shell over .env when resolving ${VAR}.
apply_env_overrides() {
  local web="$1" api="$2" db="$3" opensearch="$4" redis="$5"
  local entry name value

  [ -n "$ENV_OVERRIDE" ] || return 0

  while IFS= read -r entry; do
    entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$entry" ] || continue
    case "$entry" in
      \#*) continue ;;
      *=*) ;;
      *) die "SYMPHONY_ENV_OVERRIDE entry is not NAME=VALUE: $entry" ;;
    esac
    name="${entry%%=*}"
    value="$(printf '%s' "${entry#*=}" | sed \
      -e "s/{web}/${web}/g" \
      -e "s/{api}/${api}/g" \
      -e "s/{db}/${db}/g" \
      -e "s/{opensearch}/${opensearch}/g" \
      -e "s/{redis}/${redis}/g")"
    export "${name}=${value}"
    echo "env       : ${name}=${value}"
  done <<<"${ENV_OVERRIDE//;/$'\n'}"
}

# --------------------------------------------------------------------- data --

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

# True when the volume holds a seeded data directory, identified by a marker
# path that the service creates on first boot.
volume_seeded() {
  local vol="$1" marker="$2"
  volume_exists "$vol" || return 1
  docker run --rm -v "$vol":/v:ro alpine test -e "/v/$marker" >/dev/null 2>&1
}

project_running() {
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=$1" 2>/dev/null)" ]
}

copy_volume() {
  local src="$1" dst="$2"
  docker volume create "$dst" >/dev/null
  # `cp -a /from/.` includes dotfiles. The target is cleared first so a re-sync
  # cannot leave files from the previous contents behind.
  docker run --rm -v "$src":/from:ro -v "$dst":/to alpine \
    sh -c 'find /to -mindepth 1 -delete && cp -a /from/. /to/'
}

# Copy every data volume from SOURCE_PROJECT into the workspace's project.
# `force` (arg 2) re-copies volumes that already hold data.
sync_data() {
  local issue="$1" force="${2:-0}"
  local project="symphony-${issue}"
  local entry vol marker src dst copied=0 skipped=0

  if [ -z "$SOURCE_PROJECT" ]; then
    echo "data      : skipped (SYMPHONY_SOURCE_PROJECT is not set)"
    return 0
  fi

  if project_running "$SOURCE_PROJECT"; then
    die "source project '$SOURCE_PROJECT' is running. A file-level copy of a
       live data directory is inconsistent. Stop it first:
         docker compose -p $SOURCE_PROJECT down"
  fi

  if project_running "$project"; then
    echo "stopping $project before copying data"
    docker compose -p "$project" down >/dev/null 2>&1 || true
  fi

  for entry in "${DATA_VOLUMES[@]}"; do
    vol="${entry%%:*}"
    marker="${entry##*:}"
    src="${SOURCE_PROJECT}_${vol}"
    dst="${project}_${vol}"

    if ! volume_seeded "$src" "$marker"; then
      echo "data      : skip ${vol} (source ${src} is absent or empty)"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$force" != "1" ] && volume_seeded "$dst" "$marker"; then
      echo "data      : keep ${vol} (workspace already has data)"
      skipped=$((skipped + 1))
      continue
    fi

    echo "data      : copying ${src} -> ${dst}"
    copy_volume "$src" "$dst"
    copied=$((copied + 1))
  done

  echo "data      : ${copied} copied, ${skipped} unchanged"
}

cmd_sync_data() {
  local issue="$1"
  resolve_workspace "$issue" >/dev/null
  sync_data "$issue" 1
  echo
  echo "start it with: $0 ${issue}"
}

# ----------------------------------------------------------------- commands --

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
  local issue="$1" ws web api db opensearch redis
  ws="$(resolve_workspace "$issue")"
  web=$((3000 + issue))
  api=$((8000 + issue))
  db=$((5432 + issue))
  opensearch=$((9200 + issue))
  redis=$((6379 + issue))

  cd "$ws"
  echo "workspace : $ws"
  echo "branch    : $(git branch --show-current)"
  echo "web       : http://localhost:${web}"

  if [ -f docker-compose.yml ] || [ -f compose.yaml ]; then
    seed_env_file
    # Copy the database on first start only. An existing workspace database is
    # left alone so a restart does not discard what was entered during review.
    sync_data "$issue" 0

    export COMPOSE_PROJECT_NAME="symphony-${issue}"
    # Names must match the HOST_* variables in the repository's docker-compose.yml.
    export HOST_FRONTEND_PORT="$web" HOST_BACKEND_PORT="$api" HOST_DB_PORT="$db"
    export HOST_OPENSEARCH_PORT="$opensearch"
    export REDIS_PORT="$redis"
    apply_env_overrides "$web" "$api" "$db" "$opensearch" "$redis"
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
  sync-data) [ $# -eq 2 ] || usage; cmd_sync_data "$2" ;;
  *[!0-9]*) usage ;;
  *) cmd_start "$1" ;;
esac
