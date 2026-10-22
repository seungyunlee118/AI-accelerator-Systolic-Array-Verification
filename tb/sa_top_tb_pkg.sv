// Full-chip testbench package: job object, golden model, scoreboard, environment and tests.
package sa_top_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*;
  import axi_pkg::*;
  import sa_gemm_csr_ral_pkg::*;

  `include "sa_job.svh"
  `include "sa_phase.svh"
  `include "sa_gemm_model.svh"
  `include "sa_scoreboard.svh"
  `include "sa_dma_checker.svh"
  `include "sa_env.svh"
  `include "sa_top_base_test.svh"
  `include "gemm_smoke_test.svh"
  `include "gemm_rand_test.svh"
  `include "gemm_dim_test.svh"
  `include "gemm_edge_test.svh"
  `include "gemm_stride_test.svh"
  `include "gemm_quant_test.svh"
  `include "dma_ooo_test.svh"
  `include "dma_backpressure_test.svh"
  `include "dma_4k_test.svh"
  `include "b2b_jobs_test.svh"
  `include "err_cfg_test.svh"
  `include "err_bus_test.svh"
  `include "reset_midjob_test.svh"
endpackage
