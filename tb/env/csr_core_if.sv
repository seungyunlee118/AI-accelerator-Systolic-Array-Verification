// Stand-in for the controller in the CSR block-level testbench.
// Tests drive the core-side inputs of sa_csr (busy, error code, events, cycle count) and watch
// its outputs (start pulse, irq). race_done / race_err make tb_top raise an event in exactly
// the cycle an IRQ_STATUS write takes effect, to test the set-vs-clear rule (spec §4).
interface csr_core_if (input logic clk, input logic rst_n);
  logic        busy      = 1'b0;
  logic [3:0]  err_code  = '0;
  logic        evt_done  = 1'b0;
  logic        evt_err   = 1'b0;
  logic [31:0] cycles    = '0;
  logic        race_done = 1'b0;
  logic        race_err  = 1'b0;

  logic        start;      // from the DUT
  logic        irq;        // from the DUT

  // probes for coverage (CG-01r), connected in tb_top_csr
  logic        w1c_commit;     // a write to IRQ_STATUS takes effect this cycle
  logic [1:0]  w1c_clr;        // flags that write clears
  logic        dut_evt_done;   // events as the DUT sees them
  logic        dut_evt_err;

  int          start_count = 0;
  always @(posedge clk) if (rst_n && start) start_count++;
endinterface
