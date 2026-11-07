#!/usr/bin/env python3
"""Generate the GitHub release-notes body for a release tag.

Single source for both the release.yml `create-release` job and local
backfills (`gh release edit --notes-file`). The body is built from the
commit subjects between the previous tag and this one — this repo is
direct-push (no PRs since #6), so commit subjects ARE the changelog;
GitHub's auto-generated notes would only ever render a lone
"Full Changelog" line for such history.

Format:
    ## Changes

    ### Features
    - feat(scope): ...

    ### Fixes
    - fix(scope): ...

    ### Other
    - chore(scope): ...

    **Full Changelog**: https://github.com/<owner>/<repo>/compare/vA...vB

A per-release override file wins when present: `release-notes/vX.Y.Z.md`
(relative to the repo root). Its content replaces the generated text
verbatim; the compare link is still appended unless the file already
contains one.

Usage:
    python3 .github/scripts/generate_release_notes.py \
        --tag v3.1.0 [--repo owner/name] [--out notes.md] [--override PATH]

`--repo` defaults to the GitHub slug derived from the origin remote.
`--override` defaults to `release-notes/<tag>.md`; a missing override
file is not an error. Empty sections are omitted.
"""

import argparse
import os
import re
import subprocess
import sys

# Conventional-commit prefix -> markdown section heading, in display
# order. Anything unrecognised falls into "Other".
SECTIONS = [
    ("feat", "### Features"),
    ("fix", "### Fixes"),
]


def git(*args):
    """Run git, returning (ok, stdout_or_stderr)."""
    # Commit subjects are raw UTF-8 bytes from git; decoding with the
    # process locale breaks on non-Latin locales (e.g. cp936 Windows).
    r = subprocess.run(
        ("git",) + args, capture_output=True, text=True, encoding="utf-8"
    )
    return r.returncode, (r.stdout if r.returncode == 0 else r.stderr)


def previous_tag(tag):
    """Nearest ancestor tag of `tag`, or '' when none exists."""
    rc, out = git("describe", "--match", "v*", "--abbrev=0", tag + "^")
    if rc != 0:
        return ""
    return out.strip()


def slug_from_origin():
    """Derive 'owner/name' from the origin remote URL, or raise."""
    rc, url = git("remote", "get-url", "origin")
    if rc != 0:
        sys.exit("no --repo given and cannot read the origin remote")
    m = re.search(r"github\.com[:/](.+?)/(.+?)(?:\.git)?/?$", url.strip())
    if not m:
        sys.exit(f"cannot parse a GitHub slug from origin URL: {url.strip()}")
    return f"{m.group(1)}/{m.group(2)}"


def classify(subject):
    lowered = subject.lower()
    for prefix, _ in SECTIONS:
        if lowered.startswith(prefix):
            return prefix
    return "other"


def compare_link(repo, prev, tag):
    return f"**Full Changelog**: https://github.com/{repo}/compare/{prev}...{tag}"


def generate(repo, tag):
    prev = previous_tag(tag)
    commit_range = f"{prev}..{tag}" if prev else tag

    rc, out = git("log", "--no-merges", "--format=%s", commit_range)
    if rc != 0:
        sys.exit(f"git log {commit_range} failed: {out.strip()}")
    subjects = [line.strip() for line in out.splitlines() if line.strip()]

    groups = {prefix: [] for prefix, _ in SECTIONS}
    groups["other"] = []
    for s in subjects:
        groups[classify(s)].append(f"- {s}")

    parts = ["## Changes"]
    empty = True
    for prefix, heading in SECTIONS:
        if groups[prefix]:
            parts += ["", heading, *groups[prefix]]
            empty = False
    if groups["other"]:
        parts += ["", "### Other", *groups["other"]]
        empty = False
    if empty:
        parts += ["", "- (no commits found)"]

    if prev:
        parts += ["", compare_link(repo, prev, tag)]
    return "\n".join(parts).strip() + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tag", required=True, help="release tag, e.g. v3.1.0")
    ap.add_argument(
        "--repo",
        help="GitHub slug for the compare link (default: derive from origin)",
    )
    ap.add_argument(
        "--out",
        help="write the body to this file instead of stdout",
    )
    ap.add_argument(
        "--override",
        help="manual notes file that replaces the generated body when it "
        "exists (default: release-notes/<tag>.md relative to repo root)",
    )
    args = ap.parse_args()

    repo = args.repo or slug_from_origin()

    override = args.override or os.path.join("release-notes", f"{args.tag}.md")
    if os.path.isfile(override):
        with open(override, encoding="utf-8") as f:
            body = f.read().strip() + "\n"
        prev = previous_tag(args.tag)
        if prev and "Full Changelog" not in body:
            body += "\n" + compare_link(repo, prev, args.tag) + "\n"
        source = f"override file {override}"
    else:
        body = generate(repo, args.tag)
        source = "git log"

    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        print(f"release notes for {repo} tag {args.tag} -> {args.out} (from {source})")
    else:
        sys.stdout.write(body)


if __name__ == "__main__":
    main()
