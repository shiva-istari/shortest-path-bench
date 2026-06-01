#!/usr/bin/env bash
# setup.sh -- bootstrap a benchmark VM from "git clone" to "ready to run probe.sh"
#
# Idempotent: re-running is safe. Each step checks whether its output exists
# and skips if so. To force a step to redo work, delete its output (or pass
# the FORCE_* env vars documented below).
#
# What this does, in order:
#   1. Verify required system tools (or print apt-get/brew suggestions).
#   2. Install Go (default 1.26.3, matches go.mod) to /usr/local/go if missing.
#   3. Clone the dgraph repo if missing, build the dgraph binary from the
#      default branch (so probe.sh has something to start with -- per-PR
#      builds are done by probe.sh / benchmark.sh themselves).
#   4. Ensure each requested dataset is extracted under datasets/<name>/.
#      Tries, in order: already-extracted dir, local tarball at $BENCH_DIR,
#      DATASET_URL_<NAME> env var via scripts/download-ldbc.sh.
#   5. For each dataset, run `cmd/convert` to produce graph.rdf.gz + graph.schema.
#   6. For each dataset, run `dgraph bulk` (against a Zero this script manages)
#      to produce the cached p/ at $BENCH_DIR/datasets/<name>/dgraph/bulk-out/0/p
#
# After this script exits cleanly, you can run:
#   ./scripts/probe.sh
#
# Env vars (with defaults):
#   BENCH_DIR=$PWD                         (must be this repo's root)
#   DGRAPH_REPO=$HOME/dgraph               (cloned/used as-is if present)
#   DGRAPH_REMOTE=https://github.com/dgraph-io/dgraph.git
#   DGRAPH_BUILD_BRANCH=main               (which branch to build initially)
#   ALPHA_DIR=$HOME/db                     (where bulk-load workspace lives)
#   GO_VERSION=1.26.3
#   GO_INSTALL_DIR=/usr/local/go
#   DATASETS="kgs datagen-7_5-fb"
#   DATASET_URL_<NAME>=...                 (URL for tarball if dataset missing)
#   FORCE_BULK=0                           (set to 1 to redo bulk-load)
#   ZERO_HTTP=http://localhost:6080        (Zero state endpoint)
#
# Sudo: needed only to install Go into /usr/local/go and tools via apt-get/brew.
# Skip with INSTALL_GO=0 if Go is already in PATH at a satisfactory version.

set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================
BENCH_DIR="${BENCH_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DGRAPH_REPO="${DGRAPH_REPO:-$HOME/dgraph}"
DGRAPH_REMOTE="${DGRAPH_REMOTE:-https://github.com/dgraph-io/dgraph.git}"
DGRAPH_BUILD_BRANCH="${DGRAPH_BUILD_BRANCH:-main}"
ALPHA_DIR="${ALPHA_DIR:-$HOME/db}"
GO_VERSION="${GO_VERSION:-1.26.3}"
GO_INSTALL_DIR="${GO_INSTALL_DIR:-/usr/local/go}"
DATASETS_STR="${DATASETS:-kgs datagen-7_5-fb}"
read -ra DATASETS <<< "$DATASETS_STR"
FORCE_BULK="${FORCE_BULK:-0}"
INSTALL_GO="${INSTALL_GO:-1}"
ZERO_HTTP="${ZERO_HTTP:-http://localhost:6080}"

LOG_DIR="$BENCH_DIR/results/setup-logs"
mkdir -p "$LOG_DIR" "$ALPHA_DIR"

# ============================================================================
# Helpers
# ============================================================================
ts()  { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] ERROR: $*" >&2; exit 1; }
warn(){ echo "[$(ts)] WARN: $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)   GO_ARCH=amd64 ;;
    aarch64|arm64)  GO_ARCH=arm64 ;;
    *) die "unsupported architecture: $ARCH" ;;
esac
case "$OS" in
    Linux)  GO_OS=linux ;;
    Darwin) GO_OS=darwin ;;
    *) die "unsupported OS: $OS (only Linux and macOS supported)" ;;
esac

needs_sudo() {
    if [[ $EUID -eq 0 ]]; then
        eval "$@"
    elif have sudo; then
        sudo "$@"
    else
        die "command needs root and 'sudo' isn't on PATH: $*"
    fi
}

# Suggest a package-install command for a missing tool, OS-aware.
suggest_install() {
    local tool="$1"
    if [[ "$GO_OS" == "linux" ]]; then
        if have apt-get; then echo "sudo apt-get install -y $tool"
        elif have yum;     then echo "sudo yum install -y $tool"
        elif have apk;     then echo "sudo apk add $tool"
        else echo "(install $tool with your package manager)"
        fi
    else
        echo "brew install $tool"
    fi
}

# Confirm a version comparison: returns 0 if $1 >= $2, both in N.N.N form.
version_ge() {
    [[ "$1" == "$2" ]] && return 0
    local IFS=.
    read -ra A <<< "$1"; read -ra B <<< "$2"
    for ((i=0; i<${#B[@]}; i++)); do
        local a="${A[i]:-0}" b="${B[i]:-0}"
        if   (( a > b )); then return 0
        elif (( a < b )); then return 1
        fi
    done
    return 0
}

# ============================================================================
# Step 1: required tools
# ============================================================================
log "================================================================="
log " setup.sh  --  bootstrap shortest-path benchmark VM"
log "================================================================="
log "config:"
log "  BENCH_DIR           = $BENCH_DIR"
log "  DGRAPH_REPO         = $DGRAPH_REPO"
log "  DGRAPH_REMOTE       = $DGRAPH_REMOTE"
log "  DGRAPH_BUILD_BRANCH = $DGRAPH_BUILD_BRANCH"
log "  ALPHA_DIR           = $ALPHA_DIR"
log "  GO_VERSION (target) = $GO_VERSION"
log "  GO_INSTALL_DIR      = $GO_INSTALL_DIR"
log "  DATASETS            = ${DATASETS[*]}"
log "  OS / ARCH           = $GO_OS / $GO_ARCH"

log ""
log "[1/6] verifying system tools..."
missing=()
for tool in curl tar gzip git make awk grep sed jq zstd; do
    if ! have "$tool"; then missing+=("$tool"); fi
done

if (( ${#missing[@]} > 0 )); then
    log "  missing: ${missing[*]}"
    log "  install suggestions (you may need to run these manually):"
    for t in "${missing[@]}"; do
        log "    $(suggest_install "$t")"
    done
    die "install the missing tools above and re-run"
fi
log "  all tools present"

# ============================================================================
# Step 2: Go
# ============================================================================
log ""
log "[2/6] checking Go..."

go_installed_version=""
if have go; then
    go_installed_version=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
fi

if [[ -n "$go_installed_version" ]] && version_ge "$go_installed_version" "$GO_VERSION"; then
    log "  go $go_installed_version present (>= $GO_VERSION required), skipping install"
elif [[ "$INSTALL_GO" != "1" ]]; then
    die "go missing or too old ($go_installed_version); INSTALL_GO=0 so refusing to install. Install go >= $GO_VERSION manually."
else
    log "  go missing or too old (have='$go_installed_version', need='>=$GO_VERSION'); installing"
    go_tarball="go${GO_VERSION}.${GO_OS}-${GO_ARCH}.tar.gz"
    go_url="https://go.dev/dl/${go_tarball}"
    dl_path="/tmp/$go_tarball"
    if [[ ! -f "$dl_path" ]]; then
        log "  downloading $go_url"
        curl -L --fail --connect-timeout 30 -o "$dl_path" "$go_url" \
            || die "failed to download Go from $go_url"
    else
        log "  reusing $dl_path"
    fi
    log "  removing any existing $GO_INSTALL_DIR and extracting"
    needs_sudo rm -rf "$GO_INSTALL_DIR"
    needs_sudo tar -C "$(dirname "$GO_INSTALL_DIR")" -xzf "$dl_path"
    # Add Go to PATH for this shell so subsequent steps work without re-source.
    export PATH="$GO_INSTALL_DIR/bin:$PATH"
    if [[ ! -f /etc/profile.d/go.sh ]] && [[ -d /etc/profile.d ]]; then
        needs_sudo tee /etc/profile.d/go.sh >/dev/null <<EOF
export PATH="$GO_INSTALL_DIR/bin:\$PATH"
EOF
        log "  wrote /etc/profile.d/go.sh (login shells will pick up Go)"
    fi
    log "  installed: $(go version)"
fi

# Ensure GOPATH/bin (where 'dgraph' lands after 'make install') is on PATH.
GOPATH_BIN="$(go env GOPATH)/bin"
case ":$PATH:" in
    *":$GOPATH_BIN:"*) ;;
    *) export PATH="$GOPATH_BIN:$PATH" ;;
esac
log "  GOPATH/bin = $GOPATH_BIN  (added to PATH for this script)"

# ============================================================================
# Step 3: dgraph repo + initial build
# ============================================================================
log ""
log "[3/6] dgraph repo + initial build..."

if [[ ! -d "$DGRAPH_REPO/.git" ]]; then
    log "  cloning $DGRAPH_REMOTE -> $DGRAPH_REPO"
    git clone "$DGRAPH_REMOTE" "$DGRAPH_REPO" 2>&1 | tee "$LOG_DIR/dgraph-clone.log" >/dev/null
else
    log "  dgraph repo present at $DGRAPH_REPO"
fi

( cd "$DGRAPH_REPO"
  git fetch origin 2>&1 | tee "$LOG_DIR/dgraph-fetch.log" >/dev/null || true
  if ! git diff --quiet || ! git diff --cached --quiet; then
      die "dgraph working tree is dirty -- commit/stash before running setup again"
  fi
  if ! git rev-parse --verify --quiet "$DGRAPH_BUILD_BRANCH" >/dev/null; then
      die "branch '$DGRAPH_BUILD_BRANCH' not found in $DGRAPH_REPO (try git fetch origin)"
  fi
  log "  checking out $DGRAPH_BUILD_BRANCH"
  git checkout "$DGRAPH_BUILD_BRANCH" 2>&1 | tee -a "$LOG_DIR/dgraph-build.log" >/dev/null
)

if have dgraph; then
    log "  dgraph already on PATH: $(dgraph version 2>&1 | head -3 | tr '\n' ' ')"
else
    log "  no dgraph on PATH yet; running 'make install' in $DGRAPH_REPO"
fi
( cd "$DGRAPH_REPO" && make install ) 2>&1 | tee -a "$LOG_DIR/dgraph-build.log" >/dev/null \
    || die "dgraph 'make install' failed -- see $LOG_DIR/dgraph-build.log"
log "  dgraph build OK: $(dgraph version 2>/dev/null | awk '/^Branch/ {print $0; exit}')"

# ============================================================================
# Step 4: datasets
# ============================================================================
log ""
log "[4/6] ensuring datasets are extracted..."

extract_local_tarball() {
    local ds="$1"
    local tarball
    for cand in "$BENCH_DIR/$ds.tar.zst" "$BENCH_DIR/$ds.tar.gz" "$BENCH_DIR/datasets/$ds.tar.zst"; do
        if [[ -f "$cand" ]]; then tarball="$cand"; break; fi
    done
    [[ -n "${tarball:-}" ]] || return 1
    log "    found local tarball $tarball, extracting"
    mkdir -p "$BENCH_DIR/datasets"
    ( cd "$BENCH_DIR/datasets" && tar --zstd -xf "$tarball" ) 2>"$LOG_DIR/extract-$ds.log" \
        || ( cd "$BENCH_DIR/datasets" && tar -xzf "$tarball" ) 2>>"$LOG_DIR/extract-$ds.log"
    return 0
}

for ds in "${DATASETS[@]}"; do
    ds_dir="$BENCH_DIR/datasets/$ds"
    if [[ -d "$ds_dir" && -f "$ds_dir/$ds.properties" ]]; then
        log "  $ds: already extracted at $ds_dir"
        continue
    fi
    log "  $ds: not extracted -- attempting recovery"
    if extract_local_tarball "$ds"; then
        if [[ -f "$ds_dir/$ds.properties" ]]; then
            log "  $ds: extracted from local tarball"
            continue
        fi
    fi
    url_var="DATASET_URL_$(printf '%s' "$ds" | tr '[:lower:]-.' '[:upper:]__')"
    if [[ -n "${!url_var:-}" ]]; then
        log "  $ds: downloading from \$$url_var = ${!url_var}"
        "$BENCH_DIR/scripts/download-ldbc.sh" "${!url_var}" 2>&1 | tee "$LOG_DIR/download-$ds.log"
    fi
    if [[ ! -f "$ds_dir/$ds.properties" ]]; then
        die "dataset '$ds' not available. Either: (a) place ${ds}.tar.zst in $BENCH_DIR, (b) extract it manually to $ds_dir, or (c) set $url_var=<dataset-url> and re-run"
    fi
done
log "  all datasets present"

# ============================================================================
# Step 5: cmd/convert per dataset (LDBC -> RDF + schema)
# ============================================================================
log ""
log "[5/6] running cmd/convert per dataset..."

for ds in "${DATASETS[@]}"; do
    rdf="$BENCH_DIR/datasets/$ds/dgraph/graph.rdf.gz"
    schema="$BENCH_DIR/datasets/$ds/dgraph/graph.schema"
    if [[ -f "$rdf" && -f "$schema" ]]; then
        log "  $ds: graph.rdf.gz + graph.schema already present (skip convert)"
        continue
    fi
    log "  $ds: running convert -> $BENCH_DIR/datasets/$ds/dgraph/"
    ( cd "$BENCH_DIR" && go run ./cmd/convert -dataset "./datasets/$ds" ) \
        2>&1 | tee "$LOG_DIR/convert-$ds.log"
    [[ -f "$rdf" && -f "$schema" ]] || die "convert did not produce $rdf and/or $schema"
done

# ============================================================================
# Step 6: bulk-load per dataset (produces cached p/)
# ============================================================================
log ""
log "[6/6] bulk-loading datasets (produces cached p/ used by probe.sh)..."

# We manage Zero just for the duration of this step.
ZERO_PID=""
ZERO_DIR="$ALPHA_DIR/zero-setup"
started_zero=0

ensure_zero() {
    if curl -s -m 3 "$ZERO_HTTP/state" >/dev/null 2>&1; then
        log "  using existing Zero at $ZERO_HTTP"
        return 0
    fi
    log "  starting temporary Zero at $ZERO_HTTP (for bulk-load only)"
    mkdir -p "$ZERO_DIR"
    ( cd "$ZERO_DIR"
      nohup dgraph zero --my=localhost:5080 --replicas=1 \
          > "$LOG_DIR/zero-setup.log" 2>&1 &
      echo $! > /tmp/dgraph-zero-setup.pid
    )
    ZERO_PID=$(cat /tmp/dgraph-zero-setup.pid)
    started_zero=1
    for _ in $(seq 1 60); do
        if curl -s -m 3 "$ZERO_HTTP/state" >/dev/null 2>&1; then
            log "  zero healthy (pid=$ZERO_PID)"
            return 0
        fi
        sleep 1
    done
    die "Zero did not become healthy within 60s -- see $LOG_DIR/zero-setup.log"
}

stop_zero_if_started() {
    if (( started_zero == 1 )) && [[ -n "$ZERO_PID" ]] && kill -0 "$ZERO_PID" 2>/dev/null; then
        log "  stopping temporary Zero (pid=$ZERO_PID)"
        kill "$ZERO_PID" 2>/dev/null || true
        for _ in $(seq 1 30); do
            kill -0 "$ZERO_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$ZERO_PID" 2>/dev/null || true
        rm -f /tmp/dgraph-zero-setup.pid
    fi
}
trap stop_zero_if_started EXIT

needs_bulk=0
for ds in "${DATASETS[@]}"; do
    p_dir="$BENCH_DIR/datasets/$ds/dgraph/bulk-out/0/p"
    if [[ -d "$p_dir" && "$FORCE_BULK" != "1" ]]; then
        log "  $ds: bulk-loaded p/ already present at $p_dir (skip; set FORCE_BULK=1 to redo)"
    else
        needs_bulk=1
    fi
done

if (( needs_bulk == 1 )); then
    ensure_zero
    for ds in "${DATASETS[@]}"; do
        p_dir="$BENCH_DIR/datasets/$ds/dgraph/bulk-out/0/p"
        if [[ -d "$p_dir" && "$FORCE_BULK" != "1" ]]; then
            continue
        fi
        out_dir="$BENCH_DIR/datasets/$ds/dgraph/bulk-out"
        rdf="$BENCH_DIR/datasets/$ds/dgraph/graph.rdf.gz"
        schema="$BENCH_DIR/datasets/$ds/dgraph/graph.schema"
        [[ -f "$rdf" ]]    || die "$ds: missing $rdf (step 5 should have produced this)"
        [[ -f "$schema" ]] || die "$ds: missing $schema (step 5 should have produced this)"

        if [[ -d "$out_dir" && "$FORCE_BULK" == "1" ]]; then
            log "  $ds: FORCE_BULK=1, removing $out_dir"
            rm -rf "$out_dir"
        fi
        log "  $ds: running 'dgraph bulk' (this takes a while; tailing to $LOG_DIR/bulk-$ds.log)"
        ( cd "$BENCH_DIR/datasets/$ds/dgraph" \
            && dgraph bulk \
                  -f "$rdf" \
                  -s "$schema" \
                  --zero localhost:5080 \
                  --out bulk-out \
        ) 2>&1 | tee "$LOG_DIR/bulk-$ds.log" >/dev/null \
            || die "$ds: dgraph bulk failed -- see $LOG_DIR/bulk-$ds.log"
        [[ -d "$p_dir" ]] || die "$ds: bulk-load completed but $p_dir does not exist"
        log "  $ds: bulk-load done. p/ size: $(du -sh "$p_dir" | awk '{print $1}')"
    done
    stop_zero_if_started
fi

# ============================================================================
# Final report
# ============================================================================
log ""
log "================================================================="
log " setup complete"
log "================================================================="
log "datasets ready under $BENCH_DIR/datasets/:"
for ds in "${DATASETS[@]}"; do
    p_dir="$BENCH_DIR/datasets/$ds/dgraph/bulk-out/0/p"
    sz=$(du -sh "$p_dir" 2>/dev/null | awk '{print $1}')
    log "  $ds  -- p/ at $p_dir ($sz)"
done

cat <<EOF

NEXT STEPS:

  1. Start Zero (probe.sh and benchmark.sh expect it to be running):

       dgraph zero --my=localhost:5080 --replicas=1 &

     (or use docker-compose: 'docker compose up -d zero')

  2. Run the pre-flight probe:

       ./scripts/probe.sh

     This will, per branch in DGRAPH_REPO and per dataset, verify that the
     numpaths>=2 query actually returns. Only proceed to the full sweep if
     probe.sh exits 0.

  3. If probe.sh says all-green, run the full benchmark:

       ./scripts/run-pr-comparison.sh

ENV YOU MAY WANT TO EXPORT for probe.sh / run-pr-comparison.sh on this VM:

  export BENCH_DIR=$BENCH_DIR
  export DGRAPH_REPO=$DGRAPH_REPO
  export ALPHA_DIR=$ALPHA_DIR
  export ALPHA_DIR_PREFIX_ALLOW=$(dirname "$ALPHA_DIR")/

EOF
