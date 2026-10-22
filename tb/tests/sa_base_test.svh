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

  virtual function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    int errs = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);
    super.report_phase(phase);
    if (errs == 0) `uvm_info("RESULT", $sformatf("*** TEST PASSED: %s ***", get_type_name()), UVM_NONE)
    else           `uvm_info("RESULT", $sformatf("*** TEST FAILED: %s (%0d errors) ***", get_type_name(), errs), UVM_NONE)
  endfunction
endclass
