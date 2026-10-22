// Compile list for the CSR block-level testbench. Paths are relative to sim/.
-incdir ../tb/axil
-incdir ../tb/env
-incdir ../tb/tests
-incdir ../tb/cov

../rtl/sa_csr.sv

../tb/ral/sa_gemm_csr_ral_pkg.sv
../tb/axil/axil_if.sv
../tb/env/csr_core_if.sv
../tb/axil/axil_pkg.sv
../tb/cov/sa_cov_pkg.sv
../tb/sa_tb_pkg.sv
../tb/tb_top_csr.sv

-top tb_top_csr
