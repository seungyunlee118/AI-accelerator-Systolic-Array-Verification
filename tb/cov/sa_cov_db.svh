// Bin hit counts of one simulation, so functional coverage can be merged over a whole
// regression without IMC (the lab server has none).
//
// The SystemVerilog covergroups are the coverage model. Every collector also declares each of
// its bins here (so empty bins show up as holes) and counts every hit with the same labels it
// gives the covergroup. dump() writes one "<group> <item> <bin> <hits>" line per bin, and
// sim/covmerge.py adds the files of all passing runs together.
// check() compares the coverage these counts imply with the covergroup's own number, so the
// two copies of the bin list cannot silently drift apart.
class sa_cov_db;
  protected int unsigned hits     [string];   // "group item bin" -> hits
  protected string       item_of  [string];   // "group item bin" -> "group item"
  protected string       group_of [string];   // "group item" -> group
  protected string       order    [$];        // declaration order, for a readable dump

  function void declare(string grp, string item, string bin);
    string key = {grp, " ", item, " ", bin};
    if (hits.exists(key)) return;
    hits[key]    = 0;
    item_of[key] = {grp, " ", item};
    group_of[{grp, " ", item}] = grp;
    order.push_back(key);
  endfunction

  function void declare_all(string grp, string item, string names[$]);
    foreach (names[i]) declare(grp, item, names[i]);
  endfunction

  // Cross of two or three bin lists; bins named in skip (e.g. "A*B") are ignored bins.
  function void declare_cross(string grp, string item, string a[$], string b[$], string skip[$] = {});
    foreach (a[i]) foreach (b[j]) begin
      string bin = {a[i], "*", b[j]};
      bit    ignored = 0;
      foreach (skip[s]) if (skip[s] == bin) ignored = 1;
      if (!ignored) declare(grp, item, bin);
    end
  endfunction

  function void declare_cross3(string grp, string item, string a[$], string b[$], string c[$]);
    foreach (a[i]) foreach (b[j]) foreach (c[k]) declare(grp, item, {a[i], "*", b[j], "*", c[k]});
  endfunction

  function void hit(string grp, string item, string bin);
    string key = {grp, " ", item, " ", bin};
    if (!hits.exists(key)) `uvm_error("COV_DB", {"hit on an undeclared bin (coverage model bug): ", key})
    else hits[key]++;
  endfunction

  // Coverage of one group computed the way SystemVerilog does for a covergroup with equal
  // weights: the average over its coverpoints and crosses of the fraction of bins hit.
  function real group_pct(string grp);
    real sum = 0;
    int  n   = 0;
    foreach (group_of[it]) begin
      int tot = 0, cov = 0;
      if (group_of[it] != grp) continue;
      foreach (order[k])
        if (item_of[order[k]] == it) begin
          tot++;
          if (hits[order[k]] != 0) cov++;
        end
      sum += 100.0 * cov / tot;
      n++;
    end
    return (n == 0) ? 0.0 : sum / n;
  endfunction

  function void check(string grp, real sv_pct);
    real mine = group_pct(grp);
    if (mine - sv_pct > 0.01 || sv_pct - mine > 0.01)
      `uvm_error("COV_DB", $sformatf("%s: covergroup reports %.2f%%, bin counts give %.2f%% (bin lists differ)",
                                     grp, sv_pct, mine))
    else
      `uvm_info("COV", $sformatf("%-6s %6.2f%% in this run", grp, sv_pct), UVM_LOW)
  endfunction

  function void dump(string path);
    int fd = $fopen(path, "w");
    if (fd == 0) begin
      `uvm_error("COV_DB", {"cannot write ", path})
      return;
    end
    foreach (order[i]) $fdisplay(fd, "%s %0d", order[i], hits[order[i]]);
    $fclose(fd);
  endfunction
endclass

// Names of every value of an enum type, in order (used to declare a coverpoint's bins).
class sa_enum_names #(type E = int);
  static function void get(ref string q[$]);
    E e;
    e = e.first();
    q.delete();
    do begin
      q.push_back(e.name());
      e = e.next();
    end while (e != e.first());
  endfunction
endclass
