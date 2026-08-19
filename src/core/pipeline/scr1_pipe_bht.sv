/// @file       <scr1_pipe_bht.sv>
/// @brief      Branch History Table (BHT): 2-bit saturating counters indexed by PC
///
/// Adapted from OpenHW CVA6 `core/frontend/bht.sv`
///   Copyright/Contributors: OpenHW Group. Licensed under the Solderpad HW License v2.0.
///
// Functionality:
// - Each entry: 2-bit saturating counter + valid bit; counter MSB = direction
// - valid=0 (untrained) lets the caller fall back to static BTFN
// - Updated by the execution stage on every resolved conditional branch

`include "scr1_arch_description.svh"

module scr1_pipe_bht #(
    parameter int unsigned SCR1_BHT_SIZE  = 1024,               // number of entries
    parameter int unsigned SCR1_BHT_IDX_W = 10                  // = $clog2(SCR1_BHT_SIZE)
) (
    input   logic                       clk,
    input   logic                       rst_n,

    // Read port (combinational)
    input   logic [SCR1_BHT_IDX_W-1:0]  bht_rindex_i,           // read index
    output  logic                       bht_valid_o,            // entry has been trained
    output  logic                       bht_taken_o,            // predicted direction (counter MSB)

    // Second read port (combinational), for the fetch-side steer gate
    input   logic [SCR1_BHT_IDX_W-1:0]  bht_rindex2_i,          // read index
    output  logic                       bht_valid2_o,           // entry has been trained
    output  logic                       bht_taken2_o,           // predicted direction

    // Update port, driven by the execution stage on a resolved branch
    input   logic                       bht_upd_vd_i,           // update this cycle
    input   logic [SCR1_BHT_IDX_W-1:0]  bht_upd_index_i,        // index to update
    input   logic                       bht_upd_taken_i         // actual taken outcome
);

// Entry storage (packed vectors)
//   valid_q[i]      - entry i has been trained
//   sat_q[i][1:0]   - 2-bit saturating counter, MSB = predicted direction
logic [SCR1_BHT_SIZE-1:0]        valid_q;
logic [SCR1_BHT_SIZE-1:0][1:0]   sat_q;

logic [1:0]                      sat_cur;

// Read (untrained entries report valid=0)
assign bht_valid_o = valid_q[bht_rindex_i];
assign bht_taken_o = sat_q[bht_rindex_i][1];

// Second (fetch-side) read port
assign bht_valid2_o = valid_q[bht_rindex2_i];
assign bht_taken2_o = sat_q[bht_rindex2_i][1];

assign sat_cur = sat_q[bht_upd_index_i];

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        valid_q <= '0;
        sat_q   <= '0;
    end else if (bht_upd_vd_i) begin
        valid_q[bht_upd_index_i] <= 1'b1;
        if (~valid_q[bht_upd_index_i]) begin
            // First observation: jump to the weak state matching the outcome
            sat_q[bht_upd_index_i] <= bht_upd_taken_i ? 2'b10 : 2'b01;
        end else if (bht_upd_taken_i) begin
            if (sat_cur != 2'b11) sat_q[bht_upd_index_i] <= sat_cur + 2'b01;
        end else begin
            if (sat_cur != 2'b00) sat_q[bht_upd_index_i] <= sat_cur - 2'b01;
        end
    end
end

endmodule : scr1_pipe_bht
