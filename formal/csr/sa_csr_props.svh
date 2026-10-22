// Formal properties for the CSR block (spec v0.3 §3, §4), proven with SymbiYosys.
// Included into sa_csr when FORMAL is defined (open-source Yosys has no `bind`).
//
// ASSUME (the environment): reset at the start only; the AXI4-Lite master follows the protocol
//   (VALID held until READY, payload stable while waiting). Everything else is free: addresses,
//   data, strobes, B/R ready, and all core-side inputs (events, busy, error code, cycles).
// ASSERT (what the CSR block guarantees, for every possible input sequence):
//   P1  AXI4-Lite slave protocol: B/R stay valid and stable until taken; a response only
//       after its request.
//   P2  Response codes: OKAY exactly for mapped offsets, SLVERR otherwise (reads and writes).
//   P3  Read data: every register reads its spec value; unmapped reads return 0.
//   P4  Write semantics: RW registers change only through a write to their own offset, byte
//       lane by byte lane, writable bits only; RO / unmapped writes change nothing.
//   P5  IRQ_STATUS: events set bits, W1C clears them, and an event wins over a same-cycle clear.
//   P6  irq = OR(IRQ_STATUS & IRQ_EN);  START = one pulse after a CTRL write with lane 0, bit 0.
// The expected values come from an independent shadow model built from the bus traffic and the
// spec (its own address decode, masks and byte merge). Only the commit instant (do_write) is
// taken from the RTL; P1 also checks that a commit happens only after both AW and W arrived.

  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  // ---------------------------------------------------------------- environment
  initial assume (!rst_n);
  always @(*) if (f_past_valid) assume (rst_n);

  always @(posedge clk)
    if (f_past_valid && $past(rst_n)) begin
      if ($past(s_axil_awvalid && !s_axil_awready))
        assume (s_axil_awvalid && s_axil_awaddr == $past(s_axil_awaddr));
      if ($past(s_axil_wvalid && !s_axil_wready))
        assume (s_axil_wvalid && s_axil_wdata == $past(s_axil_wdata) && s_axil_wstrb == $past(s_axil_wstrb));
      if ($past(s_axil_arvalid && !s_axil_arready))
        assume (s_axil_arvalid && s_axil_araddr == $past(s_axil_araddr));
    end

  // ---------------------------------------------------------------- spec decode (independent)
  // Registers are words 0..14 (offsets 0x00..0x38), all contiguous.
  function automatic logic f_mapped(input logic [31:0] a);
    f_mapped = (a[7:2] <= 6'd14);
  endfunction

  // writable bits of the plain RW registers; 0 for everything else
  function automatic logic [31:0] f_wmask(input logic [5:0] w);
    case (w)
      6'd2:                 f_wmask = 32'h0000_0003;   // IRQ_EN
      6'd4:                 f_wmask = 32'h007F_7F7F;   // DIMS
      6'd5, 6'd7, 6'd9:     f_wmask = 32'hFFFF_FFFF;   // A/B/C_BASE
      6'd6, 6'd8, 6'd10:    f_wmask = 32'h0000_FFFF;   // A/B/C_STRIDE
      6'd13:                f_wmask = 32'h0000_1F03;   // QCFG
      6'd14:                f_wmask = 32'h0000_FFFF;   // QSCALE
      default:              f_wmask = 32'h0000_0000;
    endcase
  endfunction

  function automatic logic [31:0] f_merge(input logic [31:0] old_v, input logic [31:0] d,
                                          input logic [3:0] strb, input logic [31:0] m);
    logic [31:0] lanes;
    lanes = {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}} & m;
    f_merge = (old_v & ~lanes) | (d & lanes);
  endfunction

  // ---------------------------------------------------------------- shadow of the bus traffic
  logic [31:0] f_aw_addr, f_w_data, f_exp_rdata;
  logic [3:0]  f_w_strb;
  logic        f_aw_pend, f_w_pend, f_b_owed, f_r_owed;
  logic [1:0]  f_exp_bresp, f_exp_rresp;
  logic [5:0]  f_w_word;
  assign f_w_word = f_aw_addr[7:2];

  // shadow registers
  logic [31:0] f_irq_en, f_dims, f_abase, f_astr, f_bbase, f_bstr, f_cbase, f_cstr, f_qcfg, f_qscale;
  logic [1:0]  f_irq_st, f_clr;
  logic        f_start;

  function automatic logic [31:0] f_read_value(input logic [5:0] w);
    case (w)
      6'd0:  f_read_value = 32'h0;                              // CTRL reads 0
      6'd1:  f_read_value = {24'b0, err_code, 3'b0, busy};      // STATUS
      6'd2:  f_read_value = f_irq_en;
      6'd3:  f_read_value = {30'b0, f_irq_st};
      6'd4:  f_read_value = f_dims;
      6'd5:  f_read_value = f_abase;
      6'd6:  f_read_value = f_astr;
      6'd7:  f_read_value = f_bbase;
      6'd8:  f_read_value = f_bstr;
      6'd9:  f_read_value = f_cbase;
      6'd10: f_read_value = f_cstr;
      6'd11: f_read_value = cycles;                             // CYCLES
      6'd12: f_read_value = 32'h5341_0002;                      // VERSION
      6'd13: f_read_value = f_qcfg;
      6'd14: f_read_value = f_qscale;
      default: f_read_value = 32'h0;                            // unmapped
    endcase
  endfunction

  // W1C clear requested by the write that commits this cycle (lane 0 holds both flags)
  assign f_clr = (do_write && f_w_word == 6'd3) ? (f_w_data[1:0] & {2{f_w_strb[0]}}) : 2'b00;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      f_aw_pend <= 1'b0;  f_w_pend <= 1'b0;  f_b_owed <= 1'b0;  f_r_owed <= 1'b0;
      f_aw_addr <= '0;  f_w_data <= '0;  f_w_strb <= '0;
      f_exp_bresp <= '0;  f_exp_rresp <= '0;  f_exp_rdata <= '0;
      f_irq_en <= '0;  f_dims <= '0;  f_abase <= '0;  f_astr <= '0;  f_bbase <= '0;
      f_bstr <= '0;  f_cbase <= '0;  f_cstr <= '0;  f_qcfg <= '0;  f_qscale <= '0;
      f_irq_st <= '0;  f_start <= 1'b0;
    end else begin
      if (s_axil_awvalid && s_axil_awready) begin f_aw_addr <= s_axil_awaddr; f_aw_pend <= 1'b1; end
      if (s_axil_wvalid  && s_axil_wready)  begin f_w_data <= s_axil_wdata; f_w_strb <= s_axil_wstrb; f_w_pend <= 1'b1; end

      if (do_write) begin
        f_aw_pend   <= 1'b0;
        f_w_pend    <= 1'b0;
        f_b_owed    <= 1'b1;
        f_exp_bresp <= f_mapped(f_aw_addr) ? 2'b00 : 2'b10;
        case (f_w_word)
          6'd2:  f_irq_en <= f_merge(f_irq_en, f_w_data, f_w_strb, f_wmask(6'd2));
          6'd4:  f_dims   <= f_merge(f_dims,   f_w_data, f_w_strb, f_wmask(6'd4));
          6'd5:  f_abase  <= f_merge(f_abase,  f_w_data, f_w_strb, f_wmask(6'd5));
          6'd6:  f_astr   <= f_merge(f_astr,   f_w_data, f_w_strb, f_wmask(6'd6));
          6'd7:  f_bbase  <= f_merge(f_bbase,  f_w_data, f_w_strb, f_wmask(6'd7));
          6'd8:  f_bstr   <= f_merge(f_bstr,   f_w_data, f_w_strb, f_wmask(6'd8));
          6'd9:  f_cbase  <= f_merge(f_cbase,  f_w_data, f_w_strb, f_wmask(6'd9));
          6'd10: f_cstr   <= f_merge(f_cstr,   f_w_data, f_w_strb, f_wmask(6'd10));
          6'd13: f_qcfg   <= f_merge(f_qcfg,   f_w_data, f_w_strb, f_wmask(6'd13));
          6'd14: f_qscale <= f_merge(f_qscale, f_w_data, f_w_strb, f_wmask(6'd14));
          default: ;
        endcase
      end else if (s_axil_bvalid && s_axil_bready) begin
        f_b_owed <= 1'b0;
      end

      if (s_axil_arvalid && s_axil_arready) begin
        f_r_owed    <= 1'b1;
        f_exp_rdata <= f_read_value(s_axil_araddr[7:2]);
        f_exp_rresp <= f_mapped(s_axil_araddr) ? 2'b00 : 2'b10;
      end else if (s_axil_rvalid && s_axil_rready) begin
        f_r_owed <= 1'b0;
      end

      f_irq_st <= (f_irq_st & ~f_clr) | {evt_err, evt_done};    // set wins over clear
      f_start  <= do_write && f_w_word == 6'd0 && f_w_strb[0] && f_w_data[0];
    end

  // ---------------------------------------------------------------- assertions
  always @(*)
    if (rst_n) begin
      // P1 protocol: responses only for requests, commit only after AW and W both arrived
      assert (s_axil_bvalid == f_b_owed);
      assert (s_axil_rvalid == f_r_owed);
      if (do_write) assert (f_aw_pend && f_w_pend);
      // P2 response codes, P3 read data (held stable while waiting, since these only change
      // when a new request is accepted, which cannot happen while the response is pending)
      if (s_axil_bvalid) assert (s_axil_bresp == f_exp_bresp);
      if (s_axil_rvalid) assert (s_axil_rdata == f_exp_rdata && s_axil_rresp == f_exp_rresp);
      // P4 register contents equal the shadow model
      assert (r_irq_en == f_irq_en && r_dims == f_dims && r_abase == f_abase && r_astr == f_astr);
      assert (r_bbase == f_bbase && r_bstr == f_bstr && r_cbase == f_cbase && r_cstr == f_cstr);
      assert (r_qcfg == f_qcfg && r_qscale == f_qscale);
      // P5 IRQ_STATUS
      assert (r_irq_st == {30'b0, f_irq_st});
      // P6 outputs
      assert (irq == |(f_irq_st & f_irq_en[1:0]));
      assert (start == f_start);
      // Helper invariants: the request the RTL holds is the one seen on the bus. Without them
      // the induction step may start from a state that is unreachable from reset (RTL holding
      // a write the shadow never saw) and the proof ends UNKNOWN instead of PASS.
      assert (aw_have == f_aw_pend && w_have == f_w_pend);
      if (aw_have) assert (aw_addr_q == {f_aw_addr[7:2], 2'b00});
      if (w_have)  assert (w_data_q == f_w_data && w_strb_q == f_w_strb);
    end

  // ---------------------------------------------------------------- covers (not vacuous)
  always @(posedge clk)
    if (rst_n) begin
      cover (s_axil_bvalid && s_axil_bresp == 2'b10);                          // SLVERR on a write
      cover (s_axil_rvalid && s_axil_rresp == 2'b10);                          // SLVERR on a read
      cover (s_axil_rvalid && s_axil_rdata == 32'h5341_0002);                  // VERSION read
      cover (s_axil_awvalid && s_axil_awready && !(s_axil_wvalid && s_axil_wready) && !w_have); // AW first
      cover (s_axil_wvalid && s_axil_wready && !(s_axil_awvalid && s_axil_awready) && !aw_have); // W first
      cover (f_clr[0] && evt_done);                                            // set-vs-clear race
      cover (irq);
      cover (start);
      cover (do_write && f_w_word == 6'd5 && f_w_strb == 4'b0101);             // partial strobe write
    end
