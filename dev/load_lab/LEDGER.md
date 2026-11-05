# Load-time ledger

This ledger records every step of the load-time climb on `perf/load-time`, including the rejected ones. The scores come from `dev/load_lab/run.sh` (see `README.md`) under its fixed weights. `score_ms` is the estimated Old 3DS time from launch to the first hand dealt. Each step changes one thing, and it is kept only if it gains clearly and every check passes.

The checks for every kept step:

- The test suite gives 1115 passed, 4 failed and 2 skipped. From step 3 it gives 1124 passed, because that step adds the 9 tests in `tests/test_module_bundle.lua`. The 4 failures are the known `tests/test_sound_cues.lua` failures, which come from Windows `ls` and `find`.
- The Pixel Lab tour produces 99 captures that are byte-identical to the baseline by PNG sha256, with 39 call sites flagged.

| # | Change | score_ms before → after | Main parts moved | Verdict |
| --- | --- | --- | --- | --- |
| 0 | Harness, baseline at 39dd0e2 | 10395 | — | baseline |
| 1 | `zip -n .t3x:.wav:.ogg`: store textures, cues and music in game.love | 10395 → 9662 (−7.1%) | inflate 1700 → 886; read 1214 → 1196 (music stream reads 80 KiB, not 847 KB) | kept |
| 2 | Ship Lua as console-format 5.1 bytecode (`dev/luac_3ds.py`, host luac 5.1.5 built by `setup.sh`) | 9662 → 6317 (−34.6%) | lua_compile 3955 → 635 (undump, not compile); read 1196 → 1240 and inflate 886 → 897 (bytecode is 2.49 MB against 2.42 MB of source over the boot modules); PUC boot allocation 19 MB → 4 MB | kept. The build change is unverified on devkitPro and on hardware |
| 3 | Pack every module except `main.lua`, `conf.lua` and `module_bundle.lua` into one stored `modules.luab` (`dev/lua_bundle.py`). `module_bundle.lua` serves `require` from it with a seek and a read on one open handle | 6317 → 5720 (−9.5%) | open 1088 → 528 (136 → 66 files); stat 334 → 192 (167 → 96 probes); inflate 897 → 506 and read 1240 → 1636 (stored bytecode, about even); lua_compile + lua_exec 1471 → 1571, which is one tick of the host's 1 ms clock and counts against the step. PUC boot allocation 4.1 MB → 6.4 MB, because each module's bytes become a Lua string before `loadstring` | kept. A copy of the tree whose modules exist only in a source `modules.luab` runs the Pixel Lab tour to byte-identical captures under the real loader. The build change and the loader on LövePotion are unverified on devkitPro and on hardware, and the per-read latency of the FS service is not in the weights |
