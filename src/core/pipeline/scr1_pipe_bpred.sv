/// SCR1 static branch predictor (BTFN)
/// @file       <scr1_pipe_bpred.sv>
/// @brief      Static branch predictor (backward-taken / forward-not-taken)
///
/// Adapted from lowRISC Ibex `ibex_branch_predict.sv`
///   Copyright lowRISC contributors. Licensed under the Apache License, Version 2.0.
///   SPDX-License-Identifier: Apache-2.0
///
/// Changes vs. the original Ibex module:
///  - removed `ibex_pkg` import: opcodes are given as RISC-V literals;
///  - removed `prim_assert.sv`: the one-hot check is a plain SVA under
///    SCR1_TRGT_SIMULATION;
///  - added phase parameters so the predictor scope matches the integration
///    milestones (M1: only JAL; M2: + conditional RVI branches; M3: + RVC);
///  - SCR1 port/signal naming.
///
/// Functionality (unchanged from Ibex): takes an instruction and its PC,
/// detects a branch/jump and computes the target. Jumps are always predicted
/// taken; conditional branches are predicted taken when the PC offset is
/// negative (backward). The block is purely combinational; clk/rst_n are used
/// only by the assertion.

`include "scr1_arch_description.svh"

module scr1_pipe_bpred #(
    parameter bit SCR1_BP_PREDICT_BRANCHES = 1'b0,  // 0 - only JAL (M1), 1 - + conditional branches (M2)
    parameter bit SCR1_BP_PREDICT_RVC      = 1'b0   // 0 - RVI only (M1/M2), 1 - + compressed (M3)
) (
    input   logic                       clk,                    // used only by assertion
    input   logic                       rst_n,                  // used only by assertion

    // Instruction presented to the decoder (from IFU queue output)
    input   logic [`SCR1_XLEN-1:0]      bp_instr_i,             // instruction bits
    input   logic [`SCR1_XLEN-1:0]      bp_pc_i,                // PC of that instruction
    input   logic                       bp_vd_i,                // instruction is valid

    // Static prediction for the supplied instruction
    output  logic                       bp_predict_taken_o,     // predicted taken
    output  logic [`SCR1_XLEN-1:0]      bp_predict_pc_o         // predicted target PC
);

// RISC-V opcodes (were ibex_pkg enums in the original)
localparam logic [6:0] SCR1_OPCODE_BRANCH = 7'b1100011;
localparam logic [6:0] SCR1_OPCODE_JAL    = 7'b1101111;

logic [`SCR1_XLEN-1:0]  imm_j_type;
logic [`SCR1_XLEN-1:0]  imm_b_type;
logic [`SCR1_XLEN-1:0]  imm_cj_type;
logic [`SCR1_XLEN-1:0]  imm_cb_type;

logic [`SCR1_XLEN-1:0]  branch_imm;

logic [`SCR1_XLEN-1:0]  instr;

logic                   instr_j;
logic                   instr_b;
logic                   instr_cj;
logic                   instr_cb;

logic                   instr_b_taken;

// Short internal name (as in Ibex)
assign instr = bp_instr_i;

// Immediate extraction (verbatim from Ibex) ----------------------------------

// Uncompressed immediates
assign imm_j_type = { {12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0 };
assign imm_b_type = { {19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0 };

// Compressed immediates
assign imm_cj_type = { {20{instr[12]}}, instr[12], instr[8], instr[10:9], instr[6], instr[7],
    instr[2], instr[11], instr[5:3], 1'b0 };
assign imm_cb_type = { {23{instr[12]}}, instr[12], instr[6:5], instr[2], instr[11:10],
    instr[4:3], 1'b0 };

// Branch / jump detection ----------------------------------------------------

// Uncompressed branch/jump
assign instr_b = (instr[6:0] == SCR1_OPCODE_BRANCH) & SCR1_BP_PREDICT_BRANCHES;
assign instr_j = (instr[6:0] == SCR1_OPCODE_JAL);

// Compressed branch/jump (gated off unless RVC phase is enabled)
assign instr_cb = SCR1_BP_PREDICT_RVC
                & (instr[1:0] == 2'b01) & ((instr[15:13] == 3'b110) | (instr[15:13] == 3'b111));
assign instr_cj = SCR1_BP_PREDICT_RVC
                & (instr[1:0] == 2'b01) & ((instr[15:13] == 3'b101) | (instr[15:13] == 3'b001));

// Select the branch offset for target calculation (verbatim from Ibex)
always_comb begin
    branch_imm = imm_b_type;
    unique case (1'b1)
        instr_j  : branch_imm = imm_j_type;
        instr_b  : branch_imm = imm_b_type;
        instr_cj : branch_imm = imm_cj_type;
        instr_cb : branch_imm = imm_cb_type;
        default  : ;
    endcase
end

// BTFN: taken if the offset is negative
assign instr_b_taken = (instr_b & imm_b_type[31]) | (instr_cb & imm_cb_type[31]);

// Jumps always taken, otherwise use instr_b_taken
assign bp_predict_taken_o = bp_vd_i & (instr_j | instr_cj | instr_b_taken);
assign bp_predict_pc_o    = bp_pc_i + branch_imm;

`ifdef SCR1_TRGT_SIMULATION
SCR1_SVA_BPRED_ONEHOT : assert property (
    @(negedge clk) disable iff (~rst_n)
    bp_vd_i |-> $onehot0({instr_j, instr_b, instr_cj, instr_cb})
    ) else $error("BPRED Error: instruction type not one-hot");
`endif // SCR1_TRGT_SIMULATION

endmodule : scr1_pipe_bpred
