// F-CSR-02/03/04: writable bits, byte strobes, AW/W in any order, B/R back-pressure.
// 1) uvm_reg_bit_bash_seq writes 1 and 0 to every bit of every register and reads it back
//    (RO and reserved bits must not change). RAL accesses use random channel timing.
// 2) Random raw writes with random WSTRB and timing, with frequent mirror(UVM_CHECK) reads.
//    UVM's RAL applies byte enables per *field* (a field is updated whole if its lowest byte
//    is enabled, otherwise not at all), so it cannot model a strobe that writes part of a
//    32-bit field. For those writes the test computes the expected value itself and calls
//    predict(); full-width writes are tracked by the explicit predictor as usual.
class csr_rw_test extends sa_base_test;
  `uvm_component_utils(csr_rw_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    uvm_reg_bit_bash_seq bb = uvm_reg_bit_bash_seq::type_id::create("bb");
    uvm_reg              regs[$];
    uvm_reg              rg;
    uvm_status_e         st;
    bit [1:0]            resp;
    int                  n_writes = 0, n_checks = 0, n_partial = 0;

    bb.model = env.regmodel;
    bb.start(null);
    `uvm_info("CSR_RW", "bit-bash done", UVM_NONE)

    env.regmodel.get_registers(regs);
    repeat (300) begin
      rg = regs[$urandom_range(0, regs.size() - 1)];
      if ($urandom_range(0, 2) != 0) begin
        bit [3:0]  strb;
        bit [31:0] d, old_v, lanes, m;
        strb  = $urandom_range(0, 15);
        d     = $urandom;
        old_v = rg.get_mirrored_value();
        raw_write(rg.get_address(), d, strb, resp);
        expect_resp({"write ", rg.get_name()}, resp, 2'b00);
        m = rw_mask(rg);
        if (strb != 4'hF && m != 0) begin
          lanes = {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
          void'(rg.predict((old_v & ~(lanes & m)) | (d & lanes & m)));
        end
        n_writes++;
        if (strb != 4'hF) n_partial++;
      end else begin
        rg.mirror(st, UVM_CHECK);
        n_checks++;
      end
    end
    check_all_mirrors();
    `uvm_info("CSR_RW", $sformatf("random phase: %0d writes (%0d partial strobes), %0d checked reads",
                                  n_writes, n_partial, n_checks), UVM_NONE)
  endtask
endclass
