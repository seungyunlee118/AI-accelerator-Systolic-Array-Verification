// N x N output-stationary systolic array.
// Row i receives a_west[i] and column j receives b_north[j]; the caller applies the skew
// (row i delayed by i steps, column j delayed by j steps). After K + 2N - 2 enabled steps,
// c_out[i][j] holds sum_k a_row_i[k] * b_col_j[k].
module sa_array #(
  parameter int N      = 4,
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32
)(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     clear,
  input  logic                     en,
  input  logic signed [DATA_W-1:0] a_west  [N],
  input  logic signed [DATA_W-1:0] b_north [N],
  output logic signed [ACC_W-1:0]  c_out   [N][N]
);
  // a_h[i][j] feeds PE(i,j) from the west; b_v[i][j] feeds PE(i,j) from the north.
  wire signed [DATA_W-1:0] a_h [N][N+1];
  wire signed [DATA_W-1:0] b_v [N+1][N];

  for (genvar i = 0; i < N; i++) begin : g_edge
    assign a_h[i][0] = a_west[i];
    assign b_v[0][i] = b_north[i];
  end

  for (genvar i = 0; i < N; i++) begin : g_row
    for (genvar j = 0; j < N; j++) begin : g_col
      sa_pe #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_pe (
        .clk   (clk),
        .rst_n (rst_n),
        .clear (clear),
        .en    (en),
        .a_in  (a_h[i][j]),
        .b_in  (b_v[i][j]),
        .a_out (a_h[i][j+1]),
        .b_out (b_v[i+1][j]),
        .acc   (c_out[i][j])
      );
    end
  end
endmodule
