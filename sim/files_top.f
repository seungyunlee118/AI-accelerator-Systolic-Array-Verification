// Compile list for the full-chip testbench. Paths are relative to sim/.
-incdir ../tb/axil
-incdir ../tb/axi
-incdir ../tb/env
-incdir ../tb/tests

../rtl/sa_pe.sv
../rtl/sa_array.sv
../rtl/sa_outq.sv
../rtl/sa_csr.sv
../rtl/sa_dma_rd.sv
../rtl/sa_dma_wr.sv
../rtl/sa_ctrl.sv
../rtl/sa_top.sv

../tb/ral/sa_gemm_csr_ral_pkg.sv
../tb/axil/axil_if.sv
../tb/axil/axil_pkg.sv
../tb/axi/axi_if.sv
../tb/axi/axi_pkg.sv
../tb/env/sa_sys_if.sv
../tb/sa_top_tb_pkg.sv
../tb/tb_top.sv

-top tb_top
