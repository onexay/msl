# SPDX-License-Identifier: Apache-2.0
"""MkDocs hooks for the documentation site (mkdocs.yml).

The Markdown in docs/ is also read on GitHub, where it links to files outside
docs/ (../README.md, ../CONTRIBUTING.md, source files). On the site those links
would break, so:

- A page whose only content is `<!-- include: PATH -->` is replaced by the
  repo file PATH (CHANGELOG.md, CONTRIBUTING.md, SECURITY.md): one source.
- Every relative link is resolved in repo coordinates, from the file its text
  came from, then pointed at the site page for that file if there is one, or
  at the file on GitHub if not.
"""
import os
import posixpath
import re

REPO = "https://github.com/onexay/msl"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Repo files outside docs/ that have a page on the site.
PAGES = {
    "README.md": "index.md",
    "CHANGELOG.md": "project/changelog.md",
    "CONTRIBUTING.md": "project/contributing.md",
    "SECURITY.md": "internals/security.md",
    "extensions/vscode/README.md": "vscode.md",
    "docs/readme.md": "index.md",
}
# Sections of README.md that moved to their own page.
ANCHORS = {
    ("README.md", "vs-code-and-other-ides"): "vscode.md",
    ("README.md", "install"): "download.md",
    ("README.md", "known-limitations"): "index.md#known-limitations",
}

INCLUDE = re.compile(r"^\s*<!--\s*include:\s*(\S+)\s*-->\s*$")
LINK = re.compile(r"(\]\()([^)\s]+)(\))")


def _site_target(repo_path, anchor, page_dir):
    """Link text for repo_path#anchor, relative to the page's directory in docs/."""
    if (repo_path, anchor) in ANCHORS:
        target, _, frag = ANCHORS[(repo_path, anchor)].partition("#")
        anchor = frag
    elif repo_path in PAGES:
        target = PAGES[repo_path]
    elif repo_path.startswith("docs/") and not repo_path.startswith("docs/dev/"):
        target = repo_path[len("docs/"):]
    else:
        kind = "tree" if os.path.isdir(os.path.join(ROOT, repo_path)) else "blob"
        return f"{REPO}/{kind}/main/{repo_path}" + (f"#{anchor}" if anchor else "")
    rel = posixpath.relpath(target, page_dir or ".")
    return rel + (f"#{anchor}" if anchor else "")


def _rewrite(markdown, source_dir, page_dir):
    """Rewrite relative links in text that came from repo directory source_dir."""
    def fix(m):
        url = m.group(2)
        if re.match(r"^[a-z]+:|^#|^/", url):
            return m.group(0)
        path, _, anchor = url.partition("#")
        repo_path = posixpath.normpath(posixpath.join(source_dir, path))
        return m.group(1) + _site_target(repo_path, anchor, page_dir) + m.group(3)
    return LINK.sub(fix, markdown)


def _release(tag_file):
    with open(os.path.join(ROOT, tag_file), encoding="utf-8") as f:
        return f.read().strip()


def on_page_markdown(markdown, page, config, files, **kwargs):
    # Version-pinned values that change without a docs edit.
    markdown = markdown.replace("{{ vscode_release }}", _release("extensions/vscode/release.tag"))
    markdown = markdown.replace("{{ kernel_release }}", _release("kernel/release.tag"))
    src = page.file.src_uri                      # e.g. "project/changelog.md"
    page_dir = posixpath.dirname(src)
    lines = markdown.strip().splitlines()
    if len(lines) == 1 and (m := INCLUDE.match(lines[0])):
        included = m.group(1)
        with open(os.path.join(ROOT, included), encoding="utf-8") as f:
            text = f.read()
        return _rewrite(text, posixpath.dirname(included), page_dir)
    return _rewrite(markdown, posixpath.join("docs", page_dir) if page_dir else "docs", page_dir)
