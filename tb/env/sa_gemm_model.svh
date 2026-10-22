// Golden model of the SA-GEMM arithmetic, written from spec §6/§7 in 64-bit math.
// It shares no code with the RTL (vplan: avoid common-mode errors).
class sa_gemm_model;
  // §7 output stage for one accumulator value. Returns the value to be written.
  static function longint outq(longint acc, bit req, bit relu, int unsigned shift, longint scale);
    longint p, r;
    if (!req) return (relu && acc < 0) ? 0 : acc;
    p = acc * scale;
    r = (shift == 0) ? p : ((p + (64'sd1 <<< (shift - 1))) >>> shift);   // ties toward +inf
    if (relu && r < 0) r = 0;
    if (r > 127)  return 127;
    if (r < -128) return -128;
    return r;
  endfunction

  // Which §7 corner one element hits (for the scoreboard's corner counters, a precursor of
  // CG-03): "tie_pos", "tie_neg", "relu_zero", "sat_edge_hi" (exactly 128, the first value that
  // must clamp), "sat_edge_lo" (exactly -129), "clamp_hi", "clamp_lo", or "" (plain).
  static function string corner(longint acc, bit req, bit relu, int unsigned shift, longint scale);
    longint p, r;
    if (!req) return (relu && acc < 0) ? "relu_zero" : "";
    p = acc * scale;
    if (shift != 0 && (p & ((64'sd1 <<< shift) - 1)) == (64'sd1 <<< (shift - 1)))
      return (p < 0) ? "tie_neg" : "tie_pos";
    r = (shift == 0) ? p : ((p + (64'sd1 <<< (shift - 1))) >>> shift);
    if (relu && r < 0) return "relu_zero";
    if (r == 128)      return "sat_edge_hi";
    if (r == -129)     return "sat_edge_lo";
    if (r > 127)       return "clamp_hi";
    if (r < -128)      return "clamp_lo";
    return "";
  endfunction
endclass
