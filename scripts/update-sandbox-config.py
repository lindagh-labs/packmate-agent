#!/usr/bin/env python3
"""Safely update non-secret Packmate participant settings.

This helper is intentionally small and allowlisted. Participant-facing commands call
it so learners never need to copy a Python heredoc or edit coordinated Git settings
by hand.
"""

from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path


ALLOWED_KEYS = {
    "GIT_REPO_URL",
    "GIT_REVISION",
    "PROMOTION_BASE_BRANCH",
    "PACKMATE_DEMO_BRANCH",
    "PACKMATE_PROMOTION_REGISTRY_OWNER",
}
KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
FORK_URL_RE = re.compile(
    r"^https://github\.com/[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/packmate-agent(?:\.git)?$",
    re.IGNORECASE,
)
OWNER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")


def parse_assignment(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        raise argparse.ArgumentTypeError("expected KEY=VALUE")
    key, value = raw.split("=", 1)
    if not KEY_RE.fullmatch(key) or key not in ALLOWED_KEYS:
        allowed = ", ".join(sorted(ALLOWED_KEYS))
        raise argparse.ArgumentTypeError(f"unsupported key {key!r}; allowed: {allowed}")
    if not value or "\n" in value or "\r" in value or "\x00" in value:
        raise argparse.ArgumentTypeError(f"{key} requires one non-empty line")
    if key in {"GIT_REVISION", "PROMOTION_BASE_BRANCH", "PACKMATE_DEMO_BRANCH"}:
        if not BRANCH_RE.fullmatch(value) or ".." in value or value.endswith("/"):
            raise argparse.ArgumentTypeError(f"unsafe workshop branch value for {key}")
    elif key == "GIT_REPO_URL" and not FORK_URL_RE.fullmatch(value):
        raise argparse.ArgumentTypeError("GIT_REPO_URL must be an HTTPS GitHub Packmate fork URL")
    elif key == "PACKMATE_PROMOTION_REGISTRY_OWNER" and not OWNER_RE.fullmatch(value):
        raise argparse.ArgumentTypeError("invalid GitHub/GHCR owner")
    return key, value


def update_lines(text: str, updates: dict[str, str]) -> str:
    lines = text.splitlines()
    seen: set[str] = set()
    output: list[str] = []
    assignment = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")

    for line in lines:
        match = assignment.match(line)
        if match and match.group(1) in updates:
            key = match.group(1)
            if key not in seen:
                output.append(f"{key}={updates[key]}")
                seen.add(key)
            continue
        output.append(line)

    missing = [key for key in updates if key not in seen]
    if missing:
        if output and output[-1] != "":
            output.append("")
        output.append("# Participant settings managed by Packmate commands")
        output.extend(f"{key}={updates[key]}" for key in missing)

    return "\n".join(output).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Update allowlisted, non-secret values in config/sandbox.env"
    )
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--set", action="append", default=[], type=parse_assignment)
    args = parser.parse_args()

    updates = dict(args.set)
    if not updates:
        parser.error("at least one --set KEY=VALUE is required")

    path: Path = args.file
    path.parent.mkdir(parents=True, exist_ok=True)
    original = path.read_text(encoding="utf-8") if path.exists() else ""
    rendered = update_lines(original, updates)

    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

    print("PASS  participant configuration saved (non-secret settings only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
