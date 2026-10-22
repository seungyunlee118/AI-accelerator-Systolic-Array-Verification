// Job phases, decoded from the controller state probe (sa_sys_if.ctrl_state). The encoding
// follows the state_t enum in rtl/sa_ctrl.sv. It is used only to aim resets at a phase and to
// report where they landed; nothing is predicted from it.
typedef enum {PH_IDLE, PH_A_LOAD, PH_B_LOAD, PH_COMPUTE, PH_C_WRITE} sa_phase_e;

function automatic sa_phase_e sa_phase_of(bit [3:0] ctrl_state);
  case (ctrl_state)
    4'd2, 4'd3:        return PH_A_LOAD;    // S_RD_A, S_RD_A_WAIT
    4'd4, 4'd5:        return PH_B_LOAD;    // S_RD_B, S_RD_B_WAIT
    4'd6, 4'd7:        return PH_COMPUTE;   // S_CLEAR, S_FEED
    4'd8, 4'd9, 4'd10: return PH_C_WRITE;   // S_WR, S_WR_WAIT, S_NEXT_TILE
    default:           return PH_IDLE;      // S_IDLE, S_CHECK
  endcase
endfunction
