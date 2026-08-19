/// Copyright by Syntacore LLC © 2016-2020. See LICENSE for details
/// @file       <scr1_top_tb_ahb.sv>
/// @brief      SCR1 top testbench AHB
///

`include "scr1_arch_description.svh"
`include "scr1_ahb.svh"
`ifdef SCR1_IPIC_EN
`include "scr1_ipic.svh"
`endif // SCR1_IPIC_EN

module scr1_top_tb_ahb (
`ifdef VERILATOR
    input logic clk
`endif // VERILATOR
);

//-------------------------------------------------------------------------------
// Local parameters
//-------------------------------------------------------------------------------
localparam                          SCR1_MEM_SIZE       = 1024*1024;
localparam                          TIMEOUT             = 'd2000_000;//20ms;
localparam                          ARCH                = 'h1;
localparam                          COMPLIANCE          = 'h2;
localparam                          ADDR_START          = 'h200;
localparam                          ADDR_TRAP_VECTOR    = 'h240;
localparam                          ADDR_TRAP_DEFAULT   = 'h1C0;

//-------------------------------------------------------------------------------
// Local signal declaration
//-------------------------------------------------------------------------------
logic                                   rst_n;
`ifndef VERILATOR
logic                                   clk         = 1'b0;
`endif // VERILATOR
logic                                   rtc_clk     = 1'b0;
`ifdef SCR1_IPIC_EN
logic [SCR1_IRQ_LINES_NUM-1:0]          irq_lines;
`else // SCR1_IPIC_EN
logic                                   ext_irq;
`endif // SCR1_IPIC_EN
logic                                   soft_irq;
logic [31:0]                            fuse_mhartid;
integer                                 imem_req_ack_stall;
integer                                 dmem_req_ack_stall;

logic                                   test_mode   = 1'b0;
`ifdef SCR1_DBG_EN
logic                                   trst_n;
logic                                   tck;
logic                                   tms;
logic                                   tdi;
logic                                   tdo;
logic                                   tdo_en;
`endif // SCR1_DBG_EN

// Instruction Memory Interface
logic   [3:0]                           imem_hprot;
logic   [2:0]                           imem_hburst;
logic   [2:0]                           imem_hsize;
logic   [1:0]                           imem_htrans;
logic   [SCR1_AHB_WIDTH-1:0]            imem_haddr;
logic                                   imem_hready;
logic   [SCR1_AHB_WIDTH-1:0]            imem_hrdata;
logic                                   imem_hresp;

// Memory Interface
logic   [3:0]                           dmem_hprot;
logic   [2:0]                           dmem_hburst;
logic   [2:0]                           dmem_hsize;
logic   [1:0]                           dmem_htrans;
logic   [SCR1_AHB_WIDTH-1:0]            dmem_haddr;
logic                                   dmem_hwrite;
logic   [SCR1_AHB_WIDTH-1:0]            dmem_hwdata;
logic                                   dmem_hready;
logic   [SCR1_AHB_WIDTH-1:0]            dmem_hrdata;
logic                                   dmem_hresp;

// Wathdogs
int unsigned                            watchdogs_cnt;

int unsigned                            f_results;
int unsigned                            f_info;

string                                  s_results;
string                                  s_info;
`ifdef SIGNATURE_OUT
string                                  s_testname;
bit                                     b_single_run_flag;
`endif  //  SIGNATURE_OUT
`ifdef VERILATOR
logic [255:0]                           test_file;
`else // VERILATOR
string                                  test_file;
`endif // VERILATOR

bit                                     test_running;
int unsigned                            tests_passed;
int unsigned                            tests_total;

bit [1:0]                               rst_cnt;
bit                                     rst_init;


`ifdef VERILATOR
function int identify_test (logic [255:0] testname);
    bit res;
    logic [79:0] pattern_compliance;
    logic [22:0] pattern_arch;
begin
    pattern_compliance = 80'h636f6d706c69616e6365; // compliance
    pattern_arch       = 'h61726368;             // arch
    res = 0;
    for (int i = 0; i<= 176; i++) begin
        if(testname[i+:80] == pattern_compliance) begin
            return COMPLIANCE;
        end
    end
    for (int i = 0; i<= 233; i++) begin
        if(testname[i+:23] == pattern_arch) begin
            return ARCH;
        end
    end
    `ifdef SIGNATURE_OUT
        return ~res;
    `else
        return res;
    `endif
end
endfunction : identify_test

function logic [255:0] get_filename (logic [255:0] testname);
logic [255:0] res;
int i, j;
begin
    testname[7:0] = 8'h66;
    testname[15:8] = 8'h6C;
    testname[23:16] = 8'h65;

    for (i = 0; i <= 248; i += 8) begin
        if (testname[i+:8] == 0) begin
            break;
        end
    end
    i -= 8;
    for (j = 255; i >= 0;i -= 8) begin
        res[j-:8] = testname[i+:8];
        j -= 8;
    end
    for (; j >= 0;j -= 8) begin
        res[j-:8] = 0;
    end

    return res;
end
endfunction : get_filename

function logic [255:0] get_ref_filename (logic [255:0] testname);
logic [255:0] res;
int i, j;
logic [79:0] pattern_compliance;
logic [22:0] pattern_arch;
begin
    pattern_compliance = 80'h636f6d706c69616e6365; // compliance
    pattern_arch       = 'h61726368;             // arch

    for(int i = 0; i <= 176; i++) begin
        if(testname[i+:80] == pattern_compliance) begin
            testname[(i-8)+:88] = 0;
            break;
        end
    end

    for(int i = 0; i <= 233; i++) begin
        if(testname[i+:23] == pattern_arch) begin
            testname[(i-8)+:31] = 0;
            break;
        end
    end

    for(i = 32; i <= 248; i += 8) begin
        if(testname[i+:8] == 0) break;
    end
    i -= 8;
    for(j = 255; i > 24; i -= 8) begin
        res[j-:8] = testname[i+:8];
        j -= 8;
    end
    for(; j >=0;j -= 8) begin
        res[j-:8] = 0;
    end

    return res;
end
endfunction : get_ref_filename

function logic [2047:0] remove_trailing_whitespaces (logic [2047:0] str);
int i;
begin
    for (i = 0; i <= 2040; i += 8) begin
        if (str[i+:8] != 8'h20) begin
            break;
        end
    end
    str = str >> i;
    return str;
end
endfunction: remove_trailing_whitespaces

`else // VERILATOR
function int identify_test (string testname);
    begin
        if (testname.substr(0, 3) == "arch") begin
            return ARCH;
        end else if (testname.substr(0, 9) == "compliance") begin
            return COMPLIANCE;
        end else begin
            return 0;
        end
    end
endfunction : identify_test

function string get_filename (string testname);
        int length;
        begin
            length = testname.len();
            testname[length-1] = "f";
            testname[length-2] = "l";
            testname[length-3] = "e";

            return testname;
        end
endfunction : get_filename

function string get_ref_filename (string testname);
    begin
        if (identify_test(test_file) == COMPLIANCE) begin
            return testname.substr(11, testname.len() - 5);
        end else if (identify_test(test_file) == ARCH) begin
            return testname.substr(5, testname.len() - 5);
        end
    end
endfunction : get_ref_filename

`endif // VERILATOR

`ifndef VERILATOR
always #5   clk     = ~clk;         // 100 MHz
always #500 rtc_clk = ~rtc_clk;     // 1 MHz
`endif // VERILATOR

// Reset logic
assign rst_n = &rst_cnt;

always_ff @(posedge clk) begin
    if (rst_init)       rst_cnt <= '0;
    else if (~&rst_cnt) rst_cnt <= rst_cnt + 1'b1;
end


`ifdef SCR1_DBG_EN
initial begin
    trst_n  = 1'b0;
    tck     = 1'b0;
    tdi     = 1'b0;
    #900ns trst_n   = 1'b1;
    #500ns tms      = 1'b1;
    #800ns tms      = 1'b0;
    #500ns trst_n   = 1'b0;
    #100ns tms      = 1'b1;
end
`endif // SCR1_DBG_EN



//-------------------------------------------------------------------------------
// Run tests
//-------------------------------------------------------------------------------

`include "scr1_top_tb_runtests.sv"
//-------------------------------------------------------------------------------
// Core instance
//-------------------------------------------------------------------------------
scr1_top_ahb i_top (
    // Reset
    .pwrup_rst_n            (rst_n                  ),
    .rst_n                  (rst_n                  ),
    .cpu_rst_n              (rst_n                  ),
`ifdef SCR1_DBG_EN
    .sys_rst_n_o            (                       ),
    .sys_rdc_qlfy_o         (                       ),
`endif // SCR1_DBG_EN

    // Clock
    .clk                    (clk                    ),
    .rtc_clk                (rtc_clk                ),

    // Fuses
    .fuse_mhartid           (fuse_mhartid           ),
`ifdef SCR1_DBG_EN
    .fuse_idcode            (`SCR1_TAP_IDCODE       ),
`endif // SCR1_DBG_EN

    // IRQ
`ifdef SCR1_IPIC_EN
    .irq_lines              (irq_lines              ),
`else // SCR1_IPIC_EN
    .ext_irq                (ext_irq                ),
`endif // SCR1_IPIC_EN
    .soft_irq               (soft_irq               ),

    // DFT
    .test_mode              (1'b0                   ),
    .test_rst_n             (1'b1                   ),

`ifdef SCR1_DBG_EN
    // JTAG
    .trst_n                 (trst_n                 ),
    .tck                    (tck                    ),
    .tms                    (tms                    ),
    .tdi                    (tdi                    ),
    .tdo                    (tdo                    ),
    .tdo_en                 (tdo_en                 ),
`endif // SCR1_DBG_EN

    // Instruction Memory Interface
    .imem_hprot         (imem_hprot     ),
    .imem_hburst        (imem_hburst    ),
    .imem_hsize         (imem_hsize     ),
    .imem_htrans        (imem_htrans    ),
    .imem_hmastlock     (),
    .imem_haddr         (imem_haddr     ),
    .imem_hready        (imem_hready    ),
    .imem_hrdata        (imem_hrdata    ),
    .imem_hresp         (imem_hresp     ),

    // Data Memory Interface
    .dmem_hprot         (dmem_hprot     ),
    .dmem_hburst        (dmem_hburst    ),
    .dmem_hsize         (dmem_hsize     ),
    .dmem_htrans        (dmem_htrans    ),
    .dmem_hmastlock     (),
    .dmem_haddr         (dmem_haddr     ),
    .dmem_hwrite        (dmem_hwrite    ),
    .dmem_hwdata        (dmem_hwdata    ),
    .dmem_hready        (dmem_hready    ),
    .dmem_hrdata        (dmem_hrdata    ),
    .dmem_hresp         (dmem_hresp     )
);

//-------------------------------------------------------------------------------
// Memory instance
//-------------------------------------------------------------------------------
scr1_memory_tb_ahb #(
    .SCR1_MEM_POWER_SIZE    ($clog2(SCR1_MEM_SIZE))
) i_memory_tb (
    // Control
    .rst_n                  (rst_n),
    .clk                    (clk),
`ifdef SCR1_IPIC_EN
    .irq_lines              (irq_lines),
`else // SCR1_IPIC_EN
    .ext_irq                (ext_irq),
`endif // SCR1_IPIC_EN
    .soft_irq               (soft_irq),
    .imem_req_ack_stall_in  (imem_req_ack_stall),
    .dmem_req_ack_stall_in  (dmem_req_ack_stall),

    // Instruction Memory Interface
    // .imem_hprot             (imem_hprot ),
    // .imem_hburst            (imem_hburst),
    .imem_hsize             (imem_hsize ),
    .imem_htrans            (imem_htrans),
    .imem_haddr             (imem_haddr ),
    .imem_hready            (imem_hready),
    .imem_hrdata            (imem_hrdata),
    .imem_hresp             (imem_hresp ),

    // Data Memory Interface
    // .dmem_hprot             (dmem_hprot ),
    // .dmem_hburst            (dmem_hburst),
    .dmem_hsize             (dmem_hsize ),
    .dmem_htrans            (dmem_htrans),
    .dmem_haddr             (dmem_haddr ),
    .dmem_hwrite            (dmem_hwrite),
    .dmem_hwdata            (dmem_hwdata),
    .dmem_hready            (dmem_hready),
    .dmem_hrdata            (dmem_hrdata),
    .dmem_hresp             (dmem_hresp )
);

//-------------------------------------------------------------------------------
// Phase-0 branch-predictor profiling (tb-only, opt-in via -DSCR1_BP_PROFILE).
// Pure observation of DUT signals: no drive, no effect on core logic/timing.
//-------------------------------------------------------------------------------
`ifdef SCR1_BP_PROFILE
longint unsigned bpp_cycles    = 0;  // clocks after reset deassert
longint unsigned bpp_instret   = 0;  // retired instructions  -> IPC
longint unsigned bpp_branches  = 0;  // retired branches+jumps -> branch density
longint unsigned bpp_mispred   = 0;  // mispredicts            -> MPKI
longint unsigned bpp_fe_bubble = 0;  // frontend starvation: IDU ready but IFU not valid
// Phase-0.b: split the frontend bubble by cause (which lever addresses it)
longint unsigned bpp_bp_redir  = 0;  // predicted-taken redirects (late, at queue output)
longint unsigned bpp_exu_redir = 0;  // EXU redirects (mispredict/trap)
longint unsigned bpp_bub_bp    = 0;  // bubbles in shadow of a bp redirect  -> EARLY BTB addressable
longint unsigned bpp_bub_exu   = 0;  // bubbles in shadow of an EXU redirect -> accuracy addressable
longint unsigned bpp_bub_other = 0;  // bubbles not near any redirect        -> inherent (queue/mem)
int unsigned     bpp_bp_shadow  = 0;
int unsigned     bpp_exu_shadow = 0;
localparam int unsigned BPP_W = 2;   // shadow window (cycles) after a redirect
// Stage B1: early-BTB coverage/correctness, evaluated at each taken redirect
longint unsigned bpp_btb_cover   = 0; // taken redirect where BTB already had an entry
longint unsigned bpp_btb_correct = 0; // ... and the cached target matched the actual target
// Taken-transfer alignment classification (steerability): safe vs the unsafe cases
longint unsigned bpp_taken_total = 0; // all taken jumps/branches retired
longint unsigned bpp_taken_safe  = 0; // ends on a word boundary -> steerable
longint unsigned bpp_taken_rvclo = 0; // RVC in the low half   -> the predecode wall
longint unsigned bpp_taken_rviun = 0; // RVI on an odd halfword (word-straddling) -> also unsafe
// Cost of decoupling BHT from the steer: a steered branch the BHT then calls
// not-taken -> misfetch flush to the sequential path (a bubble the book's
// fetch-time counter gating would avoid).
longint unsigned bpp_steer_misfetch = 0;
// Phase-0.c: attribute each late-redirect bubble (bub_bp) to the steerability
// class of the head branch that caused the redirect -> ceiling per predecode phase.
longint unsigned bpp_bpredir_safe  = 0; // late redirect: head safe (BTB-miss/BHT-gate addressable)
longint unsigned bpp_bpredir_rvclo = 0; // ... rvc_low       (Phase-1 predecode addressable)
longint unsigned bpp_bpredir_rviun = 0; // ... rvi_unaligned  (Phase-2 straddle addressable)
longint unsigned bpp_bub_bp_safe   = 0; // bub_bp cycles owned by a safe redirect
longint unsigned bpp_bub_bp_rvclo  = 0; // ... by an rvc_low redirect
longint unsigned bpp_bub_bp_rviun  = 0; // ... by an rvi_unaligned redirect
int unsigned     bpp_bp_class      = 0; // class owning the current bp shadow (0 safe,1 rvclo,2 rviun)

always_ff @(posedge clk) begin
    if (rst_n) begin
        // steerability class of the current IFU head branch (fetch-side view)
        automatic logic          bpp_h_rvc = i_top.i_core_top.i_pipe_top.i_pipe_ifu.q_head_is_rvc;
        automatic logic          bpp_h_p1  = i_top.i_core_top.i_pipe_top.i_pipe_ifu.ifu_head_pc[1];
        automatic int unsigned   bpp_h_cls = (~(bpp_h_p1 ^ bpp_h_rvc)) ? 0 : ((bpp_h_rvc & ~bpp_h_p1) ? 1 : 2);
        bpp_cycles <= bpp_cycles + 1;
        if (i_top.i_core_top.i_pipe_top.instret)
            bpp_instret <= bpp_instret + 1;
        if (i_top.i_core_top.i_pipe_top.instret &
            (i_top.i_core_top.i_pipe_top.i_pipe_exu.exu_queue.branch_req |
             i_top.i_core_top.i_pipe_top.i_pipe_exu.exu_queue.jump_req))
            bpp_branches <= bpp_branches + 1;
        // classify each retired TAKEN transfer by steerability (rvc, pc[1])
        if (i_top.i_core_top.i_pipe_top.instret &
            i_top.i_core_top.i_pipe_top.i_pipe_exu.jb_taken) begin
            automatic logic rvc = i_top.i_core_top.i_pipe_top.i_pipe_exu.exu_queue.instr_rvc;
            automatic logic p1  = i_top.i_core_top.i_pipe_top.i_pipe_exu.pc_curr_ff[1];
            bpp_taken_total <= bpp_taken_total + 1;
            if (~(p1 ^ rvc))       bpp_taken_safe  <= bpp_taken_safe  + 1; // ends on word boundary
            else if (rvc & ~p1)    bpp_taken_rvclo <= bpp_taken_rvclo + 1; // RVC low half
            else                   bpp_taken_rviun <= bpp_taken_rviun + 1; // RVI odd half
        end
`ifdef SCR1_BPRED_EN
        if (i_top.i_core_top.i_pipe_top.instret &
            i_top.i_core_top.i_pipe_top.i_pipe_exu.bp_mispredict)
            bpp_mispred <= bpp_mispred + 1;
`endif // SCR1_BPRED_EN
`ifdef SCR1_BP_BTB
        // B2: count committed BTB-steered branches (early redirect, no flush)
        if (i_top.i_core_top.i_pipe_top.i_pipe_ifu.bp_steer_commit)
            bpp_btb_correct <= bpp_btb_correct + 1;
        // ... and steered branches the BHT then calls not-taken (misfetch flush)
        if (i_top.i_core_top.i_pipe_top.i_pipe_ifu.bp_steer_misfetch)
            bpp_steer_misfetch <= bpp_steer_misfetch + 1;
`endif // SCR1_BP_BTB
        // --- redirect events + shadow windows (Phase-0.b) ---
`ifdef SCR1_BPRED_EN
        if (i_top.i_core_top.i_pipe_top.i_pipe_ifu.bp_redirect_req) begin
            bpp_bp_redir <= bpp_bp_redir + 1;
            bpp_bp_shadow <= BPP_W;
            bpp_bp_class  <= bpp_h_cls; // remember cause for the shadow cycles
            case (bpp_h_cls)
                0: bpp_bpredir_safe  <= bpp_bpredir_safe  + 1;
                1: bpp_bpredir_rvclo <= bpp_bpredir_rvclo + 1;
                default: bpp_bpredir_rviun <= bpp_bpredir_rviun + 1;
            endcase
        end else if (bpp_bp_shadow != 0)
            bpp_bp_shadow <= bpp_bp_shadow - 1;
`endif // SCR1_BPRED_EN
        if (i_top.i_core_top.i_pipe_top.i_pipe_ifu.exu2ifu_pc_new_req_i) begin
            bpp_exu_redir <= bpp_exu_redir + 1;
            bpp_exu_shadow <= BPP_W;
        end else if (bpp_exu_shadow != 0)
            bpp_exu_shadow <= bpp_exu_shadow - 1;
        // --- classify each bubble cycle by nearest redirect cause ---
        if (i_top.i_core_top.i_pipe_top.idu2ifu_rdy &
            ~i_top.i_core_top.i_pipe_top.ifu2idu_vd) begin
            bpp_fe_bubble <= bpp_fe_bubble + 1;
`ifdef SCR1_BPRED_EN
            if (i_top.i_core_top.i_pipe_top.i_pipe_ifu.bp_redirect_req | (bpp_bp_shadow != 0)) begin
                automatic int unsigned bpp_own =
                    i_top.i_core_top.i_pipe_top.i_pipe_ifu.bp_redirect_req ? bpp_h_cls : bpp_bp_class;
                bpp_bub_bp <= bpp_bub_bp + 1;
                case (bpp_own)
                    0: bpp_bub_bp_safe  <= bpp_bub_bp_safe  + 1;
                    1: bpp_bub_bp_rvclo <= bpp_bub_bp_rvclo + 1;
                    default: bpp_bub_bp_rviun <= bpp_bub_bp_rviun + 1;
                endcase
            end else
`endif // SCR1_BPRED_EN
            if (i_top.i_core_top.i_pipe_top.i_pipe_ifu.exu2ifu_pc_new_req_i | (bpp_exu_shadow != 0))
                bpp_bub_exu <= bpp_bub_exu + 1;
            else
                bpp_bub_other <= bpp_bub_other + 1;
        end
    end
end

final begin
    $display("BP_PROFILE cycles=%0d instret=%0d branches=%0d mispred=%0d fe_bubble=%0d",
             bpp_cycles, bpp_instret, bpp_branches, bpp_mispred, bpp_fe_bubble);
    $display("BP_PROFILE2 bp_redir=%0d exu_redir=%0d bub_bp=%0d bub_exu=%0d bub_other=%0d",
             bpp_bp_redir, bpp_exu_redir, bpp_bub_bp, bpp_bub_exu, bpp_bub_other);
`ifdef SCR1_BP_BTB
    $display("BP_PROFILE3 btb_steer_commit=%0d steer_misfetch=%0d", bpp_btb_correct, bpp_steer_misfetch);
`endif // SCR1_BP_BTB
    $display("BP_PROFILE4 taken_total=%0d safe=%0d rvc_low=%0d rvi_unaligned=%0d",
             bpp_taken_total, bpp_taken_safe, bpp_taken_rvclo, bpp_taken_rviun);
    $display("BP_PROFILE5 bpredir[safe=%0d rvclo=%0d rviun=%0d] bub_bp[safe=%0d rvclo=%0d rviun=%0d]",
             bpp_bpredir_safe, bpp_bpredir_rvclo, bpp_bpredir_rviun,
             bpp_bub_bp_safe, bpp_bub_bp_rvclo, bpp_bub_bp_rviun);
end
`endif // SCR1_BP_PROFILE

endmodule : scr1_top_tb_ahb

