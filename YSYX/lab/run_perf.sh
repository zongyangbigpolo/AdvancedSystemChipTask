#!/usr/bin/env bash
# Phase 4: derive instruction mix, CPI and branch-taken ratio from the executed difftest programs.
set -euo pipefail
cd "$(dirname "$0")"
test -d build || { echo "run run_core.sh first (needs build/*.hex and results/*.ref.trace)"; exit 1; }
echo "== performance report (single-cycle RV32E, reference-model trace)"
python3 tools/perf.py report \
  sum:build/sum.hex:results/sum.ref.trace \
  fib:build/fib.hex:results/fib.ref.trace \
  sort:build/sort.hex:results/sort.ref.trace \
  branch_edge:build/branch_edge.hex:results/branch_edge.ref.trace \
  random_s1:build/random_s1.hex:results/random_s1.ref.trace \
  random_s2:build/random_s2.hex:results/random_s2.ref.trace \
  random_s3:build/random_s3.hex:results/random_s3.ref.trace | tee results/perf.log
