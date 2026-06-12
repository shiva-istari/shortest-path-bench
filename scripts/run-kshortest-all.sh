#!/usr/bin/env bash
# run-kshortest-all.sh -- per-PR k-shortest correctness sweep.
#
# Sibling of run-pr-comparison.sh, but runs `cmd/bench -mode kshortest`: for
# each branch it compares Dgraph's top-k path-cost VECTOR against the gonum Yen
# oracle across a maxfrontiersize sweep, emitting a per-frontier correctness
# table. One JSON per branch per run in
# $RESULTS_DIR/kshortest/<branch>-<dataset>-<run_tag>.json -- a re-run never
# overwrites a previous run's results.
#
# Per branch (once): git checkout + make install in $DGRAPH_REPO.
# Per branch run:
#   stop alpha; wipe $ALPHA_DIR/{p,t,w,zw}; cp <dataset bulk p/> -> $ALPHA_DIR/p
#   start alpha; wait for /health; go run ./cmd/bench -mode kshortest ...
#
# The bulk p/ is identical across branches (same dataset, same bulk), so UIDs
# are stable and the uid-map cache is valid for the whole sweep: we pass
# -refresh-uidmap only on the FIRST branch.
#
# PREREQS (run once, before this script):
#   - zero running; $DGRAPH_REPO has the PR branches as local git branches
#   - dataset prepared + bulk-loaded so bulk_p_for(<ds>) exists, e.g.:
#       go run ./cmd/prepare -format dimacs -name roadCOL -source 1 -url <URL>
#       go run ./cmd/convert  -dataset datasets/roadCOL
#       dgraph bulk -f datasets/roadCOL/dgraph/graph.rdf.gz \
#                   -s datasets/roadCOL/dgraph/graph.schema \
#                   --zero localhost:5080 --out datasets/roadCOL/dgraph/bulk-out
#
# INPUTS (env, with VM defaults):
#   BENCH_DIR=/srv/shortest-path-bench  DGRAPH_REPO=/srv/dgraph
#   ALPHA_DIR=/srv/db                   ALPHA_DIR_PREFIX_ALLOW=/srv/
#   BRANCHES_OVERRIDE="main pr-9576 pr-9599 pr-9607 pr-9678"
#   DATASET_OVERRIDE=roadCOL
#   NUMPATHS=2  TARGETS=30  FRONTIERS="100,1000,5000"  (add ,0 for unlimited)
#   BANDLO=0.0005  BANDHI=0.004  TOL=0.0001  TIMEOUT=30s  SEED=1
#   RUN_TAG=<ts>  -- suffix for all output files (default: launch timestamp)

set -euo pipefail

BENCH_DIR="${BENCH_DIR:-/srv/shortest-path-bench}"
DGRAPH_REPO="${DGRAPH_REPO:-/srv/dgraph}"
ALPHA_DIR="${ALPHA_DIR:-/srv/db}"
ALPHA_DIR_PREFIX_ALLOW="${ALPHA_DIR_PREFIX_ALLOW:-/srv/}"

BRANCHES_STR="${BRANCHES_OVERRIDE:-main pr-9576 pr-9599 pr-9607 pr-9678}"
read -ra BRANCHES <<< "$BRANCHES_STR"
DATASET="${DATASET_OVERRIDE:-roadCOL}"

NUMPATHS="${NUMPATHS:-2}"
TARGETS="${TARGETS:-100}"          # more targets -> resolves small main-vs-PR differences
# CAPPED frontiers only by default. The unlimited row (0) is memory-unbounded
# (numpaths=2, no eviction cap), slow, and its scientific job -- proving the
# wrongness is eviction-specific -- is already done: 2026-06-10 sweep gave
# unlimited baselines for all 5 branches (80/0/80/80/80%), and run
# 20260612-082535 confirmed pr-9599 at 37/37=100% correct uncapped. Top cap is
# 5000, not 10000: at 10000 44/100 targets timed out (60s), so that row mostly
# measured the timeout ceiling, and it cost ~48min. Opt back in per-run with
# FRONTIERS="100,1000,5000,0" (keep 0 LAST: results persist per-frontier, so
# the verdict rows survive an OOM on the unlimited row).
FRONTIERS="${FRONTIERS:-100,1000,5000}"
BANDLO="${BANDLO:-0.0005}"
BANDHI="${BANDHI:-0.004}"
TOL="${TOL:-0.0001}"
TIMEOUT="${TIMEOUT:-60s}"          # higher -> fewer timeouts polluting the unlimited row
SEED="${SEED:-1}"

# Every run writes to NEW files -- never overwrite a previous run's results,
# logs, or pprof evidence. launch-pr.sh passes its own RUN_TAG so the .out
# file and the per-branch artifacts share one tag; direct invocations get a
# fresh timestamp.
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d-%H%M%S)}"

ALPHA_HTTP_URL="${ALPHA_HTTP_URL:-http://localhost:8080}"
ALPHA_HEALTH_URL="$ALPHA_HTTP_URL/health"
ALPHA_GRPC="${ALPHA_GRPC:-localhost:9080}"
ZERO_STATE_URL="${ZERO_STATE_URL:-http://localhost:6080/state}"
ALPHA_HEALTH_TIMEOUT_SEC="${ALPHA_HEALTH_TIMEOUT_SEC:-300}"

RESULTS_DIR="${RESULTS_DIR:-$BENCH_DIR/results}"
KS_DIR="$RESULTS_DIR/kshortest"
LOG_DIR="$RESULTS_DIR/logs"

# Datasets array (single dataset here) so alpha.sh guard_rm_target protects it.
DATASETS=( "$DATASET" )
source "$(dirname "${BASH_SOURCE[0]}")/lib/alpha.sh"
trap 'stop_memlog; alpha_cleanup_on_exit' EXIT

# ---- pre-flight (no destructive ops) ---------------------------------------
mkdir -p "$KS_DIR" "$LOG_DIR"
log "================ run-kshortest-all.sh ================"
preflight_memory   # abort if a previous run is still hogging RAM; warn if no swap
for bin in dgraph go git make curl jq awk; do command -v "$bin" >/dev/null || die "$bin not on PATH"; done
[[ -d "$BENCH_DIR" ]]   || die "BENCH_DIR not found: $BENCH_DIR"
[[ -d "$DGRAPH_REPO" ]] || die "DGRAPH_REPO not found: $DGRAPH_REPO"
[[ -d "$ALPHA_DIR" ]]   || die "ALPHA_DIR not found: $ALPHA_DIR"
[[ "$ALPHA_DIR" == "$ALPHA_DIR_PREFIX_ALLOW"* ]] || die "ALPHA_DIR not under $ALPHA_DIR_PREFIX_ALLOW"

ds_dir="$BENCH_DIR/datasets/$DATASET"
[[ -f "$ds_dir/$DATASET.properties" ]] || die "$ds_dir/$DATASET.properties missing -- run prepare+convert"
BP=$(bulk_p_for "$DATASET")
[[ -d "$BP" ]] || die "bulk p/ missing for $DATASET at $BP -- run 'dgraph bulk' first"

( cd "$DGRAPH_REPO"
  git diff --quiet && git diff --cached --quiet || die "dgraph working tree dirty"
  for br in "${BRANCHES[@]}"; do
      git rev-parse --verify --quiet "$br" >/dev/null || die "branch '$br' not in $DGRAPH_REPO"
  done )
( cd "$BENCH_DIR" && go build ./... ) || die "bench failed to compile"
require_zero

log "config: dataset=$DATASET branches='${BRANCHES[*]}' numpaths=$NUMPATHS targets=$TARGETS"
log "        frontiers=$FRONTIERS band=[$BANDLO,$BANDHI] timeout=$TIMEOUT bulk_p=$BP ($(size_of "$BP"))"

MASTER_LOG="$LOG_DIR/kshortest-$RUN_TAG.log"
exec > >(tee -a "$MASTER_LOG") 2>&1
log "run tag: $RUN_TAG (all artifacts of this run carry this suffix)"
start_memlog "$LOG_DIR/memlog-$RUN_TAG.log"   # post-mortem RAM/RSS trace
stop_alpha

# ---- sweep -----------------------------------------------------------------
first=1
for branch in "${BRANCHES[@]}"; do
    log ""
    log "================= BRANCH: $branch ================="
    if ! ( cd "$DGRAPH_REPO"; git checkout "$branch" >/dev/null 2>&1; make install ) \
            2>&1 | tee "$LOG_DIR/build-$branch-$RUN_TAG.log"; then
        warn "[$branch] BUILD FAILED -- skipping (see $LOG_DIR/build-$branch-$RUN_TAG.log)"
        continue
    fi

    # VERIFY the running binary is actually this branch's commit, before we
    # trust any numbers from it. Catches a stale PATH or a failed make install.
    want_sha=$(cd "$DGRAPH_REPO" && git rev-parse --short=9 "$branch" 2>/dev/null)
    bin_sha=$(dgraph version 2>/dev/null | awk -F: '/Commit SHA-1/{gsub(/[[:space:]]/,"",$2); print $2}')
    log "[$branch] want commit=$want_sha  binary reports commit=$bin_sha"
    if [[ -z "$bin_sha" ]]; then
        die "[$branch] could not parse 'Commit SHA-1' from dgraph version -- cannot verify binary"
    fi
    if [[ "$bin_sha" != "$want_sha"* && "$want_sha" != "$bin_sha"* ]]; then
        die "[$branch] BINARY MISMATCH: branch commit=$want_sha but running binary=$bin_sha (PATH/build problem)"
    fi
    label="${branch}@${bin_sha}"

    alpha_log="$LOG_DIR/alpha-kshortest-$branch-$RUN_TAG.log"
    stop_alpha
    reset_data "$BP"
    start_alpha "$alpha_log"
    if ! wait_alpha; then
        warn "[$branch] alpha unhealthy in ${ALPHA_HEALTH_TIMEOUT_SEC}s -- skipping"
        tail_log "[$branch] alpha" "$alpha_log"
        stop_alpha; continue
    fi

    # /health goes green BEFORE the bulk tablets are queryable (the alpha must
    # load postings + register tablets with zero, slower against a fresh zero).
    # So wait until the data is actually served — poll count(graphalytics_id)>0
    # — otherwise the bench races ahead and fetches an empty uid map.
    log "[$branch] waiting for bulk data to be served..."
    data_ok=0
    for _ in $(seq 1 90); do
        n=$(curl -s -m 5 -H 'Content-Type: application/dql' "$ALPHA_HTTP_URL/query" \
              -d '{ q(func: has(graphalytics_id)) { count(uid) } }' 2>/dev/null \
              | jq -r '.data.q[0].count // 0' 2>/dev/null)
        if [[ "${n:-0}" =~ ^[0-9]+$ ]] && (( n > 0 )); then
            data_ok=1; log "[$branch] data served: $n nodes"; break
        fi
        sleep 2
    done
    if (( data_ok == 0 )); then
        warn "[$branch] bulk data not served within 180s -- skipping branch"
        stop_alpha; continue
    fi

    refresh=""
    if (( first == 1 )); then refresh="-refresh-uidmap"; first=0; fi  # uids stable across branches

    # Capture proof that the eviction path is actually exercised: a CPU profile
    # + goroutine dump, taken ~40s into the run (during the frontier sweep). On
    # a binary that's evicting under maxfrontiersize, `go tool pprof -top` on the
    # CPU profile shows (*priorityQueue).removeMax / pq.Pop / expandOut.
    if [[ "${CAPTURE_PPROF:-1}" == "1" ]]; then
        ( sleep 40
          curl -s "${ALPHA_HTTP_URL}/debug/pprof/profile?seconds=30" -o "$KS_DIR/pprof-cpu-$branch-$RUN_TAG.prof" 2>/dev/null
          curl -s "${ALPHA_HTTP_URL}/debug/pprof/goroutine?debug=2"  -o "$KS_DIR/pprof-goroutine-$branch-$RUN_TAG.txt" 2>/dev/null ) &
        pprof_pid=$!
    fi

    out="$KS_DIR/${branch}-${DATASET}-${RUN_TAG}.json"
    log "[$branch] kshortest ($label) -> $out"
    if ! ( cd "$BENCH_DIR" && go run ./cmd/bench \
              -mode kshortest \
              -dataset "$ds_dir" \
              -alpha "$ALPHA_GRPC" \
              -numpaths "$NUMPATHS" \
              -targets "$TARGETS" \
              -frontiers "$FRONTIERS" \
              -band-lo "$BANDLO" -band-hi "$BANDHI" \
              -tol "$TOL" -timeout "$TIMEOUT" -seed "$SEED" \
              -label "$label" \
              $refresh \
              -out "$out" \
         ) 2>&1 | tee "$LOG_DIR/bench-kshortest-$branch-$RUN_TAG.log"; then
        warn "[$branch] bench invocation failed -- see log"
        # If alpha died mid-run (e.g. OOM-killed under the memory cap), say so
        # and surface its log -- that's the difference between "bench bug" and
        # "alpha ran out of memory".
        apid=$(cat /tmp/dgraph-alpha.pid 2>/dev/null || true)
        if [[ -z "$apid" ]] || ! kill -0 "$apid" 2>/dev/null; then
            warn "[$branch] alpha is no longer running -- likely OOM-killed or crashed mid-bench"
            tail_log "[$branch] alpha" "$alpha_log"
        fi
    fi
    [[ -n "${pprof_pid:-}" ]] && wait "$pprof_pid" 2>/dev/null || true
    stop_alpha
done

# ---- cross-branch summary --------------------------------------------------
# Report correct-of-RETURNED (timeouts excluded from the denominator) as
# "c/r=NN%(rN tT)": NN% correct of returned, r returned, t timed out. A timeout
# is not a wrong answer, so folding it into correctness would understate a
# branch that simply ran slow.
log ""
log "================= SUMMARY: correct-of-returned% (returned / timeouts) ================="
printf '%-12s' "frontier"; for b in "${BRANCHES[@]}"; do printf ' %-22s' "$b"; done; echo
for fr in ${FRONTIERS//,/ }; do
    flabel=$fr; [[ "$fr" == "0" ]] && flabel="unlimited"
    printf '%-12s' "$flabel"
    for b in "${BRANCHES[@]}"; do
        f="$KS_DIR/${b}-${DATASET}-${RUN_TAG}.json"
        if [[ -f "$f" ]]; then
            cell=$(jq -r --argjson fr "$fr" '.frontiers[]? | select(.max_frontier==$fr)
                | "\(.correct_of_returned_pct|floor)%(r\(.returned) t\(.timeouts))"' "$f" 2>/dev/null)
            printf ' %-22s' "${cell:-NA}"
        else
            printf ' %-22s' "norun"
        fi
    done
    echo
done
log "results: $KS_DIR/*-${RUN_TAG}.json (per-branch JSONs carry full per-target detail)"
log "pprof:   $KS_DIR/pprof-cpu-<branch>-$RUN_TAG.prof  -> verify eviction with: go tool pprof -top <file> | grep -iE 'removeMax|pq.Pop|expandOut'"
log "master log: $MASTER_LOG"
