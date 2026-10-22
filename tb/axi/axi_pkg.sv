// AXI4 memory agent package (slave side, 64-bit data).
package axi_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "axi_mem_cfg.svh"
  `include "axi_mem_model.svh"
  `include "axi_txn.svh"
  `include "axi_mem_responder.svh"
  `include "axi_monitor.svh"
  `include "axi_mem_agent.svh"
endpackage
