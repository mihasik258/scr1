/// SCR1 early Branch Target Buffer (BTB)
/// @file       <scr1_pipe_btb.sv>
/// @brief      Directly-mapped, fetch-PC-indexed cache of taken-branch targets.
///
/// Design follows the CBTB concept from Martinez Aceves, "Implementation and
/// evaluation of Branch Predictors on RISC-V" (ch03): a directly-mapped array
/// of {valid, target} entries indexed by a PC slice, trained on resolved taken
/// branches/jumps, with NO speculative state -> no recovery logic needed. The
/// EXU remains the correctness authority; a wrong/aliased BTB entry only costs
/// a mispredict, never a functional error.
///
/// Index function is shared by the read and train ports:
///   idx = pc[SCR1_BTB_IDX_W+1 : 2]      (word-aligned, drops the 2 byte LSBs)
/// so the fetch address, the queue-head PC, and the trained branch PC all map a
/// given static branch to the same entry.
///
/// Stage B1: read for measurement only (does not steer fetch).

`include "scr1_arch_description.svh"

`ifdef SCR1_BP_BTB

module scr1_pipe_btb #(
    parameter int unsigned SCR1_BTB_SIZE  = 256,
    parameter int unsigned SCR1_BTB_IDX_W = 8
) (
    input   logic                       clk,
    input   logic                       rst_n,

    // Read / query port (fetch PC or queue-head PC)
    input   logic [`SCR1_XLEN-1:0]      btb_query_pc_i,
    output  logic                       btb_hit_o,          // entry valid for this index
    output  logic [`SCR1_XLEN-1:0]      btb_target_o,       // cached target
    output  logic                       btb_safe_o,         // branch ends on a fetch-word boundary (safe to steer)
    output  logic                       btb_is_cond_o,      // entry is a conditional branch (else unconditional jump)
    output  logic [SCR1_BP_BHT_IDX_W-1:0] btb_bht_index_o,  // BHT index of this branch (for the fetch-side gate)

    // Train port: pulse on a resolved TAKEN direct branch/jump
    input   logic                       btb_upd_vd_i,       // one-shot at retire
    input   logic [`SCR1_XLEN-1:0]      btb_upd_pc_i,       // PC of the branch/jump
    input   logic [`SCR1_XLEN-1:0]      btb_upd_target_i,   // resolved taken target
    input   logic                       btb_upd_safe_i,     // branch ends on a word boundary
    input   logic                       btb_upd_is_cond_i   // resolved transfer is a conditional branch
);

localparam int unsigned SCR1_BTB_TAG_W = `SCR1_XLEN - (SCR1_BTB_IDX_W + 2);

logic [SCR1_BTB_IDX_W-1:0]          rd_idx;
logic [SCR1_BTB_IDX_W-1:0]          wr_idx;
logic [SCR1_BTB_TAG_W-1:0]          rd_tag;
logic [SCR1_BTB_TAG_W-1:0]          wr_tag;

// Shared index/tag functions (word-aligned PC slice)
assign rd_idx = btb_query_pc_i[SCR1_BTB_IDX_W+1:2];
assign wr_idx = btb_upd_pc_i  [SCR1_BTB_IDX_W+1:2];
assign rd_tag = btb_query_pc_i[`SCR1_XLEN-1:SCR1_BTB_IDX_W+2];
assign wr_tag = btb_upd_pc_i  [`SCR1_XLEN-1:SCR1_BTB_IDX_W+2];

// Storage: packed valid vector + tag + target arrays. The tag makes a fetch-PC
// lookup an exact match (kills false hits from index aliasing across the code),
// which is required before the BTB is allowed to steer the fetch stream (B2).
// (packed valid_q reset with <='0 in one shot: verilator rejects non-blocking
//  array writes inside a for-loop reset - BLKLOOPINIT - as learned for the BHT.)
logic [SCR1_BTB_SIZE-1:0]           valid_q;
logic [SCR1_BTB_TAG_W-1:0]          tag_q    [SCR1_BTB_SIZE];
logic [`SCR1_XLEN-1:0]              target_q [SCR1_BTB_SIZE];
logic [SCR1_BTB_SIZE-1:0]           safe_q;
logic [SCR1_BTB_SIZE-1:0]           is_cond_q;
logic [SCR1_BP_BHT_IDX_W-1:0]       bht_index_q [SCR1_BTB_SIZE];

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        valid_q <= '0;
    end else if (btb_upd_vd_i) begin
        valid_q[wr_idx] <= 1'b1;
    end
end

// Tag + target + safe + is_cond + bht_index memory (no reset: read only where valid_q set)
// The branch's own BHT index is derived from its PC and stored, so the fetch-side
// gate can read the BHT at exactly this branch's index without knowing pc[1] early.
always_ff @(posedge clk) begin
    if (btb_upd_vd_i) begin
        tag_q[wr_idx]       <= wr_tag;
        target_q[wr_idx]    <= btb_upd_target_i;
        safe_q[wr_idx]      <= btb_upd_safe_i;
        is_cond_q[wr_idx]   <= btb_upd_is_cond_i;
        bht_index_q[wr_idx] <= btb_upd_pc_i[SCR1_BP_BHT_IDX_W:1];
    end
end

assign btb_hit_o       = valid_q[rd_idx] & (tag_q[rd_idx] == rd_tag);
assign btb_target_o    = target_q[rd_idx];
assign btb_safe_o      = safe_q[rd_idx];
assign btb_is_cond_o   = is_cond_q[rd_idx];
assign btb_bht_index_o = bht_index_q[rd_idx];

endmodule : scr1_pipe_btb

`endif // SCR1_BP_BTB
