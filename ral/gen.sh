#!/usr/bin/env bash
# Generate the UVM RAL package and HTML register docs from ral/sa_gemm_csr.rdl.
# Needs the PeakRDL venv:  source ~/.venvs/eda/bin/activate
set -euo pipefail
cd "$(dirname "$0")"
command -v peakrdl >/dev/null || { echo "peakrdl not found - run: source ~/.venvs/eda/bin/activate" >&2; exit 1; }

mkdir -p ../tb/ral ../docs/regs
peakrdl uvm  sa_gemm_csr.rdl -o ../tb/ral/sa_gemm_csr_ral_pkg.sv
peakrdl html sa_gemm_csr.rdl -o ../docs/regs
echo "generated: tb/ral/sa_gemm_csr_ral_pkg.sv, docs/regs/index.html"
