// CG-01 (vplan §6): every AXI4-Lite access seen by the monitor.
//   register x access (reads and writes of every register, unmapped offsets, RO writes),
//   AW/W order and strobe shape of writes, response, and "dirty" address bits that the decode
//   must ignore. The W1C set-vs-clear race is CG-01r (sa_csr_race_cov, CSR testbench only).
typedef enum {R_CTRL, R_STATUS, R_IRQ_EN, R_IRQ_STATUS, R_DIMS, R_A_BASE, R_A_STRIDE, R_B_BASE,
              R_B_STRIDE, R_C_BASE, R_C_STRIDE, R_CYCLES, R_VERSION, R_QCFG, R_QSCALE,
              R_UNMAPPED} cov_reg_e;
typedef enum {STRB_FULL, STRB_PARTIAL, STRB_ZERO} cov_strb_e;
typedef enum {ADDR_CLEAN, ADDR_HIGH_BITS, ADDR_LOW_BITS, ADDR_BOTH} cov_alias_e;
typedef enum {RESP_OKAY, RESP_SLVERR} cov_resp_e;

class sa_csr_cov extends uvm_subscriber #(axil_item);
  `uvm_component_utils(sa_csr_cov)

  sa_cov_db db;

  cov_reg_e    c_reg;
  axil_kind_e  c_kind;
  axil_order_e c_order;
  cov_strb_e   c_strb;
  cov_resp_e   c_resp;
  cov_alias_e  c_alias;

  covergroup cg_access;
    option.per_instance = 1;
    cp_reg:     coverpoint c_reg;
    cp_kind:    coverpoint c_kind;
    x_reg_kind: cross cp_reg, cp_kind;
    cp_order:   coverpoint c_order iff (c_kind == AXIL_WRITE);
    cp_strb:    coverpoint c_strb  iff (c_kind == AXIL_WRITE);
    cp_resp:    coverpoint c_resp;
    cp_alias:   coverpoint c_alias;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_access = new();
  endfunction

  function void declare(sa_cov_db d);
    string regs[$], kinds[$], q[$];
    db = d;
    sa_enum_names #(cov_reg_e)::get(regs);       db.declare_all("CG-01", "cp_reg", regs);
    sa_enum_names #(axil_kind_e)::get(kinds);    db.declare_all("CG-01", "cp_kind", kinds);
    db.declare_cross("CG-01", "x_reg_kind", regs, kinds);
    sa_enum_names #(axil_order_e)::get(q);       db.declare_all("CG-01", "cp_order", q);
    sa_enum_names #(cov_strb_e)::get(q);         db.declare_all("CG-01", "cp_strb", q);
    sa_enum_names #(cov_resp_e)::get(q);         db.declare_all("CG-01", "cp_resp", q);
    sa_enum_names #(cov_alias_e)::get(q);        db.declare_all("CG-01", "cp_alias", q);
  endfunction

  function void write(axil_item t);
    c_reg   = (t.addr[7:2] <= 6'd14) ? cov_reg_e'(t.addr[7:2]) : R_UNMAPPED;
    c_kind  = t.kind;
    c_order = t.order;
    c_strb  = (t.strb == 4'hF) ? STRB_FULL : (t.strb == 4'h0) ? STRB_ZERO : STRB_PARTIAL;
    c_resp  = (t.resp == 2'b00) ? RESP_OKAY : RESP_SLVERR;
    c_alias = cov_alias_e'({t.addr[1:0] != 0, t.addr[31:8] != 0});
    cg_access.sample();

    db.hit("CG-01", "cp_reg", c_reg.name());
    db.hit("CG-01", "cp_kind", c_kind.name());
    db.hit("CG-01", "x_reg_kind", {c_reg.name(), "*", c_kind.name()});
    if (c_kind == AXIL_WRITE) begin
      db.hit("CG-01", "cp_order", c_order.name());
      db.hit("CG-01", "cp_strb", c_strb.name());
    end
    db.hit("CG-01", "cp_resp", c_resp.name());
    db.hit("CG-01", "cp_alias", c_alias.name());
  endfunction

  // (not named check(): uvm_component::check() is a deprecated hook that UVM calls by itself)
  function void check_coverage();
    db.check("CG-01", cg_access.get_inst_coverage());
  endfunction
endclass
