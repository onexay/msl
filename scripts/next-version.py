#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Choose the next MSL release version from commits since the latest SemVer tag."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path


def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], text=True, stderr=subprocess.DEVNULL
    ).strip()


def parse(version: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        raise SystemExit(f"not a stable semantic version: {version}")
    return tuple(map(int, match.groups()))


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    base = parse((root / "VERSION").read_text().strip())
    try:
        git("rev-parse", "--verify", "HEAD")
    except subprocess.CalledProcessError:
        print(".".join(map(str, base)))
        return
    tags = []
    for tag in git("tag", "--merged", "HEAD").splitlines():
        if re.fullmatch(r"v\d+\.\d+\.\d+", tag):
            tags.append((parse(tag), tag))

    if not tags:
        print(".".join(map(str, base)))
        return

    latest_version, latest_tag = max(tags)
    messages = git("log", "-z", "--format=%B", f"{latest_tag}..HEAD").split("\0")
    breaking = any(
        "BREAKING CHANGE:" in message
        or any(re.match(r"^[a-zA-Z][\w-]*(?:\([^\n)]*\))?!:", line)
               for line in message.splitlines())
        for message in messages
    )
    feature = any(
        re.match(r"^feat(?:\([^\n)]*\))?:", line)
        for message in messages
        for line in message.splitlines()
    )

    major, minor, patch = latest_version
    if breaking:
        next_version = (major + 1, 0, 0)
    elif feature:
        next_version = (major, minor + 1, 0)
    else:
        next_version = (major, minor, patch + 1)

    print(".".join(map(str, max(base, next_version))))


if __name__ == "__main__":
    main()
