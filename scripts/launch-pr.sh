#!/usr/bin/env bash
# launch-pr.sh -- from-scratch, one-command launch of a kshortest sweep over
# one or more branches: kills stray bench/alpha processes (never zero), ensures zero is running
# as a persistent systemd unit (dgraph-zero: reboot-proof, restart-on-failure,
# OOM-protected, never restarted while healthy), then launches
# run-kshortest-all.sh detached. Exists so the operator never has to paste a
# long fragile command line into a terminal.
#
# Detach mechanism (dgraph-bench-rca, RCA-1/RCA-3): the whole sweep runs inside
# a systemd-run transient unit with a hard memory ceiling. If Dgraph eats past
# MEMORY_MAX the kernel OOM-kills it INSIDE the cgroup -- the VM and sshd stay
# alive instead of freezing, and the sweep logs the failure and moves on. The
# unit also gets journald logging on top of the file log. Falls back to plain
# nohup (uncapped -- the old freeze-prone behavior) only if systemd-run or
# passwordless sudo is unavailable.
#
#   ./scripts/launch-pr.sh pr-9599                       # one branch
#   ./scripts/launch-pr.sh main pr-9599 pr-9607          # several branches, one sweep
#   ./scripts/launch-pr.sh all                           # main + all 4 PRs
#
# Multi-branch runs share one unit/run-tag and end with the cross-branch
# summary table; the uid map is fetched once (first branch) and reused.
#
# Every run is tagged with a timestamp (RUN_TAG): output files are never
# overwritten across launches. results/sweep-<label>-latest.out always points
# at the newest run.
#
# Watch:   tail -f results/sweep-<pr>-latest.out  (or: journalctl -u dgraph-bench-<pr> -f)
# Status:  jq '.frontiers|length' /srv/results-run2/kshortest/<pr>-roadCOL-<run_tag>.json
#          (3 = all default frontiers done; exact path printed at launch)
#
# Default sweep is CAPPED frontiers only (100,1000,5000). For the unlimited
# baseline row, opt in per-run: FRONTIERS="100,1000,5000,0" ./scripts/launch-pr.sh <pr>
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: launch-pr.sh <branch ...|all>  (e.g. 'pr-9599' or 'all')" >&2; exit 1; }
if [[ "$1" == "all" ]]; then
    BRANCHES="main pr-9576 pr-9599 pr-9607 pr-9678"
    LABEL="all"
else
    BRANCHES="$*"
    # LABEL names the unit and output files; systemd unit names forbid spaces.
    if (( $# == 1 )); then LABEL="$1"; else LABEL=$(printf '%s' "$BRANCHES" | tr ' ' '-'); fi
fi
BENCH_DIR="${BENCH_DIR:-/srv/shortest-path-bench}"
RESULTS_DIR="${RESULTS_DIR:-/srv/results-run2}"
DATASET="${DATASET_OVERRIDE:-roadCOL}"
ZERO_DIR="${ZERO_DIR:-/srv/db/zero-setup}"
# 48G cap leaves 16G of the 64G VM for the OS, sshd, zero, and the Go bench
# client. MemorySwapMax MUST stay near zero: with a large value (32G), hitting
# MemoryMax never OOM-kills -- the kernel "successfully" reclaims by churning
# pages through swap on the slow boot disk and the VM freezes in an I/O death
# spiral (observed 2026-06-12, run 20260612-082535: alpha RSS pinned at 48G,
# swap 32G/32G full, CPU 350%, VM frozen). With ~1G the cgroup runs out of
# reclaim room immediately and alpha is killed cleanly instead.
MEMORY_MAX="${MEMORY_MAX:-48G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-1G}"

# Single systemd-availability check, used by both the zero unit (step 2) and
# the capped bench unit (step 3).
HAVE_SYSTEMD=0
if [[ "${USE_SYSTEMD_RUN:-1}" == "1" ]] && command -v systemd-run >/dev/null 2>&1 \
        && sudo -n true 2>/dev/null; then
    HAVE_SYSTEMD=1
fi

# 1. stop stale bench/alpha. ZERO IS NEVER TOUCHED HERE: it is shared infra
#    holding uid-lease state for every branch/PR run -- the patterns below
#    deliberately match only alpha/bench, and the 'dgraph-bench-*' unit glob
#    cannot match dgraph-zero.
sudo -n systemctl stop 'dgraph-bench-*' 2>/dev/null || true
pkill -f run-kshortest-all 2>/dev/null || true
pkill -f 'cmd/bench'       2>/dev/null || true
pkill -f 'dgraph alpha'    2>/dev/null || true
sleep 2

# 2. ensure zero -- persistent systemd unit: survives reboots (the last RCA-3
#    nohup gap), auto-restarts on failure, negative OOM score so the kernel
#    avoids killing it, and its own small cgroup fully separate from the bench
#    unit's 48G cap. A HEALTHY ZERO IS NEVER RESTARTED -- re-running this
#    script across PRs leaves it alone; we only start it when /state is down.
zero_up() { curl -s -m 3 localhost:6080/state >/dev/null; }

if (( HAVE_SYSTEMD )); then
    DGRAPH_BIN=$(command -v dgraph) || { echo "[launch] dgraph not on PATH"; exit 1; }
    mkdir -p "$ZERO_DIR"
    UNIT_FILE=/etc/systemd/system/dgraph-zero.service
    desired="[Unit]
Description=Dgraph Zero (shared bench infra -- do not stop between PR runs)
After=network.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$ZERO_DIR
ExecStart=$DGRAPH_BIN zero --my=localhost:5080 --replicas=1
Restart=on-failure
RestartSec=5
MemoryMax=4G
OOMScoreAdjust=-500
StandardOutput=append:$ZERO_DIR/zero.log
StandardError=append:$ZERO_DIR/zero.log

[Install]
WantedBy=multi-user.target"
    if [[ ! -f "$UNIT_FILE" ]] || ! diff -q <(printf '%s\n' "$desired") "$UNIT_FILE" >/dev/null 2>&1; then
        printf '%s\n' "$desired" | sudo tee "$UNIT_FILE" >/dev/null
        sudo systemctl daemon-reload
        echo "[launch] wrote $UNIT_FILE"
    fi
    sudo systemctl enable dgraph-zero >/dev/null 2>&1 || true

    if zero_up; then
        if systemctl is-active --quiet dgraph-zero; then
            echo "[launch] zero up (systemd unit dgraph-zero) -- not touching it"
        else
            # Legacy nohup zero still serving: leave it alone (killing it would
            # drop live uid-lease state). The enabled unit takes over from the
            # same $ZERO_DIR after the next reboot.
            echo "[launch] zero up (legacy non-systemd process) -- leaving it alone;"
            echo "[launch] dgraph-zero unit is enabled and takes over on next reboot"
        fi
    else
        pkill -f 'dgraph zero' 2>/dev/null || true   # clear any wedged remnant
        sleep 1
        sudo systemctl restart dgraph-zero
        for _ in $(seq 1 15); do zero_up && break; sleep 2; done
        zero_up || { echo "[launch] ZERO FAILED -- journalctl -u dgraph-zero -n 50"; exit 1; }
        echo "[launch] zero started (systemd unit dgraph-zero)"
    fi
else
    # nohup fallback (no systemd / no passwordless sudo) -- old behavior
    if ! zero_up; then
        echo "[launch] zero down -- starting it in $ZERO_DIR (nohup fallback)"
        pkill -f 'dgraph zero' 2>/dev/null || true
        sleep 1
        mkdir -p "$ZERO_DIR"
        ( cd "$ZERO_DIR" && nohup dgraph zero --my=localhost:5080 --replicas=1 > zero.log 2>&1 & )
        sleep 6
        zero_up || { echo "[launch] ZERO FAILED -- see $ZERO_DIR/zero.log"; exit 1; }
    fi
    echo "[launch] zero up"
fi

# 3. launch detached -- memory-capped systemd transient unit, nohup fallback.
#    RUN_TAG suffixes every artifact of this run (.out, JSONs, logs, pprof) so
#    a re-launch NEVER overwrites a previous run; sweep-$LABEL-latest.out is a
#    convenience symlink to the newest run's output.
cd "$BENCH_DIR"
mkdir -p results
RUN_TAG="$(date +%Y%m%d-%H%M%S)"
OUT="$BENCH_DIR/results/sweep-$LABEL-$RUN_TAG.out"
: > "$OUT"
ln -sfn "$OUT" "$BENCH_DIR/results/sweep-$LABEL-latest.out"

if (( HAVE_SYSTEMD )); then
    UNIT="dgraph-bench-$LABEL"
    sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
    # The unit starts with a CLEAN environment: tuning vars set on the
    # launch-pr.sh command line (e.g. FRONTIERS=...,0 for the unlimited row)
    # must be forwarded explicitly or they silently vanish. Use --setenv, NOT
    # -p Environment=: the latter splits its value on spaces as multiple
    # VAR=val assignments, so a multi-branch BRANCHES_OVERRIDE ("main pr-...")
    # is rejected as "Invalid environment block".
    EXTRA_ENV=()
    for var in FRONTIERS TIMEOUT TARGETS NUMPATHS SEED BANDLO BANDHI TOL CAPTURE_PPROF; do
        [[ -n "${!var:-}" ]] && EXTRA_ENV+=( --setenv="$var=${!var}" )
    done
    sudo systemd-run --unit="$UNIT" --collect \
        -p MemoryMax="$MEMORY_MAX" \
        -p MemorySwapMax="$MEMORY_SWAP_MAX" \
        -p "User=$(id -un)" \
        -p "WorkingDirectory=$BENCH_DIR" \
        -p "StandardOutput=append:$OUT" \
        -p "StandardError=append:$OUT" \
        --setenv=HOME="$HOME" \
        --setenv=PATH="$PATH" \
        --setenv=RESULTS_DIR="$RESULTS_DIR" \
        --setenv=DATASET_OVERRIDE="$DATASET" \
        --setenv=BRANCHES_OVERRIDE="$BRANCHES" \
        --setenv=RUN_TAG="$RUN_TAG" \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$BENCH_DIR/scripts/run-kshortest-all.sh"
    echo "[launch] '$BRANCHES' started as unit $UNIT (MemoryMax=$MEMORY_MAX MemorySwapMax=$MEMORY_SWAP_MAX)"
    echo "[launch] unit:    systemctl status $UNIT  |  journalctl -u $UNIT -f"
else
    echo "[launch] WARN: systemd-run/sudo unavailable -- falling back to nohup (NO memory cap;" >&2
    echo "[launch] WARN: a runaway query can exhaust RAM -- see dgraph-bench-rca)" >&2
    nohup env RESULTS_DIR="$RESULTS_DIR" DATASET_OVERRIDE="$DATASET" BRANCHES_OVERRIDE="$BRANCHES" \
        RUN_TAG="$RUN_TAG" \
        ./scripts/run-kshortest-all.sh > "$OUT" 2>&1 &
    disown
    echo "[launch] '$BRANCHES' started (pid $!)"
fi
echo "[launch] run tag: $RUN_TAG"
echo "[launch] watch:   tail -f $OUT"
echo "[launch]          (or: tail -f $BENCH_DIR/results/sweep-$LABEL-latest.out)"
echo "[launch] memlog:  $RESULTS_DIR/logs/memlog-$RUN_TAG.log"
for b in $BRANCHES; do
    echo "[launch] status:  jq '.frontiers|length' $RESULTS_DIR/kshortest/$b-$DATASET-$RUN_TAG.json"
done
