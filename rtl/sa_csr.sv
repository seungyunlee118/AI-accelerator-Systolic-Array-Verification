// AXI4-Lite CSR block (spec §4).
// One outstanding transaction per direction; AW and W are latched independently, so they
// may arrive in either order. The register write happens when both are held and B is free.
module sa_csr (
  input  logic        clk,
  input  logic        rst_n,

  // AXI4-Lite slave
  input  logic [31:0] s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [31:0] s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,

  // core interface
  output logic        start,        // one-cycle pulse
  input  logic        busy,
  input  logic [3:0]  err_code,
  input  logic        evt_done,     // one-cycle pulses from the core
  input  logic        evt_err,
  input  logic [31:0] cycles,
  output logic [6:0]  dim_m,
  output logic [6:0]  dim_n,
  output logic [6:0]  dim_k,
  output logic [31:0] a_base,
  output logic [15:0] a_stride,
  output logic [31:0] b_base,
  output logic [15:0] b_stride,
  output logic [31:0] c_base,
  output logic [15:0] c_stride,
  output logic        req_en,
  output logic        relu_en,
  output logic [4:0]  shift,
  output logic [15:0] scale,
  output logic        irq
);
  localparam logic [7:0] A_CTRL   = 8'h00, A_STATUS = 8'h04, A_IRQ_EN = 8'h08, A_IRQ_ST = 8'h0C,
                         A_DIMS   = 8'h10, A_ABASE  = 8'h14, A_ASTR   = 8'h18, A_BBASE  = 8'h1C,
                         A_BSTR   = 8'h20, A_CBASE  = 8'h24, A_CSTR   = 8'h28, A_CYCLES = 8'h2C,
                         A_VER    = 8'h30, A_QCFG   = 8'h34, A_QSCALE = 8'h38;
  localparam logic [31:0] VERSION = 32'h5341_0002;

  // writable-bit masks
  localparam logic [31:0] M_IRQ  = 32'h0000_0003;
  localparam logic [31:0] M_DIMS = 32'h007F_7F7F;
  localparam logic [31:0] M_16   = 32'h0000_FFFF;
  localparam logic [31:0] M_QCFG = 32'h0000_1F03;

  logic [31:0] r_irq_en, r_irq_st, r_dims, r_abase, r_astr, r_bbase, r_bstr;
  logic [31:0] r_cbase, r_cstr, r_qcfg, r_qscale;

  function automatic logic [31:0] lane_mask(logic [3:0] strb);
    for (int b = 0; b < 4; b++) lane_mask[8*b +: 8] = {8{strb[b]}};
  endfunction

  function automatic logic [31:0] merge(logic [31:0] old, logic [31:0] wd, logic [3:0] strb,
                                        logic [31:0] mask);
    logic [31:0] lm;
    lm = lane_mask(strb) & mask;
    merge = (old & ~lm) | (wd & lm);
  endfunction

  function automatic logic is_mapped(logic [7:0] a);
    case (a)
      A_CTRL, A_STATUS, A_IRQ_EN, A_IRQ_ST, A_DIMS, A_ABASE, A_ASTR, A_BBASE, A_BSTR,
      A_CBASE, A_CSTR, A_CYCLES, A_VER, A_QCFG, A_QSCALE: is_mapped = 1'b1;
      default: is_mapped = 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------- write channel
  logic        aw_have, w_have;
  logic [7:0]  aw_addr_q;
  logic [31:0] w_data_q;
  logic [3:0]  w_strb_q;
  logic        do_write;
  logic        wr_mapped;      // the latched write address is a register

  assign s_axil_awready = !aw_have && !s_axil_bvalid;
  assign s_axil_wready  = !w_have  && !s_axil_bvalid;
  assign do_write       = aw_have && w_have && !s_axil_bvalid;
  assign wr_mapped      = is_mapped(aw_addr_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_have       <= 1'b0;
      w_have        <= 1'b0;
      aw_addr_q     <= '0;
      w_data_q      <= '0;
      w_strb_q      <= '0;
      s_axil_bvalid <= 1'b0;
      s_axil_bresp  <= 2'b00;
    end else begin
      if (s_axil_awvalid && s_axil_awready) begin
        aw_have   <= 1'b1;
        aw_addr_q <= {s_axil_awaddr[7:2], 2'b00};
      end
      if (s_axil_wvalid && s_axil_wready) begin
        w_have   <= 1'b1;
        w_data_q <= s_axil_wdata;
        w_strb_q <= s_axil_wstrb;
      end
      if (do_write) begin
        aw_have       <= 1'b0;
        w_have        <= 1'b0;
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= wr_mapped ? 2'b00 : 2'b10;
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------- registers
  logic [31:0] irq_clr;
  assign irq_clr = (do_write && aw_addr_q == A_IRQ_ST) ? (w_data_q & lane_mask(w_strb_q) & M_IRQ)
                                                       : '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_irq_en <= '0;  r_irq_st <= '0;  r_dims   <= '0;
      r_abase  <= '0;  r_astr   <= '0;  r_bbase  <= '0;  r_bstr <= '0;
      r_cbase  <= '0;  r_cstr   <= '0;  r_qcfg   <= '0;  r_qscale <= '0;
      start    <= 1'b0;
    end else begin
      start <= do_write && aw_addr_q == A_CTRL && w_strb_q[0] && w_data_q[0];

      if (do_write) begin
        case (aw_addr_q)
          A_IRQ_EN: r_irq_en <= merge(r_irq_en, w_data_q, w_strb_q, M_IRQ);
          A_DIMS:   r_dims   <= merge(r_dims,   w_data_q, w_strb_q, M_DIMS);
          A_ABASE:  r_abase  <= merge(r_abase,  w_data_q, w_strb_q, '1);
          A_ASTR:   r_astr   <= merge(r_astr,   w_data_q, w_strb_q, M_16);
          A_BBASE:  r_bbase  <= merge(r_bbase,  w_data_q, w_strb_q, '1);
          A_BSTR:   r_bstr   <= merge(r_bstr,   w_data_q, w_strb_q, M_16);
          A_CBASE:  r_cbase  <= merge(r_cbase,  w_data_q, w_strb_q, '1);
          A_CSTR:   r_cstr   <= merge(r_cstr,   w_data_q, w_strb_q, M_16);
          A_QCFG:   r_qcfg   <= merge(r_qcfg,   w_data_q, w_strb_q, M_QCFG);
          A_QSCALE: r_qscale <= merge(r_qscale, w_data_q, w_strb_q, M_16);
          default: ;
        endcase
      end

      // W1C, with a same-cycle hardware event winning over the clear
      r_irq_st <= (r_irq_st & ~irq_clr) | {30'b0, evt_err, evt_done};
    end
  end

  // ---------------------------------------------------------------- read channel
  logic [31:0] rd_data;
  logic [1:0]  rd_resp;

  always_comb begin
    rd_resp = 2'b00;
    case ({s_axil_araddr[7:2], 2'b00})
      A_CTRL:   rd_data = '0;
      A_STATUS: rd_data = {24'b0, err_code, 3'b0, busy};
      A_IRQ_EN: rd_data = r_irq_en;
      A_IRQ_ST: rd_data = r_irq_st;
      A_DIMS:   rd_data = r_dims;
      A_ABASE:  rd_data = r_abase;
      A_ASTR:   rd_data = r_astr;
      A_BBASE:  rd_data = r_bbase;
      A_BSTR:   rd_data = r_bstr;
      A_CBASE:  rd_data = r_cbase;
      A_CSTR:   rd_data = r_cstr;
      A_CYCLES: rd_data = cycles;
      A_VER:    rd_data = VERSION;
      A_QCFG:   rd_data = r_qcfg;
      A_QSCALE: rd_data = r_qscale;
      default: begin
        rd_data = '0;
        rd_resp = 2'b10;
      end
    endcase
  end

  assign s_axil_arready = !s_axil_rvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= '0;
      s_axil_rresp  <= 2'b00;
    end else if (s_axil_arvalid && s_axil_arready) begin
      s_axil_rvalid <= 1'b1;
      s_axil_rdata  <= rd_data;
      s_axil_rresp  <= rd_resp;
    end else if (s_axil_rvalid && s_axil_rready) begin
      s_axil_rvalid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- outputs
  assign dim_m    = r_dims[6:0];
  assign dim_n    = r_dims[14:8];
  assign dim_k    = r_dims[22:16];
  assign a_base   = r_abase;
  assign a_stride = r_astr[15:0];
  assign b_base   = r_bbase;
  assign b_stride = r_bstr[15:0];
  assign c_base   = r_cbase;
  assign c_stride = r_cstr[15:0];
  assign req_en   = r_qcfg[0];
  assign relu_en  = r_qcfg[1];
  assign shift    = r_qcfg[12:8];
  assign scale    = r_qscale[15:0];
  assign irq      = |(r_irq_st[1:0] & r_irq_en[1:0]);

  // Formal properties (formal/csr). Open-source Yosys has no `bind`, so they are included here
  // only when FORMAL is defined; simulators never see them.
`ifdef FORMAL
  `include "sa_csr_props.svh"
`endif
endmodule
