// AXI4-Lite master agent package (reusable: nothing here is SA-GEMM specific).
package axil_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "axil_item.svh"
  `include "axil_driver.svh"
  `include "axil_monitor.svh"
  `include "axil_agent.svh"
  `include "axil_reg_adapter.svh"
  `include "axil_single_seq.svh"
endpackage
