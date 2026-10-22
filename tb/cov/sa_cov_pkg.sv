// Coverage pieces shared by the CSR and the full-chip testbenches: the bin-count database used
// for merging without IMC, and the CSR access coverage (CG-01).
package sa_cov_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*;

  `include "sa_cov_db.svh"
  `include "sa_csr_cov.svh"
endpackage
