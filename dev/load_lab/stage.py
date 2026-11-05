"""The Lua a console build ships, staged the way `dev/build.sh` stages it.

`build.sh` copies the working tree into its stage with one rsync whose `--exclude` list decides
what ships. That list is read from build.sh itself rather than restated here, so the two cannot
drift. On CI the working tree is a clean checkout, so the files considered are the ones git
knows about: tracked, plus untracked-but-not-ignored (a new module in a step being measured).

Only .lua files are staged. Everything else in the package comes from `package_baseline.tsv`.

When build.sh precompiles its stage (`precompile_lua`, which runs `dev/luac_3ds.py`), this does
too, with the luac named by the `LUAC51` environment variable. Any Lua 5.1.5 luac works, because
`luac_3ds.py` rewrites a 64-bit host's output into the console's layout. Two stages are written:

    stage/      what ships: bytecode when the build precompiles, else source (the PUC driver)
    stage_src/  the source before any precompile (the LÖVE driver; LuaJIT cannot load PUC bytecode)
"""

from __future__ import annotations

import fnmatch
import os
import re
import shutil
import subprocess
import sys
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


def build_precompiles(build_sh: str) -> bool:
    """Whether build.sh's packaging runs dev/luac_3ds.py over the stage."""
    return re.search(r'luac_3ds\.py" "\$HOST_LUAC" "\$STAGE_DIR"', build_sh) is not None


def _write(dest: Path, files: dict[str, bytes]) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    for path, data in files.items():
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    # For the PUC driver, which has no directory listing of its own.
    (dest / "FILES.txt").write_text("".join(p + "\n" for p in sorted(files)), encoding="utf-8", newline="\n")


def read_stage(dest: Path) -> dict[str, bytes]:
    return {p.relative_to(dest).as_posix(): p.read_bytes() for p in dest.rglob("*.lua")}


def write_stage(out: Path) -> tuple[dict[str, bytes], dict[str, bytes]]:
    """Write `out/stage_src` and `out/stage`, each emptied first. Returns (source, shipped)."""
    source = staged_lua()
    _write(out / "stage_src", source)
    _write(out / "stage", source)
    if not build_precompiles(BUILD_SH.read_text(encoding="utf-8")):
        return source, source
    luac = os.environ.get("LUAC51")
    if not luac:
        raise ValueError("build.sh precompiles Lua; set LUAC51 to a Lua 5.1.5 luac")
    sys.path.insert(0, str(REPO / "dev"))
    import luac_3ds
    luac_3ds.compile_stage(luac, out / "stage")
    shipped = read_stage(out / "stage")
    if sorted(shipped) != sorted(source):
        raise ValueError("precompiling changed the stage's file list")
    return source, shipped
