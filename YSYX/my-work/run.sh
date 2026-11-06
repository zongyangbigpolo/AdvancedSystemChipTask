#!/usr/bin/env bash
# Build ysyx_lab_core with Icarus Verilog and Verilator, run every program, and difftest against the Python reference model.
set -euo pipefail
cd "$(dirname "$0")"
OUT=results
BUILD=build
mkdir -p "$OUT" "$BUILD"
PY=python3

echo "== tool versions"
iverilog -V 2>&1 | sed -n 1p || true
verilator --version
$PY --version

echo "== verilator lint (-Wall)"
verilator --lint-only -Wall -Wno-UNUSEDSIGNAL rtl/ysyx_lab_core.v --top-module ysyx_lab_core && echo "LINT PASS"

echo "== build simulators"
iverilog -g2012 -o "$BUILD/sim_iv" rtl/ysyx_lab_core.v sim/tb.v
iverilog -g2012 -DINJECT_SRA_BUG -o "$BUILD/sim_iv_bug" rtl/ysyx_lab_core.v sim/tb.v
verilator --binary --timing -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --top-module tb \
  -Mdir "$BUILD/vl" -o sim_vl rtl/ysyx_lab_core.v sim/tb.v >"$BUILD/verilator-build.log" 2>&1
echo "BUILD PASS (iverilog, iverilog+bug, verilator)"

for seed in 1 2 3; do
  $PY tools/rvlab.py random "$BUILD/random_s$seed.S" --seed "$seed" --count 400
done

programs=(tests/sum.S tests/fib.S tests/sort.S tests/branch_edge.S tests/illegal_x16.S \
          "$BUILD/random_s1.S" "$BUILD/random_s2.S" "$BUILD/random_s3.S")
fail=0
printf '\n%-16s %-8s %-36s %-36s %s\n' PROGRAM WORDS ICARUS VERILATOR DIFFTEST
for src in "${programs[@]}"; do
  name=$(basename "$src" .S)
  words=$($PY tools/rvlab.py asm "$src" "$BUILD/$name.hex" | awk '{print $2}')
  $PY tools/rvlab.py ref "$BUILD/$name.hex" "$OUT/$name.ref.trace" >/dev/null
  iv=$(vvp -n "$BUILD/sim_iv" +HEX="$BUILD/$name.hex" +TRACE="$OUT/$name.iv.trace" | grep RESULT)
  vl=$("$BUILD/vl/sim_vl" +HEX="$BUILD/$name.hex" +TRACE="$OUT/$name.vl.trace" | grep RESULT)
  if $PY tools/rvlab.py diff "$OUT/$name.ref.trace" "$OUT/$name.iv.trace" >/dev/null &&
     $PY tools/rvlab.py diff "$OUT/$name.ref.trace" "$OUT/$name.vl.trace" >/dev/null; then
    verdict="PASS ($(($(wc -l <"$OUT/$name.ref.trace") - 1)) commits)"
  else
    verdict=FAIL; fail=1
  fi
  printf '%-16s %-8s %-36s %-36s %s\n' "$name" "$words" "${iv#RESULT }" "${vl#RESULT }" "$verdict"
done

echo
echo "== fault injection: SRA implemented as SRL (-DINJECT_SRA_BUG)"
caught=0
for seed in 1 2 3; do
  name=random_s$seed
  vvp -n "$BUILD/sim_iv_bug" +HEX="$BUILD/$name.hex" +TRACE="$OUT/$name.bug.trace" >/dev/null
  if ! $PY tools/rvlab.py diff "$OUT/$name.ref.trace" "$OUT/$name.bug.trace" >"$OUT/$name.bug.diff"; then
    caught=$((caught + 1))
    echo "[$name]"; cat "$OUT/$name.bug.diff"
  fi
done
echo "injected bug detected in $caught/3 random programs"

[ "$fail" -eq 0 ] && echo "ALL DIFFTESTS PASS" || { echo "SOME DIFFTESTS FAILED"; exit 1; }
