set shell := ["bash", "-c"]

SKILL_SRC := justfile_directory() / "skills/symphony-setup"
SKILL_DST := env_var('HOME') / ".claude/skills/symphony-setup"

# レシピ一覧
default:
    @just --list --unsorted

# スキルを ~/.claude/skills/ にリンクする
install:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "$(dirname "{{ SKILL_DST }}")"
    ln -sfn "{{ SKILL_SRC }}" "{{ SKILL_DST }}"
    echo "linked {{ SKILL_DST }} -> {{ SKILL_SRC }}"

# スキルのリンクを外す
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -L "{{ SKILL_DST }}" ]; then
      rm "{{ SKILL_DST }}"
      echo "removed {{ SKILL_DST }}"
    else
      echo "not a symlink, leaving alone: {{ SKILL_DST }}"
    fi

# インストール状態を表示する
status:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -L "{{ SKILL_DST }}" ]; then
      echo "skill    : linked -> $(readlink "{{ SKILL_DST }}")"
    else
      echo "skill    : not installed (run: just install)"
    fi
    echo "symphony-ts : ${SYMPHONY_TS:-$HOME/tools/symphony-ts}"
    ls -d "${SYMPHONY_TS:-$HOME/tools/symphony-ts}" >/dev/null 2>&1 \
      && echo "            found" || echo "            MISSING"
    echo "instances:"
    ls -1 "${SYMPHONY_HOME:-$HOME/symphony}" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

# シェル/Python スクリプトを検査する
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v shellcheck >/dev/null 2>&1; then
      shellcheck skills/symphony-setup/scripts/*.sh
    else
      echo "shellcheck not installed; falling back to bash -n"
      for f in skills/symphony-setup/scripts/*.sh; do bash -n "$f"; done
    fi
    for f in skills/symphony-setup/scripts/*.py; do
      python3 -m py_compile "$f" && echo "OK $f"
    done

# lint とドキュメント整合性をまとめて確認する
ci: lint check-doc

# SYMPHONY_USAGE.md 14.4 の preview.sh 全文がスクリプト実体と一致するか確認する
check-doc:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    perl -ne 'print if /^### 14\.4/../^### 14\.5/' SYMPHONY_USAGE.md \
      | sed -n '/^```bash$/,/^```$/p' | sed '1d;$d' > "$tmp"
    if diff -q "$tmp" skills/symphony-setup/scripts/preview.sh >/dev/null; then
      echo "check-doc: preview.sh matches SYMPHONY_USAGE.md 14.4"
    else
      echo "check-doc: MISMATCH between SYMPHONY_USAGE.md 14.4 and scripts/preview.sh" >&2
      diff "$tmp" skills/symphony-setup/scripts/preview.sh || true
      exit 1
    fi

# 対象リポジトリのディレクトリで実行してインスタンスを作る
setup *ARGS:
    @{{ justfile_directory() }}/skills/symphony-setup/scripts/setup.sh {{ ARGS }}
