#!/usr/bin/env bash
# probe.sh -- pre-flight gate for the dgraph shortest-path benchmark sweep.
#
# Verifies, BEFORE you commit hours of wall-clock to the full sweep, that:
#   1. The VM environment is sane (tools, paths, disk, ports).
#   2. Each candidate branch in the dgraph repo builds cleanly.
#   3. Each branch's freshly-built binary actually returns a result for the
#      numpaths>=2 shortest-path query on each target dataset. This is the
#      bug class the benchmark is meant to characterise -- if a branch hangs
#      here, the 100-target correctness sweep on it will be 100x timeouts
#      with zero diagnostic value.
#
# Exits 0 ONLY if every (branch, dataset) cell is green.
# Exits 1 on any failure -- do not start the full sweep.
#
# Per-cell signal recorded:
#   PASS         -- discriminator query returned a valid _path_
#   HANG         -- query hit PROBE_TIMEOUT, server stuck (the bug)
#   DATA_ERROR   -- source vertex lookup or neighbor lookup failed
#                   (suggests bulk load corrupted or wrong dataset)
#   BUILD_FAIL   -- 'make install' failed for the branch
#   ALPHA_FAIL   -- alpha didn't become healthy within ALPHA_HEALTH_TIMEOUT
#
# Override anything via env:
#   BENCH_DIR DGRAPH_REPO ALPHA_DIR
#   BRANCHES_OVERRIDE="main pr-9576"
#   DATASETS_OVERRIDE="kgs datagen-7_5-fb"
#   PROBE_TIMEOUT=5m
#   BULK_P_<DATASET_UPPER>=/path/to/p   (e.g. BULK_P_KGS=...)
#
# Typical invocation on the benchmark VM:
#   BENCH_DIR=/srv/shortest-path-bench \
#   DGRAPH_REPO=/srv/dgraph \
#   ALPHA_DIR=/srv/db \
#   ALPHA_DIR_PREFIX_ALLOW=/srv/ \
#       ./scripts/probe.sh

set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================
BENCH_DIR="${BENCH_DIR:-/Users/shiva/workspace/shortest-path-bench}"
DGRAPH_REPO="${DGRAPH_REPO:-/Users/shiva/workspace/dgraph-scratch/dgraph}"
ALPHA_DIR="${ALPHA_DIR:-/Users/shiva/workspace/db}"
ALPHA_DIR_PREFIX_ALLOW="${ALPHA_DIR_PREFIX_ALLOW:-/Users/shiva/workspace/}"

BRANCHES_STR="${BRANCHES_OVERRIDE:-main pr-9576 pr-9599 pr-9607 pr-9678}"
read -ra BRANCHES <<< "$BRANCHES_STR"

DATASETS_STR="${DATASETS_OVERRIDE:-kgs datagen-7_5-fb}"
read -ra DATASETS <<< "$DATASETS_STR"

ALPHA_HTTP_URL="${ALPHA_HTTP_URL:-http://localhost:8080}"
ALPHA_HEALTH_URL="$ALPHA_HTTP_URL/health"
ALPHA_QUERY_URL="$ALPHA_HTTP_URL/query"
ALPHA_GRPC="${ALPHA_GRPC:-localhost:9080}"
ZERO_STATE_URL="${ZERO_STATE_URL:-http://localhost:6080/state}"

PROBE_TIMEOUT="${PROBE_TIMEOUT:-5m}"
NUMPATH1_TIMEOUT="${NUMPATH1_TIMEOUT:-2m}"
ALPHA_HEALTH_TIMEOUT_SEC="${ALPHA_HEALTH_TIMEOUT_SEC:-300}"
MIN_FREE_DISK_GB="${MIN_FREE_DISK_GB:-20}"

RESULTS_DIR="${RESULTS_DIR:-$BENCH_DIR/results/probe}"
LOG_DIR="$RESULTS_DIR/logs"

# Shared Alpha lifecycle + safety helpers (stop_alpha, wait_alpha, reset_data,
# start_alpha, guard_rm_target, bulk_p_for, to_seconds, log/die/warn, etc.)
source "$(dirname "${BASH_SOURCE[0]}")/lib/alpha.sh"
trap alpha_cleanup_on_exit EXIT

# ============================================================================
# probe-specific helpers
# ============================================================================
# Read graph.<dataset>.sssp.source-vertex = N from <dataset>.properties.
source_vertex_for() {
    local ds="$1"
    local props="$BENCH_DIR/datasets/$ds/$ds.properties"
    [[ -f "$props" ]] || { echo ""; return; }
    awk -F'=' '/sssp\.source-vertex/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$props"
}

# Look up the uid for a graphalytics_id via HTTP DQL.
lookup_uid() {
    local gid="$1"
    local resp
    resp=$(curl -s -m 10 -H 'Content-Type: application/dql' -X POST "$ALPHA_QUERY_URL" --data \
        "{ q(func: eq(graphalytics_id, $gid), first: 1) { uid } }" 2>/dev/null || true)
    jq -r '.data.q[0].uid // empty' <<< "$resp" 2>/dev/null
}

# Get one neighbor uid (any direct connected) for the given uid.
lookup_neighbor() {
    local src_uid="$1"
    local resp
    resp=$(curl -s -m 10 -H 'Content-Type: application/dql' -X POST "$ALPHA_QUERY_URL" --data \
        "{ q(func: uid($src_uid)) { connected (first: 1) { uid } } }" 2>/dev/null || true)
    jq -r '.data.q[0].connected[0].uid // empty' <<< "$resp" 2>/dev/null
}

# Run shortest() with given numpaths and a hard wall-clock cap.
# Echoes:  status\twall_seconds\tpath_count
# status one of: ok | timeout | http_error | bad_json
run_shortest() {
    local src_uid="$1"
    local dst_uid="$2"
    local numpaths="$3"
    local timeout_s="$4"
    local outfile="$5"

    local start end wall rc
    start=$(date +%s)
    set +e
    curl -s --max-time "$timeout_s" -H 'Content-Type: application/dql' \
        -X POST "$ALPHA_QUERY_URL" --data \
        "{ path as shortest(from: $src_uid, to: $dst_uid, numpaths: $numpaths) {
             connected @facets(weight)
           }
           result(func: uid(path)) { uid }
         }" > "$outfile" 2>/dev/null
    rc=$?
    set -e
    end=$(date +%s)
    wall=$(( end - start ))

    if (( rc == 28 )); then
        printf 'timeout\t%d\t0\n' "$wall"; return
    fi
    if (( rc != 0 )); then
        printf 'http_error\t%d\t0\n' "$wall"; return
    fi
    if ! jq -e . "$outfile" >/dev/null 2>&1; then
        printf 'bad_json\t%d\t0\n' "$wall"; return
    fi
    local pcount
    pcount=$(jq -r '.data._path_ | length // 0' "$outfile" 2>/dev/null)
    pcount="${pcount:-0}"
    printf 'ok\t%d\t%d\n' "$wall" "$pcount"
}

# ============================================================================
# Pre-flight
# ============================================================================
mkdir -p "$RESULTS_DIR" "$LOG_DIR"

log "================================================================="
log " probe.sh -- pre-flight gate for shortest-path benchmark"
log "================================================================="
log "config:"
log "  BENCH_DIR              = $BENCH_DIR"
log "  DGRAPH_REPO            = $DGRAPH_REPO"
log "  ALPHA_DIR              = $ALPHA_DIR"
log "  ALPHA_DIR_PREFIX_ALLOW = $ALPHA_DIR_PREFIX_ALLOW"
log "  branches               = ${BRANCHES[*]}"
log "  datasets               = ${DATASETS[*]}"
log "  probe timeout          = $PROBE_TIMEOUT (numpaths>=2)"
log "  numpaths=1 timeout     = $NUMPATH1_TIMEOUT (sanity)"
log "  alpha-health timeout   = ${ALPHA_HEALTH_TIMEOUT_SEC}s"

log ""
log "[pre-flight] checking host binaries..."
for bin in dgraph go git make curl jq awk; do
    command -v "$bin" >/dev/null || die "$bin not on PATH"
done
log "[pre-flight]   all binaries present"

log "[pre-flight] checking directory paths..."
[[ -d "$BENCH_DIR" ]]   || die "BENCH_DIR not found: $BENCH_DIR"
[[ -d "$DGRAPH_REPO" ]] || die "DGRAPH_REPO not found: $DGRAPH_REPO"
[[ -d "$ALPHA_DIR" ]]   || die "ALPHA_DIR not found: $ALPHA_DIR"
[[ "$ALPHA_DIR" == "$ALPHA_DIR_PREFIX_ALLOW"* ]] \
    || die "ALPHA_DIR ($ALPHA_DIR) not under allowed prefix $ALPHA_DIR_PREFIX_ALLOW"
[[ "$ALPHA_DIR" != "/" ]]    || die "ALPHA_DIR is /"
[[ "$ALPHA_DIR" != "$HOME" ]] || die "ALPHA_DIR equals HOME"
log "[pre-flight]   directories OK"

log "[pre-flight] checking free disk under $ALPHA_DIR..."
free_gb=$(df -Pg "$ALPHA_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || \
          df -P "$ALPHA_DIR" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
if [[ -z "$free_gb" ]]; then
    log "[pre-flight]   warning: could not parse df output, skipping disk check"
elif (( free_gb < MIN_FREE_DISK_GB )); then
    die "free disk under $ALPHA_DIR is ${free_gb}GB, need >= ${MIN_FREE_DISK_GB}GB"
else
    log "[pre-flight]   ${free_gb}GB free (need >=${MIN_FREE_DISK_GB}GB)"
fi

log "[pre-flight] checking dgraph repo working tree clean..."
( cd "$DGRAPH_REPO"
  if ! git diff --quiet || ! git diff --cached --quiet; then
      die "dgraph working tree is dirty. commit/stash before probing."
  fi )
log "[pre-flight]   clean"

log "[pre-flight] checking all branches exist locally in dgraph repo..."
( cd "$DGRAPH_REPO"
  for br in "${BRANCHES[@]}"; do
      git rev-parse --verify --quiet "$br" >/dev/null \
          || die "branch '$br' not found locally in $DGRAPH_REPO (did you forget 'git fetch'?)"
  done )
log "[pre-flight]   all ${#BRANCHES[@]} branches present"

log "[pre-flight] checking datasets..."
for ds in "${DATASETS[@]}"; do
    ds_dir="$BENCH_DIR/datasets/$ds"
    [[ -d "$ds_dir" ]] || die "dataset dir missing: $ds_dir"
    [[ -f "$ds_dir/$ds.properties" ]] || die "$ds_dir/$ds.properties missing"
    src_v=$(source_vertex_for "$ds")
    [[ -n "$src_v" ]] || die "$ds_dir/$ds.properties has no 'sssp.source-vertex' line"
    bp=$(bulk_p_for "$ds")
    [[ -d "$bp" ]] || die "bulk-loaded p/ missing for $ds at $bp (set BULK_P_${ds^^} or run setup)"
    log "[pre-flight]   $ds: src=$src_v  bulk_p=$bp ($(size_of "$bp"))"
done

log "[pre-flight] checking zero is reachable..."
curl -s -m 5 "$ZERO_STATE_URL" >/dev/null 2>&1 \
    || die "zero is not reachable at $ZERO_STATE_URL -- start it before probing"
log "[pre-flight]   zero responding"

log "[pre-flight] sanity-building bench tool..."
( cd "$BENCH_DIR" && go build ./... ) || die "bench failed to compile in $BENCH_DIR"
log "[pre-flight]   bench compiles"

stop_alpha
log "[pre-flight] all green. starting probe loop."
log ""

# ============================================================================
# Probe loop -- per branch, per dataset
# ============================================================================
# Results table: STATUS[branch:dataset] = "PASS|HANG|DATA_ERROR|BUILD_FAIL|ALPHA_FAIL"
# Detail rows kept in arrays for the summary table.
declare -A STATUS
declare -A NP1_WALL
declare -A NP2_WALL
declare -A NP2_PATHS
declare -A SRC_UID
declare -A DST_UID

probe_t0=$(date +%s)

for branch in "${BRANCHES[@]}"; do
    log "================================================================="
    log " BRANCH: $branch"
    log "================================================================="

    log "[$branch] checkout + make install"
    if ! ( cd "$DGRAPH_REPO"
           git checkout "$branch" >/dev/null 2>&1
           make install ) >"$LOG_DIR/build-$branch.log" 2>&1; then
        log "[$branch] BUILD FAILED -- see $LOG_DIR/build-$branch.log"
        for ds in "${DATASETS[@]}"; do
            STATUS["$branch:$ds"]="BUILD_FAIL"
        done
        continue
    fi

    bin_branch=$(dgraph version 2>/dev/null | awk '/^Branch/ {print $3; exit}' || true)
    if [[ -n "$bin_branch" && "$bin_branch" != "$branch" ]]; then
        log "[$branch] WARN: dgraph binary reports Branch='$bin_branch' (expected '$branch')"
    fi

    for ds in "${DATASETS[@]}"; do
        cell="$branch:$ds"
        log "----- [$branch / $ds] -----"

        stop_alpha
        bp=$(bulk_p_for "$ds")
        log "  reset_data using $bp"
        reset_data "$bp"

        start_alpha "$LOG_DIR/alpha-$branch-$ds.log"
        if ! wait_alpha; then
            log "  alpha did not become healthy in ${ALPHA_HEALTH_TIMEOUT_SEC}s"
            STATUS["$cell"]="ALPHA_FAIL"
            continue
        fi
        log "  alpha healthy"

        src_v=$(source_vertex_for "$ds")
        src_uid=$(lookup_uid "$src_v")
        if [[ -z "$src_uid" ]]; then
            log "  source vertex $src_v not found in alpha -- bulk load mismatch?"
            STATUS["$cell"]="DATA_ERROR"
            continue
        fi
        SRC_UID["$cell"]="$src_uid"

        dst_uid=$(lookup_neighbor "$src_uid")
        if [[ -z "$dst_uid" ]]; then
            log "  source $src_uid has no 'connected' neighbor -- bulk load mismatch?"
            STATUS["$cell"]="DATA_ERROR"
            continue
        fi
        DST_UID["$cell"]="$dst_uid"
        log "  using src=$src_uid dst=$dst_uid"

        np1_to=$(to_seconds "$NUMPATH1_TIMEOUT")
        IFS=$'\t' read -r np1_status np1_wall np1_paths < <(
            run_shortest "$src_uid" "$dst_uid" 1 "$np1_to" \
                "$RESULTS_DIR/probe-$branch-$ds-np1.json"
        )
        NP1_WALL["$cell"]="$np1_wall"
        log "  numpaths=1: $np1_status wall=${np1_wall}s paths=$np1_paths"
        if [[ "$np1_status" != "ok" || "$np1_paths" -eq 0 ]]; then
            log "  numpaths=1 didn't return a path -- skipping numpaths=2 for this cell"
            STATUS["$cell"]="DATA_ERROR"
            continue
        fi

        np2_to=$(to_seconds "$PROBE_TIMEOUT")
        IFS=$'\t' read -r np2_status np2_wall np2_paths < <(
            run_shortest "$src_uid" "$dst_uid" 2 "$np2_to" \
                "$RESULTS_DIR/probe-$branch-$ds-np2.json"
        )
        NP2_WALL["$cell"]="$np2_wall"
        NP2_PATHS["$cell"]="$np2_paths"
        log "  numpaths=2: $np2_status wall=${np2_wall}s paths=$np2_paths"

        case "$np2_status" in
            ok)
                if (( np2_paths >= 1 )); then
                    STATUS["$cell"]="PASS"
                else
                    STATUS["$cell"]="DATA_ERROR"
                fi
                ;;
            timeout)        STATUS["$cell"]="HANG" ;;
            http_error)     STATUS["$cell"]="HANG" ;;
            bad_json)       STATUS["$cell"]="DATA_ERROR" ;;
            *)              STATUS["$cell"]="HANG" ;;
        esac
    done

    stop_alpha
done

probe_t1=$(date +%s)
probe_elapsed=$(( probe_t1 - probe_t0 ))

# ============================================================================
# Summary
# ============================================================================
log ""
log "================================================================="
log " probe summary (elapsed: ${probe_elapsed}s)"
log "================================================================="

printf '\n%-14s %-22s %-12s %-10s %-10s %-8s\n' \
    "branch" "dataset" "status" "np1_wall_s" "np2_wall_s" "np2_paths"
printf '%-14s %-22s %-12s %-10s %-10s %-8s\n' \
    "------" "-------" "------" "----------" "----------" "---------"

all_green=1
for branch in "${BRANCHES[@]}"; do
    for ds in "${DATASETS[@]}"; do
        cell="$branch:$ds"
        st="${STATUS[$cell]:-MISSING}"
        np1="${NP1_WALL[$cell]:-?}"
        np2="${NP2_WALL[$cell]:-?}"
        nps="${NP2_PATHS[$cell]:-?}"
        printf '%-14s %-22s %-12s %-10s %-10s %-8s\n' \
            "$branch" "$ds" "$st" "$np1" "$np2" "$nps"
        [[ "$st" == "PASS" ]] || all_green=0
    done
done

# Machine-readable results for run-pr-comparison.sh to consume.
results_json="$RESULTS_DIR/probe-results.json"
{
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "elapsed_s": %d,\n' "$probe_elapsed"
    printf '  "all_green": %s,\n' "$([[ $all_green -eq 1 ]] && echo true || echo false)"
    printf '  "cells": [\n'
    first=1
    for branch in "${BRANCHES[@]}"; do
        for ds in "${DATASETS[@]}"; do
            cell="$branch:$ds"
            st="${STATUS[$cell]:-MISSING}"
            np1="${NP1_WALL[$cell]:-}"
            np2="${NP2_WALL[$cell]:-}"
            nps="${NP2_PATHS[$cell]:-}"
            # Convert missing/non-numeric to JSON null.
            [[ "$np1" =~ ^[0-9]+$ ]] || np1=null
            [[ "$np2" =~ ^[0-9]+$ ]] || np2=null
            [[ "$nps" =~ ^[0-9]+$ ]] || nps=null
            (( first == 0 )) && printf ',\n'
            printf '    {"branch": "%s", "dataset": "%s", "status": "%s", "np1_wall_s": %s, "np2_wall_s": %s, "np2_paths": %s}' \
                "$branch" "$ds" "$st" "$np1" "$np2" "$nps"
            first=0
        done
    done
    printf '\n  ]\n}\n'
} > "$results_json"
log "wrote machine-readable results: $results_json"

echo
if (( all_green == 1 )); then
    log "VERDICT: ALL GREEN -- safe to start the full benchmark sweep."
    log "         (every branch returns numpaths>=2 on every dataset)"
    exit 0
else
    log "VERDICT: BLOCKED -- at least one (branch, dataset) cell is not PASS."
    log ""
    log "  Interpretation guide:"
    log "    HANG        -- branch does not fix the numpaths>=2 hang."
    log "                   Running the full sweep on it will produce all timeouts."
    log "    BUILD_FAIL  -- 'make install' failed on this branch in $DGRAPH_REPO."
    log "                   See $LOG_DIR/build-<branch>.log"
    log "    ALPHA_FAIL  -- alpha never became healthy with this branch's binary."
    log "                   See $LOG_DIR/alpha-<branch>-<dataset>.log"
    log "    DATA_ERROR  -- source vertex / neighbor lookup failed."
    log "                   Re-check that the bulk-loaded p/ matches the dataset."
    log ""
    log "  Do NOT start the full sweep. Fix the failing cells first."
    exit 1
fi
