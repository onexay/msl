#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail if a Markdown file links to a repo file or heading that doesn't exist.

Checks relative links and #anchors in every tracked .md file (or the files
given as arguments). External URLs are not fetched. Anchors follow GitHub's
rules: lowercase, punctuation dropped, spaces to hyphens, -1/-2 for repeats.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FENCE = re.compile(r"^(```|~~~).*?^\1", re.S | re.M)
LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def anchors(path, cache={}):
    if path not in cache:
        seen, out = {}, set()
        text = FENCE.sub("", open(path, encoding="utf-8").read())
        for m in re.finditer(r"^#{1,6}\s+(.+?)\s*#*\s*$", text, re.M):
            slug = re.sub(r"[^\w\- ]", "", m.group(1).lower()).replace(" ", "-")
            n = seen.get(slug, 0)
            seen[slug] = n + 1
            out.add(slug if n == 0 else f"{slug}-{n}")
        cache[path] = out
    return cache[path]


def check(md):
    bad = []
    text = FENCE.sub("", open(md, encoding="utf-8").read())
    text = re.sub(r"`[^`\n]*`", "", text)
    for link in LINK.findall(text):
        if re.match(r"[a-z][a-z0-9+.-]*:", link, re.I):
            continue
        path, _, frag = link.partition("#")
        target = os.path.normpath(os.path.join(os.path.dirname(md), path)) if path else md
        if not os.path.exists(target):
            bad.append(f"{md}: {link}: no such file")
        elif frag and target.endswith(".md") and frag.lower() not in anchors(target):
            bad.append(f"{md}: {link}: no such heading")
    return bad


def main():
    os.chdir(ROOT)
    files = sys.argv[1:] or subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"], capture_output=True, text=True, check=True
    ).stdout.split()
    bad = [b for f in files if os.path.exists(f) for b in check(f)]
    print("\n".join(bad) or f"links ok ({len(files)} files)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
