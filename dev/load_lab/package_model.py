"""What each file in game.love costs to fetch: its size, its size in the zip, and whether the
console has to inflate it.

Non-Lua entries come from `package_baseline.tsv` (a real CI-built .3dsx). Lua entries are the
staged Lua, deflated here at zlib level 6 -- Info-ZIP's default, and within 0.1% of the CI zip
over all its Lua. The packaging step's own options are read from build.sh's `zip` command, so
a change there is modelled from the build script itself:

  -n .a:.b   store files with these suffixes (Info-ZIP 3.0 on Linux matches case-sensitively)
  -0         store everything

Info-ZIP also stores any file that deflate would not shrink; so does this model.
"""

from __future__ import annotations

import re
import zlib
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "package_baseline.tsv"


@dataclass(frozen=True)
class Entry:
    path: str
    size: int      # bytes once extracted
    stored: int    # bytes in the zip
    deflated: bool


def zip_options(build_sh: str) -> tuple[bool, tuple[str, ...]]:
    """(store_all, store_suffixes) from the `zip` call that packs game.love."""
    m = re.search(r'zip (-[^"]*?)"\$BUILD_DIR/game\.love"', build_sh)
    if not m:
        raise ValueError("game.love's zip command not found in build.sh")
    args = m.group(1).split()
    store_all, suffixes = False, ()
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-n":
            suffixes = tuple(s for s in args[i + 1].split(":") if s)
            i += 2
            continue
        if not a.startswith("-"):
            raise ValueError(f"unexpected zip argument {a!r}")
        for flag in a[1:]:
            if flag == "0":
                store_all = True
            elif flag not in "qr":
                raise ValueError(f"zip flag -{flag} is not modelled")
        i += 1
    return store_all, suffixes


def deflate_size(data: bytes) -> int:
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    return len(c.compress(data) + c.flush())


def read_manifest() -> dict[str, tuple[int, int]]:
    out = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            continue
        path, size, deflated, _method = line.split("\t")
        out[path] = (int(size), int(deflated))
    return out


def build(lua: dict[str, bytes], build_sh: str) -> dict[str, Entry]:
    store_all, suffixes = zip_options(build_sh)
    entries: dict[str, Entry] = {}

    def add(path: str, size: int, deflated_size: int) -> None:
        store = store_all or path.endswith(suffixes) or deflated_size >= size
        entries[path] = Entry(path, size, size if store else deflated_size, not store)

    for path, (size, deflated_size) in read_manifest().items():
        if not path.endswith(".lua"):
            add(path, size, deflated_size)
    for path, data in lua.items():
        add(path, len(data), deflate_size(data))
    return entries
