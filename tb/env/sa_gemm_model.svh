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
endclass
