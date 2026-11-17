#!/usr/bin/env bash
#
# mayhem/build.sh — build libtorrent's fuzzers (fuzz + standalone) and its unit-test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Coverage instrumentation for the LIBRARY (upstream's fuzzers/Jamfile compiles everything with
# -fsanitize=fuzzer; the no-link form instruments without pulling the engine's main() into the lib).
: "${FUZZ_COVERAGE_FLAGS=-fsanitize=fuzzer-no-link}"
FUZZERS="$(tr '\n' ';' < "$SRC/mayhem/fuzzers.txt" | sed 's/;$//')"

# The defines upstream's fuzzers/Jamfile builds with (asserts + debug iterators on, internal symbols
# exported, harness logging off); asserts/invariant state comes from the CMake options below.
FUZZ_DEFS="-D_GLIBCXX_DEBUG -D_GLIBCXX_DEBUG_PEDANTIC -DTORRENT_EXPORT_EXTRA -DTORRENT_USE_IPV6=1 -D_SCL_SECURE=1 -DDEBUG_LOGGING=0"
FUZZ_FLAGS="$SANITIZER_FLAGS $FUZZ_COVERAGE_FLAGS -fno-omit-frame-pointer $DEBUG_FLAGS"
# The only C in the build is the vendored WebTorrent stack (deps/libdatachannel: libjuice, usrsctp).
# libjuice's picohash.h calls its hash callbacks through a pointer of a different function type
# (picohash.h:680), which UBSan's `function` check halts on during every ICE setup — the
# rtc_peer_conn harness died on its first inputs. Relax exactly that one check, for the C deps only:
# libtorrent itself (all C++) keeps the full ASan+UBSan set, halting.
FUZZ_C_RELAX=""
case "$SANITIZER_FLAGS" in *undefined*) FUZZ_C_RELAX="-fno-sanitize=function" ;; esac

# libjuice (the ICE agent under libdatachannel) follows RFC 8445 and never offers loopback host
# candidates. The Mayhem sandbox has no network interface but `lo`, so the rtc_peer_conn harness's
# in-process WebRTC pair gathered zero candidates and every input sat out its 10 s setup wait — the
# target executed nothing. libjuice's own test option ENABLE_LOCALHOST_ADDRESS (fuzz build only)
# lists 127.0.0.1/::1 as host candidates, so the two peers connect over loopback.
# 1+2) libtorrent (WebTorrent on, as OSS-Fuzz builds it) with sanitizers + coverage, and every
#      harness in fuzzers/src linked twice: <name> (libFuzzer) and <name>-standalone (run-once driver).
#      One shared, instrumented libtorrent serves all of them (see mayhem/fuzz/CMakeLists.txt for why
#      not static); the binaries find it by RPATH in cmake-build-fuzz/libtorrent.
#      Build dirs are named cmake-build-* because upstream's .gitignore covers that pattern.
cmake -S "$SRC/mayhem/fuzz" -B "$SRC/cmake-build-fuzz" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS $FUZZ_C_RELAX" \
  -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS $FUZZ_DEFS" \
  -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
  -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" \
  -DCMAKE_EXE_LINKER_FLAGS="$FUZZ_FLAGS" \
  -DBUILD_SHARED_LIBS=ON \
  -Dwebtorrent=ON -Ddeprecated-functions=ON \
  -Ddeveloper-options=ON -Dasserts=on \
  -DENABLE_LOCALHOST_ADDRESS=ON \
  -DMAYHEM_OUT="$SRC" \
  -DMAYHEM_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
  -DMAYHEM_STANDALONE_MAIN="$STANDALONE_FUZZ_MAIN" \
  -DMAYHEM_LSAN_OFF="$SRC/mayhem/lsan_off.cc" \
  -DMAYHEM_FUZZERS="$FUZZERS"
cmake --build "$SRC/cmake-build-fuzz" -j"$MAYHEM_JOBS"

# 3) The project's own unit tests with its NORMAL flags (upstream CMake defaults: shared library,
#    Release), independent of the sanitized build. Only the suite mayhem/tests.txt lists is built —
#    upstream's "deterministic-tests" (test/Jamfile) that run without external servers.
cmake -S "$SRC" -B "$SRC/cmake-build-tests" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -Dbuild_tests=ON
# shellcheck disable=SC2046
cmake --build "$SRC/cmake-build-tests" -j"$MAYHEM_JOBS" --target $(grep -v '^#' "$SRC/mayhem/tests.txt")

echo "build.sh: built $(wc -l < "$SRC/mayhem/fuzzers.txt") fuzzers (+ standalone) and $(grep -vc '^#' "$SRC/mayhem/tests.txt") test programs"
