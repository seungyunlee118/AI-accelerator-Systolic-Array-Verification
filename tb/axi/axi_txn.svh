// One complete AXI4 burst as observed by the monitor (read or write).
typedef enum bit {AXI_READ, AXI_WRITE} axi_dir_e;

class axi_txn extends uvm_sequence_item;
  `uvm_object_utils(axi_txn)

  axi_dir_e    dir;
  bit [3:0]    id;
  bit [31:0]   addr;
  bit [7:0]    len;            // beats - 1
  bit [63:0]   data[$];
  bit [7:0]    strb[$];        // writes only
  bit [1:0]    resp;           // worst response of the burst
  int unsigned outstanding;    // reads only: bursts in flight when this AR was accepted
  bit          out_of_order;   // reads only: finished before an older read burst
  bit          interleaved;    // reads only: another ID's beat arrived in the middle of it

  function new(string name = "axi_txn");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("%s id=%0d addr=%08h beats=%0d resp=%0d%s%s", dir.name(), id, addr, len + 1, resp,
                     out_of_order ? " ooo" : "", interleaved ? " interleaved" : "");
  endfunction
endclass
