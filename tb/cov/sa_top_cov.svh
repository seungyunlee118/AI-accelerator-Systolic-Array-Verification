// Full-chip functional coverage, CG-02 .. CG-09 of the vplan (§6).
//   CG-02 job_cfg    each START of a legal job: dimension classes, M/N mod the tile size (edge
//                    tiles), output mode, ReLU, stride kinds; cross M mod T x N mod T x mode
//   CG-03 output     each checked C element: result class (incl. exact saturation edges), ties,
//                    SCALE and SHIFT classes; crosses class x ReLU, class x mode, tie x mode
//   CG-04 dma_read   each read burst: outstanding when issued, ARID, length, 4 KB end, out of
//                    order, interleaved, error; cross outstanding x out of order
//   CG-05 dma_write  each write beat: burst length, WSTRB shape, 4 KB end, error; WSTRB x mode
//   CG-06 errors     each job end: error code; for read errors the phase and the reads in flight
//                    (crossed); for BAD_DIM whether BAD_ADDR was present too
//   CG-07 job_flow   each job end: START while busy, config writes while busy, back-to-back
//                    START, completion seen by interrupt or by polling
//   CG-08 reset      each reset after power-on: job phase x reads in flight
//   CG-09 array      ARRAY_N of the build (4 or 8)
// Only passing runs are merged (sim/regress.py), so coverage never counts a failing job.
typedef enum {D_1, D_2_3, D_4, D_5_7, D_8, D_9_63, D_64}       cov_dim_e;
typedef enum {MOD_0, MOD_1, MOD_2, MOD_3, MOD_4, MOD_5, MOD_6, MOD_7} cov_mod_e;   // MOD_4..7: 8x8 only
typedef enum {MODE_INT32, MODE_INT8}                            cov_mode_e;
typedef enum {RELU_OFF, RELU_ON}                                cov_relu_e;
typedef enum {STRIDE_EXACT, STRIDE_GAP, STRIDE_OVERLAP, STRIDE_ZERO} cov_stride_e;
typedef enum {C_PACKED, C_GAP}                                  cov_cgap_e;
typedef enum {OUT_IN_RANGE, OUT_CLAMP_HI, OUT_CLAMP_LO, OUT_SAT_EDGE_HI, OUT_SAT_EDGE_LO,
              OUT_RELU_ZERO}                                    cov_out_e;
typedef enum {TIE_NONE, TIE_POS, TIE_NEG}                       cov_tie_e;
typedef enum {SCALE_0, SCALE_1, SCALE_MID, SCALE_MAX}           cov_scale_e;
typedef enum {SHIFT_0, SHIFT_1, SHIFT_MID, SHIFT_31}            cov_shift_e;
typedef enum {OT_1, OT_2, OT_3, OT_4}                           cov_ot_e;
typedef enum {ID_0, ID_1, ID_2, ID_3}                           cov_id_e;
typedef enum {LEN_1_BEAT, LEN_2_7_BEATS, LEN_8_BEATS}           cov_rlen_e;
typedef enum {AWLEN_0, AWLEN_1, AWLEN_2_PLUS}                   cov_awlen_e;
typedef enum {WS_FULL, WS_LOW_HALF, WS_HIGH_HALF, WS_SINGLE, WS_OTHER} cov_wstrb_e;
typedef enum {CV_NO, CV_YES}                                    cov_yn_e;
typedef enum {EC_NONE, EC_BAD_DIM, EC_BAD_ADDR, EC_RD_ERR, EC_WR_ERR} cov_err_e;
typedef enum {RDP_A_LOAD, RDP_B_LOAD}                           cov_rd_phase_e;
typedef enum {DONE_BY_IRQ, DONE_BY_POLL}                        cov_done_e;
typedef enum {RST_OT_0, RST_OT_1, RST_OT_2, RST_OT_3, RST_OT_4} cov_rst_ot_e;
typedef enum {ARRAY_4, ARRAY_8}                                 cov_array_e;

`uvm_analysis_imp_decl(_axi)
`uvm_analysis_imp_decl(_axil)

class sa_top_cov extends uvm_component;
  `uvm_component_utils(sa_top_cov)

  uvm_analysis_imp_axi  #(axi_txn,   sa_top_cov) axi_export;
  uvm_analysis_imp_axil #(axil_item, sa_top_cov) axil_export;

  virtual sa_sys_if sys;
  sa_dma_checker    dma_chk;
  sa_cov_db         db;
  int unsigned      array_n = 4;

  localparam int B2B_CYCLES = 30;   // START this soon after the previous job's W1C = back-to-back

  protected sa_job   job;
  protected longint  cyc, last_clear_cyc = -1000;
  protected bit      flag_start_busy, flag_cfg_busy, flag_b2b;
  protected sa_phase_e last_phase;
  protected int        last_rd_ot;

  // ---- sampled values
  cov_dim_e    j_m, j_n, j_k;
  cov_mod_e    j_m4, j_n4;
  cov_mode_e   j_mode;
  cov_relu_e   j_relu;
  cov_stride_e j_ast, j_bst;
  cov_cgap_e   j_cgap;

  cov_out_e    o_class;
  cov_tie_e    o_tie;
  cov_scale_e  o_scale;
  cov_shift_e  o_shift;
  cov_mode_e   o_mode;
  cov_relu_e   o_relu;

  cov_ot_e     r_ot;
  cov_id_e     r_id;
  cov_rlen_e   r_len;
  cov_yn_e     r_4k, r_ooo, r_ilv, r_err;

  cov_awlen_e  w_len;
  cov_wstrb_e  w_strb;
  cov_yn_e     w_4k, w_err;
  cov_mode_e   w_mode;

  cov_err_e      e_code;
  cov_rd_phase_e e_rd_phase;
  cov_ot_e       e_rd_ot;
  cov_yn_e       e_both;

  cov_yn_e     f_start_busy, f_cfg_busy, f_b2b;
  cov_done_e   f_done;

  sa_phase_e   s_phase;
  cov_rst_ot_e s_ot;

  cov_array_e  a_n;

  // ---- covergroups
  covergroup cg_job;                                   // CG-02
    option.per_instance = 1;
    cp_m: coverpoint j_m;
    cp_n: coverpoint j_n;
    cp_k: coverpoint j_k;
    cp_m_mod_t: coverpoint j_m4;
    cp_n_mod_t: coverpoint j_n4;
    cp_mode: coverpoint j_mode;
    cp_relu: coverpoint j_relu;
    cp_a_stride: coverpoint j_ast;
    cp_b_stride: coverpoint j_bst;
    cp_c_gap: coverpoint j_cgap;
    x_mod_t_mode: cross cp_m_mod_t, cp_n_mod_t, cp_mode;
  endgroup

  covergroup cg_out;                                   // CG-03
    option.per_instance = 1;
    cp_class: coverpoint o_class;
    cp_tie:   coverpoint o_tie;
    cp_scale: coverpoint o_scale iff (o_mode == MODE_INT8);
    cp_shift: coverpoint o_shift iff (o_mode == MODE_INT8);
    cp_mode:  coverpoint o_mode;
    cp_relu:  coverpoint o_relu;
    x_class_relu: cross cp_class, cp_relu {
      ignore_bins zero_needs_relu = binsof(cp_class) intersect {OUT_RELU_ZERO} && binsof(cp_relu) intersect {RELU_OFF};
      ignore_bins relu_no_low     = binsof(cp_class) intersect {OUT_CLAMP_LO, OUT_SAT_EDGE_LO} && binsof(cp_relu) intersect {RELU_ON};
    }
    x_class_mode: cross cp_class, cp_mode {
      ignore_bins int32_no_clamp = binsof(cp_class) intersect {OUT_CLAMP_HI, OUT_CLAMP_LO, OUT_SAT_EDGE_HI, OUT_SAT_EDGE_LO}
                                   && binsof(cp_mode) intersect {MODE_INT32};
    }
    x_tie_mode: cross cp_tie, cp_mode {
      ignore_bins int32_no_tie = binsof(cp_tie) intersect {TIE_POS, TIE_NEG} && binsof(cp_mode) intersect {MODE_INT32};
    }
  endgroup

  covergroup cg_rd;                                    // CG-04
    option.per_instance = 1;
    cp_outstanding: coverpoint r_ot;
    cp_arid:        coverpoint r_id;
    cp_len:         coverpoint r_len;
    cp_ends_at_4k:  coverpoint r_4k;
    cp_ooo:         coverpoint r_ooo;
    cp_interleaved: coverpoint r_ilv;
    cp_error:       coverpoint r_err;
    x_ot_ooo:       cross cp_outstanding, cp_ooo {
      // issued with nothing else in flight: there is no older burst to finish before
      ignore_bins alone_never_ooo = binsof(cp_outstanding) intersect {OT_1} && binsof(cp_ooo) intersect {CV_YES};
    }
  endgroup

  covergroup cg_wr;                                    // CG-05, per write beat
    option.per_instance = 1;
    cp_awlen:      coverpoint w_len;
    cp_wstrb:      coverpoint w_strb;
    cp_ends_at_4k: coverpoint w_4k;
    cp_error:      coverpoint w_err;
    cp_mode:       coverpoint w_mode;
    x_wstrb_mode:  cross cp_wstrb, cp_mode {
      // INT32 rows are whole 4-byte elements starting at an 8-byte boundary (C_BASE, C_STRIDE and
      // the tile start are multiples of 8): only FF and 0F can occur
      ignore_bins int32_whole_words = binsof(cp_wstrb) intersect {WS_HIGH_HALF, WS_SINGLE, WS_OTHER} &&
                                      binsof(cp_mode) intersect {MODE_INT32};
    }
  endgroup

  covergroup cg_err;                                   // CG-06
    option.per_instance = 1;
    cp_code:       coverpoint e_code;
    cp_rd_phase:   coverpoint e_rd_phase iff (e_code == EC_RD_ERR);
    cp_rd_inflight: coverpoint e_rd_ot   iff (e_code == EC_RD_ERR);
    x_rd_phase_inflight: cross cp_rd_phase, cp_rd_inflight;
    cp_dim_and_addr: coverpoint e_both   iff (e_code == EC_BAD_DIM);
  endgroup

  covergroup cg_flow;                                  // CG-07
    option.per_instance = 1;
    cp_start_while_busy:  coverpoint f_start_busy;
    cp_config_while_busy: coverpoint f_cfg_busy;
    cp_back_to_back:      coverpoint f_b2b;
    cp_completion:        coverpoint f_done;
  endgroup

  covergroup cg_rst;                                   // CG-08
    option.per_instance = 1;
    cp_phase:    coverpoint s_phase;
    cp_inflight: coverpoint s_ot;
    x_phase_inflight: cross cp_phase, cp_inflight {
      ignore_bins no_reads = binsof(cp_phase) intersect {PH_IDLE, PH_COMPUTE, PH_C_WRITE}
                             && binsof(cp_inflight) intersect {RST_OT_1, RST_OT_2, RST_OT_3, RST_OT_4};
    }
  endgroup

  covergroup cg_array;                                 // CG-09
    option.per_instance = 1;
    cp_array_n: coverpoint a_n;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_job = new();  cg_out = new();  cg_rd = new();  cg_wr = new();
    cg_err = new();  cg_flow = new();  cg_rst = new();  cg_array = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axi_export  = new("axi_export", this);
    axil_export = new("axil_export", this);
    if (!uvm_config_db#(virtual sa_sys_if)::get(this, "", "sys_vif", sys))
      `uvm_fatal("NOVIF", "virtual sa_sys_if 'sys_vif' not found in config_db")
    void'(uvm_config_db#(int unsigned)::get(this, "", "array_n", array_n));
  endfunction

  // ------------------------------------------------------------ bin lists for the merge
  function void declare(sa_cov_db d);
    string q[$], dims[$], m4[$], mode[$], relu[$], cls[$], tie[$], ot[$], yn[$], ws[$], rdp[$], ph[$], rot[$];
    db = d;
    sa_enum_names #(cov_dim_e)::get(dims);   sa_enum_names #(cov_mod_e)::get(m4);
    sa_enum_names #(cov_mode_e)::get(mode);  sa_enum_names #(cov_relu_e)::get(relu);
    sa_enum_names #(cov_yn_e)::get(yn);      sa_enum_names #(cov_ot_e)::get(ot);

    db.declare_all("CG-02", "cp_m", dims);  db.declare_all("CG-02", "cp_n", dims);  db.declare_all("CG-02", "cp_k", dims);
    db.declare_all("CG-02", "cp_m_mod_t", m4);  db.declare_all("CG-02", "cp_n_mod_t", m4);
    db.declare_all("CG-02", "cp_mode", mode);  db.declare_all("CG-02", "cp_relu", relu);
    sa_enum_names #(cov_stride_e)::get(q);
    db.declare_all("CG-02", "cp_a_stride", q);  db.declare_all("CG-02", "cp_b_stride", q);
    sa_enum_names #(cov_cgap_e)::get(q);     db.declare_all("CG-02", "cp_c_gap", q);
    db.declare_cross3("CG-02", "x_mod_t_mode", m4, m4, mode);

    sa_enum_names #(cov_out_e)::get(cls);    db.declare_all("CG-03", "cp_class", cls);
    sa_enum_names #(cov_tie_e)::get(tie);    db.declare_all("CG-03", "cp_tie", tie);
    sa_enum_names #(cov_scale_e)::get(q);    db.declare_all("CG-03", "cp_scale", q);
    sa_enum_names #(cov_shift_e)::get(q);    db.declare_all("CG-03", "cp_shift", q);
    db.declare_all("CG-03", "cp_mode", mode);  db.declare_all("CG-03", "cp_relu", relu);
    db.declare_cross("CG-03", "x_class_relu", cls, relu,
                     '{"OUT_RELU_ZERO*RELU_OFF", "OUT_CLAMP_LO*RELU_ON", "OUT_SAT_EDGE_LO*RELU_ON"});
    db.declare_cross("CG-03", "x_class_mode", cls, mode,
                     '{"OUT_CLAMP_HI*MODE_INT32", "OUT_CLAMP_LO*MODE_INT32", "OUT_SAT_EDGE_HI*MODE_INT32", "OUT_SAT_EDGE_LO*MODE_INT32"});
    db.declare_cross("CG-03", "x_tie_mode", tie, mode, '{"TIE_POS*MODE_INT32", "TIE_NEG*MODE_INT32"});

    db.declare_all("CG-04", "cp_outstanding", ot);
    sa_enum_names #(cov_id_e)::get(q);       db.declare_all("CG-04", "cp_arid", q);
    sa_enum_names #(cov_rlen_e)::get(q);     db.declare_all("CG-04", "cp_len", q);
    db.declare_all("CG-04", "cp_ends_at_4k", yn);  db.declare_all("CG-04", "cp_ooo", yn);
    db.declare_all("CG-04", "cp_interleaved", yn); db.declare_all("CG-04", "cp_error", yn);
    db.declare_cross("CG-04", "x_ot_ooo", ot, yn, '{"OT_1*CV_YES"});

    sa_enum_names #(cov_awlen_e)::get(q);    db.declare_all("CG-05", "cp_awlen", q);
    sa_enum_names #(cov_wstrb_e)::get(ws);   db.declare_all("CG-05", "cp_wstrb", ws);
    db.declare_all("CG-05", "cp_ends_at_4k", yn);  db.declare_all("CG-05", "cp_error", yn);
    db.declare_all("CG-05", "cp_mode", mode);
    db.declare_cross("CG-05", "x_wstrb_mode", ws, mode, '{"WS_HIGH_HALF*MODE_INT32", "WS_SINGLE*MODE_INT32", "WS_OTHER*MODE_INT32"});

    sa_enum_names #(cov_err_e)::get(q);      db.declare_all("CG-06", "cp_code", q);
    sa_enum_names #(cov_rd_phase_e)::get(rdp); db.declare_all("CG-06", "cp_rd_phase", rdp);
    db.declare_all("CG-06", "cp_rd_inflight", ot);
    db.declare_cross("CG-06", "x_rd_phase_inflight", rdp, ot);
    db.declare_all("CG-06", "cp_dim_and_addr", yn);

    db.declare_all("CG-07", "cp_start_while_busy", yn);  db.declare_all("CG-07", "cp_config_while_busy", yn);
    db.declare_all("CG-07", "cp_back_to_back", yn);
    sa_enum_names #(cov_done_e)::get(q);     db.declare_all("CG-07", "cp_completion", q);

    sa_enum_names #(sa_phase_e)::get(ph);    db.declare_all("CG-08", "cp_phase", ph);
    sa_enum_names #(cov_rst_ot_e)::get(rot); db.declare_all("CG-08", "cp_inflight", rot);
    begin
      string skip[$];
      foreach (ph[i]) foreach (rot[j])
        if (ph[i] != "PH_A_LOAD" && ph[i] != "PH_B_LOAD" && rot[j] != "RST_OT_0")
          skip.push_back({ph[i], "*", rot[j]});
      db.declare_cross("CG-08", "x_phase_inflight", ph, rot, skip);
    end

    sa_enum_names #(cov_array_e)::get(q);    db.declare_all("CG-09", "cp_array_n", q);
  endfunction

  // ------------------------------------------------------------ binning helpers
  static function cov_dim_e dim_bin(int unsigned d);
    if (d == 1)  return D_1;
    if (d <= 3)  return D_2_3;
    if (d == 4)  return D_4;
    if (d <= 7)  return D_5_7;
    if (d == 8)  return D_8;
    if (d <= 63) return D_9_63;
    return D_64;
  endfunction

  static function cov_stride_e stride_bin(int unsigned stride, int unsigned row_bytes);
    int unsigned packed_len = 8 * ((row_bytes + 7) / 8);
    if (stride == 0)          return STRIDE_ZERO;
    if (stride < packed_len)  return STRIDE_OVERLAP;
    if (stride == packed_len) return STRIDE_EXACT;
    return STRIDE_GAP;
  endfunction

  static function cov_yn_e yn(bit b);
    return b ? CV_YES : CV_NO;
  endfunction

  // ------------------------------------------------------------ CG-02: a job is started
  function void job_start(sa_job j);
    job = j;
    flag_start_busy = 0;
    flag_cfg_busy   = 0;
    flag_b2b        = 0;
    if (j.cfg_err() != 0) return;
    j_m = dim_bin(j.m);  j_n = dim_bin(j.n);  j_k = dim_bin(j.k);
    j_m4 = cov_mod_e'(j.m % array_n);  j_n4 = cov_mod_e'(j.n % array_n);
    j_mode = j.req ? MODE_INT8 : MODE_INT32;
    j_relu = j.relu ? RELU_ON : RELU_OFF;
    j_ast  = stride_bin(j.a_stride, j.k);
    j_bst  = stride_bin(j.b_stride, j.n);
    j_cgap = (j.c_stride == 8 * ((j.e() * j.n + 7) / 8)) ? C_PACKED : C_GAP;
    cg_job.sample();
    db.hit("CG-02", "cp_m", j_m.name());  db.hit("CG-02", "cp_n", j_n.name());  db.hit("CG-02", "cp_k", j_k.name());
    db.hit("CG-02", "cp_m_mod_t", j_m4.name());  db.hit("CG-02", "cp_n_mod_t", j_n4.name());
    db.hit("CG-02", "cp_mode", j_mode.name());  db.hit("CG-02", "cp_relu", j_relu.name());
    db.hit("CG-02", "cp_a_stride", j_ast.name());  db.hit("CG-02", "cp_b_stride", j_bst.name());
    db.hit("CG-02", "cp_c_gap", j_cgap.name());
    db.hit("CG-02", "x_mod_t_mode", {j_m4.name(), "*", j_n4.name(), "*", j_mode.name()});
  endfunction

  // ------------------------------------------------------------ CG-03: one checked C element
  function void element(sa_job j, longint acc);
    longint p, r;
    o_mode  = j.req ? MODE_INT8 : MODE_INT32;
    o_relu  = j.relu ? RELU_ON : RELU_OFF;
    o_tie   = TIE_NONE;
    o_scale = (j.scale == 0) ? SCALE_0 : (j.scale == 1) ? SCALE_1 : (j.scale == 65535) ? SCALE_MAX : SCALE_MID;
    o_shift = (j.shift == 0) ? SHIFT_0 : (j.shift == 1) ? SHIFT_1 : (j.shift == 31) ? SHIFT_31 : SHIFT_MID;
    if (!j.req) begin
      o_class = (j.relu && acc < 0) ? OUT_RELU_ZERO : OUT_IN_RANGE;
    end else begin
      p = acc * longint'(j.scale);
      if (j.shift != 0 && (p & ((64'sd1 <<< j.shift) - 1)) == (64'sd1 <<< (j.shift - 1)))
        o_tie = (p < 0) ? TIE_NEG : TIE_POS;
      r = (j.shift == 0) ? p : ((p + (64'sd1 <<< (j.shift - 1))) >>> j.shift);
      if (j.relu && r < 0) o_class = OUT_RELU_ZERO;
      else if (r == 128)   o_class = OUT_SAT_EDGE_HI;
      else if (r == -129)  o_class = OUT_SAT_EDGE_LO;
      else if (r > 127)    o_class = OUT_CLAMP_HI;
      else if (r < -128)   o_class = OUT_CLAMP_LO;
      else                 o_class = OUT_IN_RANGE;
    end
    cg_out.sample();
    db.hit("CG-03", "cp_class", o_class.name());  db.hit("CG-03", "cp_tie", o_tie.name());
    if (j.req) begin
      db.hit("CG-03", "cp_scale", o_scale.name());  db.hit("CG-03", "cp_shift", o_shift.name());
    end
    db.hit("CG-03", "cp_mode", o_mode.name());  db.hit("CG-03", "cp_relu", o_relu.name());
    db.hit("CG-03", "x_class_relu", {o_class.name(), "*", o_relu.name()});
    db.hit("CG-03", "x_class_mode", {o_class.name(), "*", o_mode.name()});
    db.hit("CG-03", "x_tie_mode", {o_tie.name(), "*", o_mode.name()});
  endfunction

  // ------------------------------------------------------------ CG-04 / CG-05: AXI4 bursts
  function void write_axi(axi_txn t);
    bit at_4k = ((t.addr + 8 * (int'(t.len) + 1)) % 4096) == 0;
    if (t.dir == AXI_READ) begin
      if (t.outstanding < 1 || t.outstanding > 4 || t.id > 3) return;   // reported by the SVA
      r_ot  = cov_ot_e'(t.outstanding - 1);
      r_id  = cov_id_e'(t.id);
      r_len = (t.len == 0) ? LEN_1_BEAT : (t.len == 7) ? LEN_8_BEATS : LEN_2_7_BEATS;
      r_4k  = yn(at_4k);  r_ooo = yn(t.out_of_order);  r_ilv = yn(t.interleaved);  r_err = yn(t.resp != 0);
      cg_rd.sample();
      db.hit("CG-04", "cp_outstanding", r_ot.name());  db.hit("CG-04", "cp_arid", r_id.name());
      db.hit("CG-04", "cp_len", r_len.name());  db.hit("CG-04", "cp_ends_at_4k", r_4k.name());
      db.hit("CG-04", "cp_ooo", r_ooo.name());  db.hit("CG-04", "cp_interleaved", r_ilv.name());
      db.hit("CG-04", "cp_error", r_err.name());
      db.hit("CG-04", "x_ot_ooo", {r_ot.name(), "*", r_ooo.name()});
    end else begin
      if (job == null) return;
      w_len  = (t.len >= 2) ? AWLEN_2_PLUS : cov_awlen_e'(t.len);
      w_4k   = yn(at_4k);
      w_err  = yn(t.resp != 0);
      w_mode = job.req ? MODE_INT8 : MODE_INT32;
      foreach (t.strb[i]) begin
        bit [7:0] s = t.strb[i];
        w_strb = (s == 8'hFF) ? WS_FULL : (s == 8'h0F) ? WS_LOW_HALF : (s == 8'hF0) ? WS_HIGH_HALF :
                 ($countones(s) == 1) ? WS_SINGLE : WS_OTHER;
        cg_wr.sample();
        db.hit("CG-05", "cp_awlen", w_len.name());  db.hit("CG-05", "cp_wstrb", w_strb.name());
        db.hit("CG-05", "cp_ends_at_4k", w_4k.name());  db.hit("CG-05", "cp_error", w_err.name());
        db.hit("CG-05", "cp_mode", w_mode.name());
        db.hit("CG-05", "x_wstrb_mode", {w_strb.name(), "*", w_mode.name()});
      end
    end
  endfunction

  // ------------------------------------------------------------ CG-07 inputs: CSR writes
  function void write_axil(axil_item t);
    bit [5:0] w = t.addr[7:2];
    if (t.kind != AXIL_WRITE || t.resp != 2'b00) return;
    if (w == 6'd3 && t.strb[0] && t.data[1:0] != 0) last_clear_cyc = cyc;        // IRQ_STATUS W1C
    if (w == 6'd0 && t.strb[0] && t.data[0]) begin                               // CTRL.START
      if (sys.busy === 1'b1)                    flag_start_busy = 1;
      else if (cyc - last_clear_cyc <= B2B_CYCLES) flag_b2b     = 1;
    end
    if (sys.busy === 1'b1 && (w inside {[6'd4:6'd10], 6'd13, 6'd14})) flag_cfg_busy = 1;
  endfunction

  // ------------------------------------------------------------ CG-06 / CG-07: a job ended
  function void job_end(sa_job j, bit [3:0] err, bit polled);
    e_code = cov_err_e'(err);
    cg_err_sample(j);
    f_start_busy = yn(flag_start_busy);
    f_cfg_busy   = yn(flag_cfg_busy);
    f_b2b        = yn(flag_b2b);
    f_done       = polled ? DONE_BY_POLL : DONE_BY_IRQ;
    cg_flow.sample();
    db.hit("CG-07", "cp_start_while_busy", f_start_busy.name());
    db.hit("CG-07", "cp_config_while_busy", f_cfg_busy.name());
    db.hit("CG-07", "cp_back_to_back", f_b2b.name());
    db.hit("CG-07", "cp_completion", f_done.name());
  endfunction

  protected function void cg_err_sample(sa_job j);
    if (e_code == EC_RD_ERR) begin
      if (!(dma_chk.err_phase inside {PH_A_LOAD, PH_B_LOAD}) || dma_chk.err_rd_ot < 1 || dma_chk.err_rd_ot > 4) begin
        `uvm_warning("COV", "read error outside a load phase or with no read in flight; not sampled")
        return;
      end
      e_rd_phase = (dma_chk.err_phase == PH_A_LOAD) ? RDP_A_LOAD : RDP_B_LOAD;
      e_rd_ot    = cov_ot_e'(dma_chk.err_rd_ot - 1);
    end
    e_both = yn(e_code == EC_BAD_DIM && (j.a_base[2:0] != 0 || j.b_base[2:0] != 0 || j.c_base[2:0] != 0 ||
                                         j.a_stride % 8 != 0 || j.b_stride % 8 != 0 || j.c_stride % 8 != 0 ||
                                         j.c_stride < j.e() * j.n));
    cg_err.sample();
    db.hit("CG-06", "cp_code", e_code.name());
    if (e_code == EC_RD_ERR) begin
      db.hit("CG-06", "cp_rd_phase", e_rd_phase.name());
      db.hit("CG-06", "cp_rd_inflight", e_rd_ot.name());
      db.hit("CG-06", "x_rd_phase_inflight", {e_rd_phase.name(), "*", e_rd_ot.name()});
    end
    if (e_code == EC_BAD_DIM) db.hit("CG-06", "cp_dim_and_addr", e_both.name());
  endfunction

  // ------------------------------------------------------------ CG-08 / CG-09
  virtual task run_phase(uvm_phase phase);
    bit released = 0;
    a_n = (array_n == 8) ? ARRAY_8 : ARRAY_4;
    cg_array.sample();
    db.hit("CG-09", "cp_array_n", a_n.name());
    fork
      forever begin                                   // last values before any reset edge
        @(sys.mon_cb);
        cyc++;
        if (sys.rst_n === 1'b1) begin
          released   = 1;
          last_phase = sa_phase_of(sys.mon_cb.ctrl_state);
          last_rd_ot = dma_chk.rd_ot;
        end
      end
      forever begin
        @(negedge sys.rst_n);
        if (!released) continue;                      // power-on reset
        s_phase = last_phase;
        s_ot    = cov_rst_ot_e'((last_rd_ot > 4) ? 4 : last_rd_ot);
        if (!(s_phase inside {PH_A_LOAD, PH_B_LOAD})) s_ot = RST_OT_0;
        cg_rst.sample();
        db.hit("CG-08", "cp_phase", s_phase.name());
        db.hit("CG-08", "cp_inflight", s_ot.name());
        db.hit("CG-08", "x_phase_inflight", {s_phase.name(), "*", s_ot.name()});
      end
    join
  endtask

  // (not named check(): uvm_component::check() is a deprecated hook that UVM calls by itself)
  function void check_coverage();
    db.check("CG-02", cg_job.get_inst_coverage());
    db.check("CG-03", cg_out.get_inst_coverage());
    db.check("CG-04", cg_rd.get_inst_coverage());
    db.check("CG-05", cg_wr.get_inst_coverage());
    db.check("CG-06", cg_err.get_inst_coverage());
    db.check("CG-07", cg_flow.get_inst_coverage());
    db.check("CG-08", cg_rst.get_inst_coverage());
    db.check("CG-09", cg_array.get_inst_coverage());
  endfunction
endclass
