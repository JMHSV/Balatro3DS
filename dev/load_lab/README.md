# Load Lab

The Load Lab estimates how long an Old 3DS takes to get from launch to the first hand dealt. It reports the estimate as one number, `score_ms`, and breaks it into parts.

It covers two phases:

- **boot**: from the first line of `main.lua` to the end of the first frame of the main menu.
- **hand**: from that menu to the first hand dealt, along the Pixel Lab tour's path (`to_hand.lua`). Only the hand phase's loading work counts: file I/O, textures, and the compile and module-body time of modules it requires first. Its per-frame game code does not count.

The lab is desktop-only. `dev/` is never staged into a console build.

## Run it

You need LÖVE 11.5, PUC Lua 5.1.5 with its `luac`, and Python 3. On Windows, the LuaBinaries `lua-5.1.5_Win32_bin.zip` build works.

From the repository root, run:

	LOVE=<path to lovec.exe or love> LUA51=<path to lua5.1> LUAC51=<path to luac5.1> bash dev/load_lab/run.sh [out_dir]

`LUAC51` is needed only while `dev/build.sh` precompiles Lua.

The script writes `<out_dir>/report.txt`. The default `out_dir` is `dev/load_lab/out/latest`. It prints the score and the parts table. Two runs on an unchanged tree agree to about 1 ms of `score_ms`. The Lua compile and exec split can move by about 60 ms between runs.

## What each piece does

| File | Job |
| --- | --- |
| `stage.py` | Writes `<out>/stage`, the `.lua` files a 3dsx build ships, and `<out>/stage_src`, their source. It reads the exclude list from the `rsync` call in `dev/build.sh` and `EXCLUDE_ASSETS` from `dev/config.sh`. It generates `build_info.lua` the way `prepare_build_info 3dsx` does. When `build.sh` precompiles, it runs `dev/luac_3ds.py` over `stage` with `LUAC51`, so `stage` holds console bytecode. |
| `init.lua` | The LÖVE driver. `main.lua` installs it when `--load-lab` is on the command line. It runs the real game from `stage_src`, because LuaJIT cannot load PUC bytecode. It records each stat, open, texture, font, sound and save write under the path the console opens. A `.png` counts as its `.t3x`, a `.ttf` as its `.bcfnt`, and a cue as its `.wav`. Output goes to `trace.txt`. |
| `view.lua` | The console's view of the package. Non-Lua entries come from `package_baseline.tsv` and Lua comes from the stage. |
| `puc_boot.lua` | The PUC 5.1 driver. It walks the same two phases against `tests/love_stub.lua`, with `stage` held in memory, so it runs the bytecode that ships. It writes phase CPU times, and a load bench that loads every module 20 times: a compile for source, an undump for bytecode (`puc_time_*.txt`). In alloc mode it stops the collector and records bytes allocated (`puc_alloc.txt`). |
| `bitop.lua` | A pure-Lua stand-in for the Lua BitOp library, which the console links and stock PUC 5.1 lacks. The driver subtracts its extra cost from each phase. |
| `package_model.py` | Gives the size, zip size and compression of each file in `game.love`. It reads the `zip` options in `dev/build.sh` (`-n` and `-0`). |
| `score.py` | Combines the traces under fixed weights into `report.txt`. |
| `package_baseline.tsv` | The `game.love` listing from a real CI-built .3dsx. tex3ds, mkbcfnt and ffmpeg produce those assets, and they are not on this machine. |

`score.py` refuses to run when the two drivers compiled different modules, when the stage is older than the tree or not packaged the way `build.sh` packages it, or when the trace opens a file the package does not have.

## The weights

The weights were fixed before the first change was measured. Do not change them to make a change look better. A change that wins only under other weights did not win.

| Cost | Weight | Where it comes from |
| --- | --- | --- |
| Stat (existence probe, directory list) | 2 ms | PhysFS checks the SD save directory before the archive. One SD directory lookup costs low milliseconds. |
| Open a package file | 8 ms | `love.filesystem.read` measures about 21 ms all in (`perf_flags.lua`). That leaves about 8 ms after the read and inflate of a small file. |
| Read from the SD card | 4 MiB/s | Effective throughput for the Old 3DS SD path through FS:USER and PhysFS, with small reads. |
| Inflate | 6 MiB/s | zlib on a 268 MHz ARM11 with no L2 cache. This is scaled from ARM1176 (Raspberry Pi 1) figures. |
| Texture or font object | 16 ms | `newImage` of a small sprite costs about 24 ms (`consumable.lua`, `game.lua`). That is 16 ms after the 8 ms open. |
| Texture decode and upload | 20 MiB/s | Over pow2-padded width × height × bytes per pixel: 4 for rgba8, 2 for the la8 foil and holo sheets. For a font, it is over the `.bcfnt` size. |
| Save-directory write | 36 ms | A settings save measured at 36 ms (`game.lua`). |
| Lua CPU | ×100 host PUC 5.1 time | The clock ratio is about 17× (4.9 GHz Ryzen 9 5950X against 268 MHz). The IPC ratio is about 5 to 6×. |
| Streamed Vorbis | Whole file read and inflated if deflated, else 80 KiB read | LövePotion streams Vorbis from a PhysFS file (`wrap_sound.cpp`, `vorbisdecoder.cpp`). vorbisfile seeks to the end of a seekable stream when it opens it. A seek in a deflated zip entry inflates up to the target, and a backward seek starts again from the beginning. One full inflate is the lower bound. |

The Lua CPU part has two halves. **lua_compile** is the load bench summed over the modules each phase loaded. For shipped bytecode, that is the undump. **lua_exec** is the rest. For boot, that is phase CPU minus compile. For hand, it is the self time of modules first required there.

The collector's cost is already inside the PUC CPU time, so allocation (`puc_alloc_kb`) is reported but not weighted. `cia_estimate_ms` scores the same trace as a CIA, where RomFS holds plain files: nothing is inflated, and reads are at full size.

## What the score cannot see

- **Device constants.** Every weight is an estimate. The ranking of two changes is reliable only when they gain in the same part, or when their gains differ by more than the weights' uncertainty. On the Old 3DS, measure a kept change with `benchmark.lua` or a stopwatch.
- **C work in the stub.** `tests/love_stub.lua` does no real drawing or decoding, so the PUC time is Lua only. The LÖVE trace accounts for textures and files.
- **Bytes the zip model invents.** Lua is deflated at zlib level 6, which matches the CI zip within 0.1% over all Lua. Other entries keep their CI sizes.
- **Bytecode on the console.** The undump is timed on a 32-bit x86 PUC 5.1.5, whose chunks are byte-identical to the console's. It has not been loaded on a 3DS by the lab.
