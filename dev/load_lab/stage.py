"""The Lua a console build ships, staged the way `dev/build.sh` stages it.

`build.sh` copies the working tree into its stage with one rsync whose `--exclude` list decides
what ships. That list is read from build.sh itself rather than restated here, so the two cannot
drift. On CI the working tree is a clean checkout, so the files considered are the ones git
knows about: tracked, plus untracked-but-not-ignored (a new module in a step being measured).

Only .lua files are staged. Everything else in the package comes from `package_baseline.tsv`.
"""

from __future__ import annotations

import fnmatch
import re
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUILD_SH = REPO / "dev" / "build.sh"
CONFIG_SH = REPO / "dev" / "config.sh"

# What `prepare_build_info 3dsx` writes for a non-release build, with a fixed commit so reports
# compare. The real one differs only in the hash's characters.
BUILD_INFO = 'return { commit = "0000000", target = "3dsx" }\n'


def rsync_excludes(build_sh: str) -> list[str]:
    """The literal `--exclude '<pattern>'` arguments of build.sh's staging rsync."""
    start = build_sh.index("rsync -a --delete")
    end = build_sh.index('"$REPO_ROOT/" "$STAGE_DIR/"', start)
    patterns = re.findall(r"--exclude '([^']+)'", build_sh[start:end])
    if not patterns:
        raise ValueError("found no --exclude patterns in build.sh's staging rsync")
    return patterns


def exclude_assets(config_sh: str) -> list[str]:
    """`EXCLUDE_ASSETS` from config.sh: repository-relative paths, anchored at the root."""
    m = re.search(r"^EXCLUDE_ASSETS=\((.*?)^\)", config_sh, re.S | re.M)
    if not m:
        raise ValueError("EXCLUDE_ASSETS not found in config.sh")
    body = "\n".join(line.split("#", 1)[0] for line in m.group(1).splitlines())
    return re.findall(r'"([^"]+)"', body)


def excluded(path: str, patterns: list[str], anchored: list[str]) -> bool:
    """rsync's rules for these pattern shapes: `name/` excludes a directory of that name at any
    depth, a pattern without a slash matches a path component's name, `/x` is anchored."""
    parts = path.split("/")
    if path in anchored:
        return True
    for pat in patterns:
        if pat.endswith("/"):
            name = pat[:-1]
            if any(fnmatch.fnmatchcase(p, name) for p in parts[:-1]):
                return True
        elif "/" not in pat:
            if any(fnmatch.fnmatchcase(p, pat) for p in parts):
                return True
        else:
            raise ValueError(f"unhandled rsync pattern shape: {pat!r}")
    return False


def repo_files() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(REPO), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True, capture_output=True,
    ).stdout
    files = sorted({p.decode("utf-8") for p in out.split(b"\0") if p})
    return [p for p in files if (REPO / p).is_file()]  # ls-files --cached lists deletions too


def staged_lua() -> dict[str, bytes]:
    """path -> bytes for every .lua file a 3dsx build ships, after the build's Lua handling."""
    patterns = rsync_excludes(BUILD_SH.read_text(encoding="utf-8"))
    anchored = exclude_assets(CONFIG_SH.read_text(encoding="utf-8"))
    out: dict[str, bytes] = {}
    for path in repo_files():
        if path.endswith(".lua") and not excluded(path, patterns, anchored):
            out[path] = (REPO / path).read_bytes()
    if "build_info.lua" in out:
        raise ValueError("build_info.lua is in the tree; build.sh generates it")
    out["build_info.lua"] = BUILD_INFO.encode("ascii")
    return out


def write_stage(dest: Path) -> dict[str, bytes]:
    """Write the staged Lua to `dest` (emptied first) and return it. `FILES.txt` lists it, for
    the PUC driver, which has no directory listing of its own."""
    if dest.exists():
        shutil.rmtree(dest)
    files = staged_lua()
    for path, data in files.items():
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (dest / "FILES.txt").write_text("".join(p + "\n" for p in sorted(files)), encoding="utf-8", newline="\n")
    return files
