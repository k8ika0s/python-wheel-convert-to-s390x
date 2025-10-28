#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# build-wheels.sh — s390x wheel validator + FULL dep-closure builder (v7.4)
#
# Fixes in v7.4:
#   * Correctly derives base package name from spec using packaging.Requirement
#     (no more rebuilding e.g. numpy when numpy wheels already exist)
#   * If a build produced no wheels but wheelhouse already has that base, log [have]
# =============================================================================

VALIDATED_DIR="${1:-/validated_wheels}"
LOG_DIR="${2:-/work/build_logs}"
mkdir -p "$VALIDATED_DIR" "$LOG_DIR"

# ---------- pretty logging ----------
ts()  { date -u +'%Y-%m-%d %H:%M:%S'; }
rule(){ printf '%*s\n' "${COLUMNS:-120}" '' | tr ' ' -; }
hdr() { echo; rule; echo "[$(ts)] $*"; rule; }
log() { echo "[$(ts)] $*"; }
warn(){ echo "[$(ts)] WARN:  $*"  | tee -a "$LOG_DIR/warnings.log"; }
err() { echo "[$(ts)] ERROR: $*"  | tee -a "$LOG_DIR/errors.log" 1>&2; }

PY_BIN="${PY_BIN:-/venv/bin/python3}"
PIP_BIN="${PIP_BIN:-/venv/bin/pip}"

normalize_name() {  # pip-style normalization
  "$PY_BIN" - "$1" <<'PY'
import re, sys
print(re.sub(r"[-_.]+","-",sys.argv[1]).lower())
PY
}

base_name_from_spec() { # uses packaging to extract the canonical project name
  "$PY_BIN" - "$1" <<'PY'
import sys
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
spec=sys.argv[1]
try:
    r=Requirement(spec)
    print(canonicalize_name(r.name))
except Exception:
    # fallback: take first token before any bracket/space/comparison
    import re
    name=re.split(r'[\s\[<>=!~;]', spec, 1)[0]
    print(canonicalize_name(name))
PY
}

already_have_any() { # base-name (normalized, versionless)
  local n="$1"
  shopt -s nullglob
  local m=( "$VALIDATED_DIR"/"${n//-/_}"-*.whl "$VALIDATED_DIR"/"$n"-*.whl )
  shopt -u nullglob
  (( ${#m[@]} > 0 ))
}

ensure_pytools() {
  . /venv/bin/activate
  "$PIP_BIN" install --upgrade pip setuptools wheel packaging >/dev/null
}

validate_wheel_no_deps() { # wheel_path
  local whl="$1" tmp; tmp="$(mktemp -d)"
  "$PIP_BIN" install --no-deps --target "$tmp" "$whl" >"$LOG_DIR/validate_$(basename "$whl").log" 2>&1
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

requires_from_wheel() { # prints one PEP 508 line per dep
  "$PY_BIN" - "$1" <<'PY'
import sys, zipfile, email
from packaging.requirements import Requirement
from packaging.markers import default_environment
env = default_environment()
wheel = sys.argv[1]
with zipfile.ZipFile(wheel, 'r') as zf:
    metas = [p for p in zf.namelist() if p.endswith('METADATA') and '.dist-info/' in p]
    if not metas:
        sys.exit(0)
    msg = email.message_from_bytes(zf.read(metas[0]))
    for line in msg.get_all('Requires-Dist', []):
        try:
            r = Requirement(line)
        except Exception:
            continue
        if r.marker and not r.marker.evaluate(env):
            continue
        print(str(r))
PY
}

# ---------------- Arrow C++ (once) for PyArrow ----------------
build_arrow_cpp_once() {
  local PREFIX="/usr/local"
  if [ -f "${PREFIX}/lib/libarrow.so" ]; then
    export CMAKE_PREFIX_PATH="${PREFIX}:${CMAKE_PREFIX_PATH:-}"
    export Arrow_DIR="${PREFIX}/lib/cmake/Arrow"
    log "Arrow C++ already present at ${PREFIX}"
    return 0
  fi
  hdr "BUILD: Arrow C++ (s390x) — required for PyArrow"
  local SRC="/tmp/arrow-src"
  [ -d "$SRC" ] || git clone https://github.com/apache/arrow.git "$SRC" >/dev/null
  pushd "$SRC/cpp" >/dev/null
  mkdir -p build_s390x && cd build_s390x
  log "CMake configure → $LOG_DIR/arrow_cmake.out"
  cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DARROW_S390X_ARCH=ON \
        -DARROW_DEPENDENCY_SOURCE=BUNDLED \
        -DARROW_BUILD_SHARED=ON \
        -DARROW_COMPUTE=ON \
        -DARROW_CSV=ON \
        -DARROW_DATASET=ON \
        -DARROW_PARQUET=ON \
        -DARROW_FILESYSTEM=ON \
        -DARROW_JSON=ON \
        .. >"$LOG_DIR/arrow_cmake.out" 2>&1 || { err "Arrow cmake failed"; return 1; }
  log "make -j$(nproc) → $LOG_DIR/arrow_make.out"
  make -j"$(nproc)" >"$LOG_DIR/arrow_make.out" 2>&1 || { err "Arrow make failed"; return 1; }
  log "make install → $LOG_DIR/arrow_install.out"
  make install >"$LOG_DIR/arrow_install.out" 2>&1 || { err "Arrow install failed"; return 1; }
  popd >/dev/null
  export CMAKE_PREFIX_PATH="${PREFIX}:${CMAKE_PREFIX_PATH:-}"
  export Arrow_DIR="${PREFIX}/lib/cmake/Arrow"
  log "Arrow C++ installed at ${PREFIX}"
}

# -------- Robust artifact detection helpers --------
_list_whl() { ls -1 "$VALIDATED_DIR"/*.whl 2>/dev/null || true; }

_detect_new_wheels() { # before_list_text -> prints new file paths (one per line)
  local before_text="$1" after neww
  after="$(_list_whl)"
  while IFS= read -r neww; do
    [[ -z "$neww" ]] && continue
    if ! grep -Fxq "$neww" <<<"$before_text"; then
      echo "$neww"
    fi
  done <<< "$after"
}

_parse_saved_from_log() { # log_path -> prints /path/to/*.whl parsed from "Saved ..." lines
  local logp="$1" line path
  while IFS= read -r line; do
    case "$line" in
      *"Saved "*".whl"*)
        path="${line##*Saved }"; path="${path%% *}"
        [[ -f "$path" ]] && echo "$path"
        ;;
    esac
  done < "$logp"
}

# Build a spec (PEP 508). Special-case pyarrow to use local Arrow C++.
build_spec_with_deps() {
  local spec="$1"
  local base_norm; base_norm="$(base_name_from_spec "$spec")"

  ensure_pytools

  # Snapshot wheelhouse BEFORE build
  local before_list; before_list="$(_list_whl)"

  local logname
  if [[ "$base_norm" == "pyarrow" ]]; then
    build_arrow_cpp_once || return 1
    export PYARROW_BUNDLE_ARROW_CPP=0
    export PYARROW_CMAKE_OPTIONS="${PYARROW_CMAKE_OPTIONS:-} -DCMAKE_FIND_DEBUG_MODE=OFF"
    hdr "BUILD: $spec (PyArrow) against local Arrow C++"
    logname="$LOG_DIR/pyarrow_build.log"
  else
    hdr "BUILD: $spec (source with deps)"
    logname="$LOG_DIR/build_$(echo "$base_norm" | tr -cd '[:alnum:]').log"
  fi

  log "Wheel dir: $VALIDATED_DIR  |  Log: $logname"
  if ! "$PIP_BIN" wheel --wheel-dir "$VALIDATED_DIR" --no-binary=:all: "$spec" \
       >"$logname" 2>&1; then
    err "Build failed: $spec"
    return 1
  fi

  # Detect new wheels (diff); fallback to parsing pip output
  local produced; produced="$(_detect_new_wheels "$before_list")"
  if [[ -z "$produced" ]]; then
    produced="$(_parse_saved_from_log "$logname")"
  fi

  if [[ -z "$produced" ]]; then
    if already_have_any "$base_norm"; then
      log "[have] No new wheels emitted for $base_norm; prior wheel(s) already present."
    else
      warn "Built $spec but did not detect new wheel(s) in $VALIDATED_DIR"
    fi
  else
    log "Produced wheel(s):"
    printf '  - %s\n' $produced || true
  fi
  return 0
}

# Collect full transitive dependency closure (BFS)
build_dependency_closure() { # starting_specs... (each is a full PEP 508 line)
  local -a queue=("$@")
  local -A seen=()
  local any_new=0

  hdr "PHASE 3b: TRANSITIVE DEPENDENCIES (closure walk)"
  log "Seeded specs:"; printf '  - %s\n' "${queue[@]}" || true
  rule

  while ((${#queue[@]})); do
    local spec="${queue[0]}"; queue=("${queue[@]:1}")
    [[ -z "$spec" ]] && continue
    local base_norm; base_norm="$(base_name_from_spec "$spec")"

    if [[ -n "${seen[$base_norm]:-}" ]]; then
      log "[skip] already processed: $spec"
      continue
    fi
    seen["$base_norm"]=1

    if already_have_any "$base_norm"; then
      log "[have] wheel exists for: $base_norm"
      continue
    fi

    # Snapshot BEFORE this build for precise diff
    local before; before="$(_list_whl)"

    if build_spec_with_deps "$spec"; then
      any_new=1

      # Produced wheels from this step
      local produced; produced="$(_detect_new_wheels "$before")"
      if [[ -z "$produced" ]]; then
        if already_have_any "$base_norm"; then
          log "[have] $base_norm present after build."
        else
          # Best-effort fallback: guess by basename
          shopt -s nullglob
          local guess=( "$VALIDATED_DIR"/"$base_norm"-*.whl "$VALIDATED_DIR"/"${base_norm//-/_}"-*.whl )
          shopt -u nullglob
          if (( ${#guess[@]} )); then
            produced="$(printf '%s\n' "${guess[@]}")"
            log "Produced (fallback guess):"; printf '    - %s\n' "${guess[@]}"
          else
            warn "Built $spec but could not determine produced wheel(s)"
          fi
        fi
      else
        log "Produced:"; printf '    - %s\n' $produced || true
      fi

      # Enqueue deps from produced wheels (line-by-line, marker-safe)
      local w
      while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        local reqs; reqs="$(requires_from_wheel "$w" || true)"
        if [[ -n "$reqs" ]]; then
          log "deps($(basename "$w")):"
          printf '%s\n' "$reqs" | sed 's/^/    - /'
          local r b
          while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            b="$(base_name_from_spec "$r")"
            [[ -z "${seen[$b]:-}" ]] && queue+=("$r")
          done <<< "$reqs"
        else
          log "deps($(basename "$w")): (none)"
        fi
      done <<< "$produced"

    else
      warn "Continuing after failed build of: $spec"
    fi
    rule
  done

  return $any_new
}

process_one_wheel() { # /work/foo.whl
  local whl="$1"

  hdr "PHASE 2: STRUCTURAL VALIDATION → $(basename "$whl")"
  log "Install test (no-deps)… log: $LOG_DIR/validate_$(basename "$whl").log"
  if validate_wheel_no_deps "$whl"; then
    cp -f "$whl" "$VALIDATED_DIR"/ || warn "copy failed: $whl"
    log "✔ Valid → copied to $VALIDATED_DIR"
  else
    warn "Validation failed — will still analyze deps from METADATA"
  fi
  rule

  hdr "PHASE 3: DEPENDENCY RESOLUTION (direct)"
  local reqs; reqs="$(requires_from_wheel "$whl" || true)"
  if [[ -z "$reqs" ]]; then
    log "No Requires-Dist found."
    return 0
  fi
  log "Declared dependencies:"; printf '%s\n' "$reqs" | sed 's/^/  - /'
  rule

  # feed the closure as proper lines (not words)
  mapfile -t _seed < <(printf '%s\n' "$reqs")
  build_dependency_closure "${_seed[@]}" || true
}

main() {
  . /venv/bin/activate

  hdr "ENV CHECK"
  PY_STR="$("$PY_BIN" -c 'import sys; print(sys.version.replace("\n"," "))' 2>/dev/null || true)"
  PIP_STR="$("$PY_BIN" -m pip --version 2>/dev/null || true)"
  log "Python: ${PY_STR}"
  log "pip:    ${PIP_STR}"
  rule

  ensure_pytools

  hdr "PHASE 1: DISCOVERY"
  shopt -s nullglob
  local WHEELS=( *.whl )
  shopt -u nullglob
  if (( ${#WHEELS[@]} == 0 )); then
    log "No *.whl files found in $(pwd)"
    exit 0
  fi
  log "Found ${#WHEELS[@]} wheel(s):"; printf '  - %s\n' "${WHEELS[@]}"
  rule

  local failed=0
  local whl
  for whl in "${WHEELS[@]}"; do
    log ">>> Processing: $(basename "$whl")"
    process_one_wheel "$whl" || failed=$((failed+1))
  done

  hdr "PHASE 4: SUMMARY"
  log "Validated wheels directory ($VALIDATED_DIR):"
  ls -lh "$VALIDATED_DIR" || true
  rule
  local count; count=$(ls -1 "$VALIDATED_DIR"/*.whl 2>/dev/null | wc -l || true)
  log "Total wheels present: $count"
  if (( failed > 0 )); then
    warn "Completed with $failed failure(s). See logs in: $LOG_DIR"
    exit 1
  fi
  log "Completed successfully. Logs: $LOG_DIR"
}

main "$@"