#!/usr/bin/env python3
"""Precompile staged Lua into the bytecode the 3DS runtime loads.

    python3 dev/luac_3ds.py <luac> <stage_dir>

Every source .lua file under <stage_dir> is replaced, in place and under the same name, by its
Lua 5.1 bytecode. LövePotion's loader passes whatever the file holds to `luaL_loadbuffer`, which
takes source or bytecode alike, so `require` and `love.filesystem.load` need no change. The
console then skips the compile: on an Old 3DS that is about four seconds of a cold boot.

Bytecode is only loadable by a VM whose header matches. The console's is devkitPro's
3ds-liblua51: stock Lua 5.1.5 (unmodified luaconf.h) for 32-bit little-endian ARM, so int, size_t
and Instruction are 4 bytes and a number is an 8-byte double. `lundump.c` refuses any other header
outright ("bad header in precompiled chunk"), so a mismatch cannot load wrongly; it fails to load.

A 64-bit build host's luac writes size_t as 8 bytes, so its output is rewritten here into the
console's layout. Nothing else in a 5.1 chunk depends on the host. Debug info is kept (no `-s`):
error messages and tracebacks name the same files and lines as they would from source.

`luac` runs from inside <stage_dir> on each file's relative path, so each chunk is named
"@<path>", the name LövePotion's loader would give the source.
"""

from __future__ import annotations

import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SIGNATURE = b"\x1bLua"
VERSION = 0x51
FORMAT = 0

# The console's header: little-endian, int 4, size_t 4, Instruction 4, lua_Number 8, not integral.
CONSOLE_HEADER = bytes([0x1B, 0x4C, 0x75, 0x61, 0x51, 0x00, 0x01, 0x04, 0x04, 0x04, 0x08, 0x00])

TNIL, TBOOLEAN, TNUMBER, TSTRING = 0, 1, 3, 4


class ChunkError(ValueError):
    pass


class _Reader:
    def __init__(self, data: bytes, size_t: int):
        self.data, self.pos, self.size_t = data, 0, size_t

    def take(self, n: int) -> bytes:
        if self.pos + n > len(self.data):
            raise ChunkError("truncated chunk")
        b = self.data[self.pos:self.pos + n]
        self.pos += n
        return b

    def byte(self) -> int:
        return self.take(1)[0]

    def int(self) -> int:
        return struct.unpack("<i", self.take(4))[0]

    def size(self) -> int:
        return int.from_bytes(self.take(self.size_t), "little")


def _string(r: _Reader, out: bytearray) -> None:
    n = r.size()
    if n > 0xFFFFFFFF:
        raise ChunkError("string too long for a 32-bit size_t")
    out += struct.pack("<I", n)
    out += r.take(n)


def _count(r: _Reader, out: bytearray) -> int:
    n = r.int()
    if n < 0:
        raise ChunkError("negative count")
    out += struct.pack("<i", n)
    return n


def _function(r: _Reader, out: bytearray) -> None:
    # ldump.c DumpFunction, field by field.
    _string(r, out)                      # source (size 0 when inherited from the parent)
    out += r.take(4 + 4 + 4)             # linedefined, lastlinedefined, nups/numparams/is_vararg/maxstacksize
    out += r.take(4 * _count(r, out))    # code
    for _ in range(_count(r, out)):      # constants
        t = r.byte()
        out.append(t)
        if t == TNIL:
            pass
        elif t == TBOOLEAN:
            out += r.take(1)
        elif t == TNUMBER:
            out += r.take(8)
        elif t == TSTRING:
            _string(r, out)
        else:
            raise ChunkError(f"unknown constant type {t}")
    for _ in range(_count(r, out)):      # nested functions
        _function(r, out)
    out += r.take(4 * _count(r, out))    # lineinfo
    for _ in range(_count(r, out)):      # locvars
        _string(r, out)
        out += r.take(8)                 # startpc, endpc
    for _ in range(_count(r, out)):      # upvalue names
        _string(r, out)


def to_console(chunk: bytes) -> bytes:
    """Rewrite a Lua 5.1 chunk from a little-endian host into the console's layout."""
    h = chunk[:12]
    if len(h) < 12 or h[:4] != SIGNATURE or h[4] != VERSION or h[5] != FORMAT:
        raise ChunkError("not a Lua 5.1 chunk")
    endian, size_int, size_t, size_instr, size_number, integral = h[6:12]
    if (endian, size_int, size_instr, size_number, integral) != (1, 4, 4, 8, 0) or size_t not in (4, 8):
        raise ChunkError(f"host luac's header {h.hex()} cannot be rewritten for the console")
    r = _Reader(chunk, size_t)
    r.pos = 12
    out = bytearray(CONSOLE_HEADER)
    _function(r, out)
    if r.pos != len(chunk):
        raise ChunkError("trailing bytes after the main function")
    return bytes(out)


def check_stage(stage: Path) -> None:
    """Refuse anything but a build stage: this rewrites files in place, and pointed at a
    checkout it would turn the working tree into bytecode."""
    if not (stage / "main.lua").is_file() or not (stage / "conf.lua").is_file():
        raise ChunkError(f"{stage} is not a build stage (no main.lua and conf.lua)")
    for marker in (".git", "dev", "tests"):
        if (stage / marker).exists():
            raise ChunkError(f"{stage} has {marker}/, so it is a checkout, not a build stage")


def compile_stage(luac: str, stage: Path) -> int:
    """Compile every source .lua under `stage` in place. Returns how many were compiled."""
    check_stage(stage)
    count = 0
    with tempfile.TemporaryDirectory() as tmp:
        out_path = os.path.join(tmp, "out.luac")
        for path in sorted(stage.rglob("*.lua")):
            if path.read_bytes()[:4] == SIGNATURE:
                continue  # already compiled (`build.sh all` packages twice)
            rel = path.relative_to(stage).as_posix()
            done = subprocess.run([luac, "-o", out_path, rel], cwd=stage, capture_output=True, text=True)
            if done.returncode != 0:
                raise ChunkError(f"luac failed on {rel}: {done.stderr.strip()}")
            path.write_bytes(to_console(Path(out_path).read_bytes()))
            count += 1
    return count


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    n = compile_stage(argv[1], Path(argv[2]))
    print(f"precompiled {n} Lua files for the console")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
