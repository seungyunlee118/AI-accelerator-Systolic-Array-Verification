// F-CSR-01: every register reads back its reset value after reset.
// Uses UVM's built-in uvm_reg_hw_reset_seq: it reads every register through the bus and
// compares each non-volatile field with the reset value in the RAL model.
class csr_reset_test extends sa_base_test;
  `uvm_component_utils(csr_reset_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    uvm_reg_hw_reset_seq seq = uvm_reg_hw_reset_seq::type_id::create("seq");
    uvm_reg_data_t       version;
    uvm_status_e         status;

    seq.model = env.regmodel;
    seq.start(null);

    // Not vacuous: VERSION is the one register whose reset value is not 0, so read it
    // explicitly and print it.
    env.regmodel.VERSION.read(status, version);
    `uvm_info("CSR_RESET", $sformatf("VERSION = 0x%08h (status %s)", version, status.name()), UVM_NONE)
    if (status != UVM_IS_OK || version != 32'h5341_0002)
      `uvm_error("CSR_RESET", "VERSION read is wrong")
  endtask
endclass
