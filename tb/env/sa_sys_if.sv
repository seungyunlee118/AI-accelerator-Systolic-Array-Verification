// System-level signals of the full-chip testbench.
//   irq              DUT interrupt output.
//   rst_req          Tests set it to assert the asynchronous reset at any time (spec §9).
//   busy, ctrl_state White-box probes of the controller, connected in tb_top. They are used
//                    only to aim stimulus at a job phase and to check when BUSY falls; results
//                    are always predicted from the spec, never from these probes.
interface sa_sys_if (input logic clk, input logic rst_n);
  logic       irq;
  logic       rst_req = 1'b0;
  logic       busy;
  logic [3:0] ctrl_state;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input irq, busy, ctrl_state;
  endclocking
endinterface
