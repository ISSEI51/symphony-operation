#!/usr/bin/env bash
# Create a Symphony instance for one GitHub repository and apply the standard
# configuration documented in SYMPHONY_USAGE.md section 14.
#
# Run it from the target repository root, or pass --repo explicitly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYMPHONY_TS="${SYMPHONY_TS:-$HOME/tools/symphony-ts}"
SYMPHONY_HOME="${SYMPHONY_HOME:-$HOME/symphony}"

repo=""
instance=""
model="opus"
concurrency=10
with_preview="auto"
force=0

usage() {
  cat >&2 <<'EOF'
usage: setup.sh [options]

options:
  --repo <owner/repo>   target repository (default: origin remote of cwd)
  --instance <name>     instance directory name (default: repository name)
  --model <alias>       claude model alias (default: opus)
  --concurrency <n>     polling.max_concurrent_runs (default: 10)
  --preview <yes|no>    install bin/preview.sh (default: yes when package.json
                        or docker-compose.yml exists in cwd)
  --force               overwrite an existing instance directory
  -h, --help            show this message
EOF
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --instance) instance="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --concurrency) concurrency="${2:-}"; shift 2 ;;
    --preview) with_preview="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

# ---------------------------------------------------------------- preflight --
[ -d "$SYMPHONY_TS" ] || die "symphony-ts not found at $SYMPHONY_TS (set SYMPHONY_TS)"
command -v gh >/dev/null 2>&1 || die "gh is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

if [ -z "$repo" ]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git repository; pass --repo <owner/repo>"
  origin="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$origin" ] || die "no origin remote; pass --repo <owner/repo>"
  # git@github.com:owner/repo.git | https://github.com/owner/repo.git
  repo="$(printf '%s\n' "$origin" \
    | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
fi

case "$concurrency" in
  ""|*[!0-9]*) die "--concurrency must be a positive integer, got: $concurrency" ;;
esac
[ "$concurrency" -ge 1 ] || die "--concurrency must be >= 1, got: $concurrency"

case "$repo" in
  */*) ;;
  *) die "--repo must be <owner>/<repo>, got: $repo" ;;
esac

gh repo view "$repo" >/dev/null 2>&1 || die "cannot access repository: $repo"

[ -n "$instance" ] || instance="${repo##*/}"
instance_root="$SYMPHONY_HOME/$instance"
workflow="$instance_root/WORKFLOW.md"

if [ -e "$workflow" ] && [ "$force" -eq 0 ]; then
  die "instance already exists: $workflow (use --force to overwrite)"
fi

if [ "$with_preview" = "auto" ]; then
  if [ -f package.json ] || [ -f docker-compose.yml ] || [ -f compose.yaml ]; then
    with_preview="yes"
  else
    with_preview="no"
  fi
fi

# --------------------------------------------------------------- scaffolding --
echo "repo      : $repo"
echo "instance  : $instance_root"
echo "model     : $model"
echo "concurrency: $concurrency"
echo "preview   : $with_preview"
echo

mkdir -p "$instance_root"

init_args=(tsx bin/symphony.ts init "$instance_root"
  --tracker-repo "$repo" --runner claude-code)
[ "$force" -eq 1 ] && init_args+=(--force)

(cd "$SYMPHONY_TS" && pnpm "${init_args[@]}") >/dev/null

[ -f "$workflow" ] || die "symphony init did not produce $workflow"

# ------------------------------------------------- standard customization 1/4 --
# Model. SYMPHONY_USAGE.md 14.1
perl -pi -e "s/--model sonnet\$/--model ${model}/" "$workflow"
grep -q -- "--model ${model}" "$workflow" || die "failed to set --model ${model}"

# ------------------------------------------------- standard customization 2/4 --
# Block cloud credentials from the runner subprocess. SYMPHONY_USAGE.md 14.2
perl -0pi -e 's/^  env: \{\}$/  env:\n    AWS_PROFILE: ""\n    AWS_DEFAULT_PROFILE: ""\n    AWS_ACCESS_KEY_ID: ""\n    AWS_SECRET_ACCESS_KEY: ""\n    AWS_SESSION_TOKEN: ""\n    AWS_REGION: ""\n    AWS_DEFAULT_REGION: ""\n    AWS_EC2_METADATA_DISABLED: "true"\n    AWS_SHARED_CREDENTIALS_FILE: "\/dev\/null"\n    AWS_CONFIG_FILE: "\/dev\/null"/m' "$workflow"
grep -q "AWS_ACCESS_KEY_ID" "$workflow" || die "failed to inject agent.env"

# ------------------------------------------------- standard customization 3/4 --
# Issue completion is owned by Symphony. SYMPHONY_USAGE.md 14.3
if ! grep -q "auto-closing keywords" "$workflow"; then
  printf '%s\n' \
    '10. Never use GitHub auto-closing keywords such as `Closes #...`, `Fixes #...`, or `Resolves #...` in pull request titles, bodies, or commit messages. Issue completion is owned by Symphony.' \
    >> "$workflow"
fi

# ------------------------------------------------- standard customization 4/4 --
# Concurrency. SYMPHONY_USAGE.md 14.4
perl -pi -e "s/^  max_concurrent_runs: \\d+\$/  max_concurrent_runs: ${concurrency}/" "$workflow"
grep -q "^  max_concurrent_runs: ${concurrency}\$" "$workflow" \
  || die "failed to set max_concurrent_runs: ${concurrency}"

# ----------------------------------------------------------- optional tuning --
if [ "$with_preview" = "yes" ]; then
  mkdir -p "$instance_root/bin"
  cp "$SCRIPT_DIR/preview.sh" "$instance_root/bin/preview.sh"
  chmod +x "$instance_root/bin/preview.sh"
fi

# ------------------------------------------------------------------ summary --
echo "created:"
echo "  $workflow"
echo "  $instance_root/OPERATOR.md"
[ "$with_preview" = "yes" ] && echo "  $instance_root/bin/preview.sh"
echo
echo "next:"
echo "  cd $SYMPHONY_TS"
echo "  pnpm tsx bin/symphony.ts factory start \\"
echo "    --workflow $workflow \\"
echo "    --i-understand-that-this-will-be-running-without-the-usual-guardrails"
