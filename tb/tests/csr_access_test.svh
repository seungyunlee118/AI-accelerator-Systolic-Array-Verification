// F-CSR-05: address decoding (spec §4).
// 1) Every unmapped offset 0x00..0xFC returns SLVERR on write and read (read data 0) and
//    changes no register.
// 2) The explicit case from the vplan teach-back: a write to 0x54 must not touch A_BASE (0x14).
//    A decoder that looked at too few bits ([5:2]) would alias 0x54 onto 0x14.
// 3) Every register works through "dirty" addresses: random bits [31:8] and [1:0].
// 4) Writes to read-only registers return OKAY and change nothing.
class csr_access_test extends sa_base_test;
  `uvm_component_utils(csr_access_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task body();
    uvm_reg      regs[$];
    uvm_reg      rg;
    uvm_status_e st;
    bit [31:0]   data, v, alias_w, alias_r, exp, a;
    bit [1:0]    resp;
    int          n_unmapped = 0;

    env.regmodel.get_registers(regs);

    // Put known non-zero values in every RW register first, so a stray write is visible.
    foreach (regs[i])
      if (rw_mask(regs[i]) != 0) begin
        regs[i].write(st, $urandom);
        if (st != UVM_IS_OK) `uvm_error("CSR_ACCESS", {"setup write failed: ", regs[i].get_name()})
      end

    // 1) unmapped offsets
    for (int off = 0; off < 256; off += 4) begin
      if (env.regmodel.default_map.get_reg_by_offset(off) != null) continue;
      raw_write(off, $urandom, 4'hF, resp);
      expect_resp($sformatf("write to unmapped 0x%02h", off), resp, 2'b10);
      raw_read(off, data, resp);
      expect_resp($sformatf("read from unmapped 0x%02h", off), resp, 2'b10);
      if (data != 0) `uvm_error("CSR_ACCESS", $sformatf("unmapped 0x%02h read data %08h, expected 0", off, data))
      n_unmapped++;
    end
    check_all_mirrors();
    `uvm_info("CSR_ACCESS", $sformatf("%0d unmapped offsets return SLVERR with no side effect", n_unmapped), UVM_NONE)

    // 2) the 0x54 example
    raw_write(32'h54, 32'hDEAD_BEEF, 4'hF, resp);
    expect_resp("write to 0x54", resp, 2'b10);
    env.regmodel.A_BASE.mirror(st, UVM_CHECK);

    // 3) aliased addresses. The write alias rotates over the registers: only [31:8] dirty,
    //    only [1:0] dirty, or both (coverage CG-01 cp_alias showed "only [1:0]" was never hit).
    foreach (regs[i]) begin
      bit [23:0] hi = (i % 3 != 1) ? 24'($urandom_range(1, 24'hFF_FFFF)) : 24'h0;
      bit [1:0]  lo = (i % 3 != 0) ? 2'($urandom_range(1, 3))             : 2'b00;
      rg      = regs[i];
      a       = rg.get_address();
      alias_w = {hi, a[7:2], lo};
      alias_r = {24'($urandom), a[7:2], 2'($urandom)};      // random [31:8] and [1:0]
      if (rw_mask(rg) != 0) begin
        v   = $urandom;
        exp = v & rw_mask(rg);
        raw_write(alias_w, v, 4'hF, resp);
        expect_resp($sformatf("aliased write %08h", alias_w), resp, 2'b00);
        raw_read(alias_r, data, resp);
        expect_resp($sformatf("aliased read %08h", alias_r), resp, 2'b00);
        if (data != exp)
          `uvm_error("CSR_ACCESS", $sformatf("%s via aliases: wrote %08h at %08h, read %08h at %08h, expected %08h",
                                             rg.get_name(), v, alias_w, data, alias_r, exp))
        void'(rg.predict(exp));      // the predictor cannot map alias addresses: resync the mirror
      end else if (rg == env.regmodel.VERSION) begin
        raw_read(alias_r, data, resp);
        if (resp != 2'b00 || data != 32'h5341_0002)
          `uvm_error("CSR_ACCESS", $sformatf("VERSION via alias %08h read %08h resp %0d", alias_r, data, resp))
      end
    end
    `uvm_info("CSR_ACCESS", "every register works through aliased addresses", UVM_NONE)

    // 4) read-only registers ignore writes
    foreach (regs[i]) begin
      rg = regs[i];
      if (rg == env.regmodel.STATUS || rg == env.regmodel.CYCLES || rg == env.regmodel.VERSION) begin
        raw_write(rg.get_address(), 32'hFFFF_FFFF, 4'hF, resp);
        expect_resp({"write to RO ", rg.get_name()}, resp, 2'b00);
      end
    end
    check_all_mirrors();
    env.regmodel.VERSION.mirror(st, UVM_CHECK);
  endtask
endclass
