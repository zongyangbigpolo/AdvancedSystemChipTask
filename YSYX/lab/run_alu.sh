#!/usr/bin/env bash
# Phase 1: build the ALU, generate reference vectors with Python, and verify with Icarus Verilog.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build results
echo "== tool versions"
iverilog -V 2>&1 | sed -n 1p || true
python3 --version
echo "== generate reference vectors"
python3 tools/perf.py vectors build/alu_vectors.txt --seed 1 --count 100000
echo "== build and run ALU testbench"
iverilog -g2012 -o build/alu_tb rtl/ysyx_alu.v sim/alu_tb.v
vvp -n build/alu_tb +VEC=build/alu_vectors.txt | tee results/alu.log
