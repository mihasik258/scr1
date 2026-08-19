/// @file       <scr1_pipe_ras.sv>
/// @brief      Return Address Stack (RAS) for return target prediction
///
/// Adapted from OpenHW CVA6 `core/frontend/ras.sv`
///   Copyright/Contributors: OpenHW Group. Licensed under the Solderpad HW License v2.0.
///
// Functionality:
// - Shift-register stack: a call pushes the return address, a return pops it
// - Top entry is the predicted return target; flush clears the whole stack

`include "scr1_arch_description.svh"

module scr1_pipe_ras #(
    parameter int unsigned SCR1_RAS_DEPTH = 4
) (
    input   logic                       clk,
    input   logic                       rst_n,
    input   logic                       ras_flush_i,    // clear the whole stack
    input   logic                       ras_push_i,     // call:   push ras_data_i
    input   logic                       ras_pop_i,      // return: pop the top
    input   logic [`SCR1_XLEN-1:0]      ras_data_i,     // return address to push
    output  logic                       ras_valid_o,    // top entry is valid
    output  logic [`SCR1_XLEN-1:0]      ras_data_o      // top entry (predicted return target)
);

typedef struct packed {
    logic                  valid;
    logic [`SCR1_XLEN-1:0] ra;
} type_scr1_ras_entry_s;

type_scr1_ras_entry_s [SCR1_RAS_DEPTH-1:0] stack_q;
type_scr1_ras_entry_s [SCR1_RAS_DEPTH-1:0] stack_d;

// Current top of stack is the prediction
assign ras_valid_o = stack_q[0].valid;
assign ras_data_o  = stack_q[0].ra;

always_comb begin
    stack_d = stack_q;

    if (ras_push_i) begin
        stack_d[0].ra                       = ras_data_i;
        stack_d[0].valid                    = 1'b1;
        stack_d[SCR1_RAS_DEPTH-1:1]         = stack_q[SCR1_RAS_DEPTH-2:0];
    end

    if (ras_pop_i) begin
        stack_d[SCR1_RAS_DEPTH-2:0]         = stack_q[SCR1_RAS_DEPTH-1:1];
        stack_d[SCR1_RAS_DEPTH-1].valid     = 1'b0;
        stack_d[SCR1_RAS_DEPTH-1].ra        = '0;
    end

    // Simultaneous pop+push: replace the top
    if (ras_pop_i && ras_push_i) begin
        stack_d          = stack_q;
        stack_d[0].ra    = ras_data_i;
        stack_d[0].valid = 1'b1;
    end

    // Flush (highest priority)
    if (ras_flush_i) begin
        stack_d = '0;
    end
end

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        stack_q <= '0;
    end else begin
        stack_q <= stack_d;
    end
end

endmodule : scr1_pipe_ras
