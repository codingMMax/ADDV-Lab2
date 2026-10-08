# Pipeline Implementation Walkthrough — Part 1

Code-level companion to [`pipeline-guide.md`](pipeline-guide.md). **Scope:** the
full Step 2 pipeline skeleton (complete code you can type in); Step 3 hazards
stay conceptual here — the equations and wiring table are in §6, and the full
explanation is in the guide (§6–8).

Files touched: `part1/rtl/datapath.sv` (most work), `part1/rtl/controller.sv`,
`part1/rtl/top.sv` (`mips` wiring only). `top`'s interface and `testbench.v`
stay unchanged.

---

## 1. Interface changes (internal only)

| Module | Before | After |
|---|---|---|
| `controller` | in: `zero`; out: `pcsrc` | out: `branch`; no `zero` input, no `pcsrc` output |
| `datapath` | in: `pcsrc`, `instr`; out: `zero` | in: `branch`, `jump`, controls, `instrF`, `readdata`; out: `pc`, `instrD`, `aluout`, `writedata`, `memwriteM` |
| `mips` | controller decodes `instr`; `pcsrc` to datapath | controller decodes `datapath.instrD`; `branch` to datapath; `memwrite` output comes from the MEM stage (`memwriteM`) |
| `top`, `testbench` | — | unchanged |

Why `memwriteM`: in the single-cycle design `memwrite` came straight from the
controller (ID stage). In the pipeline, `dmem` must be written only when the
`sw` reaches the MEM stage, so the datapath exports the pipelined control.

---

## 2. New `controller.sv` (full code)

Only the module header changes; `maindec` and `aludec` stay as they are.

```systemverilog
module controller(
    input [5:0] op, funct,
    output mem2reg, memwrite,
    output branch, alusrc,
    output regdst, regwrite,
    output jump,
    output [2:0] alucontrol
);
    logic [1:0] aluop;

    maindec md (op, mem2reg, memwrite, branch, alusrc, regdst, regwrite, jump, aluop);
    aludec  ad (funct, aluop, alucontrol);
endmodule
```

Changes: drop the `zero` input and the `pcsrc` output/assign; expose `branch`
(maindec already produces it). `pcsrc` is now computed in EX.

---

## 3. New `mips` wiring in `top.sv` (full code)

```systemverilog
module mips(
    input clk, reset,
    output [31:0] pc,
    input [31:0] instr,
    output memwrite,
    output [31:0] aluout, writedata,
    input [31:0] readdata
);
    logic mem2reg, memwriteD, branch, alusrc, regdst, regwrite, jump;
    logic [2:0] alucontrol;
    logic [31:0] instrD;

    controller c(
        .op(instrD[31:26]), .funct(instrD[5:0]),
        .mem2reg(mem2reg), .memwrite(memwriteD), .branch(branch),
        .alusrc(alusrc), .regdst(regdst), .regwrite(regwrite),
        .jump(jump), .alucontrol(alucontrol)
    );

    datapath dp(
        .clk(clk), .reset(reset),
        .branch(branch), .jump(jump),
        .mem2reg(mem2reg), .memwrite(memwriteD), .alusrc(alusrc),
        .regdst(regdst), .regwrite(regwrite), .alucontrol(alucontrol),
        .instrF(instr), .readdata(readdata),
        .pc(pc), .instrD(instrD),
        .aluout(aluout), .writedata(writedata), .memwriteM(memwrite)
    );
endmodule
```

`top`, `dmem`, `imem` stay exactly as they are. Note how the datapath's
`instrD` output feeds the controller, and the controller's outputs feed back
into the datapath — all within `mips`.

---

## 4. `datapath.sv` — Step 2 (full code)

### 4.1 Ports and declarations

```systemverilog
module datapath(
    input  logic        clk, reset,
    input  logic        branch, jump,
    input  logic        mem2reg, memwrite, alusrc, regdst, regwrite,
    input  logic [2:0]  alucontrol,
    input  logic [31:0] instrF, readdata,
    output logic [31:0] pc, instrD,
    output logic [31:0] aluout, writedata,
    output logic        memwriteM
);
    // IF
    logic [31:0] pcplus4F, pcnextF, pctargetD;
    // IF/ID
    logic [31:0] pcplus4D;
    // ID
    logic [31:0] rd1D, rd2D, signimmD;
    logic [4:0]  writeregD;
    // ID/EX
    logic        regwriteE, mem2regE, memwriteE, alusrcE, branchE;
    logic [2:0]  alucontrolE;
    logic [31:0] pcplus4E, rd1E, rd2E, signimmE;
    logic [4:0]  rsE, rtE, writeregE;
    // EX
    logic [31:0] srcAE, srcBE, srcBE_raw, aluoutE, writedataE, pcbranchE;
    logic        zeroE, pcsrcE;
    // EX/MEM
    logic        regwriteM, mem2regM;
    logic [31:0] aluoutM, writedataM;
    logic [4:0]  writeregM;
    // MEM/WB
    logic        regwriteW, mem2regW;
    logic [31:0] readdataW, aluoutW;
    logic [4:0]  writeregW;
    // WB
    logic [31:0] resultW;
    // hazard control (Step 3 drives these; Step 2 ties them off)
    logic        StallF, StallD, FlushD, FlushE;
```

### 4.2 `pipe_reg` helper (add next to the other helpers)

```systemverilog
module pipe_reg #(parameter WIDTH = 1) (
    input  logic             clk, reset,
    input  logic             en,     // 0 = hold (stall)
    input  logic             flush,  // 1 = clear (bubble)
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);
    always_ff @(posedge clk, posedge reset)
        if (reset)       q <= '0;
        else if (flush)  q <= '0;
        else if (en)     q <= d;
endmodule
```

### 4.3 Checkpoint 1 — sections 1–2 (IF + IF/ID)

```systemverilog
    // =====================================================================
    // 1. FETCH (IF)
    // =====================================================================
    assign pctargetD = {pcplus4D[31:28], instrD[25:0], 2'b00};   // jump target (ID)
    // NOTE: branch (EX) has priority over jump (ID) — a wrong-path jump in ID
    // must not override a taken branch in EX.
    assign pcnextF   = pcsrcE ? pcbranchE : (jump ? pctargetD : pcplus4F);

    pipe_reg #(32) pcreg(clk, reset, ~StallF, 1'b0, pcnextF, pc);
    adder pcadd1(pc, 32'b100, pcplus4F);

    // =====================================================================
    // 2. IF/ID PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(32) if_id_pcplus4(clk, reset, ~StallD, FlushD, pcplus4F, pcplus4D);
    pipe_reg #(32) if_id_instr (clk, reset, ~StallD, FlushD, instrF,   instrD);
```

### 4.4 Checkpoint 2 — sections 3–4 (ID + ID/EX)

```systemverilog
    // =====================================================================
    // 3. DECODE + REGISTER FILE (ID)
    // =====================================================================
    regfile rf(clk, regwriteW, instrD[25:21], instrD[20:16], writeregW, resultW, rd1D, rd2D);
    mux2 #(5)  wrmux(instrD[20:16], instrD[15:11], regdst, writeregD);
    signext se(instrD[15:0], signimmD);

    // =====================================================================
    // 4. ID/EX PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(1)  id_ex_regwrite (clk, reset, 1'b1, FlushE, regwrite,      regwriteE);
    pipe_reg #(1)  id_ex_mem2reg  (clk, reset, 1'b1, FlushE, mem2reg,       mem2regE);
    pipe_reg #(1)  id_ex_memwrite (clk, reset, 1'b1, FlushE, memwrite,      memwriteE);
    pipe_reg #(1)  id_ex_alusrc   (clk, reset, 1'b1, FlushE, alusrc,        alusrcE);
    pipe_reg #(1)  id_ex_branch   (clk, reset, 1'b1, FlushE, branch,        branchE);
    pipe_reg #(3)  id_ex_aluctrl  (clk, reset, 1'b1, FlushE, alucontrol,    alucontrolE);
    pipe_reg #(32) id_ex_pcplus4  (clk, reset, 1'b1, FlushE, pcplus4D,      pcplus4E);
    pipe_reg #(32) id_ex_rd1      (clk, reset, 1'b1, FlushE, rd1D,          rd1E);
    pipe_reg #(32) id_ex_rd2      (clk, reset, 1'b1, FlushE, rd2D,          rd2E);
    pipe_reg #(32) id_ex_signimm  (clk, reset, 1'b1, FlushE, signimmD,      signimmE);
    pipe_reg #(5)  id_ex_rs       (clk, reset, 1'b1, FlushE, instrD[25:21], rsE);
    pipe_reg #(5)  id_ex_rt       (clk, reset, 1'b1, FlushE, instrD[20:16], rtE);
    pipe_reg #(5)  id_ex_writereg (clk, reset, 1'b1, FlushE, writeregD,     writeregE);
```

`regdst` is consumed in ID (by `wrmux`), so it does not need to be pipelined.

**Gotcha — regfile read timing (required for the baseline program).** Keep the
posedge write, but add a **write-through bypass** on both read ports:

```systemverilog
always_ff @(posedge clk) begin
    if (we3) rf[wa3] <= wd3;
end
// a same-cycle WB -> ID read returns the incoming write data
assign rd1 = (ra1 != 0) ? ((we3 && wa3 == ra1) ? wd3 : rf[ra1]) : 0;
assign rd2 = (ra2 != 0) ? ((we3 && wa3 == ra2) ? wd3 : rf[ra2]) : 0;
```

Why: an instruction **3 ahead** of a consumer writes back in WB on the same
posedge at which the consumer's ID/EX register latches its operands. With a
plain posedge write, the consumer captures the old value — e.g. `w0 addi $2` →
`w3 or ...,$2` latches `x` (verified in simulation). The bypass makes the read
port return the in-flight write data during that same cycle, which is the
hardware-friendly "write first half, read second half" register file (no mixed
clock edges, no stalls). An equivalent alternative is writing the array on the
negedge; the bypass keeps everything on posedge. Forwarding does not help here:
the producer is already past MEM/WB when the consumer is in EX.

### 4.5 Checkpoint 3 — sections 5–6 (EX + EX/MEM)

```systemverilog
    // =====================================================================
    // 5. EXECUTE (EX)
    // =====================================================================
    // Step 2: no forwarding yet — Step 3 replaces these two with forward muxes.
    assign srcAE     = rd1E;
    assign srcBE_raw = rd2E;

    mux2 #(32) srcbmux(srcBE_raw, signimmE, alusrcE, srcBE);
    alu alu0(srcAE, srcBE, alucontrolE, aluoutE, zeroE);

    adder pcadd2(pcplus4E, {signimmE[29:0], 2'b00}, pcbranchE);
    assign pcsrcE = branchE & zeroE;

    assign writedataE = srcBE_raw;   // store data = rd2 (forwarded in Step 3)

    // =====================================================================
    // 6. EX/MEM PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(1)  ex_mem_regwrite (clk, reset, 1'b1, 1'b0, regwriteE,  regwriteM);
    pipe_reg #(1)  ex_mem_mem2reg  (clk, reset, 1'b1, 1'b0, mem2regE,   mem2regM);
    pipe_reg #(1)  ex_mem_memwrite (clk, reset, 1'b1, 1'b0, memwriteE,  memwriteM);
    pipe_reg #(32) ex_mem_aluout   (clk, reset, 1'b1, 1'b0, aluoutE,    aluoutM);
    pipe_reg #(32) ex_mem_writedata(clk, reset, 1'b1, 1'b0, writedataE, writedataM);
    pipe_reg #(5)  ex_mem_writereg (clk, reset, 1'b1, 1'b0, writeregE,  writeregM);
```

Key points:
- `pcsrcE` is computed here (not in the controller), because `zeroE` is only
  known after the ALU.
- `writedataE` uses the raw `rd2` **before** the `alusrc` mux — that's the value
  `sw` stores. Step 3 forwards into it.
- EX/MEM and MEM/WB registers are never flushed (wrong-path instructions only
  exist in IF and ID when a branch resolves in EX).

### 4.6 Checkpoint 4 — sections 7–9 (MEM + MEM/WB + WB)

```systemverilog
    // =====================================================================
    // 7. MEMORY (MEM) — dmem lives in top.sv
    // =====================================================================
    assign aluout    = aluoutM;
    assign writedata = writedataM;

    // =====================================================================
    // 8. MEM/WB PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(1)  mem_wb_regwrite(clk, reset, 1'b1, 1'b0, regwriteM,  regwriteW);
    pipe_reg #(1)  mem_wb_mem2reg (clk, reset, 1'b1, 1'b0, mem2regM,   mem2regW);
    pipe_reg #(32) mem_wb_readdata(clk, reset, 1'b1, 1'b0, readdata,   readdataW);
    pipe_reg #(32) mem_wb_aluout  (clk, reset, 1'b1, 1'b0, aluoutM,    aluoutW);
    pipe_reg #(5)  mem_wb_writereg(clk, reset, 1'b1, 1'b0, writeregM,  writeregW);

    // =====================================================================
    // 9. WRITEBACK (WB) — drives the regfile write port in section 3
    // =====================================================================
    assign resultW = mem2regW ? readdataW : aluoutW;

    // =====================================================================
    // Step 2 placeholders — Step 3 replaces these with the hazard unit
    // =====================================================================
    assign StallF = 1'b0;
    assign StallD = 1'b0;
    assign FlushD = 1'b0;
    assign FlushE = 1'b0;
endmodule
```

---

## 5. Build order and expected results

| Checkpoint | What to add | Expected |
|---|---|---|
| 1 | Sections 1–2 + `pipe_reg` + `instrD` export + `mips`/controller rewiring | compiles; sim wrong |
| 2 | Sections 3–4 | compiles; sim wrong |
| 3 | Sections 5–6 + PC-next muxes | compiles; sim wrong |
| 4 | Sections 7–9 + placeholders | compiles; `make sim-part1` runs but reports errors (hazards unhandled) |

If it doesn't even compile, check §7 below.

---

## 6. Step 3 hookup (conceptual)

Replace the placeholders with the hazard unit (details in `pipeline-guide.md`
§6–8):

```systemverilog
    // forwarding (declares: logic [1:0] forwardAE, forwardBE; logic load_use;)
    always_comb begin
        forwardAE = 2'b00;
        if      (regwriteM && writeregM != 0 && writeregM == rsE) forwardAE = 2'b10;
        else if (regwriteW && writeregW != 0 && writeregW == rsE) forwardAE = 2'b01;
    end
    always_comb begin
        forwardBE = 2'b00;
        if      (regwriteM && writeregM != 0 && writeregM == rtE) forwardBE = 2'b10;
        else if (regwriteW && writeregW != 0 && writeregW == rtE) forwardBE = 2'b01;
    end

    assign srcAE     = (forwardAE == 2'b10) ? aluoutM :
                       (forwardAE == 2'b01) ? resultW  : rd1E;
    assign srcBE_raw = (forwardBE == 2'b10) ? aluoutM :
                       (forwardBE == 2'b01) ? resultW  : rd2E;

    // load-use stall + flush
    assign load_use = mem2regE && (writeregE != 0) &&
                      ((writeregE == instrD[25:21]) || (writeregE == instrD[20:16]));
    assign StallF = load_use;
    assign StallD = load_use;
    assign FlushE = pcsrcE | load_use;
    assign FlushD = pcsrcE | jump;
```

`en`/`flush` wiring that this drives:

| Register | en | flush |
|---|---|---|
| `pcreg` | `~StallF` | 0 |
| IF/ID (`pcplus4D`, `instrD`) | `~StallD` | `FlushD` |
| ID/EX (all fields) | 1 | `FlushE` |
| EX/MEM, MEM/WB | 1 | 0 |

Reminders:
- `resultW` is the WB mux output — the MEM/WB forwarding value.
- `writedataE = srcBE_raw` (forwarded `rd2`) is what makes the baseline
  `sub → sw` sequence store the right value.
- Branch has priority over jump in `pcnextF` (already in the Step 2 code).

---

## 7. Common compile errors and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `implicit net` warning for a stage signal | typo or missing declaration | declare it in §4.1; add `` `default_nettype none `` to catch it |
| "output port connected to input" | driving an input port from a module output (e.g. `wrmux` output wired to a control input) | use the dedicated wire (`writeregD`, `write2reg`, ...) |
| `instrD` undriven / x | IF/ID register output not connected | check the `if_id_instr` instance and the `mips` connection |
| Width mismatch warnings | 31- vs 32-bit literals or wrong pipe_reg WIDTH | use `32'b0`/`32'bx` and match the field width |
| Sim hangs in testbench | no `memwrite` ever reaches `dmem` | `memwriteM` not exported/wired to `mips.memwrite` |
| Branch takes the jump target | jump/ID has priority over branch/EX in `pcnextF` | branch first: `pcsrcE ? pcbranchE : (jump ? pctargetD : pcplus4F)` |
| Consumer 3 instructions behind reads `x` | regfile write not visible to a same-cycle ID read | add the write-through bypass (`we3 && wa3 == ra1 ? wd3 : rf[ra1]`) or write the array on negedge |

---

## 8. Appendix — Stage naming convention (F/D/E/M/W)

The final code uses stage-explicit suffixes (a signal carries the suffix of the
stage that consumes it: `instrD`, `rd1E`, `aluoutM`, `readdataW`). Key renames
relative to the snippets in this guide:

| Guide name | Code name |
|---|---|
| `branch`, `jump` inputs | `branchD`, `jumpD` |
| `mem2reg, memwrite, alusrc, regdst, regwrite, alucontrol` | `*D` |
| `instr` (datapath input) | `instrF` |
| `readdata` (input) | `readdataM` |
| `pc` (output) | `pcF` |
| `aluout`, `writedata` (outputs) | `aluoutM`, `storeDataM` |
| `pctargetD` | `pcjumpD` |
| `srcAE`, `srcBE`, `srcBE_raw` | `aluSrcAE`, `aluSrcBE`, `rtFwdE` |
| `writedataE/M` | `storeDataE/M` |
| `writeregD/E/M/W` | `destD/E/M/W` |
| `load_use` | `loadUseE` |
| `forwardAE/BE` | `fwdAE/fwdBE` |

Full mapping and the suffix rule: `pipeline-guide.md` §14.
