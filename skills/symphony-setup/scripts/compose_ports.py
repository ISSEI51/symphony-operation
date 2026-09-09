#!/usr/bin/env python3
"""Parameterize host ports in development compose files.

Symphony runs several issues in parallel, each in its own workspace clone.
Hardcoded host ports make the second workspace fail to start. This rewrites

    - "3000:3000"

into

    - "${HOST_WEB_PORT:-3000}:3000"

so an unset variable reproduces the current behaviour byte for byte. Only the
host side is touched; the container side never changes because services address
each other by service name.

Safety rules:
  * only files on an explicit development allowlist are considered
  * any path whose name suggests production/staging is refused
  * entries that already contain "$" are left alone
  * entries that cannot be parsed are reported, never rewritten
  * container-only entries ("3000") have no host port and are skipped
  * default mode is --check; --write is required to modify anything

Exit codes: 0 nothing to do, 1 changes needed (--check) or error, 2 usage.
"""
from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

# Files we are willing to rewrite. Anything not listed here is ignored.
DEV_COMPOSE_NAMES = (
    "docker-compose.yml",
    "docker-compose.yaml",
    "docker-compose.dev.yml",
    "docker-compose.dev.yaml",
    "docker-compose.override.yml",
    "docker-compose.override.yaml",
    "compose.yml",
    "compose.yaml",
    "compose.dev.yml",
    "compose.dev.yaml",
    "compose.override.yml",
    "compose.override.yaml",
)

# Refused even if passed explicitly.
FORBIDDEN_TOKENS = (
    "prod",
    "production",
    "stg",
    "staging",
    "release",
    "live",
)

SHORT_PORT_RE = re.compile(
    r"""^
    (?:(?P<ip>\[[0-9A-Fa-f:]+\]|[0-9]{1,3}(?:\.[0-9]{1,3}){3}):)?
    (?P<host>[0-9]+(?:-[0-9]+)?)
    :
    (?P<container>[0-9]+(?:-[0-9]+)?)
    (?P<proto>/(?:tcp|udp))?
    $""",
    re.VERBOSE,
)

LIST_ITEM_RE = re.compile(r"^(?P<indent>\s*)-\s+(?P<value>.*?)(?P<comment>\s+#.*)?$")
KEY_RE = re.compile(r"^(?P<indent>\s*)(?P<key>[A-Za-z0-9_.-]+):\s*(?P<value>.*?)$")
PUBLISHED_RE = re.compile(
    r"^(?P<indent>\s*)published:\s*(?P<quote>[\"']?)(?P<value>[^\"'#]*)(?P=quote)(?P<rest>.*)$"
)


def sanitize(name: str) -> str:
    cleaned = re.sub(r"[^0-9A-Za-z]+", "_", name).strip("_").upper()
    return cleaned or "SERVICE"


class Namer:
    """HOST_<SERVICE>_PORT, with _2, _3 ... for services exposing several ports."""

    def __init__(self) -> None:
        self._counts: dict[str, int] = {}

    def next_for(self, service: str) -> str:
        base = f"HOST_{sanitize(service)}_PORT"
        count = self._counts.get(base, 0) + 1
        self._counts[base] = count
        return base if count == 1 else f"{base}_{count}"


def strip_quotes(value: str) -> tuple[str, str]:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1], value[0]
    return value, ""


def rewrite(text: str, path: Path) -> tuple[str, list[str], list[str]]:
    """Return (new_text, changes, warnings)."""
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    changes: list[str] = []
    warnings: list[str] = []
    namer = Namer()

    in_services = False
    services_indent = 0
    service = None
    service_indent = 0
    in_ports = False
    ports_indent = 0

    for lineno, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        if stripped and not stripped.startswith("#"):
            key_match = KEY_RE.match(line)

            if key_match and key_match.group("key") == "services" and indent == 0:
                in_services, services_indent = True, indent
                service, in_ports = None, False
                out.append(raw)
                continue

            # A new top-level key ends the services block.
            if in_services and indent <= services_indent and key_match and key_match.group("key") != "services":
                in_services, service, in_ports = False, None, False

            if in_services:
                # Service name: the first nesting level under services.
                if key_match and service is None and indent > services_indent:
                    service, service_indent = key_match.group("key"), indent
                    in_ports = False
                    out.append(raw)
                    continue
                if key_match and service is not None and indent <= service_indent:
                    service, service_indent = key_match.group("key"), indent
                    in_ports = False
                    out.append(raw)
                    continue
                if key_match and service is not None and indent > service_indent:
                    if key_match.group("key") == "ports":
                        in_ports, ports_indent = True, indent
                        out.append(raw)
                        continue
                    if in_ports and indent <= ports_indent:
                        in_ports = False

        if in_ports and service is not None:
            # Long syntax: published: 8080
            published = PUBLISHED_RE.match(line)
            if published:
                value = published.group("value").strip()
                if value and "$" not in value and value.isdigit():
                    var = namer.next_for(service)
                    new_line = (
                        f'{published.group("indent")}published: '
                        f'"${{{var}:-{value}}}"{published.group("rest")}'
                    )
                    changes.append(f"{path}:{lineno} {service}: published {value} -> ${{{var}:-{value}}}")
                    out.append(new_line + "\n")
                    continue
                out.append(raw)
                continue

            item = LIST_ITEM_RE.match(line)
            if item and item.group("value").strip():
                value_raw = item.group("value").strip()
                comment = item.group("comment") or ""

                # Long syntax opener: "- target: 80"
                if value_raw.startswith("target:"):
                    out.append(raw)
                    continue

                value, quote = strip_quotes(value_raw)

                if "$" in value:
                    out.append(raw)
                    continue
                if ":" not in value:
                    # Container-only port; the host side is ephemeral already.
                    out.append(raw)
                    continue

                match = SHORT_PORT_RE.match(value)
                if match is None:
                    warnings.append(
                        f"{path}:{lineno} could not parse port entry, left unchanged: {value_raw}"
                    )
                    out.append(raw)
                    continue

                var = namer.next_for(service)
                ip = f'{match.group("ip")}:' if match.group("ip") else ""
                proto = match.group("proto") or ""
                host = match.group("host")
                new_value = f'"{ip}${{{var}:-{host}}}:{match.group("container")}{proto}"'
                new_line = f'{item.group("indent")}- {new_value}{comment}'
                changes.append(f"{path}:{lineno} {service}: {value} -> {new_value.strip(chr(34))}")
                out.append(new_line + "\n")
                continue

        out.append(raw)

    return "".join(out), changes, warnings


def refuse_production(path: Path) -> str | None:
    lowered = path.name.lower()
    for token in FORBIDDEN_TOKENS:
        if re.search(rf"(^|[.\-_]){token}([.\-_]|$)", lowered):
            return token
    return None


def collect(root: Path, explicit: list[str]) -> tuple[list[Path], list[str]]:
    problems: list[str] = []
    if explicit:
        paths = []
        for name in explicit:
            path = (root / name).resolve() if not Path(name).is_absolute() else Path(name)
            token = refuse_production(path)
            if token is not None:
                problems.append(f"refused {path.name}: looks like a {token} file")
                continue
            if not path.is_file():
                problems.append(f"not found: {path}")
                continue
            paths.append(path)
        return paths, problems

    return [root / name for name in DEV_COMPOSE_NAMES if (root / name).is_file()], problems


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Parameterize host ports in development compose files.",
    )
    parser.add_argument("--root", default=".", help="repository root (default: cwd)")
    parser.add_argument("--write", action="store_true", help="apply changes")
    parser.add_argument(
        "--file",
        action="append",
        default=[],
        dest="files",
        help="explicit compose file (repeatable); production-looking names are refused",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"ERROR root is not a directory: {root}", file=sys.stderr)
        return 2

    paths, problems = collect(root, args.files)
    for problem in problems:
        print(f"SKIP {problem}")

    if not paths:
        print("OK no development compose file found; nothing to check")
        return 1 if problems else 0

    total_changes = 0
    total_warnings = 0

    for path in paths:
        original = path.read_text(encoding="utf-8")
        updated, changes, warnings = rewrite(original, path.relative_to(root))

        for warning in warnings:
            print(f"WARN {warning}")
        total_warnings += len(warnings)

        if not changes:
            print(f"OK {path.relative_to(root)}: host ports already parameterized")
            continue

        total_changes += len(changes)
        for change in changes:
            print(f"CHANGE {change}")

        if args.write:
            path.write_text(updated, encoding="utf-8")
            print(f"WROTE {path.relative_to(root)}")
        else:
            diff = difflib.unified_diff(
                original.splitlines(keepends=True),
                updated.splitlines(keepends=True),
                fromfile=str(path.relative_to(root)),
                tofile=str(path.relative_to(root)) + " (proposed)",
            )
            sys.stdout.writelines(diff)

    gitignore = root / ".gitignore"
    ignored = gitignore.is_file() and any(
        line.strip() in (".env", "/.env", "*.env") for line in gitignore.read_text(encoding="utf-8").splitlines()
    )
    if not ignored:
        print("WARN .env is not listed in .gitignore; add it before using per-workspace ports")

    print(f"SUMMARY files={len(paths)} changes={total_changes} warnings={total_warnings}")
    if total_changes and not args.write:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
