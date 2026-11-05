"""Load Lab score: estimated Old 3DS milliseconds from boot to the first hand dealt.

    python dev/load_lab/score.py stage  <out>   write <out>/stage (the Lua a build ships)
    python dev/load_lab/score.py report <out>   read the traces in <out>, write <out>/report.txt

`run.sh` runs both around the drivers. The inputs to `report` are:

    trace.txt          LÖVE driver: every stat, open, texture, font, sound and save write
    puc_time_*.txt     PUC 5.1 driver, timing runs (the median of them is used)
    puc_alloc.txt      PUC 5.1 driver with the collector stopped: bytes allocated

THE WEIGHTS ARE FIXED. They were set before the first change was measured and are not to be
tuned to favour a change; see README.md for where each comes from. A step that looks better only
under different weights did not improve load time by this harness's measure.

The score covers all of boot (main.lua's first line to the first menu frame) and the loading
work of the hand phase (menu to first hand dealt): its file I/O, textures, and the compile and
module-body time of anything first required there. The hand phase's per-frame game code is not
load work and is left out, so animating a menu never counts against a change.
"""

from __future__ import annotations

import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import package_model  # noqa: E402
import stage  # noqa: E402

# --- weights (fixed; see the module docstring) ---------------------------------------------

STAT_MS = 2.0            # one existence probe (PhysFS asks the SD save directory first)
OPEN_MS = 8.0            # opening one package file (love.filesystem.read is ~21 ms all in)
READ_MIB_S = 4.0         # reading the package off the SD card
INFLATE_MIB_S = 6.0      # zlib inflate on a 268 MHz ARM11
TEXTURE_MS = 16.0        # fixed cost of one texture or font object (newImage ~24 ms - open)
DECODE_MIB_S = 20.0      # decoding / uploading texture bytes (pow2-padded)
SAVE_WRITE_MS = 36.0     # one save-directory write (settings save measured at 36 ms)
LUA_CPU_FACTOR = 100.0   # Old 3DS PUC 5.1 seconds per host PUC 5.1 second
STREAM_PREFETCH = 80 * 1024  # bytes a stored Vorbis stream reads before it plays

MIB = 1024 * 1024
PHASES = ("boot", "hand")


def ms_for(nbytes: float, mib_s: float) -> float:
    return nbytes / (mib_s * MIB) * 1000.0


def pow2(n: int) -> int:
    p = 8
    while p < n:
        p *= 2
    return p


def texture_bpp(path: str) -> int:
    # build.sh texture_format_for: foil and holo ship as la8, every other sheet as rgba8.
    if path.endswith(("/textures/1x/editions/foil.t3x", "/textures/1x/editions/holo.t3x")):
        return 2
    return 4


# --- trace files ----------------------------------------------------------------------------

@dataclass
class Trace:
    header: dict[str, str] = field(default_factory=dict)
    events: list[tuple[str, str, str, str, str]] = field(default_factory=list)
    modules: list[dict] = field(default_factory=list)
    phases: dict[str, float] = field(default_factory=dict)
    stats: dict[tuple[str, str], str] = field(default_factory=dict)
    bench: dict[str, float] = field(default_factory=dict)


def read_trace(path: Path) -> Trace:
    t = Trace()
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "# load lab trace v1":
        raise ValueError(f"{path}: not a load lab trace")
    for line in lines[1:]:
        f = line.split("\t")
        kind = f[0]
        if kind == "#":
            t.header[f[1]] = f[2]
        elif kind == "event":
            t.events.append((f[1], f[2], f[3], f[4], f[5]))
        elif kind == "module":
            t.modules.append({"phase": f[1], "name": f[2], "path": f[3], "bytes": int(f[4]),
                              "compile": float(f[5]), "exec": float(f[6]), "self": float(f[7]),
                              "observed": f[8] == "observed"})
        elif kind == "phase":
            t.phases[f[1]] = float(f[2])
        elif kind == "phasestat":
            t.stats[(f[1], f[2])] = f[3]
        elif kind == "compilebench":
            t.bench[f[2]] = float(f[4])
        else:
            raise ValueError(f"{path}: unknown record {kind!r}")
    return t


# --- the score ------------------------------------------------------------------------------

@dataclass
class Parts:
    ms: dict[str, float] = field(default_factory=lambda: defaultdict(float))
    count: dict[str, int] = field(default_factory=lambda: defaultdict(int))
    nbytes: dict[str, int] = field(default_factory=lambda: defaultdict(int))


PART_ORDER = ("stat", "open", "read", "inflate", "texture", "decode", "save_write",
              "lua_compile", "lua_exec")


def io_parts(love: Trace, pkg: dict[str, package_model.Entry], cia: bool) -> dict[str, Parts]:
    """File, texture and save costs per phase. `cia`: RomFS, plain files, nothing to inflate."""
    out = {p: Parts() for p in PHASES}
    textures = []

    def fetch(p: Parts, path: str, how: str) -> None:
        e = pkg.get(path)
        if e is None:
            raise ValueError(f"trace opens {path}, which the package model does not have")
        p.ms["open"] += OPEN_MS
        p.count["open"] += 1
        stored = e.size if cia else e.stored
        inflate = 0 if cia or not e.deflated else e.size
        if how == "stream" and not inflate:
            stored = min(stored, STREAM_PREFETCH)
        p.ms["read"] += ms_for(stored, READ_MIB_S)
        p.nbytes["read"] += stored
        p.ms["inflate"] += ms_for(inflate, INFLATE_MIB_S)
        p.nbytes["inflate"] += inflate

    for phase, kind, path, a, b in love.events:
        p = out[phase]
        if kind in ("stat", "list"):
            p.ms["stat"] += STAT_MS
            p.count["stat"] += 1
        elif kind == "open":
            if a in ("missing", "miss"):
                p.ms["stat"] += STAT_MS
                p.count["stat"] += 1
            else:
                fetch(p, path, b)
        elif kind == "save_read":
            p.ms["open"] += OPEN_MS
            p.count["open"] += 1
        elif kind == "save_write":
            p.ms["save_write"] += SAVE_WRITE_MS
            p.count["save_write"] += 1
        elif kind in ("texture", "texture_data"):
            w, h = int(a), int(b)
            decoded = pow2(w) * pow2(h) * texture_bpp(path)
            p.ms["texture"] += TEXTURE_MS
            p.count["texture"] += 1
            p.ms["decode"] += ms_for(decoded, DECODE_MIB_S)
            p.nbytes["decode"] += decoded
            textures.append((phase, path, w, h, decoded))
        elif kind == "font":
            size = pkg[path].size
            p.ms["texture"] += TEXTURE_MS
            p.count["texture"] += 1
            p.ms["decode"] += ms_for(size, DECODE_MIB_S)
            p.nbytes["decode"] += size
            textures.append((phase, path, 0, 0, size))
        elif kind == "font_builtin":
            p.ms["texture"] += TEXTURE_MS
            p.count["texture"] += 1
        else:
            raise ValueError(f"unscored event kind {kind!r}")
    return out, textures


def median_runs(runs: list[Trace]) -> dict:
    """Per-phase CPU (shim cost removed), per-module compile bench and self time: medians."""
    def med(xs):
        return statistics.median(xs)

    cpu = {ph: med([float(r.phases[ph]) - float(r.stats[(ph, "bitop_excess_s")]) for r in runs])
           for ph in PHASES}
    paths = [m["path"] for m in runs[0].modules if m["observed"]]
    for r in runs[1:]:
        if [m["path"] for m in r.modules if m["observed"]] != paths:
            raise ValueError("PUC runs compiled different modules")
    bench = {p: med([r.bench[p] for r in runs]) for p in paths}
    self_time = {p: med([next(m["self"] for m in r.modules if m["path"] == p) for r in runs])
                 for p in paths}
    phase_of = {m["path"]: m["phase"] for m in runs[0].modules if m["observed"]}
    return {"cpu": cpu, "bench": bench, "self": self_time, "phase_of": phase_of}


def lua_parts(puc: dict, parts: dict[str, Parts]) -> None:
    for ph in PHASES:
        mods = [p for p, mph in puc["phase_of"].items() if mph == ph]
        compile_s = sum(puc["bench"][p] for p in mods)
        if ph == "boot":
            exec_s = max(0.0, puc["cpu"][ph] - compile_s)
        else:
            exec_s = sum(puc["self"][p] for p in mods)
        parts[ph].ms["lua_compile"] += compile_s * LUA_CPU_FACTOR * 1000
        parts[ph].ms["lua_exec"] += exec_s * LUA_CPU_FACTOR * 1000
        parts[ph].count["lua_compile"] = len(mods)


def check_drivers_agree(love: Trace, puc_run: Trace) -> None:
    """Both drivers must have walked the same code: same modules, same phases."""
    def mods(t):
        return [(m["phase"], m["path"]) for m in t.modules]
    a = [x for x in mods(love)]
    b = [x for x in mods(puc_run)]
    if sorted(a) != sorted(b):
        only_love = sorted(set(a) - set(b))
        only_puc = sorted(set(b) - set(a))
        raise ValueError(f"drivers disagree on modules: only LÖVE {only_love}, only PUC {only_puc}")


def report(out: Path) -> str:
    build_sh = stage.BUILD_SH.read_text(encoding="utf-8")
    stage_dir = out / "stage"
    lua = {p.relative_to(stage_dir).as_posix(): p.read_bytes()
           for p in stage_dir.rglob("*.lua")}
    if lua != stage.staged_lua():
        raise ValueError(f"{stage_dir} is stale; rerun `score.py stage`")
    pkg = package_model.build(lua, build_sh)
    cia_pkg = pkg

    love = read_trace(out / "trace.txt")
    time_runs = [read_trace(p) for p in sorted(out.glob("puc_time_*.txt"))]
    if len(time_runs) < 3:
        raise ValueError("need at least 3 PUC timing runs")
    alloc = read_trace(out / "puc_alloc.txt")
    for r in time_runs:
        if r.header.get("mode") != "time":
            raise ValueError("a puc_time file is not a time-mode run")
    if alloc.header.get("mode") != "alloc":
        raise ValueError("puc_alloc.txt is not an alloc-mode run")
    check_drivers_agree(love, time_runs[0])
    puc = median_runs(time_runs)

    parts, textures = io_parts(love, pkg, cia=False)
    lua_parts(puc, parts)
    cia_parts, _ = io_parts(love, cia_pkg, cia=True)
    lua_parts(puc, cia_parts)

    def total(ps):
        return sum(sum(p.ms.values()) for p in ps.values())

    score = total(parts)
    lines = ["# load lab report v1", f"score_ms\t{score:.0f}"]
    for ph in PHASES:
        lines.append(f"{ph}_ms\t{sum(parts[ph].ms.values()):.0f}")
    lines.append(f"cia_estimate_ms\t{total(cia_parts):.0f}")
    lines.append("")
    lines.append("part\tboot_ms\thand_ms\ttotal_ms\tcount\tbytes")
    for k in PART_ORDER:
        b, h = parts["boot"].ms[k], parts["hand"].ms[k]
        c = parts["boot"].count[k] + parts["hand"].count[k]
        n = parts["boot"].nbytes[k] + parts["hand"].nbytes[k]
        lines.append(f"{k}\t{b:.0f}\t{h:.0f}\t{b + h:.0f}\t{c}\t{n}")
    lines.append("")

    lines.append("summary\tboot\thand")
    def lua_bytes(ph):
        return sum(m["bytes"] for m in love.modules if m["phase"] == ph)
    def lua_count(ph):
        return sum(1 for m in love.modules if m["phase"] == ph)
    for label, fn in (("lua_modules", lua_count), ("lua_source_bytes", lua_bytes)):
        lines.append(f"{label}\t{fn('boot')}\t{fn('hand')}")
    for label, key in (("files_opened", "open"), ("stats", "stat")):
        lines.append(f"{label}\t{parts['boot'].count[key]}\t{parts['hand'].count[key]}")
    for label, key in (("bytes_read", "read"), ("bytes_inflated", "inflate"), ("texture_bytes_decoded", "decode")):
        lines.append(f"{label}\t{parts['boot'].nbytes[key]}\t{parts['hand'].nbytes[key]}")
    lines.append(f"puc_cpu_host_s\t{puc['cpu']['boot']:.4f}\t{puc['cpu']['hand']:.4f}")
    lines.append(f"puc_alloc_kb\t{alloc.stats[('boot', 'alloc_kb')]}\t{alloc.stats[('hand', 'alloc_kb')]}")
    lines.append(f"luajit_gc_kb_delta\t{love.stats.get(('boot', 'luajit_gc_kb_delta'), '')}\t{love.stats.get(('hand', 'luajit_gc_kb_delta'), '')}")
    lines.append(f"bitop_shim_calls\t{time_runs[0].stats[('boot', 'bitop_calls')]}\t{time_runs[0].stats[('hand', 'bitop_calls')]}")
    lines.append(f"hand_frames\t\t{love.stats.get(('hand', 'frames'), '')}")
    lines.append("")

    lines.append("module\tphase\tsource_bytes\tzip_bytes\tcompile_ms\tself_exec_ms")
    for m in love.modules:
        p = m["path"]
        e = pkg[p]
        c = puc["bench"].get(p, 0.0) * LUA_CPU_FACTOR * 1000
        s = puc["self"].get(p, 0.0) * LUA_CPU_FACTOR * 1000
        lines.append(f"{p}\t{m['phase']}\t{e.size}\t{e.stored}\t{c:.1f}\t{s:.0f}")
    lines.append("")

    lines.append("texture\tphase\twidth\theight\tdecoded_bytes")
    for ph, path, w, h, d in textures:
        lines.append(f"{path}\t{ph}\t{w}\t{h}\t{d}")
    lines.append("")

    lines.append("file_opened\tphase\thow\tsize\tzip_bytes\tdeflated")
    for ph, kind, path, a, b in love.events:
        if kind == "open" and a not in ("missing", "miss") and b != "compile":
            e = pkg[path]
            lines.append(f"{path}\t{ph}\t{b}\t{e.size}\t{e.stored}\t{'yes' if e.deflated else 'no'}")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("stage", "report"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    out = Path(argv[2])
    if argv[1] == "stage":
        files = stage.write_stage(out / "stage")
        print(f"[load-lab] staged {len(files)} Lua files to {out / 'stage'}")
        return 0
    text = report(out)
    (out / "report.txt").write_text(text, encoding="utf-8", newline="\n")
    head = text.split("\n\n")[0:2]
    print("\n\n".join(head))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
