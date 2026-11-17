#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Runs upstream's unit tests listed in mayhem/tests.txt (the "deterministic-tests" set from
# test/Jamfile), built by mayhem/build.sh into cmake-build-tests/test with the project's normal flags.
# Each program is upstream's own runner (test/main.cpp): it executes every TORRENT_TEST case, checks
# the TEST_CHECK/TEST_EQUAL assertions, and ends with one summary line per case —
#   "[<case>] ***PASS***"   or   "[<case>] <n> FAILURES"
# CTRF counts are those per-case lines. A program that dies, or prints no summary, counts as a failure.
TESTDIR="$SRC/cmake-build-tests/test"
LIST="$SRC/mayhem/tests.txt"
: "${TEST_TIMEOUT:=900}"     # per test program, seconds (a hung program is a failure, not a stall)

if [ ! -d "$TESTDIR" ]; then
  echo "missing $TESTDIR — mayhem/build.sh must build the test suite first" >&2
  emit_ctrf "libtorrent-unit-tests" 0 1 0; exit 1
fi

passed=0; failed=0
log="$(mktemp)"; trap 'rm -f "$log"' EXIT
cd "$TESTDIR"
for t in $(grep -v '^#' "$LIST"); do
  if [ ! -x "./$t" ]; then
    echo "MISSING test program: $t (build.sh should have built it)"; failed=$((failed + 1)); continue
  fi
  # Upstream's disk_cache::kick_hasher (pread_disk_io thread) has a data race that SIGSEGVs the
  # session-based programs (test_torrent, test_resume) in 1 of 3 runs or more, before the runner prints its
  # summary. A death by signal with no summary is retried; an assertion failure, a clean exit without
  # PASS lines or a program that keeps crashing still fails, so a neutered/broken build cannot pass.
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    # -n: no output redirection, so the per-case summary and any failure text reach this log
    timeout -k 10 "$TEST_TIMEOUT" "./$t" -n >"$log" 2>&1; rc=$?
    p=$(grep -c '\*\*\*PASS\*\*\*' "$log"); f=$(grep -cE '\] [0-9]+ FAILURES' "$log")
    if [ $((p + f)) -eq 0 ] && [ "$rc" -gt 128 ] && [ "$rc" -ne 137 ] && [ "$attempt" -lt 10 ]; then
      echo "retry $t: killed by signal $((rc - 128)) before its summary (attempt $attempt)"; rm -rf "$TESTDIR"/test_tmp_* 2>/dev/null; continue
    fi
    break
  done
  if [ $((p + f)) -eq 0 ]; then
    echo "FAIL $t: no test summary (exit $rc)"; tail -15 "$log"; f=1
  elif [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
    echo "FAIL $t: exit $rc with no failing case reported"; tail -15 "$log"; f=1
  elif [ "$f" -gt 0 ]; then
    echo "FAIL $t: $f failing case(s), $p passing"; grep -aE 'TEST_ERROR|FAILURES' "$log" | head -20
  else
    echo "ok   $t: $p case(s)"
  fi
  passed=$((passed + p)); failed=$((failed + f))
  rm -rf "$TESTDIR"/test_tmp_* 2>/dev/null
done
cd "$SRC"

emit_ctrf "libtorrent-unit-tests" "$passed" "$failed"
