// Base test: builds the environment, waits for reset, runs body(), prints one PASS/FAIL line.
// Derived tests only override body().
class sa_base_test extends uvm_test;
  `uvm_component_utils(sa_base_test)

  sa_csr_env      env;
  virtual axil_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = sa_csr_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "virtual axil_if 'vif' not found in config_db")
    uvm_top.set_timeout(1ms, 1);           // a hung test fails instead of running forever
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    uvm_top.print_topology();
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait (vif.rst_n === 1'b1);
    repeat (2) @(posedge vif.clk);
    body();
    repeat (5) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask

  // Stimulus of the test. Overridden by every derived test.
  virtual task body();
  endtask

  // ------------------------------------------------------------ helpers for derived tests
  // Raw AXI4-Lite accesses (any address, any strobes), returning the bus response.
  task raw_write(bit [31:0] addr, bit [31:0] data, bit [3:0] strb, output bit [1:0] resp);
    axil_single_seq s = axil_single_seq::type_id::create("s");
    s.kind = AXIL_WRITE;  s.addr = addr;  s.data = data;  s.strb = strb;
    s.start(env.axil.sqr);
    resp = s.resp;
  endtask

  task raw_read(bit [31:0] addr, output bit [31:0] data, output bit [1:0] resp);
    axil_single_seq s = axil_single_seq::type_id::create("s");
    s.kind = AXIL_READ;  s.addr = addr;
    s.start(env.axil.sqr);
    data = s.data;
    resp = s.resp;
  endtask

  // Bits of a register that software can write (its RW fields).
  function bit [31:0] rw_mask(uvm_reg rg);
    uvm_reg_field f[$];
    rg.get_fields(f);
    rw_mask = '0;
    foreach (f[i])
      if (f[i].get_access() == "RW")
        rw_mask |= 32'(((64'd1 << f[i].get_n_bits()) - 1) << f[i].get_lsb_pos());
  endfunction

  // Read every register through the bus and compare with the RAL mirror.
  task check_all_mirrors();
    uvm_reg      regs[$];
    uvm_status_e st;
    env.regmodel.get_registers(regs);
    foreach (regs[i]) regs[i].mirror(st, UVM_CHECK);
  endtask

  function void expect_resp(string what, bit [1:0] got, bit [1:0] exp);
    if (got !== exp) `uvm_error("RESP", $sformatf("%s: response %0d, expected %0d", what, got, exp))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    int errs = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);
    super.report_phase(phase);
    if (errs == 0) `uvm_info("RESULT", $sformatf("*** TEST PASSED: %s ***", get_type_name()), UVM_NONE)
    else           `uvm_info("RESULT", $sformatf("*** TEST FAILED: %s (%0d errors) ***", get_type_name(), errs), UVM_NONE)
  endfunction
endclass
