// System-level signals of the full-chip testbench that tests need to watch.
interface sa_sys_if (input logic clk, input logic rst_n);
  logic irq;
endinterface
