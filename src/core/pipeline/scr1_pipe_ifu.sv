/// Copyright by Syntacore LLC © 2016-2021. See LICENSE for details
/// @file       <scr1_pipe_ifu.sv>
/// @brief      Instruction Fetch Unit (IFU)
///

//------------------------------------------------------------------------------
 //
 // Functionality:
 // - Controls instruction fetching process:
 //   - Fetches instructions either from IMEM or from Program Buffer, supporting
 //     pending IMEM instructions handling
 //   - Handles new PC misalignment and constructs the correct instruction (supports
 //     RVI and RVC instructions)
 //   - Either stores instructions in the instruction queue or bypasses to the
 //     IDU if the corresponding option is used
 //   - Flushes instruction queue if requested
 //
 // Structure:
 // - Instruction queue
 // - IFU FSM
 // - IFU <-> IMEM i/f
 // - IFU <-> IDU i/f
 // - IFU <-> HDU i/f
 //
//------------------------------------------------------------------------------

`include "scr1_memif.svh"
`include "scr1_arch_description.svh"
`ifdef SCR1_DBG_EN
`include "scr1_hdu.svh"
`endif // SCR1_DBG_EN

module scr1_pipe_ifu
(
    // Control signals
    input   logic                                   rst_n,                      // IFU reset
    input   logic                                   clk,                        // IFU clock
    input   logic                                   pipe2ifu_stop_fetch_i,      // Stop instruction fetch

    // IFU <-> IMEM interface
    input   logic                                   imem2ifu_req_ack_i,         // Instruction memory request acknowledgement
    output  logic                                   ifu2imem_req_o,             // Instruction memory request
    output  type_scr1_mem_cmd_e                     ifu2imem_cmd_o,             // Instruction memory command (READ/WRITE)
    output  logic [`SCR1_IMEM_AWIDTH-1:0]           ifu2imem_addr_o,            // Instruction memory address
    input   logic [`SCR1_IMEM_DWIDTH-1:0]           imem2ifu_rdata_i,           // Instruction memory read data
    input   type_scr1_mem_resp_e                    imem2ifu_resp_i,            // Instruction memory response

    // IFU <-> EXU New PC interface
    input   logic                                   exu2ifu_pc_new_req_i,       // New PC request (jumps, branches, traps etc)
    input   logic [`SCR1_XLEN-1:0]                  exu2ifu_pc_new_i,           // New PC

`ifdef SCR1_DBG_EN
    // IFU <-> HDU Program Buffer interface
    input   logic                                   hdu2ifu_pbuf_fetch_i,       // Fetch instructions provided by Program Buffer
    output  logic                                   ifu2hdu_pbuf_rdy_o,         // Program Buffer Instruction i/f ready
    input   logic                                   hdu2ifu_pbuf_vd_i,          // Program Buffer Instruction valid
    input   logic                                   hdu2ifu_pbuf_err_i,         // Program Buffer Instruction i/f error
    input   logic [SCR1_HDU_CORE_INSTR_WIDTH-1:0]   hdu2ifu_pbuf_instr_i,       // Program Buffer Instruction itself
`endif // SCR1_DBG_EN

`ifdef SCR1_CLKCTRL_EN
    output  logic                                   ifu2pipe_imem_txns_pnd_o,   // There are pending imem transactions
`endif // SCR1_CLKCTRL_EN

    // IFU <-> IDU interface
    input   logic                                   idu2ifu_rdy_i,              // IDU ready for new data
    output  logic [`SCR1_IMEM_DWIDTH-1:0]           ifu2idu_instr_o,            // IFU instruction
    output  logic                                   ifu2idu_imem_err_o,         // Instruction access fault exception
    output  logic                                   ifu2idu_err_rvi_hi_o,       // 1 - imem fault when trying to fetch second half of an unaligned RVI instruction
    output  logic                                   ifu2idu_vd_o                // IFU request
`ifdef SCR1_BP_RAS_EN
    ,
    // IFU -> EXU RAS prediction (return target), aligned with the instruction
    output  logic                                   ifu2exu_bp_ras_vd_o,        // this instr is a predicted return
    output  logic [`SCR1_XLEN-1:0]                  ifu2exu_bp_ras_target_o     // predicted return target (RAS top)
`endif // SCR1_BP_RAS_EN
`ifdef SCR1_BP_DYNAMIC
    ,
    // IFU -> EXU: dynamic-predictor metadata carried with the instruction (D0)
    output  logic                                   ifu2exu_bp_predicted_taken_o, // direction predicted for this instr
    output  logic [SCR1_BP_BHT_IDX_W-1:0]           ifu2exu_bp_index_o,           // BHT index used at fetch (for training)
    // EXU -> IFU: BHT training channel (D0: connected but not yet consumed here)
    input   logic                                   exu2ifu_bp_upd_vd_i,          // a conditional branch resolved
    input   logic [SCR1_BP_BHT_IDX_W-1:0]           exu2ifu_bp_upd_index_i,       // BHT index to update
    input   logic                                   exu2ifu_bp_upd_taken_i        // actual taken outcome
`endif // SCR1_BP_DYNAMIC
`ifdef SCR1_BP_BTB
    ,
    // EXU -> IFU: early-BTB training channel (resolved taken direct branch/jump)
    input   logic                                   exu2ifu_bp_btb_upd_vd_i,      // train pulse
    input   logic [`SCR1_XLEN-1:0]                  exu2ifu_bp_btb_upd_pc_i,      // branch/jump PC
    input   logic [`SCR1_XLEN-1:0]                  exu2ifu_bp_btb_upd_target_i,  // resolved taken target
    input   logic                                   exu2ifu_bp_btb_upd_safe_i     // branch ends on word boundary
`endif // SCR1_BP_BTB
);

//------------------------------------------------------------------------------
// Local parameters declaration
//------------------------------------------------------------------------------

localparam SCR1_IFU_Q_SIZE_WORD     = 2;
localparam SCR1_IFU_Q_SIZE_HALF     = SCR1_IFU_Q_SIZE_WORD * 2;
localparam SCR1_TXN_CNT_W           = 3;

localparam SCR1_IFU_QUEUE_ADR_W     = $clog2(SCR1_IFU_Q_SIZE_HALF);
localparam SCR1_IFU_QUEUE_PTR_W     = SCR1_IFU_QUEUE_ADR_W + 1;

localparam SCR1_IFU_Q_FREE_H_W      = $clog2(SCR1_IFU_Q_SIZE_HALF + 1);
localparam SCR1_IFU_Q_FREE_W_W      = $clog2(SCR1_IFU_Q_SIZE_WORD + 1);

//------------------------------------------------------------------------------
// Local types declaration
//------------------------------------------------------------------------------

typedef enum logic {
    SCR1_IFU_FSM_IDLE,
    SCR1_IFU_FSM_FETCH
} type_scr1_ifu_fsm_e;

typedef enum logic[1:0] {
    SCR1_IFU_QUEUE_WR_NONE,      // No write to queue
    SCR1_IFU_QUEUE_WR_FULL,      // Write 32 rdata bits to queue
    SCR1_IFU_QUEUE_WR_HI         // Write 16 upper rdata bits to queue
} type_scr1_ifu_queue_wr_e;

typedef enum logic[1:0] {
    SCR1_IFU_QUEUE_RD_NONE,      // No queue read
    SCR1_IFU_QUEUE_RD_HWORD,     // Read halfword
    SCR1_IFU_QUEUE_RD_WORD       // Read word
} type_scr1_ifu_queue_rd_e;

`ifdef SCR1_NO_DEC_STAGE
typedef enum logic[1:0] {
    SCR1_BYPASS_NONE,               // No bypass
    SCR1_BYPASS_RVC,                // Bypass RVC
    SCR1_BYPASS_RVI_RDATA_QUEUE,    // Bypass RVI, rdata+queue
    SCR1_BYPASS_RVI_RDATA           // Bypass RVI, rdata only
} type_scr1_bypass_e;
`endif // SCR1_NO_DEC_STAGE

typedef enum logic [2:0] {
    // SCR1_IFU_INSTR_<UPPER_16_BITS>_<LOWER_16_BITS>
    SCR1_IFU_INSTR_NONE,                // No valid instruction
    SCR1_IFU_INSTR_RVI_HI_RVI_LO,       // Full RV32I instruction
    SCR1_IFU_INSTR_RVC_RVC,
    SCR1_IFU_INSTR_RVI_LO_RVC,
    SCR1_IFU_INSTR_RVC_RVI_HI,
    SCR1_IFU_INSTR_RVI_LO_RVI_HI,
    SCR1_IFU_INSTR_RVC_NV,              // Instruction after unaligned new_pc
    SCR1_IFU_INSTR_RVI_LO_NV            // Instruction after unaligned new_pc
} type_scr1_ifu_instr_e;

//------------------------------------------------------------------------------
// Local signals declaration
//------------------------------------------------------------------------------

// Instruction queue signals
//------------------------------------------------------------------------------

// New PC unaligned flag register
logic                               new_pc_unaligned_ff;
logic                               new_pc_unaligned_next;
logic                               new_pc_unaligned_upd;

// IMEM instruction type decoder
logic                               instr_hi_is_rvi;
logic                               instr_lo_is_rvi;
type_scr1_ifu_instr_e               instr_type;

// Register to store if the previous IMEM instruction had low part of RVI instruction
// in its high part
logic                               instr_hi_rvi_lo_ff;
logic                               instr_hi_rvi_lo_next;

// Queue read/write size decoders
type_scr1_ifu_queue_rd_e            q_rd_size;
logic                               q_rd_vd;
logic                               q_rd_none;
logic                               q_rd_hword;
type_scr1_ifu_queue_wr_e            q_wr_size;
logic                               q_wr_none;
logic                               q_wr_full;

// Write/read pointer registers
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_rptr;
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_rptr_next;
logic                               q_rptr_upd;
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_wptr;
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_wptr_next;
logic                               q_wptr_upd;

// Instruction queue control signals
logic                               q_wr_en;
logic                               q_flush_req;

// Queue data registers
logic [`SCR1_IMEM_DWIDTH/2-1:0]     q_data  [SCR1_IFU_Q_SIZE_HALF];
logic [`SCR1_IMEM_DWIDTH/2-1:0]     q_data_head;
logic [`SCR1_IMEM_DWIDTH/2-1:0]     q_data_next;

// Queue error flags registers
logic                               q_err   [SCR1_IFU_Q_SIZE_HALF];
logic                               q_err_head;
logic                               q_err_next;

// Instruction queue status signals
logic                               q_is_empty;
logic                               q_has_free_slots;
logic                               q_has_1_ocpd_hw;
logic                               q_head_is_rvc;
logic                               q_head_is_rvi;
logic [SCR1_IFU_Q_FREE_H_W-1:0]     q_ocpd_h;
logic [SCR1_IFU_Q_FREE_H_W-1:0]     q_free_h_next;
logic [SCR1_IFU_Q_FREE_W_W-1:0]     q_free_w_next;

// IFU FSM signals
//------------------------------------------------------------------------------

// IFU FSM control signals
logic                               ifu_fetch_req;
logic                               ifu_stop_req;

type_scr1_ifu_fsm_e                 ifu_fsm_curr;
type_scr1_ifu_fsm_e                 ifu_fsm_next;
logic                               ifu_fsm_fetch;

// IMEM signals
//------------------------------------------------------------------------------

// IMEM response signals
logic                               imem_resp_ok;
logic                               imem_resp_er;
logic                               imem_resp_er_discard_pnd;
logic                               imem_resp_discard_req;
logic                               imem_resp_received;
logic                               imem_resp_vd;
logic                               imem_handshake_done;

logic [15:0]                        imem_rdata_lo;
logic [31:16]                       imem_rdata_hi;

// IMEM address signals
logic                               imem_addr_upd;
logic [`SCR1_XLEN-1:2]              imem_addr_ff;
logic [`SCR1_XLEN-1:2]              imem_addr_next;

// IMEM pending transactions counter
logic                               imem_pnd_txns_cnt_upd;
logic [SCR1_TXN_CNT_W-1:0]          imem_pnd_txns_cnt;
logic [SCR1_TXN_CNT_W-1:0]          imem_pnd_txns_cnt_next;
logic [SCR1_TXN_CNT_W-1:0]          imem_vd_pnd_txns_cnt;
logic                               imem_pnd_txns_q_full;

// IMEM responses discard counter
logic                               imem_resp_discard_cnt_upd;
logic [SCR1_TXN_CNT_W-1:0]          imem_resp_discard_cnt;
logic [SCR1_TXN_CNT_W-1:0]          imem_resp_discard_cnt_next;

`ifdef SCR1_NEW_PC_REG
logic                               new_pc_req_ff;
`endif // SCR1_NEW_PC_REG

// Instruction bypass signals
`ifdef SCR1_NO_DEC_STAGE
type_scr1_bypass_e                  instr_bypass_type;
logic                               instr_bypass_vd;
`endif // SCR1_NO_DEC_STAGE

// Static branch predictor (BTFN) signals
logic                               ifu_head_pc_upd;
logic [`SCR1_XLEN-1:0]              ifu_head_pc;        // PC of the instruction at the queue output
logic                               bp_instr_consumed;  // instruction accepted by IDU this cycle
logic                               bp_predict_taken;   // predictor: taken
logic [`SCR1_XLEN-1:0]              bp_predict_pc;      // predictor: target PC
logic                               bp_redirect_req;    // predicted-taken redirect request
logic                               bp_any_taken;       // predicted taken (branch/jump OR RAS return)
logic [`SCR1_XLEN-1:0]              bp_any_target;      // predicted target (PC+imm OR RAS top)
logic                               bp_is_branch;       // instr at queue output is a branch/jump (B2)
`ifdef SCR1_BP_BTB
logic                               q_steered [SCR1_IFU_Q_SIZE_HALF]; // per-halfword: word was BTB-steered
// steer-flag FIFO carrying the fetch-time steer decision to the response/enqueue
localparam int unsigned SCR1_STEER_FIFO_DEPTH = 8;
logic                               steer_fifo [SCR1_STEER_FIFO_DEPTH];
logic                               steer_fifo_unal [SCR1_STEER_FIFO_DEPTH]; // target[1] of the steer
logic [2:0]                         steer_fifo_wptr;
logic [2:0]                         steer_fifo_rptr;
`endif // SCR1_BP_BTB

`ifdef SCR1_BP_RAS_EN
// Return Address Stack signals
logic                               ras_is_call;        // instr at queue output is a call
logic                               ras_is_return;      // instr at queue output is a return
logic                               ras_push;           // push return address this cycle
logic                               ras_pop;            // pop this cycle
logic                               ras_top_valid;      // RAS top is valid
logic [`SCR1_XLEN-1:0]              ras_top;            // RAS top (predicted return target)
logic [`SCR1_XLEN-1:0]              ras_link;           // return address to push (PC + instr size)
logic                               ras_predict_vd;     // return with a valid RAS prediction
`endif // SCR1_BP_RAS_EN

// Effective New PC request seen by the IFU datapath:
// external EXU redirect (jumps/branches/traps/...) OR predictor redirect
logic                               pc_new_req_i2;
logic [`SCR1_XLEN-1:0]              pc_new_i2;

//------------------------------------------------------------------------------
// Instruction queue
//------------------------------------------------------------------------------
//
 // Instruction queue consists of the following functional units:
 // - New PC unaligned flag register
 // - Instruction type decoder, including register to store if the previous
 //   IMEM instruction had low part of RVI instruction in its high part
 // - Read/write size decoders
 // - Read/write pointer registers
 // - Data and error flag registers
 // - Status logic
//

// New PC unaligned flag register
//------------------------------------------------------------------------------

assign new_pc_unaligned_upd = pc_new_req_i2 | imem_resp_vd;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        new_pc_unaligned_ff <= 1'b0;
    end else if (new_pc_unaligned_upd) begin
        new_pc_unaligned_ff <= new_pc_unaligned_next;
    end
end

assign new_pc_unaligned_next = pc_new_req_i2 ? pc_new_i2[1]
                             : ~imem_resp_vd  ? new_pc_unaligned_ff
`ifdef SCR1_BP_BTB
                             // A steered branch word: the NEXT response is its
                             // target word, whose low half must be skipped when
                             // the target is unaligned. The branch word itself
                             // already enqueued with the current (correct) flag.
                             : steer_resp      ? steer_unal_resp
`endif // SCR1_BP_BTB
                                              : 1'b0;

// Instruction type decoder
//------------------------------------------------------------------------------

assign instr_hi_is_rvi = &imem2ifu_rdata_i[17:16];
assign instr_lo_is_rvi = &imem2ifu_rdata_i[1:0];

always_comb begin
    instr_type = SCR1_IFU_INSTR_NONE;

    if (imem_resp_ok & ~imem_resp_discard_req) begin
        if (new_pc_unaligned_ff) begin
            instr_type = instr_hi_is_rvi ? SCR1_IFU_INSTR_RVI_LO_NV
                                         : SCR1_IFU_INSTR_RVC_NV;
        end else begin // ~new_pc_unaligned_ff
            if (instr_hi_rvi_lo_ff) begin
                instr_type = instr_hi_is_rvi ? SCR1_IFU_INSTR_RVI_LO_RVI_HI
                                             : SCR1_IFU_INSTR_RVC_RVI_HI;
            end else begin // SCR1_OTHER
                case ({instr_hi_is_rvi, instr_lo_is_rvi})
                    2'b00   : instr_type   = SCR1_IFU_INSTR_RVC_RVC;
                    2'b10   : instr_type   = SCR1_IFU_INSTR_RVI_LO_RVC;
                    default : instr_type   = SCR1_IFU_INSTR_RVI_HI_RVI_LO;
                endcase
            end
        end
    end
end

// Register to store if the previous IMEM instruction had low part of RVI
// instruction in its high part
//------------------------------------------------------------------------------

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        instr_hi_rvi_lo_ff <= 1'b0;
    end else begin
        if (pc_new_req_i2) begin
            instr_hi_rvi_lo_ff <= 1'b0;
        end else if (imem_resp_vd) begin
            instr_hi_rvi_lo_ff <= instr_hi_rvi_lo_next;
        end
    end
end

assign instr_hi_rvi_lo_next = (instr_type == SCR1_IFU_INSTR_RVI_LO_NV)
                            | (instr_type == SCR1_IFU_INSTR_RVI_LO_RVI_HI)
                            | (instr_type == SCR1_IFU_INSTR_RVI_LO_RVC);

// Queue write/read size decoders
//------------------------------------------------------------------------------

// Queue read size decoder
assign q_rd_vd    = ~q_is_empty & ifu2idu_vd_o & idu2ifu_rdy_i;
assign q_rd_hword = q_head_is_rvc | q_err_head
`ifdef SCR1_NO_DEC_STAGE
                  | (q_head_is_rvi & instr_bypass_vd)
`endif // SCR1_NO_DEC_STAGE
                  ;
assign q_rd_size  = ~q_rd_vd   ? SCR1_IFU_QUEUE_RD_NONE
                  : q_rd_hword ? SCR1_IFU_QUEUE_RD_HWORD
                               : SCR1_IFU_QUEUE_RD_WORD;
assign q_rd_none  = (q_rd_size == SCR1_IFU_QUEUE_RD_NONE);

// Queue write size decoder
always_comb begin
    q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
    if (~imem_resp_discard_req) begin
        if (imem_resp_ok) begin
`ifdef SCR1_NO_DEC_STAGE
            case (instr_type)
                SCR1_IFU_INSTR_NONE         : q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
                SCR1_IFU_INSTR_RVI_LO_NV    : q_wr_size = SCR1_IFU_QUEUE_WR_HI;
                SCR1_IFU_INSTR_RVC_NV       : q_wr_size = (instr_bypass_vd & idu2ifu_rdy_i)
                                                        ? SCR1_IFU_QUEUE_WR_NONE
                                                        : SCR1_IFU_QUEUE_WR_HI;
                SCR1_IFU_INSTR_RVI_HI_RVI_LO: q_wr_size = (instr_bypass_vd & idu2ifu_rdy_i)
                                                        ? SCR1_IFU_QUEUE_WR_NONE
                                                        : SCR1_IFU_QUEUE_WR_FULL;
                SCR1_IFU_INSTR_RVC_RVC,
                SCR1_IFU_INSTR_RVI_LO_RVC,
                SCR1_IFU_INSTR_RVC_RVI_HI,
                SCR1_IFU_INSTR_RVI_LO_RVI_HI: q_wr_size = (instr_bypass_vd & idu2ifu_rdy_i)
                                                        ? SCR1_IFU_QUEUE_WR_HI
                                                        : SCR1_IFU_QUEUE_WR_FULL;
            endcase // instr_type
`else // SCR1_NO_DEC_STAGE
            case (instr_type)
                SCR1_IFU_INSTR_NONE         : q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
                SCR1_IFU_INSTR_RVC_NV,
                SCR1_IFU_INSTR_RVI_LO_NV    : q_wr_size = SCR1_IFU_QUEUE_WR_HI;
                default                     : q_wr_size = SCR1_IFU_QUEUE_WR_FULL;
            endcase // instr_type
`endif // SCR1_NO_DEC_STAGE
        end else if (imem_resp_er) begin
            q_wr_size = SCR1_IFU_QUEUE_WR_FULL;
        end // imem_resp_er
    end // ~imem_resp_discard_req
end

assign q_wr_none   = (q_wr_size == SCR1_IFU_QUEUE_WR_NONE);
assign q_wr_full   = (q_wr_size == SCR1_IFU_QUEUE_WR_FULL);

// Write/read pointer registers
//------------------------------------------------------------------------------

assign q_flush_req = pc_new_req_i2 | pipe2ifu_stop_fetch_i;

// Queue write pointer register
assign q_wptr_upd  = q_flush_req | ~q_wr_none;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        q_wptr <= '0;
    end else if (q_wptr_upd) begin
        q_wptr <= q_wptr_next;
    end
end

assign q_wptr_next = q_flush_req ? '0
                   : ~q_wr_none  ? q_wptr + (q_wr_full ? SCR1_IFU_QUEUE_PTR_W'('b010) : SCR1_IFU_QUEUE_PTR_W'('b001))
                                 : q_wptr;

// Queue read pointer register
assign q_rptr_upd  = q_flush_req | ~q_rd_none;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        q_rptr <= '0;
    end else if (q_rptr_upd) begin
        q_rptr <= q_rptr_next;
    end
end

assign q_rptr_next = q_flush_req ? '0
                   : ~q_rd_none  ? q_rptr + (q_rd_hword ? SCR1_IFU_QUEUE_PTR_W'('b001) : SCR1_IFU_QUEUE_PTR_W'('b010))
                                 : q_rptr;

// Queue data and error flag registers
//------------------------------------------------------------------------------

assign imem_rdata_hi = imem2ifu_rdata_i[31:16];
assign imem_rdata_lo = imem2ifu_rdata_i[15:0];

assign q_wr_en = imem_resp_vd & ~q_flush_req;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        q_data  <= '{SCR1_IFU_Q_SIZE_HALF{'0}};
        q_err   <= '{SCR1_IFU_Q_SIZE_HALF{1'b0}};
`ifdef SCR1_BP_BTB
        q_steered <= '{SCR1_IFU_Q_SIZE_HALF{1'b0}};
`endif // SCR1_BP_BTB
    end else if (q_wr_en) begin
        case (q_wr_size)
            SCR1_IFU_QUEUE_WR_HI    : begin
                q_data[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_rdata_hi;
                q_err [SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_resp_er;
`ifdef SCR1_BP_BTB
                q_steered[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]      <= steer_resp;
`endif // SCR1_BP_BTB
            end
            SCR1_IFU_QUEUE_WR_FULL  : begin
                q_data[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_rdata_lo;
                q_err [SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_resp_er;
                q_data[SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)]  <= imem_rdata_hi;
                q_err [SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)]  <= imem_resp_er;
`ifdef SCR1_BP_BTB
                q_steered[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]      <= steer_resp;
                q_steered[SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)] <= steer_resp;
`endif // SCR1_BP_BTB
            end
        endcase
    end
end

assign q_data_head = q_data [SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_data_next = q_data [SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];
assign q_err_head  = q_err  [SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_err_next  = q_err  [SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];

// Queue status logic
//------------------------------------------------------------------------------

assign q_ocpd_h         = SCR1_IFU_Q_FREE_H_W'(q_wptr - q_rptr);
assign q_free_h_next    = SCR1_IFU_Q_FREE_H_W'(SCR1_IFU_Q_SIZE_HALF - (q_wptr - q_rptr_next));
assign q_free_w_next    = SCR1_IFU_Q_FREE_W_W'(q_free_h_next >> 1'b1);

assign q_is_empty       = (q_rptr == q_wptr);
assign q_has_free_slots = (SCR1_TXN_CNT_W'(q_free_w_next) > imem_vd_pnd_txns_cnt);
assign q_has_1_ocpd_hw  = (q_ocpd_h == SCR1_IFU_Q_FREE_H_W'(1));

assign q_head_is_rvi    = &(q_data_head[1:0]);
assign q_head_is_rvc    = ~q_head_is_rvi;

//------------------------------------------------------------------------------
// IFU FSM
//------------------------------------------------------------------------------

// IFU FSM control signals
assign ifu_fetch_req = pc_new_req_i2 & ~pipe2ifu_stop_fetch_i;
assign ifu_stop_req  = pipe2ifu_stop_fetch_i
                     | (imem_resp_er_discard_pnd & ~pc_new_req_i2);

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ifu_fsm_curr <= SCR1_IFU_FSM_IDLE;
    end else begin
        ifu_fsm_curr <= ifu_fsm_next;
    end
end

always_comb begin
    case (ifu_fsm_curr)
        SCR1_IFU_FSM_IDLE   : begin
            ifu_fsm_next = ifu_fetch_req ? SCR1_IFU_FSM_FETCH
                                         : SCR1_IFU_FSM_IDLE;
        end
        SCR1_IFU_FSM_FETCH  : begin
            ifu_fsm_next = ifu_stop_req  ? SCR1_IFU_FSM_IDLE
                                         : SCR1_IFU_FSM_FETCH;
        end
    endcase
end

assign ifu_fsm_fetch = (ifu_fsm_curr == SCR1_IFU_FSM_FETCH);

//------------------------------------------------------------------------------
// IFU <-> IMEM interface
//------------------------------------------------------------------------------
//
 // IFU <-> IMEM interface consists of the following functional units:
 // - IMEM response logic
 // - IMEM address register
 // - Pending IMEM transactions counter
 // - IMEM discard responses counter
 // - IFU <-> IMEM interface output signals
//

// IMEM response logic
//------------------------------------------------------------------------------

assign imem_resp_er             = (imem2ifu_resp_i == SCR1_MEM_RESP_RDY_ER);
assign imem_resp_ok             = (imem2ifu_resp_i == SCR1_MEM_RESP_RDY_OK);
assign imem_resp_received       = imem_resp_ok | imem_resp_er;
assign imem_resp_vd             = imem_resp_received & ~imem_resp_discard_req;
assign imem_resp_er_discard_pnd = imem_resp_er & ~imem_resp_discard_req;

assign imem_handshake_done = ifu2imem_req_o & imem2ifu_req_ack_i;

// IMEM address register
//------------------------------------------------------------------------------

assign imem_addr_upd = imem_handshake_done | pc_new_req_i2;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        imem_addr_ff <= '0;
    end else if (imem_addr_upd) begin
        imem_addr_ff <= imem_addr_next;
    end
end

`ifndef SCR1_NEW_PC_REG
assign imem_addr_next = pc_new_req_i2 ? pc_new_i2[`SCR1_XLEN-1:2]                 + imem_handshake_done
`ifdef SCR1_BP_BTB
                      : btb_steer_req  ? btb_target_fetch[`SCR1_XLEN-1:2]        // early-BTB fetch steer
`endif // SCR1_BP_BTB
                      : &imem_addr_ff[5:2]   ? imem_addr_ff                                     + imem_handshake_done
                                             : {imem_addr_ff[`SCR1_XLEN-1:6], imem_addr_ff[5:2] + imem_handshake_done};
`else // SCR1_NEW_PC_REG
assign imem_addr_next = pc_new_req_i2 ? pc_new_i2[`SCR1_XLEN-1:2]
                      : &imem_addr_ff[5:2]   ? imem_addr_ff                                     + imem_handshake_done
                                             : {imem_addr_ff[`SCR1_XLEN-1:6], imem_addr_ff[5:2] + imem_handshake_done};
`endif // SCR1_NEW_PC_REG

// Pending IMEM transactions counter
//------------------------------------------------------------------------------
// Pending IMEM transactions occur if IFU request has been acknowledged, but
// response comes in the next cycle or later

assign imem_pnd_txns_cnt_upd  = imem_handshake_done ^ imem_resp_received;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        imem_pnd_txns_cnt <= '0;
    end else if (imem_pnd_txns_cnt_upd) begin
        imem_pnd_txns_cnt <= imem_pnd_txns_cnt_next;
    end
end

assign imem_pnd_txns_cnt_next = imem_pnd_txns_cnt + (imem_handshake_done - imem_resp_received);
assign imem_pnd_txns_q_full   = &imem_pnd_txns_cnt;

// IMEM discard responses counter
//------------------------------------------------------------------------------
// IMEM instructions should be discarded in the following 2 cases:
// 1. New PC is requested by jump, branch, mret or other instruction
// 2. IMEM response was erroneous and not discarded
//
// In both cases the number of instructions to be discarded equals to the number
// of pending instructions.
// In the 1st case we don't need all the instructions that haven't been fetched
// yet, since the PC has changed.
// In the 2nd case, since the IMEM responce was erroneous there is no guarantee
// that subsequent IMEM instructions would be valid.

assign imem_resp_discard_cnt_upd = pc_new_req_i2 | imem_resp_er
                                 | (imem_resp_ok & imem_resp_discard_req);

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        imem_resp_discard_cnt <= '0;
    end else if (imem_resp_discard_cnt_upd) begin
        imem_resp_discard_cnt <= imem_resp_discard_cnt_next;
    end
end

`ifndef SCR1_NEW_PC_REG
assign imem_resp_discard_cnt_next = pc_new_req_i2         ? imem_pnd_txns_cnt_next - imem_handshake_done
                                  : imem_resp_er_discard_pnd ? imem_pnd_txns_cnt_next
                                                             : imem_resp_discard_cnt - 1'b1;
`else // SCR1_NEW_PC_REG
assign imem_resp_discard_cnt_next = pc_new_req_i2 | imem_resp_er_discard_pnd
                                  ? imem_pnd_txns_cnt_next
                                  : imem_resp_discard_cnt - 1'b1;
`endif // SCR1_NEW_PC_REG

assign imem_vd_pnd_txns_cnt  = imem_pnd_txns_cnt - imem_resp_discard_cnt;
assign imem_resp_discard_req = |imem_resp_discard_cnt;

// IFU <-> IMEM interface output signals
//------------------------------------------------------------------------------

`ifndef SCR1_NEW_PC_REG
assign ifu2imem_req_o  = (pc_new_req_i2 & ~imem_pnd_txns_q_full & ~pipe2ifu_stop_fetch_i)
                       | (ifu_fsm_fetch        & ~imem_pnd_txns_q_full & q_has_free_slots);
assign ifu2imem_addr_o = pc_new_req_i2
                       ? {pc_new_i2[`SCR1_XLEN-1:2], 2'b00}
                       : {imem_addr_ff, 2'b00};
`else // SCR1_NEW_PC_REG
assign ifu2imem_req_o  = ifu_fsm_fetch & ~imem_pnd_txns_q_full & q_has_free_slots;
assign ifu2imem_addr_o = {imem_addr_ff, 2'b00};
`endif // SCR1_NEW_PC_REG

assign ifu2imem_cmd_o  = SCR1_MEM_CMD_RD;

`ifdef SCR1_CLKCTRL_EN
assign ifu2pipe_imem_txns_pnd_o = |imem_pnd_txns_cnt;
`endif // SCR1_CLKCTRL_EN

//------------------------------------------------------------------------------
// IFU <-> IDU interface
//------------------------------------------------------------------------------
//
 // IFU <-> IDU interface consists of the following functional units:
 // - Instruction bypass type decoder
 // - IFU <-> IDU status signals
 // - Output instruction multiplexer
//

`ifdef SCR1_NO_DEC_STAGE

// Instruction bypass type decoder
//------------------------------------------------------------------------------

assign instr_bypass_vd  = (instr_bypass_type != SCR1_BYPASS_NONE);

always_comb begin
    instr_bypass_type    = SCR1_BYPASS_NONE;

    if (imem_resp_vd) begin
        if (q_is_empty) begin
            case (instr_type)
                SCR1_IFU_INSTR_RVC_NV,
                SCR1_IFU_INSTR_RVC_RVC,
                SCR1_IFU_INSTR_RVI_LO_RVC       : begin
                    instr_bypass_type = SCR1_BYPASS_RVC;
                end
                SCR1_IFU_INSTR_RVI_HI_RVI_LO    : begin
                    instr_bypass_type = SCR1_BYPASS_RVI_RDATA;
                end
                default : begin end
            endcase // instr_type
        end else if (q_has_1_ocpd_hw & q_head_is_rvi) begin
            if (instr_hi_rvi_lo_ff) begin
                instr_bypass_type = SCR1_BYPASS_RVI_RDATA_QUEUE;
            end
        end
    end // imem_resp_vd
end

// IFU <-> IDU interface status signals
//------------------------------------------------------------------------------

always_comb begin
    ifu2idu_vd_o         = 1'b0;
    ifu2idu_imem_err_o   = 1'b0;
    ifu2idu_err_rvi_hi_o = 1'b0;

    if (ifu_fsm_fetch | ~q_is_empty) begin
        if (instr_bypass_vd) begin
            ifu2idu_vd_o          = 1'b1;
            ifu2idu_imem_err_o    = (instr_bypass_type == SCR1_BYPASS_RVI_RDATA_QUEUE)
                                  ? (imem_resp_er | q_err_head)
                                  : imem_resp_er;
            ifu2idu_err_rvi_hi_o  = (instr_bypass_type == SCR1_BYPASS_RVI_RDATA_QUEUE) & imem_resp_er;
        end else if (~q_is_empty) begin
            if (q_has_1_ocpd_hw) begin
                ifu2idu_vd_o         = q_head_is_rvc | q_err_head;
                ifu2idu_imem_err_o   = q_err_head;
                ifu2idu_err_rvi_hi_o = ~q_err_head & q_head_is_rvi & q_err_next;
            end else begin
                ifu2idu_vd_o         = 1'b1;
                ifu2idu_imem_err_o   = q_err_head ? 1'b1 : (q_head_is_rvi & q_err_next);
            end
        end // ~q_is_empty
    end
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_vd_o          = hdu2ifu_pbuf_vd_i;
        ifu2idu_imem_err_o    = hdu2ifu_pbuf_err_i;
    end
`endif // SCR1_DBG_EN
end

// Output instruction multiplexer
//------------------------------------------------------------------------------

always_comb begin
    case (instr_bypass_type)
        SCR1_BYPASS_RVC            : begin
            ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'(new_pc_unaligned_ff ? imem_rdata_hi
                                                                     : imem_rdata_lo);
        end
        SCR1_BYPASS_RVI_RDATA      : begin
            ifu2idu_instr_o = imem2ifu_rdata_i;
        end
        SCR1_BYPASS_RVI_RDATA_QUEUE: begin
            ifu2idu_instr_o = {imem_rdata_lo, q_data_head};
        end
        default                    : begin
            ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'(q_head_is_rvc ? q_data_head
                                                               : {q_data_next, q_data_head});
        end
    endcase // instr_bypass_type
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'({'0, hdu2ifu_pbuf_instr_i});
    end
`endif // SCR1_DBG_EN
end

`else   // SCR1_NO_DEC_STAGE

// IFU <-> IDU interface status signals
//------------------------------------------------------------------------------

always_comb begin
    ifu2idu_vd_o          = 1'b0;
    ifu2idu_imem_err_o    = 1'b0;
    ifu2idu_err_rvi_hi_o  = 1'b0;
    if (~q_is_empty) begin
        if (q_has_1_ocpd_hw) begin
            ifu2idu_vd_o          = q_head_is_rvc | q_err_head;
            ifu2idu_imem_err_o    = q_err_head;
        end else begin
            ifu2idu_vd_o          = 1'b1;
            ifu2idu_imem_err_o    = q_err_head ? 1'b1 : (q_head_is_rvi & q_err_next);
            ifu2idu_err_rvi_hi_o  = ~q_err_head & q_head_is_rvi & q_err_next;
        end
    end // ~q_is_empty
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_vd_o          = hdu2ifu_pbuf_vd_i;
        ifu2idu_imem_err_o    = hdu2ifu_pbuf_err_i;
    end
`endif // SCR1_DBG_EN
end

// Output instruction multiplexer
//------------------------------------------------------------------------------

always_comb begin
    ifu2idu_instr_o = q_head_is_rvc ? `SCR1_IMEM_DWIDTH'(q_data_head)
                                    : {q_data_next, q_data_head};
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'({'0, hdu2ifu_pbuf_instr_i});
    end
`endif // SCR1_DBG_EN
end

`endif  // SCR1_NO_DEC_STAGE

`ifdef SCR1_DBG_EN
assign ifu2hdu_pbuf_rdy_o = idu2ifu_rdy_i;
`endif // SCR1_DBG_EN

//------------------------------------------------------------------------------
// Static branch predictor (BTFN) - milestone M1: JAL only
//------------------------------------------------------------------------------
//
 // Shadow fetch PC (ifu_head_pc) holds the PC of the instruction currently at
 // the queue output (ifu2idu_instr_o). It advances one instruction at a time
 // (decode rate) and is reset on any redirect. Invariant to keep: at the moment
 // an instruction is consumed, ifu_head_pc must equal pc_curr_ff in the EXU for
 // the same instruction (checked by assertion below).
//

assign bp_instr_consumed = ifu2idu_vd_o & idu2ifu_rdy_i;
assign ifu_head_pc_upd   = exu2ifu_pc_new_req_i | bp_redirect_req | bp_instr_consumed;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ifu_head_pc <= '0;
    end else if (ifu_head_pc_upd) begin
        ifu_head_pc <= exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i
`ifdef SCR1_BP_BTB
                     : bp_redirect_req       ? (bp_steer_misfetch ? bp_seq_pc : bp_any_target)
                     : bp_steer_commit       ? bp_predict_pc     // steered-taken: target already queued, no flush
                                             : bp_seq_pc;
`else // SCR1_BP_BTB
                     : bp_redirect_req       ? bp_any_target
                                             : ifu_head_pc + (q_head_is_rvc ? `SCR1_XLEN'd2 : `SCR1_XLEN'd4);
`endif // SCR1_BP_BTB
    end
end

`ifdef SCR1_BP_DYNAMIC
//------------------------------------------------------------------------------
// Branch History Table (D1): dynamic direction for conditional branches
//------------------------------------------------------------------------------
// Read by the shadow PC (same index carried to EXU for training); trained from
// the EXU->IFU channel on every resolved conditional branch. Feeds the
// direction decision inside scr1_pipe_bpred (BTFN fallback when untrained).
logic                              bht_valid;
logic                              bht_taken;

scr1_pipe_bht #(
    .SCR1_BHT_SIZE  (SCR1_BP_BHT_SIZE ),
    .SCR1_BHT_IDX_W (SCR1_BP_BHT_IDX_W)
) i_bht (
    .clk             (clk                             ),
    .rst_n           (rst_n                           ),
    .bht_rindex_i    (ifu_head_pc[SCR1_BP_BHT_IDX_W:1]),
    .bht_valid_o     (bht_valid                       ),
    .bht_taken_o     (bht_taken                       ),
    .bht_upd_vd_i    (exu2ifu_bp_upd_vd_i             ),
    .bht_upd_index_i (exu2ifu_bp_upd_index_i          ),
    .bht_upd_taken_i (exu2ifu_bp_upd_taken_i          )
);
`endif // SCR1_BP_DYNAMIC

`ifdef SCR1_BP_BTB
//------------------------------------------------------------------------------
// Early Branch Target Buffer (B1: measurement only, does not steer fetch)
//------------------------------------------------------------------------------
// Trained from the EXU on resolved taken direct branches/jumps. In B1 it is read
// by the queue-head PC (ifu_head_pc) so we can compare, at the moment the late
// predictor redirects (bp_redirect_req), whether the BTB already holds the
// correct target early. In B2 the read moves to the fetch address and drives
// the fetch stream.
logic                              btb_hit_fetch;      // BTB hit for the word being fetched
logic [`SCR1_XLEN-1:0]             btb_target_fetch;   // its cached taken target
logic                              btb_safe_fetch;     // cached branch ends on word boundary

scr1_pipe_btb #(
    .SCR1_BTB_SIZE  (SCR1_BP_BTB_SIZE ),
    .SCR1_BTB_IDX_W (SCR1_BP_BTB_IDX_W)
) i_btb (
    .clk              (clk                         ),
    .rst_n            (rst_n                       ),
    .btb_query_pc_i   ({imem_addr_ff, 2'b00}       ),  // read at the fetch address (early)
    .btb_hit_o        (btb_hit_fetch               ),
    .btb_target_o     (btb_target_fetch            ),
    .btb_safe_o       (btb_safe_fetch              ),
    .btb_upd_vd_i     (exu2ifu_bp_btb_upd_vd_i     ),
    .btb_upd_pc_i     (exu2ifu_bp_btb_upd_pc_i     ),
    .btb_upd_target_i (exu2ifu_bp_btb_upd_target_i ),
    .btb_upd_safe_i   (exu2ifu_bp_btb_upd_safe_i   )
);

// --- B2 early-BTB fetch steer -------------------------------------------------
// A BTB hit on the fetch address means "the word being fetched contains a taken
// branch; after fetching it, steer to the cached target". We change only the
// NEXT fetch address (no queue flush): the branch's own word is still fetched
// and enqueued, then the target is fetched right behind it.
logic                              btb_steer_req;      // steer the next fetch this cycle
// Steer ONLY safe (word-boundary-ending) branches. The target may now be
// unaligned (target[1]==1): the target word's low half is skipped by driving
// new_pc_unaligned for the target word (carried through the steer FIFO, applied
// on the branch word's response - see below). Unsafe (RVC-low) branches still
// fall back to the D1 late redirect.
assign btb_steer_req = btb_hit_fetch & btb_safe_fetch
                     & imem_handshake_done & ifu_fsm_fetch
                     & ~pc_new_req_i2;                 // an architectural redirect wins

// The steered word will be written to the queue when its response returns. The
// steer flag must travel with the in-flight request (request->response are
// decoupled), so it rides a small FIFO popped on each imem response, and the
// popped value marks the queue entry (q_steered) it lands in.
logic                              steer_resp;         // steer flag for the response being written
logic                              steer_unal_resp;    // steer target[1] for the response being written
logic                              q_steered_head;     // head instruction belongs to a steered word
// ends-on-word-boundary: the target is the very next queue entry only when the
// consumed branch ends at a word boundary (RVI-aligned or RVC in the high half).
logic                              bp_ends_on_word;
logic                              bp_steer_hit;       // a safe BTB-steered branch is at the queue output
logic                              bp_steer_commit;    // ... and direction predictor agrees taken -> no flush
logic                              bp_steer_misfetch;  // ... but direction predictor says not-taken -> flush to seq
logic [`SCR1_XLEN-1:0]             bp_seq_pc;          // sequential fall-through PC
assign bp_ends_on_word    = ~(ifu_head_pc[1] ^ q_head_is_rvc);
assign bp_steer_hit       = q_steered_head & bp_ends_on_word & bp_is_branch & bp_instr_consumed;
assign bp_steer_commit    = bp_steer_hit &  bp_predict_taken;
assign bp_steer_misfetch  = bp_steer_hit & ~bp_predict_taken;
assign bp_seq_pc          = ifu_head_pc + (q_head_is_rvc ? `SCR1_XLEN'd2 : `SCR1_XLEN'd4);

// steer-flag FIFO: push on request handshake, pop on response. The AHB response
// always trails the address handshake by >=1 cycle, so the FIFO is never popped
// empty. Pushes/pops stay balanced across redirects because discarded responses
// still pop (they just don't write q_steered, gated by q_wr_en below).
assign steer_resp      = steer_fifo[steer_fifo_rptr];
assign steer_unal_resp = steer_fifo_unal[steer_fifo_rptr];

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        steer_fifo_wptr <= '0;
        steer_fifo_rptr <= '0;
    end else begin
        if (imem_handshake_done) begin
            steer_fifo[steer_fifo_wptr]      <= btb_steer_req;
            steer_fifo_unal[steer_fifo_wptr] <= btb_target_fetch[1]; // target alignment for the word AFTER this one
            steer_fifo_wptr                  <= steer_fifo_wptr + 1'b1;
        end
        if (imem_resp_received) begin
            steer_fifo_rptr <= steer_fifo_rptr + 1'b1;
        end
    end
end

// Head steer flag, aligned with q_data_head / q_err_head
assign q_steered_head = q_steered[SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
`endif // SCR1_BP_BTB

// Static predictor (adapted from Ibex ibex_branch_predict): direction + PC+imm target.
scr1_pipe_bpred #(
    .SCR1_BP_PREDICT_BRANCHES (1'b1),   // M2: predict conditional branches (BTFN)
    .SCR1_BP_PREDICT_RVC      (1'b1)    // M3: predict compressed jumps/branches
) i_bpred (
    .clk                (clk               ),
    .rst_n              (rst_n             ),
    .bp_instr_i         (ifu2idu_instr_o   ),
    .bp_pc_i            (ifu_head_pc       ),
    .bp_vd_i            (ifu2idu_vd_o & ~ifu2idu_imem_err_o),
    .bp_predict_taken_o (bp_predict_taken  ),
    .bp_predict_pc_o    (bp_predict_pc     ),
    .bp_is_branch_o     (bp_is_branch      )
`ifdef SCR1_BP_DYNAMIC
    ,
    .bp_bht_valid_i     (bht_valid         ),
    .bp_bht_taken_i     (bht_taken         )
`endif // SCR1_BP_DYNAMIC
);

`ifdef SCR1_BP_RAS_EN
//------------------------------------------------------------------------------
// Return Address Stack: call/return detection + return-target prediction
//------------------------------------------------------------------------------
// Detect call/return of the instruction at the queue output, per RISC-V ABI
// (link registers x1/x5). Covers RVI (jal/jalr) and RVC (c.jal/c.jalr/c.jr).
logic [`SCR1_IMEM_DWIDTH-1:0]       ras_instr;
logic                              ras_rd_link;
logic                              ras_rs1_link;
logic                              rvi_jal;
logic                              rvi_jalr;
logic                              rvc_jr;
logic                              rvc_jalr;
logic                              rvc_jal;
logic                              rvc_jr_link;

assign ras_instr    = ifu2idu_instr_o;
assign ras_rd_link  = (ras_instr[11:7]  == 5'd1) | (ras_instr[11:7]  == 5'd5);
assign ras_rs1_link = (ras_instr[19:15] == 5'd1) | (ras_instr[19:15] == 5'd5);
assign rvi_jal      = (ras_instr[6:0] == 7'b1101111);
assign rvi_jalr     = (ras_instr[6:0] == 7'b1100111);
// RVC (quadrant C2, funct3=100): c.jr (bit12=0), c.jalr (bit12=1), rs2 field == 0
assign rvc_jr       = (ras_instr[1:0]==2'b10) & (ras_instr[15:13]==3'b100)
                    & (ras_instr[12]==1'b0)   & (ras_instr[11:7]!=5'd0) & (ras_instr[6:2]==5'd0);
assign rvc_jalr     = (ras_instr[1:0]==2'b10) & (ras_instr[15:13]==3'b100)
                    & (ras_instr[12]==1'b1)   & (ras_instr[11:7]!=5'd0) & (ras_instr[6:2]==5'd0);
assign rvc_jal      = (ras_instr[1:0]==2'b01) & (ras_instr[15:13]==3'b001);  // c.jal (RV32)
assign rvc_jr_link  = (ras_instr[11:7] == 5'd1) | (ras_instr[11:7] == 5'd5);

assign ras_is_call   = (rvi_jal  & ras_rd_link)
                     | (rvi_jalr & ras_rd_link)
                     | rvc_jalr | rvc_jal;
assign ras_is_return = (rvi_jalr & ras_rs1_link & ~ras_rd_link)
                     | (rvc_jr   & rvc_jr_link);

assign ras_predict_vd = ras_is_return & ras_top_valid;
assign ras_link       = ifu_head_pc + (q_head_is_rvc ? `SCR1_XLEN'd2 : `SCR1_XLEN'd4);
assign ras_push       = ras_is_call   & bp_instr_consumed & ~exu2ifu_pc_new_req_i;
assign ras_pop        = ras_is_return & ras_top_valid & bp_instr_consumed & ~exu2ifu_pc_new_req_i;

scr1_pipe_ras #(
    .SCR1_RAS_DEPTH (SCR1_RAS_DEPTH)
) i_ras (
    .clk         (clk                  ),
    .rst_n       (rst_n                ),
    .ras_flush_i (1'b0                 ),   // never flush: EXU always verifies target -> correctness holds; flush is only a perf heuristic and clearing on every redirect destroys the stack
    .ras_push_i  (ras_push             ),
    .ras_pop_i   (ras_pop              ),
    .ras_data_i  (ras_link             ),
    .ras_valid_o (ras_top_valid        ),
    .ras_data_o  (ras_top              )
);

// Carry the return prediction to EXU (latched there alongside the instruction)
assign ifu2exu_bp_ras_vd_o     = ras_predict_vd;
assign ifu2exu_bp_ras_target_o = ras_top;

// Combined prediction: branch/jump (PC+imm) OR return (RAS top)
assign bp_any_taken  = bp_predict_taken | ras_predict_vd;
assign bp_any_target = ras_predict_vd ? ras_top : bp_predict_pc;
`else // SCR1_BP_RAS_EN
assign bp_any_taken  = bp_predict_taken;
assign bp_any_target = bp_predict_pc;
`endif // SCR1_BP_RAS_EN

// Redirect fetch on a predicted-taken instruction once IDU accepts it.
// A real EXU redirect always has priority over the prediction.
`ifdef SCR1_BP_BTB
// Flush the fetch when: a non-steered taken branch redirects to its target (D1),
// OR a steered branch the direction predictor calls not-taken must be pulled
// back to the sequential path (steer misfetch). A committed steered-taken branch
// needs no flush - its target is already the next queue entry.
assign bp_redirect_req = bp_instr_consumed & ~exu2ifu_pc_new_req_i
                       & ( (bp_any_taken & ~bp_steer_commit) | bp_steer_misfetch );
`elsif SCR1_BPRED_EN
assign bp_redirect_req = bp_any_taken & bp_instr_consumed & ~exu2ifu_pc_new_req_i;
`else // SCR1_BPRED_EN
assign bp_redirect_req = 1'b0;   // predictor disabled -> IFU behaves as original
`endif // SCR1_BP_BTB

// Effective New PC request/value for the IFU datapath. EXU redirect wins.
assign pc_new_req_i2 = exu2ifu_pc_new_req_i | bp_redirect_req;
`ifdef SCR1_BP_BTB
// A steer-misfetch redirects to the sequential fall-through, not the branch target.
assign pc_new_i2     = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i
                     : bp_steer_misfetch     ? bp_seq_pc
                                             : bp_any_target;
`else // SCR1_BP_BTB
assign pc_new_i2     = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i : bp_any_target;
`endif // SCR1_BP_BTB

`ifdef SCR1_BP_DYNAMIC
//------------------------------------------------------------------------------
// Dynamic branch predictor - D0 scaffolding (no functional change yet)
//------------------------------------------------------------------------------
// Carry the predicted direction and the BHT index to EXU alongside the
// instruction. The index is the shadow-PC (RVC => 2-byte aligned, so from
// bit 1). Today the direction still comes from the static BTFN block; D1
// replaces bp_predict_taken's source with a BHT read indexed by this same
// ifu_head_pc, and consumes the exu2ifu_bp_upd_* training channel below.
// Honest direction from BHT/BTFN (no force-taken): a steered branch that the
// direction predictor calls not-taken is corrected in the IFU (steer misfetch
// flush to the sequential path), so it costs no extra EXU mispredict.
assign ifu2exu_bp_predicted_taken_o = bp_predict_taken;
assign ifu2exu_bp_index_o           = ifu_head_pc[SCR1_BP_BHT_IDX_W:1];
`endif // SCR1_BP_DYNAMIC

`ifdef SCR1_TRGT_SIMULATION

//------------------------------------------------------------------------------
// Assertions
//------------------------------------------------------------------------------

// X checks

SCR1_SVA_IFU_XCHECK : assert property (
    @(negedge clk) disable iff (~rst_n)
    !$isunknown({imem2ifu_req_ack_i, idu2ifu_rdy_i, exu2ifu_pc_new_req_i})
    ) else $error("IFU Error: unknown values");

SCR1_SVA_IFU_XCHECK_REQ : assert property (
    @(negedge clk) disable iff (~rst_n)
    ifu2imem_req_o |-> !$isunknown({ifu2imem_addr_o, ifu2imem_cmd_o})
    ) else $error("IFU Error: unknown {ifu2imem_addr_o, ifu2imem_cmd_o}");

// Behavior checks

SCR1_SVA_IFU_DRC_UNDERFLOW : assert property (
    @(negedge clk) disable iff (~rst_n)
    ~imem_resp_discard_req |=> ~(imem_resp_discard_cnt == SCR1_TXN_CNT_W'('1))
    ) else $error("IFU Error: imem_resp_discard_cnt underflow");

SCR1_SVA_IFU_DRC_RANGE : assert property (
    @(negedge clk) disable iff (~rst_n)
    (imem_resp_discard_cnt >= 0) & (imem_resp_discard_cnt <= imem_pnd_txns_cnt)
    ) else $error("IFU Error: imem_resp_discard_cnt out of range");

SCR1_SVA_IFU_QUEUE_OVF : assert property (
    @(negedge clk) disable iff (~rst_n)
    (q_ocpd_h >= SCR1_IFU_Q_FREE_H_W'(SCR1_IFU_Q_SIZE_HALF-1)) |->
    ((q_ocpd_h == SCR1_IFU_Q_FREE_H_W'(SCR1_IFU_Q_SIZE_HALF-1)) ? (q_wr_size != SCR1_IFU_QUEUE_WR_FULL)
                                                                : (q_wr_size == SCR1_IFU_QUEUE_WR_NONE))
    ) else $error("IFU Error: queue overflow");

SCR1_SVA_IFU_IMEM_ERR_BEH : assert property (
    @(negedge clk) disable iff (~rst_n)
    (imem_resp_er & ~imem_resp_discard_req & ~pc_new_req_i2) |=>
    (ifu_fsm_curr == SCR1_IFU_FSM_IDLE) & (imem_resp_discard_cnt == imem_pnd_txns_cnt)
    ) else $error("IFU Error: incorrect behavior after memory error");

SCR1_SVA_IFU_NEW_PC_REQ_BEH : assert property (
    @(negedge clk) disable iff (~rst_n)
    pc_new_req_i2 |=> q_is_empty
    ) else $error("IFU Error: incorrect behavior after pc_new_req_i2");

SCR1_SVA_IFU_IMEM_ADDR_ALIGNED : assert property (
    @(negedge clk) disable iff (~rst_n)
    ifu2imem_req_o |-> ~|ifu2imem_addr_o[1:0]
    ) else $error("IFU Error: unaligned IMEM access");

SCR1_SVA_IFU_STOP_FETCH : assert property (
    @(negedge clk) disable iff (~rst_n)
    pipe2ifu_stop_fetch_i |=> (ifu_fsm_curr == SCR1_IFU_FSM_IDLE)
    ) else $error("IFU Error: fetch not stopped");

SCR1_SVA_IFU_IMEM_FAULT_RVI_HI : assert property (
    @(negedge clk) disable iff (~rst_n)
    ifu2idu_err_rvi_hi_o |-> ifu2idu_imem_err_o
    ) else $error("IFU Error: ifu2idu_imem_err_o == 0");

`endif // SCR1_TRGT_SIMULATION

endmodule : scr1_pipe_ifu
