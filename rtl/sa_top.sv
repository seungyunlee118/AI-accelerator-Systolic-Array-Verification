// SA-GEMM top level (spec §3): CSR block, controller, DMA read and write engines.
// The AXI4 master port is shared: AR/R come from the read engine, AW/W/B from the write engine.
module sa_top #(
  parameter int ARRAY_N = 4
)(
  input  logic        clk,
  input  logic        rst_n,

  // AXI4-Lite slave (CSR)
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

  // AXI4 master (DMA)
  output logic [3:0]  m_axi_awid,
  output logic [31:0] m_axi_awaddr,
  output logic [7:0]  m_axi_awlen,
  output logic [2:0]  m_axi_awsize,
  output logic [1:0]  m_axi_awburst,
  output logic        m_axi_awvalid,
  input  logic        m_axi_awready,
  output logic [63:0] m_axi_wdata,
  output logic [7:0]  m_axi_wstrb,
  output logic        m_axi_wlast,
  output logic        m_axi_wvalid,
  input  logic        m_axi_wready,
  input  logic [3:0]  m_axi_bid,
  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,
  output logic [3:0]  m_axi_arid,
  output logic [31:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [3:0]  m_axi_rid,
  input  logic [63:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready,

  output logic        irq
);
  // CSR <-> controller
  logic        start, busy, evt_done, evt_err, req_en, relu_en;
  logic [3:0]  err_code;
  logic [31:0] cycles, a_base, b_base, c_base;
  logic [6:0]  dim_m, dim_n, dim_k;
  logic [15:0] a_stride, b_stride, c_stride, scale;
  logic [4:0]  shift;

  // controller <-> DMA
  logic                   rd_cmd_valid, rd_cmd_ready, rd_cmd_sel, rd_done, rd_err;
  logic [31:0]            rd_cmd_base;
  logic [15:0]            rd_cmd_stride;
  logic [6:0]             rd_cmd_rows, rd_cmd_row_len;
  logic                   buf_we, buf_sel;
  logic [5:0]             buf_row;
  logic [2:0]             buf_beat;
  logic [63:0]            buf_data;
  logic                   wr_cmd_valid, wr_cmd_ready, wr_done, wr_err;
  logic [31:0]            wr_cmd_addr;
  logic [5:0]             wr_cmd_nbytes;
  logic [32*ARRAY_N-1:0]  wr_cmd_data;

  sa_csr u_csr (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .start, .busy, .err_code, .evt_done, .evt_err, .cycles,
    .dim_m, .dim_n, .dim_k, .a_base, .a_stride, .b_base, .b_stride, .c_base, .c_stride,
    .req_en, .relu_en, .shift, .scale, .irq
  );

  sa_ctrl #(.AN(ARRAY_N)) u_ctrl (
    .clk, .rst_n,
    .start, .dim_m, .dim_n, .dim_k, .a_base, .a_stride, .b_base, .b_stride, .c_base, .c_stride,
    .req_en, .relu_en, .shift, .scale,
    .busy, .err_code, .evt_done, .evt_err, .cycles,
    .rd_cmd_valid, .rd_cmd_ready, .rd_cmd_base, .rd_cmd_stride, .rd_cmd_rows, .rd_cmd_row_len,
    .rd_cmd_sel, .rd_done, .rd_err,
    .buf_we, .buf_sel, .buf_row, .buf_beat, .buf_data,
    .wr_cmd_valid, .wr_cmd_ready, .wr_cmd_addr, .wr_cmd_nbytes, .wr_cmd_data, .wr_done, .wr_err
  );

  sa_dma_rd u_dma_rd (
    .clk, .rst_n,
    .cmd_valid   (rd_cmd_valid),
    .cmd_ready   (rd_cmd_ready),
    .cmd_base    (rd_cmd_base),
    .cmd_stride  (rd_cmd_stride),
    .cmd_rows    (rd_cmd_rows),
    .cmd_row_len (rd_cmd_row_len),
    .cmd_sel     (rd_cmd_sel),
    .done        (rd_done),
    .err         (rd_err),
    .buf_we, .buf_sel, .buf_row, .buf_beat, .buf_data,
    .m_axi_arid, .m_axi_araddr, .m_axi_arlen, .m_axi_arsize, .m_axi_arburst,
    .m_axi_arvalid, .m_axi_arready,
    .m_axi_rid, .m_axi_rdata, .m_axi_rresp, .m_axi_rlast, .m_axi_rvalid, .m_axi_rready
  );

  sa_dma_wr #(.MAX_BYTES(4 * ARRAY_N)) u_dma_wr (
    .clk, .rst_n,
    .cmd_valid  (wr_cmd_valid),
    .cmd_ready  (wr_cmd_ready),
    .cmd_addr   (wr_cmd_addr),
    .cmd_nbytes (wr_cmd_nbytes),
    .cmd_data   (wr_cmd_data),
    .done       (wr_done),
    .err        (wr_err),
    .m_axi_awid, .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
    .m_axi_awvalid, .m_axi_awready,
    .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
    .m_axi_bid, .m_axi_bresp, .m_axi_bvalid, .m_axi_bready
  );
endmodule
