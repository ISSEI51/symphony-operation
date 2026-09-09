---
name: symphony-setup
description: Set up a Symphony factory for the repository in the current directory so GitHub Issues labeled symphony:ready are implemented by Claude Code automatically. Use when the user asks to enable Symphony, set up the Symphony factory, run Symphony on this repo, automate issues with Symphony, or start/stop/check the factory for the current project.
---

# Symphony Setup

Create and operate a Symphony instance for the repository in the current working
directory.

Full operating guide: `SYMPHONY_USAGE.md` in the `symphony-operation` repository.
Read it when the user asks anything beyond the steps below.

## Scope

One Symphony instance drives exactly one GitHub repository. The instance lives
outside the target repository, at `~/symphony/<instance>/`. **Never add Symphony
files to the target repository.**

## Step 1: Preflight

Run from the target repository root:

```bash
git remote get-url origin
gh auth status
ls ~/tools/symphony-ts
```

Stop and tell the user what is missing if any of these fail:

- not a git repository, or no `origin` remote — ask for `<owner>/<repo>`
- `gh` unauthenticated — tell the user to run `gh auth login` themselves
- `~/tools/symphony-ts` absent — ask where symphony-ts is checked out, then pass
  it as `SYMPHONY_TS=<path>`

## Step 2: Decide options

Inspect the repository and choose:

| Option | Rule |
| --- | --- |
| `--model` | `opus` (default). Use `sonnet` only if the user says the repo carries routine work only |
| `--concurrency` | omit unless the user wants parallel issues. `3` is a reasonable first value |
| `--preview` | `yes` when `package.json`, `docker-compose.yml`, or `compose.yaml` exists (auto-detected). Installs `bin/preview.sh` |

Report the choices to the user in one line before running.

## Step 3: Create the instance

```bash
<skill-dir>/scripts/setup.sh
```

The script is idempotent-guarded: it refuses to overwrite an existing instance
unless `--force` is passed. It performs:

1. `symphony init --runner claude-code` into `~/symphony/<instance>/`
2. sets `--model` in `agent.command`
3. blanks AWS credential environment variables in `agent.env`
4. appends the rule that forbids `Closes #...` in PR bodies
5. installs `bin/preview.sh` when requested

Each step is verified inside the script; it exits non-zero on failure.

## Step 4: Verify

```bash
grep -n -- "--model" ~/symphony/<instance>/WORKFLOW.md
grep -c AWS_ ~/symphony/<instance>/WORKFLOW.md
tail -1 ~/symphony/<instance>/WORKFLOW.md
```

Expect the chosen model, 10 AWS lines, and the auto-closing-keywords rule.

## Step 5: Check host ports in development compose files

Skip when the repository has no compose file.

Hardcoded host ports make the second parallel workspace fail to start, and they
break `preview.sh`. **This is the only step that touches the target repository,
so report first and write only after the user agrees.**

```bash
python3 <skill-dir>/scripts/compose_ports.py
```

It prints a unified diff and exits 1 when changes are needed. The rewrite turns
`- "3000:3000"` into `- "${HOST_WEB_PORT:-3000}:3000"`, so **with the variable
unset the resolved configuration is byte-identical to before**. Prove that when
the user is cautious about an existing setup:

```bash
docker compose config > /tmp/compose-before.txt
python3 <skill-dir>/scripts/compose_ports.py --write
docker compose config > /tmp/compose-after.txt
diff /tmp/compose-before.txt /tmp/compose-after.txt   # must print nothing
```

Otherwise apply with:

```bash
python3 <skill-dir>/scripts/compose_ports.py --write
```

| | |
| --- | --- |
| considered | `docker-compose.yml/.yaml`, `docker-compose.dev.*`, `docker-compose.override.*`, `compose.yml/.yaml`, `compose.dev.*`, `compose.override.*` |
| refused | any name containing `prod`, `production`, `stg`, `staging`, `release`, `live` — even when passed via `--file` |
| left alone | entries already containing `$`, container-only entries such as `"6379"`, entries it cannot parse (reported as `WARN`) |
| preserved | container port, bind IP, `/tcp` `/udp` suffix, port ranges, comments, indentation |
| variable name | `HOST_<SERVICE>_PORT`, with `_2`, `_3` when a service exposes several ports |

Never pass a production compose file with `--file`. The script refuses those
names, but do not attempt to work around it.

If the script warns that `.env` is missing from `.gitignore`, tell the user; do
not edit `.gitignore` yourself unless asked.

## Step 6: Start

Ask the user before starting — the factory runs Claude Code with
`bypassPermissions` against a live repository.

```bash
cd ~/tools/symphony-ts

pnpm tsx bin/symphony.ts factory start \
  --workflow ~/symphony/<instance>/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Then show the dashboard command and stop:

```bash
pnpm tsx bin/symphony.ts factory attach \
  --workflow ~/symphony/<instance>/WORKFLOW.md
```

## Step 7: Tell the user how to hand over work

```bash
gh issue create --repo <owner>/<repo> \
  --title "<title>" --body "<body>" --label "symphony:ready"
```

The three `symphony:*` labels are created automatically on the first poll cycle.

## Operating an existing instance

| Intent | Command |
| --- | --- |
| status | `pnpm tsx bin/symphony.ts factory status --workflow <workflow>` |
| dashboard | `pnpm tsx bin/symphony.ts factory attach --workflow <workflow>` |
| stop | `pnpm tsx bin/symphony.ts factory stop --workflow <workflow>` |
| apply config change | edit `WORKFLOW.md`, then `factory restart --workflow <workflow>` |
| preview issue #N | `~/symphony/<instance>/bin/preview.sh <N>` |

All from `~/tools/symphony-ts`.

## Merging

Symphony stops at `landing-command` after opening a PR and waits for a merge
instruction. Tell the user, do not decide for them:

- **`/land` as a PR comment** — first non-empty line must be exactly `/land`.
  Symphony verifies checks, mergeability, and review threads before merging
- **manual merge** (browser button or `gh pr merge`) — Symphony detects the
  merge on the next poll and still closes the issue and cleans the workspace,
  but skips its own guard checks

Never post `/land` on the user's behalf unless they explicitly ask for it in the
current turn.

## Rules

- Do not create, modify, or delete files inside the target repository. The one
  exception is Step 5, which rewrites host ports in development compose files —
  show the diff and get the user's agreement before writing, and never touch a
  production, staging, or release compose file
- Do not run `factory start` without asking
- Do not create GitHub issues, comments, or merges unless the user asks
- If an instance already exists for this repository, report its path and current
  status instead of creating a second one
