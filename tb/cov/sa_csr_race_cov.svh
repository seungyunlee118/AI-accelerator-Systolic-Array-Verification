// CG-01r (vplan §6, CG-01 "W1C clear with an event in the same cycle"): a write to IRQ_STATUS
// that clears a flag commits in exactly the cycle the core raises that same flag. Seen through
// probes of the CSR block (csr_core_if, CSR testbench only), checked by csr_irq_test.
typedef enum {RACE_DONE, RACE_ERR} cov_race_e;

class sa_csr_race_cov extends uvm_component;
  `uvm_component_utils(sa_csr_race_cov)

  virtual csr_core_if core;
  sa_cov_db           db;
  cov_race_e          c_race;

  covergroup cg_race;
    option.per_instance = 1;
    cp_race: coverpoint c_race;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_race = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual csr_core_if)::get(this, "", "core_vif", core))
      `uvm_fatal("NOVIF", "virtual csr_core_if 'core_vif' not found in config_db")
  endfunction

  function void declare(sa_cov_db d);
    string q[$];
    db = d;
    sa_enum_names #(cov_race_e)::get(q);
    db.declare_all("CG-01r", "cp_race", q);
  endfunction

  function void sample(cov_race_e r);
    c_race = r;
    cg_race.sample();
    db.hit("CG-01r", "cp_race", r.name());
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(posedge core.clk);
      if (core.rst_n !== 1'b1 || !core.w1c_commit) continue;
      if (core.w1c_clr[0] && core.dut_evt_done) sample(RACE_DONE);
      if (core.w1c_clr[1] && core.dut_evt_err)  sample(RACE_ERR);
    end
  endtask

  function void check();
    db.check("CG-01r", cg_race.get_inst_coverage());
  endfunction
endclass
