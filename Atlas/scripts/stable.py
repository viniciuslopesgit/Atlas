"""Picks the stable version that should be on main.

A published version is stable when, in this order (full criteria in docs/RELEASE_CRITERIA.md):
  1. it is a published Release (not a draft) with Atlas-X.Y.Z.zip and SHA256SUMS; published as a pre-release it
     is a beta, which is what is expected until it is promoted;
  2. the tag is in dev's history and already has .mainignore (earlier ones do not build without the tests);
  3. GitHub CI passed on the tag's commit (every check completed successfully);
  4. it has no open issues labelled "bug" that mention it (X.Y.Z or vX.Y.Z);
  5. no version published after it brings fixes (### Fixed in the CHANGELOG): if one does,
     the version had known bugs and the stable one becomes the fix;
  6. it has been published for at least SOAK hours (a minimum waiting period, not proof of reliability);
  7. a new major version (X changes) is only promoted with explicit approval (STABLE_APPROVE=X.Y.Z).
The candidate is the most recent version that meets everything; it is only promoted if it is newer than main's.
Then Atlas/scripts/stable.sh runs the full check again on the tag's commit before promoting it.

main only keeps the essential files: the tag's content without what is in .mainignore.

Usage: python3 Atlas/scripts/stable.py [--json]   (data from GitHub via gh, and from git)
       python3 Atlas/scripts/stable.py excluded <ref>   paths of <ref> that do not go to main
"""

import fnmatch
import json
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

DEFAULT_SOAK_HOURS = 24


@dataclass
class Release:
    version: str
    published: datetime
    draft: bool = False
    prerelease: bool = False
    assets: list = field(default_factory=list)
    on_dev: bool = True
    main_ready: bool = True
    ci_ok: bool = True


@dataclass
class Verdict:
    version: str
    ok: bool
    reason: str


def parse_version(v):
    """'v1.2.10' → (1, 2, 10). Returns None for tags that are not X.Y.Z."""
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", v.strip())
    return tuple(int(x) for x in m.groups()) if m else None


def changelog_sections(text):
    """{version: section text} from the CHANGELOG."""
    sections = {}
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^## \[|^\[\d|\Z)", text, re.M | re.S):
        sections[m.group(1)] = m.group(2)
    return sections


def has_fixes(section):
    # Only spaces and tabs inside a line ([ \t], not \s, which also matches newlines): with \s the blank
    # lines could be split in many ways and the search took exponential time (CodeQL py/redos).
    return re.search(r"^### Fixed[ \t]*\n(?:[ \t]*\n)*- \S", section or "", re.M) is not None


def mentions(issue_text, version):
    return re.search(rf"(?<![\d.])v?{re.escape(version)}(?![\d.])", issue_text) is not None


def main_status(main_version, verdicts):
    """Warning when main has a version that does not meet the rules (None if everything is fine)."""
    v = next((v for v in verdicts if v.version == main_version), None)
    if main_version is None or (v and v.ok):
        return None
    reason = v.reason if v else "has no published Release"
    stable = next((x.version for x in verdicts if x.ok and parse_version(x.version) < parse_version(main_version)), None)
    return f"main has {main_version}, which is not stable yet ({reason}); latest stable: {stable or 'none'}"


def evaluate(releases, changelog, main_version, now, soak_hours=DEFAULT_SOAK_HOURS, bug_issues=(), approved=()):
    """Returns (candidate or None, [Verdict] from newest to oldest)."""
    sections = changelog_sections(changelog)
    main_key = parse_version(main_version) if main_version else None
    published = sorted(
        (r for r in releases if parse_version(r.version) and not r.draft),
        key=lambda r: parse_version(r.version),
        reverse=True,
    )
    verdicts = []
    for r in sorted(releases, key=lambda r: parse_version(r.version) or (-1,), reverse=True):
        key = parse_version(r.version)
        if key is None:
            verdicts.append(Verdict(r.version, False, "not an X.Y.Z version"))
            continue
        if r.draft:
            verdicts.append(Verdict(r.version, False, "draft (not published)"))
            continue
        if f"Atlas-{r.version}.zip" not in r.assets:
            verdicts.append(Verdict(r.version, False, f"the Release does not have Atlas-{r.version}.zip"))
            continue
        if r.main_ready and "SHA256SUMS" not in r.assets:
            verdicts.append(Verdict(r.version, False, "the Release does not have SHA256SUMS"))
            continue
        if not r.on_dev:
            verdicts.append(Verdict(r.version, False, "the tag is not in dev's history"))
            continue
        if not r.main_ready:
            verdicts.append(Verdict(r.version, False, "predates main with only essential files (no .mainignore)"))
            continue
        if not r.ci_ok:
            verdicts.append(Verdict(r.version, False, "no green CI on the tag's commit"))
            continue
        bugs = [title for title, text in bug_issues if mentions(text, r.version)]
        if bugs:
            verdicts.append(Verdict(r.version, False, f"open bug issue: {bugs[0]}"))
            continue
        fixed_by = [n.version for n in published if parse_version(n.version) > key and has_fixes(sections.get(n.version))]
        if fixed_by:
            verdicts.append(Verdict(r.version, False, f"has bugs fixed later, in {fixed_by[-1]}"))
            continue
        age = now - r.published
        if age < timedelta(hours=soak_hours):
            until = (r.published + timedelta(hours=soak_hours)).astimezone().strftime("%d/%m %H:%M")
            verdicts.append(Verdict(r.version, False, f"soaking until {until} ({soak_hours:g} h)"))
            continue
        if main_key and key[0] > main_key[0] and r.version not in approved:
            verdicts.append(Verdict(r.version, False, f"major version: needs approval (STABLE_APPROVE={r.version})"))
            continue
        verdicts.append(Verdict(r.version, True, "stable"))

    candidate = next((v.version for v in verdicts if v.ok), None)
    if candidate and main_key and parse_version(candidate) <= main_key:
        candidate = None
    return candidate, verdicts


def load_patterns(text):
    """.mainignore lines, without comments or empty lines."""
    return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def is_excluded(path, patterns):
    for p in patterns:
        if p.endswith("/"):
            if path.startswith(p) or fnmatch.fnmatchcase(path.split("/")[0] + "/", p):
                return True
        elif path == p or fnmatch.fnmatchcase(path, p):
            return True
    return False


def excluded_paths(paths, patterns):
    return [p for p in paths if is_excluded(p, patterns)]


def plist_version(data):
    """CFBundleShortVersionString of an Info.plist (bytes), or None."""
    try:
        return plistlib.loads(data).get("CFBundleShortVersionString")
    except Exception:
        return None


# ---- Data gathering (git and gh) -------------------------------------------------------------

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def ci_conclusions_ok(conclusions):
    """Every check completed successfully (and at least one)."""
    return bool(conclusions) and all(c in ("success", "skipped", "neutral") for c in conclusions)


def ci_passed(sha):
    try:
        out = run("gh", "api", f"repos/{{owner}}/{{repo}}/commits/{sha}/check-runs", "--jq", "[.check_runs[].conclusion]")
    except subprocess.CalledProcessError:
        return False
    return ci_conclusions_ok(json.loads(out or "[]"))


def latest_stable_release(data):
    """The newest X.Y.Z Release that is not a pre-release (main's version before main had an Info.plist)."""
    stable = [d["tagName"] for d in data if not d["isDraft"] and not d["isPrerelease"] and parse_version(d["tagName"])]
    return max(stable, key=parse_version).lstrip("v") if stable else None


def gather():
    run("git", "fetch", "-q", "--tags", "--force", "origin", "dev", "main")
    data = json.loads(run("gh", "release", "list", "--limit", "100", "--json",
                          "tagName,publishedAt,isDraft,isPrerelease"))
    releases = []
    for d in data:
        tag = d["tagName"]
        if not parse_version(tag):
            continue   # development builds (X.Y.Z-dev.N, before 2.0.0) are never stable candidates
        assets = json.loads(run("gh", "release", "view", tag, "--json", "assets"))["assets"]
        on_dev = subprocess.run(["git", "merge-base", "--is-ancestor", f"refs/tags/{tag}", "origin/dev"]).returncode == 0
        main_ready = subprocess.run(["git", "cat-file", "-e", f"refs/tags/{tag}:.mainignore"],
                                    capture_output=True).returncode == 0
        ci_ok = main_ready and ci_passed(run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}").strip())
        releases.append(Release(
            version=tag.lstrip("v"),
            published=datetime.fromisoformat(d["publishedAt"].replace("Z", "+00:00")),
            draft=d["isDraft"], prerelease=d["isPrerelease"],
            assets=[a["name"] for a in assets], on_dev=on_dev, main_ready=main_ready, ci_ok=ci_ok,
        ))
    issues = json.loads(run("gh", "issue", "list", "--state", "open", "--label", "bug", "--limit", "200",
                            "--json", "title,body"))
    bug_issues = [(i["title"], i["title"] + "\n" + (i["body"] or "")) for i in issues]
    changelog = run("git", "show", "origin/dev:CHANGELOG.md")
    # main does not share the tags' history (each stable version is a commit of its own): the version
    # comes from main's Info.plist, or from the last stable Release while main predates it.
    plist = subprocess.run(["git", "show", "origin/main:Atlas/Resources/Info.plist"], capture_output=True).stdout
    return releases, changelog, plist_version(plist) or latest_stable_release(data), bug_issues


def main():
    import os
    if len(sys.argv) == 3 and sys.argv[1] == "excluded":
        # The list in force is dev's (STABLE_MAINIGNORE=file to rehearse a local list).
        local = os.environ.get("STABLE_MAINIGNORE")
        patterns = load_patterns(open(local, encoding="utf-8").read() if local else run("git", "show", "origin/dev:.mainignore"))
        paths = run("git", "ls-tree", "-r", "--name-only", sys.argv[2]).splitlines()
        print("\n".join(excluded_paths(paths, patterns)))
        return
    soak = float(os.environ.get("STABLE_SOAK_HOURS", DEFAULT_SOAK_HOURS))
    releases, changelog, main_version, bug_issues = gather()
    approved = {v.strip().lstrip("v") for v in os.environ.get("STABLE_APPROVE", "").split(",") if v.strip()}
    candidate, verdicts = evaluate(releases, changelog, main_version, datetime.now(timezone.utc), soak, bug_issues, approved)
    warning = main_status(main_version, verdicts)
    if "--json" in sys.argv:
        print(json.dumps({"main": main_version, "candidate": candidate, "main_warning": warning,
                          "verdicts": [v.__dict__ for v in verdicts]}, ensure_ascii=False))
        return
    print(f"main: {main_version or '(no version)'}")
    for v in verdicts:
        mark = "✓" if v.ok else "·"
        here = "  ← main" if v.version == main_version else ""
        print(f"  {mark} {v.version:<8} {v.reason}{here}")
    if warning:
        print(f"⚠️  Warning: {warning}.")
    if candidate:
        print(f"Stable candidate: {candidate} (newer than main)")
    elif not warning:
        print("No version to promote: main already has the latest stable version.")
    else:
        print("No version to promote right now.")


if __name__ == "__main__":
    main()
