#!/usr/bin/env bash
# launch-pr.sh -- from-scratch, one-command launch of a single PR's kshortest
# run: kills stray bench/alpha processes, starts zero if it's down, then
# launches run-kshortest-all.sh fully detached (nohup + disown). Exists so the
# operator never has to paste a long fragile command line into a terminal.
#
#   ./scripts/launch-pr.sh pr-9599
#
# Watch:   tail -f results/sweep-<pr>.out
# Status:  jq '.frontiers|length' /srv/results-run2/kshortest/<pr>-roadCOL.json
#          (4 = all frontiers done)
set -euo pipefail

PR="${1:?usage: launch-pr.sh <branch, e.g. pr-9599>}"
BENCH_DIR="${BENCH_DIR:-/srv/shortest-path-bench}"
RESULTS_DIR="${RESULTS_DIR:-/srv/results-run2}"
DATASET="${DATASET_OVERRIDE:-roadCOL}"
ZERO_DIR="${ZERO_DIR:-/srv/db/zero-setup}"

# 1. stop stale bench/alpha (never zero unless it's dead -- it serves all runs)
pkill -f run-kshortest-all 2>/dev/null || true
pkill -f 'cmd/bench'       2>/dev/null || true
pkill -f 'dgraph alpha'    2>/dev/null || true
sleep 2

# 2. ensure zero
if ! curl -s -m 3 localhost:6080/state >/dev/null; then
    echo "[launch] zero down -- starting it in $ZERO_DIR"
    pkill -f 'dgraph zero' 2>/dev/null || true
    sleep 1
    mkdir -p "$ZERO_DIR"
    ( cd "$ZERO_DIR" && nohup dgraph zero --my=localhost:5080 --replicas=1 > zero.log 2>&1 & )
    sleep 6
    curl -s -m 3 localhost:6080/state >/dev/null \
        || { echo "[launch] ZERO FAILED -- see $ZERO_DIR/zero.log"; exit 1; }
fi
echo "[launch] zero up"

# 3. launch detached
cd "$BENCH_DIR"
mkdir -p results
OUT="$BENCH_DIR/results/sweep-$PR.out"
nohup env RESULTS_DIR="$RESULTS_DIR" DATASET_OVERRIDE="$DATASET" BRANCHES_OVERRIDE="$PR" \
    ./scripts/run-kshortest-all.sh > "$OUT" 2>&1 &
disown
echo "[launch] $PR started (pid $!)"
echo "[launch] watch:   tail -f $OUT"
echo "[launch] status:  jq '.frontiers|length' $RESULTS_DIR/kshortest/$PR-$DATASET.json"
