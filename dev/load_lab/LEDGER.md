# Load-time ledger

This ledger records every step of the load-time climb on `perf/load-time`, including the rejected ones. The scores come from `dev/load_lab/run.sh` (see `README.md`) under its fixed weights. `score_ms` is the estimated Old 3DS time from launch to the first hand dealt. Each step changes one thing, and it is kept only if it gains clearly and every check passes.

The checks for every kept step:

- The test suite gives 1115 passed, 4 failed and 2 skipped. The 4 failures are the known `tests/test_sound_cues.lua` failures, which come from Windows `ls` and `find`.
- The Pixel Lab tour produces 99 captures that are byte-identical to the baseline by PNG sha256, with 39 call sites flagged.

| # | Change | score_ms before → after | Main parts moved | Verdict |
| --- | --- | --- | --- | --- |
| 0 | Harness, baseline at 39dd0e2 | 10395 | — | baseline |
