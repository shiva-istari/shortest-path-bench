#!/usr/bin/env bash
# run-kshortest-all.sh -- per-PR k-shortest correctness sweep.
#
# Sibling of run-pr-comparison.sh, but runs `cmd/bench -mode kshortest`: for
# each branch it compares Dgraph's top-k path-cost VECTOR against the gonum Yen
# oracle across a maxfrontiersize sweep, emitting a per-frontier correctness
# table. One JSON per branch in $RESULTS_DIR/kshortest/<branch>-<dataset>.json.
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
#   NUMPATHS=2  TARGETS=30  FRONTIERS="0,10000,1000,100"
#   BANDLO=0.0005  BANDHI=0.004  TOL=0.0001  TIMEOUT=30s  SEED=1

set -euo pipefail

BENCH_DIR="${BENCH_DIR:-/srv/shortest-path-bench}"
DGRAPH_REPO="${DGRAPH_REPO:-/srv/dgraph}"
ALPHA_DIR="${ALPHA_DIR:-/srv/db}"
ALPHA_DIR_PREFIX_ALLOW="${ALPHA_DIR_PREFIX_ALLOW:-/srv/}"

BRANCHES_STR="${BRANCHES_OVERRIDE:-main pr-9576 pr-9599 pr-9607 pr-9678}"
read -ra BRANCHES <<< "$BRANCHES_STR"
DATASET="${DATASET_OVERRIDE:-roadCOL}"

NUMPATHS="${NUMPATHS:-2}"
TARGETS="${TARGETS:-30}"
FRONTIERS="${FRONTIERS:-0,10000,1000,100}"
BANDLO="${BANDLO:-0.0005}"
BANDHI="${BANDHI:-0.004}"
TOL="${TOL:-0.0001}"
TIMEOUT="${TIMEOUT:-30s}"
SEED="${SEED:-1}"

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
trap alpha_cleanup_on_exit EXIT

# ---- pre-flight (no destructive ops) ---------------------------------------
mkdir -p "$KS_DIR" "$LOG_DIR"
log "================ run-kshortest-all.sh ================"
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

MASTER_LOG="$LOG_DIR/kshortest-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$MASTER_LOG") 2>&1
stop_alpha

# ---- sweep -----------------------------------------------------------------
first=1
for branch in "${BRANCHES[@]}"; do
    log ""
    log "================= BRANCH: $branch ================="
    if ! ( cd "$DGRAPH_REPO"; git checkout "$branch" >/dev/null 2>&1; make install ) \
            2>&1 | tee "$LOG_DIR/build-$branch.log"; then
        warn "[$branch] BUILD FAILED -- skipping (see $LOG_DIR/build-$branch.log)"
        continue
    fi

    stop_alpha
    reset_data "$BP"
    start_alpha "$LOG_DIR/alpha-kshortest-$branch.log"
    if ! wait_alpha; then
        warn "[$branch] alpha unhealthy in ${ALPHA_HEALTH_TIMEOUT_SEC}s -- skipping"
        stop_alpha; continue
    fi

    refresh=""
    if (( first == 1 )); then refresh="-refresh-uidmap"; first=0; fi  # uids stable across branches

    out="$KS_DIR/${branch}-${DATASET}.json"
    log "[$branch] kshortest -> $out"
    if ! ( cd "$BENCH_DIR" && go run ./cmd/bench \
              -mode kshortest \
              -dataset "$ds_dir" \
              -alpha "$ALPHA_GRPC" \
              -numpaths "$NUMPATHS" \
              -targets "$TARGETS" \
              -frontiers "$FRONTIERS" \
              -band-lo "$BANDLO" -band-hi "$BANDHI" \
              -tol "$TOL" -timeout "$TIMEOUT" -seed "$SEED" \
              $refresh \
              -out "$out" \
         ) 2>&1 | tee "$LOG_DIR/bench-kshortest-$branch.log"; then
        warn "[$branch] bench invocation failed -- see log"
    fi
    stop_alpha
done

# ---- cross-branch summary --------------------------------------------------
log ""
log "================= SUMMARY (correct% by frontier) ================="
printf '%-14s' "frontier"; for b in "${BRANCHES[@]}"; do printf ' %-12s' "$b"; done; echo
for fr in ${FRONTIERS//,/ }; do
    label=$fr; [[ "$fr" == "0" ]] && label="unlimited"
    printf '%-14s' "$label"
    for b in "${BRANCHES[@]}"; do
        f="$KS_DIR/${b}-${DATASET}.json"
        if [[ -f "$f" ]]; then
            pct=$(jq -r --argjson fr "$fr" '.frontiers[]? | select(.max_frontier==$fr) | .correct_pct' "$f" 2>/dev/null)
            printf ' %-12s' "${pct:-NA}"
        else
            printf ' %-12s' "norun"
        fi
    done
    echo
done
log "results: $KS_DIR   master log: $MASTER_LOG"
