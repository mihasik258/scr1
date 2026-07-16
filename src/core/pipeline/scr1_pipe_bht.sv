/// SCR1 Branch History Table (BHT)
/// @file       <scr1_pipe_bht.sv>
/// @brief      Direction predictor: 2-bit saturating counters indexed by PC
///
/// Adapted from OpenHW CVA6 `core/frontend/bht.sv`
///   Copyright/Contributors: OpenHW Group. Licensed under the Solderpad HW License v2.0.
///
/// Changes vs. the original CVA6 module:
///  - removed `config_pkg`/`ariane_pkg` types: plain SCR1 signals;
///  - scalarised: SCR1 fetches one instruction at a time, so the per-fetch
///    array `bht_prediction_o[INSTR_PER_FETCH-1:0]` collapses to a single
///    {valid, taken} output;
///  - register-based storage (no macro RAM): fine for the small table on a
///    slow MCU-class core, and gives a simple synchronous reset of valid bits;
///  - SCR1 naming.
///
/// Functionality (unchanged from CVA6): each entry is a 2-bit saturating
/// counter plus a valid bit. The counter MSB is the predicted direction
/// (1x -> taken, 0x -> not-taken). `valid` tells the caller whether the entry
/// has ever been trained, so an untrained entry can fall back to static BTFN.
/// Updates come from the execution stage on every resolved conditional branch.

`include "scr1_arch_description.svh"

module scr1_pipe_bht #(
    parameter int unsigned SCR1_BHT_SIZE  = 1024,               // number of entries
    parameter int unsigned SCR1_BHT_IDX_W = 10                  // = $clog2(SCR1_BHT_SIZE)
) (
    input   logic                       clk,
    input   logic                       rst_n,

    // Read port (combinational), indexed at fetch by the shadow PC
    input   logic [SCR1_BHT_IDX_W-1:0]  bht_rindex_i,           // read index
    output  logic                       bht_valid_o,            // entry has been trained
    output  logic                       bht_taken_o,            // predicted direction (counter MSB)

    // Update port, driven by the execution stage on a resolved branch
    input   logic                       bht_upd_vd_i,           // update this cycle
    input   logic [SCR1_BHT_IDX_W-1:0]  bht_upd_index_i,        // index to update
    input   logic                       bht_upd_taken_i         // actual taken outcome
);

// Entry storage as packed vectors so the whole table resets in one statement
// (no for-loop reset, which some tools reject for arrays).
//   valid_q[i]      - entry i has been trained
//   sat_q[i][1:0]   - 2-bit saturating counter, MSB = predicted direction
logic [SCR1_BHT_SIZE-1:0]        valid_q;
logic [SCR1_BHT_SIZE-1:0][1:0]   sat_q;

logic [1:0]                      sat_cur;

// Read (untrained entries report valid=0 -> caller uses BTFN fallback)
assign bht_valid_o = valid_q[bht_rindex_i];
assign bht_taken_o = sat_q[bht_rindex_i][1];

assign sat_cur = sat_q[bht_upd_index_i];

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        valid_q <= '0;
        sat_q   <= '0;
    end else if (bht_upd_vd_i) begin
        valid_q[bht_upd_index_i] <= 1'b1;
        if (~valid_q[bht_upd_index_i]) begin
            // First observation: jump the counter to weakly match the outcome,
            // so the next prediction already tracks it (learn in one step).
            sat_q[bht_upd_index_i] <= bht_upd_taken_i ? 2'b10 : 2'b01;
        end else if (bht_upd_taken_i) begin
            if (sat_cur != 2'b11) sat_q[bht_upd_index_i] <= sat_cur + 2'b01;
        end else begin
            if (sat_cur != 2'b00) sat_q[bht_upd_index_i] <= sat_cur - 2'b01;
        end
    end
end

endmodule : scr1_pipe_bht
