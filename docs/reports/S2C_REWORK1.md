Ops-Head: 82e81beef01633f337c7ceb4c74607c27e79ba1f (this file is committed on top of it)
Head (forge-core): ba125fd88027505aa2437c4919e7834db74972f2

# S2c rework 1 - forge-ops part

Full report: forge-core `docs/reports/S2C_REWORK1.md` (branch `f5c/s2c`). forge-ops changes of this rework: `bin/forge-run-job` consumes the graph's dispatch record (`core.graph_run_orders`, published -> running, exactly once) immediately before starting a job (`consume_order`, exit 65 refused / 69 database unreachable, no side effect); `bin/forge-postbote.sh` passes the order DB access (`FORGE_RUN_ORDER_PSQL`, `FORGE_PG_CONTAINER`, `DOCKER_*`) through its `env -i`; tests: `tests/test_run_kind.sh` section 7b (213 checks), `tests/fake-psql`, `tests/lib_orders.sh`, `tests/compare_watchers.py` (30 non-RUN cases, base bd6a8af vs this branch: 30 identical), mutation script (8 new mutants, 8/8 killed). All seven shell suites green (213 / 47 / 153 / 40 / 54 / 13 / 14). Nothing deployed, no watcher restart.
