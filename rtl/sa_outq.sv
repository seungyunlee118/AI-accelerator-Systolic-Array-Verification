// Output stage (spec §7): optional ReLU, optional requantization to INT8.
// Purely combinational; out32 is used when req_en = 0, out8 when req_en = 1.
module sa_outq (
  input  logic signed [31:0] acc,
  input  logic               req_en,
  input  logic               relu_en,
  input  logic [4:0]         shift,
  input  logic [15:0]        scale,
  output logic [31:0]        out32,
  output logic [7:0]         out8
);
  logic signed [48:0] p, r;

  always_comb begin
    // INT32 path
    out32 = (relu_en && acc < 0) ? 32'd0 : acc;

    // INT8 path
    p = acc * $signed({1'b0, scale});                  // exact: |p| < 2**47
    if (shift == 5'd0) r = p;
    else               r = (p + (49'sd1 <<< (shift - 5'd1))) >>> shift;
    if (relu_en && r < 0) r = '0;

    if      (r > 49'sd127)  out8 = 8'h7F;
    else if (r < -49'sd128) out8 = 8'h80;
    else                    out8 = r[7:0];

    if (!req_en) out8 = '0;  // unused in INT32 mode
  end
endmodule
