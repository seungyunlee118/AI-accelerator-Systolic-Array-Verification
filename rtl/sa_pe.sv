// Output-stationary processing element: acc += a_in * b_in, then forwards a (east) and b (south).
module sa_pe #(
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32
)(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     clear,   // synchronous: zero accumulator and forwarding regs
  input  logic                     en,      // advance one step; when low, all state holds
  input  logic signed [DATA_W-1:0] a_in,
  input  logic signed [DATA_W-1:0] b_in,
  output logic signed [DATA_W-1:0] a_out,
  output logic signed [DATA_W-1:0] b_out,
  output logic signed [ACC_W-1:0]  acc
);
  logic signed [2*DATA_W-1:0] prod;
  assign prod = a_in * b_in;   // exact signed product

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (clear) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (en) begin
      a_out <= a_in;
      b_out <= b_in;
      acc   <= acc + prod;   // prod is sign-extended to ACC_W
    end
  end
endmodule
