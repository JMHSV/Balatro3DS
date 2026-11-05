#!/usr/bin/env python3
"""Pack a build stage's Lua modules, and the other files named, into one file: the game bundle,
which bundle.lua serves `require` and `Bundle.read` from.

    python3 dev/bundle.py <stage_dir> [<pattern>...]

On the console every `require` through the runtime's loader, and every file opened by path,
probes the save directory and opens a file, and PhysFS reopens the package for each open: at
seventy-odd modules and forty-odd cues that is about a second of boot. Every .lua file under
<stage_dir> moves into <stage_dir>/game.bundle, except the three the runtime loads before the
bundle's searcher exists: main.lua, conf.lua and bundle.lua. So does every other file whose
stage-relative path matches a <pattern> (fnmatch, `*` crosses `/`) and no `!<pattern>`. The
files' bytes are copied as they are.

The format (bundle.lua reads it):

    "BNDL1 " + the index's length in bytes as 9 decimal digits + "\\n"
    the index: one "<path>\\t<size>\\n" line per file, sorted by path
    the files' bytes, concatenated in index order

The bundle must be stored, not deflated, in game.love: the loader seeks in it, and a seek
backwards in a deflated zip entry inflates the entry again from its start.

Running it again merges. Files already in the bundle stay, and a loose file replaces its entry
(`build.sh all` rewrites build_info.lua between the .3dsx and the CIA).
"""

from __future__ import annotations

import fnmatch
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from luac_3ds import check_stage  # noqa: E402

BUNDLE = "game.bundle"
LOOSE = ("main.lua", "conf.lua", "bundle.lua")
MAGIC = b"BNDL1 "
HEADER_BYTES = 16


class BundleError(ValueError):
    pass


def selected(path: str, patterns: list[str]) -> bool:
    """Whether a stage-relative path goes into the bundle."""
    if path in LOOSE or path == BUNDLE:
        return False
    if path.endswith(".lua"):
        return True
    include = [p for p in patterns if not p.startswith("!")]
    exclude = [p[1:] for p in patterns if p.startswith("!")]
    return (any(fnmatch.fnmatchcase(path, p) for p in include)
            and not any(fnmatch.fnmatchcase(path, p) for p in exclude))


def encode(files: dict[str, bytes]) -> bytes:
    index = bytearray()
    for path in sorted(files):
        if "\t" in path or "\n" in path or not path:
            raise BundleError(f"cannot bundle {path!r}")
        index += f"{path}\t{len(files[path])}\n".encode("utf-8")
    if len(index) >= 10 ** 9:
        raise BundleError("index too long")
    header = MAGIC + f"{len(index):09d}\n".encode("ascii")
    assert len(header) == HEADER_BYTES
    return header + bytes(index) + b"".join(files[p] for p in sorted(files))


def decode(data: bytes) -> dict[str, bytes]:
    header = data[:HEADER_BYTES]
    if len(header) != HEADER_BYTES or header[:6] != MAGIC or header[-1:] != b"\n" or not header[6:15].isdigit():
        raise BundleError("no BNDL1 header")
    length = int(header[6:15])
    index = data[HEADER_BYTES:HEADER_BYTES + length]
    if len(index) != length or (index and not index.endswith(b"\n")):
        raise BundleError("truncated index")
    out: dict[str, bytes] = {}
    offset = HEADER_BYTES + length
    for line in index.decode("utf-8").splitlines():
        path, size = line.split("\t")
        n = int(size)
        out[path] = data[offset:offset + n]
        if len(out[path]) != n:
            raise BundleError(f"truncated data for {path}")
        offset += n
    if offset != len(data):
        raise BundleError("trailing bytes after the last file")
    return out


def index_bytes(data: bytes) -> int:
    """Header plus index: what the loader reads when it opens the bundle."""
    decode(data)
    return HEADER_BYTES + int(data[6:15])


def bundle_stage(stage: Path, patterns: list[str]) -> int:
    """Move the stage's selected files into its bundle. Returns how many files the bundle holds."""
    check_stage(stage)
    if not (stage / LOOSE[2]).is_file():
        raise BundleError(f"{stage} has no {LOOSE[2]}, so nothing would read a bundle")
    target = stage / BUNDLE
    files = decode(target.read_bytes()) if target.exists() else {}
    moved = [p for p in sorted(stage.rglob("*"))
             if p.is_file() and selected(p.relative_to(stage).as_posix(), patterns)]
    for path in moved:
        files[path.relative_to(stage).as_posix()] = path.read_bytes()
    target.write_bytes(encode(files))
    for path in moved:
        path.unlink()
    # Directories left empty (engine/, nest/modules/...) would ship as empty zip entries.
    for d in sorted({p.parent for p in moved}, key=lambda d: len(d.parts), reverse=True):
        while d != stage and d.is_dir() and not any(d.iterdir()):  # a deeper one's walk may have removed d
            d.rmdir()
            d = d.parent
    return len(files)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    n = bundle_stage(Path(argv[1]), argv[2:])
    print(f"bundled {n} files into {BUNDLE}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
