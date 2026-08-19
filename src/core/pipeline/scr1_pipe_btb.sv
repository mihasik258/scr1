/// @file       <scr1_pipe_btb.sv>
/// @brief      Branch Target Buffer (BTB)
///
// Functionality:
// - Directly-mapped, tagged cache of taken-branch targets, indexed by fetch PC
// - Trained by the EXU on resolved taken direct branches/jumps
//
// Index/tag (shared by read and train ports):
//   idx = pc[SCR1_BTB_IDX_W+1 : 2]
//   tag = pc[XLEN-1 : SCR1_BTB_IDX_W+2]

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
    output  logic                       btb_safe_o,         // branch ends on a fetch-word boundary
    output  logic                       btb_is_cond_o,      // entry is a conditional branch
    output  logic                       btb_rvclo_o,        // entry is an RVC branch in the low half (rvc_low)
    output  logic [SCR1_BP_BHT_IDX_W-1:0] btb_bht_index_o,  // BHT index of this branch

    // Train port: pulse on a resolved TAKEN direct branch/jump
    input   logic                       btb_upd_vd_i,       // one-shot at retire
    input   logic [`SCR1_XLEN-1:0]      btb_upd_pc_i,       // PC of the branch/jump
    input   logic [`SCR1_XLEN-1:0]      btb_upd_target_i,   // resolved taken target
    input   logic                       btb_upd_safe_i,     // branch ends on a word boundary
    input   logic                       btb_upd_is_cond_i,  // resolved transfer is a conditional branch
    input   logic                       btb_upd_rvclo_i     // branch is an RVC in the low half (rvc_low)
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

// Entry storage: valid vector + tag/target/safe/is_cond/bht_index arrays
logic [SCR1_BTB_SIZE-1:0]           valid_q;
logic [SCR1_BTB_TAG_W-1:0]          tag_q    [SCR1_BTB_SIZE];
logic [`SCR1_XLEN-1:0]              target_q [SCR1_BTB_SIZE];
logic [SCR1_BTB_SIZE-1:0]           safe_q;
logic [SCR1_BTB_SIZE-1:0]           is_cond_q;
logic [SCR1_BTB_SIZE-1:0]           rvclo_q;
logic [SCR1_BP_BHT_IDX_W-1:0]       bht_index_q [SCR1_BTB_SIZE];

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        valid_q <= '0;
    end else if (btb_upd_vd_i) begin
        valid_q[wr_idx] <= 1'b1;
    end
end

// Tag/target/safe/is_cond/bht_index memory (no reset)
always_ff @(posedge clk) begin
    if (btb_upd_vd_i) begin
        tag_q[wr_idx]       <= wr_tag;
        target_q[wr_idx]    <= btb_upd_target_i;
        safe_q[wr_idx]      <= btb_upd_safe_i;
        is_cond_q[wr_idx]   <= btb_upd_is_cond_i;
        rvclo_q[wr_idx]     <= btb_upd_rvclo_i;
        bht_index_q[wr_idx] <= btb_upd_pc_i[SCR1_BP_BHT_IDX_W:1];
    end
end

assign btb_hit_o       = valid_q[rd_idx] & (tag_q[rd_idx] == rd_tag);
assign btb_target_o    = target_q[rd_idx];
assign btb_safe_o      = safe_q[rd_idx];
assign btb_is_cond_o   = is_cond_q[rd_idx];
assign btb_rvclo_o     = rvclo_q[rd_idx];
assign btb_bht_index_o = bht_index_q[rd_idx];

endmodule : scr1_pipe_btb

`endif // SCR1_BP_BTB
