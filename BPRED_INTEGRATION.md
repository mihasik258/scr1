# Интеграция статического предсказателя переходов (BTFN) в SCR1

Полный набор изменений для переноса в чистую копию SCR1.
Предиктор адаптирован из `ibex_branch_predict.sv` (Apache-2.0).
Режим: полный (JAL + условные ветвления + RVC). Проверено: `riscv_isa` 56/56 PASS,
dhrystone −6.1% тактов на `CFG=MAX`.

Всего 5 файлов: 1 новый + 4 правки.

--------------------------------------------------------------------------------
## 1) НОВЫЙ ФАЙЛ: src/core/pipeline/scr1_pipe_bpred.sv
--------------------------------------------------------------------------------

```systemverilog
/// SCR1 static branch predictor (BTFN)
/// @file       <scr1_pipe_bpred.sv>
/// @brief      Static branch predictor (backward-taken / forward-not-taken)
///
/// Adapted from lowRISC Ibex `ibex_branch_predict.sv`
///   Copyright lowRISC contributors. Licensed under the Apache License, Version 2.0.
///   SPDX-License-Identifier: Apache-2.0

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

assign instr = bp_instr_i;

// Immediate extraction (verbatim from Ibex)
assign imm_j_type = { {12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0 };
assign imm_b_type = { {19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0 };
assign imm_cj_type = { {20{instr[12]}}, instr[12], instr[8], instr[10:9], instr[6], instr[7],
    instr[2], instr[11], instr[5:3], 1'b0 };
assign imm_cb_type = { {23{instr[12]}}, instr[12], instr[6:5], instr[2], instr[11:10],
    instr[4:3], 1'b0 };

// Branch / jump detection
assign instr_b = (instr[6:0] == SCR1_OPCODE_BRANCH) & SCR1_BP_PREDICT_BRANCHES;
assign instr_j = (instr[6:0] == SCR1_OPCODE_JAL);
assign instr_cb = SCR1_BP_PREDICT_RVC
                & (instr[1:0] == 2'b01) & ((instr[15:13] == 3'b110) | (instr[15:13] == 3'b111));
assign instr_cj = SCR1_BP_PREDICT_RVC
                & (instr[1:0] == 2'b01) & ((instr[15:13] == 3'b101) | (instr[15:13] == 3'b001));

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

assign bp_predict_taken_o = bp_vd_i & (instr_j | instr_cj | instr_b_taken);
assign bp_predict_pc_o    = bp_pc_i + branch_imm;

`ifdef SCR1_TRGT_SIMULATION
SCR1_SVA_BPRED_ONEHOT : assert property (
    @(negedge clk) disable iff (~rst_n)
    bp_vd_i |-> $onehot0({instr_j, instr_b, instr_cj, instr_cb})
    ) else $error("BPRED Error: instruction type not one-hot");
`endif // SCR1_TRGT_SIMULATION

endmodule : scr1_pipe_bpred
```

--------------------------------------------------------------------------------
## 2) src/core.files  — зарегистрировать новый модуль
--------------------------------------------------------------------------------

После строки `core/pipeline/scr1_pipe_ifu.sv` добавить:
```
core/pipeline/scr1_pipe_bpred.sv
```

--------------------------------------------------------------------------------
## 3) src/includes/scr1_arch_description.svh  — глобальный выключатель
--------------------------------------------------------------------------------

В секции `// CORE INTEGRATION OPTIONS` (перед "Bypasses on AXI/AHB bridge I/O") добавить:
```systemverilog
// Static branch predictor (BTFN). When commented out -> bit-identical to original.
`define SCR1_BPRED_EN
```

--------------------------------------------------------------------------------
## 4) src/core/pipeline/scr1_pipe_ifu.sv
--------------------------------------------------------------------------------

### 4.1 Объявления сигналов — ПОСЛЕ блока "Instruction bypass signals"
Найти:
```systemverilog
// Instruction bypass signals
`ifdef SCR1_NO_DEC_STAGE
type_scr1_bypass_e                  instr_bypass_type;
logic                               instr_bypass_vd;
`endif // SCR1_NO_DEC_STAGE
```
Добавить сразу после:
```systemverilog

// Static branch predictor (BTFN) signals
logic                               ifu_head_pc_upd;
logic [`SCR1_XLEN-1:0]              ifu_head_pc;        // PC of the instruction at the queue output
logic                               bp_instr_consumed;  // instruction accepted by IDU this cycle
logic                               bp_predict_taken;   // predictor: taken
logic [`SCR1_XLEN-1:0]              bp_predict_pc;      // predictor: target PC
logic                               bp_redirect_req;    // predicted-taken redirect request
// Effective New PC request seen by the IFU datapath (EXU redirect OR predictor)
logic                               pc_new_req_i2;
logic [`SCR1_XLEN-1:0]              pc_new_i2;
```

### 4.2 Замены в датапути (заменить сигнал EXU-редиректа на "эффективный")
Заменить `exu2ifu_pc_new_req_i` -> `pc_new_req_i2` и `exu2ifu_pc_new_i` -> `pc_new_i2`
в СЛЕДУЮЩИХ выражениях (НЕ трогать порт-декларацию и три места из п.4.3, где
приоритет EXU задаётся намеренно):

1. `assign new_pc_unaligned_upd = exu2ifu_pc_new_req_i | imem_resp_vd;`
   -> `assign new_pc_unaligned_upd = pc_new_req_i2 | imem_resp_vd;`

2. `assign new_pc_unaligned_next = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i[1]`
   -> `assign new_pc_unaligned_next = pc_new_req_i2 ? pc_new_i2[1]`
   (и выровнять продолжение тернарника)

3. `if (exu2ifu_pc_new_req_i) begin`  (сброс instr_hi_rvi_lo_ff)
   -> `if (pc_new_req_i2) begin`

4. `assign q_flush_req = exu2ifu_pc_new_req_i | pipe2ifu_stop_fetch_i;`
   -> `assign q_flush_req = pc_new_req_i2 | pipe2ifu_stop_fetch_i;`

5. `assign ifu_fetch_req = exu2ifu_pc_new_req_i & ~pipe2ifu_stop_fetch_i;`
   -> `assign ifu_fetch_req = pc_new_req_i2 & ~pipe2ifu_stop_fetch_i;`

6. `| (imem_resp_er_discard_pnd & ~exu2ifu_pc_new_req_i);`
   -> `| (imem_resp_er_discard_pnd & ~pc_new_req_i2);`

7. `assign imem_addr_upd = imem_handshake_done | exu2ifu_pc_new_req_i;`
   -> `assign imem_addr_upd = imem_handshake_done | pc_new_req_i2;`

8. В обеих ветках `imem_addr_next` (ifndef/ifdef SCR1_NEW_PC_REG):
   `exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i[`SCR1_XLEN-1:2] ...`
   -> `pc_new_req_i2 ? pc_new_i2[`SCR1_XLEN-1:2] ...`

9. `assign imem_resp_discard_cnt_upd = exu2ifu_pc_new_req_i | imem_resp_er`
   -> `assign imem_resp_discard_cnt_upd = pc_new_req_i2 | imem_resp_er`

10. В обеих ветках `imem_resp_discard_cnt_next`:
    `exu2ifu_pc_new_req_i ...` -> `pc_new_req_i2 ...`

11. В блоке `ifu2imem_req_o` / `ifu2imem_addr_o` (ifndef SCR1_NEW_PC_REG):
    `exu2ifu_pc_new_req_i` -> `pc_new_req_i2`,
    `{exu2ifu_pc_new_i[`SCR1_XLEN-1:2], 2'b00}` -> `{pc_new_i2[`SCR1_XLEN-1:2], 2'b00}`

### 4.3 Блок предсказателя — ПЕРЕД `` `ifdef SCR1_TRGT_SIMULATION `` (перед ассертами)
Найти:
```systemverilog
`ifdef SCR1_DBG_EN
assign ifu2hdu_pbuf_rdy_o = idu2ifu_rdy_i;
`endif // SCR1_DBG_EN

`ifdef SCR1_TRGT_SIMULATION
```
Вставить между ними:
```systemverilog
//------------------------------------------------------------------------------
// Static branch predictor (BTFN)
//------------------------------------------------------------------------------
// Shadow fetch PC: PC of the instruction at the queue output. Advances one
// instruction at a time, reset on any redirect. Invariant: at consume time it
// equals pc_curr_ff in the EXU for the same instruction.

assign bp_instr_consumed = ifu2idu_vd_o & idu2ifu_rdy_i;
assign ifu_head_pc_upd   = exu2ifu_pc_new_req_i | bp_redirect_req | bp_instr_consumed;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ifu_head_pc <= '0;
    end else if (ifu_head_pc_upd) begin
        ifu_head_pc <= exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i
                     : bp_redirect_req       ? bp_predict_pc
                                             : ifu_head_pc + (q_head_is_rvc ? `SCR1_XLEN'd2 : `SCR1_XLEN'd4);
    end
end

scr1_pipe_bpred #(
    .SCR1_BP_PREDICT_BRANCHES (1'b1),   // M2: conditional branches
    .SCR1_BP_PREDICT_RVC      (1'b1)    // M3: compressed jumps/branches
) i_bpred (
    .clk                (clk               ),
    .rst_n              (rst_n             ),
    .bp_instr_i         (ifu2idu_instr_o   ),
    .bp_pc_i            (ifu_head_pc       ),
    .bp_vd_i            (ifu2idu_vd_o & ~ifu2idu_imem_err_o),
    .bp_predict_taken_o (bp_predict_taken  ),
    .bp_predict_pc_o    (bp_predict_pc     )
);

// EXU redirect always has priority over the prediction.
`ifdef SCR1_BPRED_EN
assign bp_redirect_req = bp_predict_taken & bp_instr_consumed & ~exu2ifu_pc_new_req_i;
`else
assign bp_redirect_req = 1'b0;
`endif // SCR1_BPRED_EN

assign pc_new_req_i2 = exu2ifu_pc_new_req_i | bp_redirect_req;
assign pc_new_i2     = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i : bp_predict_pc;

```

### 4.4 Два поведенческих ассерта (внутри `SCR1_TRGT_SIMULATION`)
- `(imem_resp_er & ~imem_resp_discard_req & ~exu2ifu_pc_new_req_i) |=>`
  -> `(imem_resp_er & ~imem_resp_discard_req & ~pc_new_req_i2) |=>`
- `exu2ifu_pc_new_req_i |=> q_is_empty`
  -> `pc_new_req_i2 |=> q_is_empty`

--------------------------------------------------------------------------------
## 5) src/core/pipeline/scr1_pipe_exu.sv
--------------------------------------------------------------------------------

### 5.1 Объявления — ПОСЛЕ декларации `jb_new_pc` / `jb_misalign`
Найти:
```systemverilog
logic [`SCR1_XLEN-1:0]              jb_new_pc;
`ifndef SCR1_RVC_EXT
logic                               jb_misalign;
`endif
```
Добавить после:
```systemverilog

// Static branch predictor signals - mirror of scr1_pipe_bpred in the IFU
logic                               bp_taken;           // this instr was predicted taken
logic                               bp_mispredict;      // prediction != actual outcome
logic                               bp_recover_seq;     // predicted taken, resolved not-taken
logic                               pc_curr_transfer;   // architectural control transfer this cycle
```

### 5.2 pc_curr_next — отвязать от запроса редиректа
`assign pc_curr_next = exu2ifu_pc_new_req_o        ? exu2ifu_pc_new_o`
-> `assign pc_curr_next = pc_curr_transfer            ? exu2ifu_pc_new_o`

### 5.3 Мультиплексор нового PC — добавить восстановление не-взятой ветки
Найти:
```systemverilog
        exu_queue.fencei_req: exu2ifu_pc_new_o = inc_pc;
        default             : exu2ifu_pc_new_o = ialu_addr_res & SCR1_JUMP_MASK;
    endcase
```
Заменить на:
```systemverilog
        exu_queue.fencei_req: exu2ifu_pc_new_o = inc_pc;
        bp_recover_seq      : exu2ifu_pc_new_o = inc_pc;   // predicted taken, resolved not-taken
        default             : exu2ifu_pc_new_o = ialu_addr_res & SCR1_JUMP_MASK;
    endcase
```

### 5.4 Разделить "архитектурный переход" и "редирект выборки" + зеркало предиктора
Найти ВЕСЬ блок:
```systemverilog
assign exu2ifu_pc_new_req_o = init_pc                                        // reset
                            | exu2csr_take_irq_o
                            | exu2csr_take_exc_o
                            | (exu2csr_mret_instr_o & ~csr2exu_mstatus_mie_up_i)
                            | (exu_queue_vd & exu_queue.fencei_req)
                            | (wfi_run_start_ff
`ifdef SCR1_CLKCTRL_EN
                            & clk_pipe_en
`endif // SCR1_CLKCTRL_EN
                            )
`ifdef SCR1_DBG_EN
                            | dbg_run_start_npbuf
`endif // SCR1_DBG_EN
                            | (exu_queue_vd & jb_taken);

// Jump/branch signals
assign branch_taken = exu_queue.branch_req & ialu_cmp;
assign jb_taken     = exu_queue.jump_req | branch_taken;
assign jb_new_pc    = ialu_addr_res & SCR1_JUMP_MASK;
```
Заменить на:
```systemverilog
// Architectural control transfer this cycle. Drives the PC register and tracelog.
assign pc_curr_transfer     = init_pc
                            | exu2csr_take_irq_o
                            | exu2csr_take_exc_o
                            | (exu2csr_mret_instr_o & ~csr2exu_mstatus_mie_up_i)
                            | (exu_queue_vd & exu_queue.fencei_req)
                            | (wfi_run_start_ff
`ifdef SCR1_CLKCTRL_EN
                            & clk_pipe_en
`endif // SCR1_CLKCTRL_EN
                            )
`ifdef SCR1_DBG_EN
                            | dbg_run_start_npbuf
`endif // SCR1_DBG_EN
                            | (exu_queue_vd & jb_taken);

// Fetch-redirect request: same events, but jumps/branches only on MISPREDICT.
assign exu2ifu_pc_new_req_o = init_pc
                            | exu2csr_take_irq_o
                            | exu2csr_take_exc_o
                            | (exu2csr_mret_instr_o & ~csr2exu_mstatus_mie_up_i)
                            | (exu_queue_vd & exu_queue.fencei_req)
                            | (wfi_run_start_ff
`ifdef SCR1_CLKCTRL_EN
                            & clk_pipe_en
`endif // SCR1_CLKCTRL_EN
                            )
`ifdef SCR1_DBG_EN
                            | dbg_run_start_npbuf
`endif // SCR1_DBG_EN
                            | (exu_queue_vd & bp_mispredict);

// Jump/branch signals
assign branch_taken = exu_queue.branch_req & ialu_cmp;
assign jb_taken     = exu_queue.jump_req | branch_taken;
assign jb_new_pc    = ialu_addr_res & SCR1_JUMP_MASK;

// Static predictor mirror. Must match scr1_pipe_bpred in the IFU exactly.
//   direct jumps (JAL, c.j, c.jal) : jump_req & sum2_op==PC_IMM
//   backward branches (bXX, c.beqz/c.bnez) : branch_req & imm[XLEN-1]
//   JALR (indirect)                : not predicted -> mispredict -> redirect
`ifdef SCR1_BPRED_EN
assign bp_taken       = (exu_queue.jump_req   & (exu_queue.sum2_op == SCR1_SUM2_OP_PC_IMM))
                      | (exu_queue.branch_req &  exu_queue.imm[`SCR1_XLEN-1]);
`else
assign bp_taken       = 1'b0;    // predictor disabled -> mispredict==jb_taken (original)
`endif // SCR1_BPRED_EN
assign bp_mispredict  = jb_taken ^ bp_taken;
assign bp_recover_seq = exu_queue_vd & bp_mispredict & ~jb_taken;
```

### 5.5 Tracelog update_pc — отвязать от запроса редиректа
`assign update_pc    = exu2ifu_pc_new_req_o ? exu2ifu_pc_new_o : inc_pc;`
-> `assign update_pc    = pc_curr_transfer ? exu2ifu_pc_new_o : inc_pc;`

--------------------------------------------------------------------------------
## 6) Сборка и проверка
--------------------------------------------------------------------------------

```bash
cd scr1_full
# корректность (должно быть 56/56):
make run_verilator TARGETS=riscv_isa   TRACE=0 CFG=MAX
# выигрыш (сравнить diff тактов с baseline, закомментировав `define SCR1_BPRED_EN):
make run_verilator TARGETS=dhrystone21 TRACE=0 CFG=MAX
```

Фазовые параметры (в инстансе `scr1_pipe_bpred`, п.4.3) и зеркало (п.5.4) ВСЕГДА
меняются синхронно:
  - M1  : BRANCHES=0, RVC=0 ; в зеркале только `jump_req & sum2_op==PC_IMM & ~instr_rvc`
  - Full : BRANCHES=1, RVC=1 ; зеркало как в п.5.4

Выключатель `SCR1_BPRED_EN` (п.3) закомментировать -> ядро бит-в-бит равно оригиналу.
