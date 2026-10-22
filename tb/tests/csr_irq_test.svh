// F-CSR-08 (interrupts) plus the CSR's core-side behavior:
// A) STATUS and CYCLES show the controller's busy / error code / cycle count.
// B) CTRL.START gives exactly one pulse, only when byte lane 0 is written with bit 0 = 1.
// C) Every IRQ_EN x event combination: sticky IRQ_STATUS, W1C, irq = OR(IRQ_STATUS & IRQ_EN).
// D) The race: an event in the same cycle as the W1C clear of that bit leaves the bit set.
// IRQ_STATUS, STATUS and CYCLES are volatile, so RAL does not check them; this test checks
// them itself with raw reads.
class csr_irq_test extends sa_base_test;
  `uvm_component_utils(csr_irq_test)

  virtual csr_core_if core;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual csr_core_if)::get(this, "", "core_vif", core))
      `uvm_fatal("NOVIF", "virtual csr_core_if 'core_vif' not found in config_db")
  endfunction

  // one-cycle event pulse(s) from the "controller"
  task pulse(bit done, bit err);
    @(negedge core.clk);
    core.evt_done = done;
    core.evt_err  = err;
    @(negedge core.clk);
    core.evt_done = 1'b0;
    core.evt_err  = 1'b0;
  endtask

  task expect_irq_state(string what, bit [1:0] exp_st, bit exp_irq);
    bit [31:0] data;
    bit [1:0]  resp;
    raw_read(32'h0C, data, resp);
    if (data[1:0] !== exp_st)
      `uvm_error("CSR_IRQ", $sformatf("%s: IRQ_STATUS=%b expected %b", what, data[1:0], exp_st))
    @(negedge core.clk);
    if (core.irq !== exp_irq)
      `uvm_error("CSR_IRQ", $sformatf("%s: irq=%b expected %b", what, core.irq, exp_irq))
  endtask

  virtual task body();
    bit [31:0]   data;
    bit [1:0]    resp;
    uvm_status_e st;
    int          starts0;

    // A) STATUS / CYCLES reflect the core inputs
    repeat (8) begin
      bit [3:0]  ec;
      bit        b;
      bit [31:0] cy;
      ec = $urandom; b = $urandom; cy = $urandom;
      @(negedge core.clk);
      core.err_code = ec;  core.busy = b;  core.cycles = cy;
      raw_read(32'h04, data, resp);
      if (data !== {24'b0, ec, 3'b0, b}) `uvm_error("CSR_IRQ", $sformatf("STATUS=%08h, expected busy=%0b err=%0d", data, b, ec))
      raw_read(32'h2C, data, resp);
      if (data !== cy) `uvm_error("CSR_IRQ", $sformatf("CYCLES=%08h, expected %08h", data, cy))
    end
    @(negedge core.clk);
    core.err_code = '0;  core.busy = 1'b0;  core.cycles = '0;

    // B) START pulse rules
    starts0 = core.start_count;
    raw_write(32'h000, 32'h1, 4'h1, resp);     // lane 0 written, bit 0 = 1  -> pulse
    raw_write(32'h000, 32'h1, 4'hE, resp);     // lane 0 not written         -> none
    raw_write(32'h000, 32'h0, 4'hF, resp);     // bit 0 = 0                  -> none
    raw_write(32'h100, 32'h1, 4'hF, resp);     // aliased address            -> pulse
    repeat (2) @(posedge core.clk);
    if (core.start_count - starts0 != 2)
      `uvm_error("CSR_IRQ", $sformatf("START pulses: %0d, expected 2", core.start_count - starts0))
    env.regmodel.CTRL.read(st, data);
    if (data != 0) `uvm_error("CSR_IRQ", $sformatf("CTRL reads %08h, expected 0", data))

    // C) every enable x event combination
    for (int en = 0; en < 4; en++) begin
      env.regmodel.IRQ_EN.write(st, en);
      raw_write(32'h0C, 32'h3, 4'hF, resp);                       // start clean
      expect_irq_state($sformatf("en=%0d clean", en), 2'b00, 1'b0);
      pulse(1, 0);
      expect_irq_state($sformatf("en=%0d after DONE", en), 2'b01, en[0]);
      pulse(0, 1);
      expect_irq_state($sformatf("en=%0d after ERR", en), 2'b11, |en[1:0]);
      raw_write(32'h0C, 32'h0, 4'hF, resp);                       // writing 0 clears nothing
      expect_irq_state($sformatf("en=%0d W1C 0", en), 2'b11, |en[1:0]);
      raw_write(32'h0C, 32'h1, 4'hF, resp);                       // clear DONE only
      expect_irq_state($sformatf("en=%0d W1C DONE", en), 2'b10, en[1]);
      raw_write(32'h0C, 32'h2, 4'hE, resp);                       // lane 0 not written: no clear
      expect_irq_state($sformatf("en=%0d W1C no strobe", en), 2'b10, en[1]);
      raw_write(32'h0C, 32'h2, 4'h1, resp);                       // clear ERR
      expect_irq_state($sformatf("en=%0d W1C ERR", en), 2'b00, 1'b0);
    end

    // D) event and clear in the same cycle: the event wins
    env.regmodel.IRQ_EN.write(st, 3);
    pulse(1, 1);
    @(negedge core.clk);
    core.race_done = 1'b1;
    raw_write(32'h0C, 32'h1, 4'hF, resp);                         // clear DONE while a new DONE arrives
    @(negedge core.clk);
    core.race_done = 1'b0;
    expect_irq_state("race on DONE", 2'b11, 1'b1);
    @(negedge core.clk);
    core.race_err = 1'b1;
    raw_write(32'h0C, 32'h3, 4'hF, resp);                         // clear both while a new ERR arrives
    @(negedge core.clk);
    core.race_err = 1'b0;
    expect_irq_state("race on ERR", 2'b10, 1'b1);
    raw_write(32'h0C, 32'h3, 4'hF, resp);
    expect_irq_state("final clear", 2'b00, 1'b0);
    `uvm_info("CSR_IRQ", "status inputs, START rules, IRQ combinations and set-vs-clear race checked", UVM_NONE)
  endtask
endclass
