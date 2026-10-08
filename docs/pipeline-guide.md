# Pipeline Implementation Guide — Part 1

This guide teaches the 5-stage pipeline for **this** codebase: `part1/rtl/top.sv`,
`controller.sv`, `datapath.sv`, `tb/testbench.v`, `mem/memfile.dat`. Read it with
the source open. Plain English first, code details second.

---

## 1. Why pipeline at all

The single-cycle design (`reference/`) does everything for one instruction in
one clock period:

```
PC → imem → regfile read → ALU → dmem → regfile write
```

The clock must be long enough for the whole chain (the critical path), so the
frequency is low. Pipelining puts registers *between* the pieces of work:

- Each instruction still *finishes* in 5 steps (**latency = 5 cycles**).
- But one instruction finishes **every cycle** once the pipe is full
  (**throughput = 1 IPC**, CPI = 1 in the ideal case).
- The clock only has to cover the longest *single stage*, so frequency goes up.

The price: instructions overlap, so an instruction in one stage can depend on an
instruction still ahead of it in another stage. Those overlaps are **hazards**.

---

## 2. Logical stages vs physical stages

**Logical stages** are the five jobs a MIPS instruction needs done. **Physical
stages** are the clock-cycle boundaries created by pipeline registers: each
clock, every logical stage runs *simultaneously* on *different* instructions.

| Logical stage | What happens | Physical register at its end | Hardware in this design |
|---|---|---|---|
| **IF** — fetch | PC → instruction memory; compute PC+4 | **IF/ID** | `pcreg` (`flopr`), `pcadd1`, `imem` (in `top.sv`) |
| **ID** — decode | decode controls; read regfile; sign-extend; build jump target | **ID/EX** | `controller` (in `mips`, fed by `datapath.instrD`), `regfile`, `signext`, jump target concat |
| **EX** — execute | ALU op; branch compare + branch target; forwarding muxes | **EX/MEM** | `alu`, `pcadd2`, `pcbrmux`, forward muxes |
| **MEM** — memory | load/store data | **MEM/WB** | `dmem` (in `top.sv`) |
| **WB** — writeback | choose ALU result vs load data; write regfile | — | `resmux`, `regfile` write port |

Pipeline registers are the *physical* stages: IF/ID holds the fetched
instruction while ID works, ID/EX holds decoded values while EX works, etc.
Every register advances on `posedge clk`.

### Instruction work per stage

| Instr | IF | ID | EX | MEM | WB |
|---|---|---|---|---|---|
| `add/sub/and/or/slt` | fetch | decode, read `rs`,`rt` | ALU result | — | write `rd` |
| `addi` | fetch | decode, read `rs` | ALU `rs+imm` | — | write `rt` |
| `lw` | fetch | decode, read `rs` | address `rs+imm` | read data | write `rt` |
| `sw` | fetch | decode, read `rs`,`rt` | address `rs+imm`, store data | write memory | — |
| `beq` | fetch | decode, read `rs`,`rt` | compare (`zero`), branch target | — | — |
| `j` | fetch | decode, jump target | — | — | — |

In the current single-cycle `datapath.sv`, all of these muxes/logic coexist in
one combinational blob. In Step 2 you cut it apart at the register boundaries
and carry the values each later stage needs.

### 2.1 Lab constraints on the file structure

The lab fixes where the pipeline lives, so "split the stages" means **sections
inside the single `datapath` module**, not new hierarchy levels:

- Required hierarchy (do not change): `testbench → top → mips →
  {controller, datapath} → imem, dmem`. The only interface that must stay
  identical is `top`'s; everything between `mips`/`controller`/`datapath` is
  internal and may change.
- The lab requires `datapath.sv` to be structured in this order: fetch logic →
  IF/ID registers → decode/regfile → ID/EX registers → execute → EX/MEM
  registers → memory logic → MEM/WB registers → writeback.
- Helper modules already instantiated by `datapath` (`regfile`, `alu`, `adder`,
  `mux2`, `sl2`, `signext`, `flopr`) are fine; add `pipe_reg` alongside them.
  Do **not** create `stage_fetch`/`stage_decode`/... modules — that changes the
  hierarchy the lab asks you to follow.

The current `part1/rtl/datapath.sv` already carries banner comments for all
nine sections with `TODO:` field lists; implement into those sections in order.

---

## 3. Pipeline register contents (the heart of Step 2)

Each register is just a bundle of `flopr`s. Widths in parentheses.

### IF/ID — produced by IF, consumed by ID
| Field | Width | Why |
|---|---|---|
| `pcplus4D` | 32 | ID builds the jump target `{pcplus4[31:28], instr[25:0], 2'b00}` and passes it to EX for the branch target |
| `instrD` | 32 | decode (controller), regfile addresses, sign-extend |

### ID/EX — produced by ID, consumed by EX
| Field | Width | Why |
|---|---|---|
| `regwrite, mem2reg, memwrite` | 1 each | controls that continue to MEM/WB |
| `alusrc` | 1 | selects ALU B input (`rd2` vs `signimm`) |
| `alucontrol` | 3 | ALU operation |
| `branch` | 1 | **new** — controller must expose `branch` (see §8.1); `pcsrc` is computed in EX because `zero` isn't known until EX |
| `pcplus4E` | 32 | branch target adder in EX |
| `rd1E`, `rd2E` | 32 each | ALU operands (before forwarding) |
| `signimmE` | 32 | ALU immediate / branch offset |
| `rsE`, `rtE` | 5 each | forwarding comparisons (`rtE` also needed for load-use stall) |
| `writeregE` | 5 | destination register, computed in ID: `regdst ? instr[15:11] : instr[20:16]` |

### EX/MEM — produced by EX, consumed by MEM/WB
| Field | Width | Why |
|---|---|---|
| `regwrite, mem2reg, memwrite` | 1 each | writeback/memory controls |
| `aluoutM` | 32 | address for `lw`/`sw`, result for R-type |
| `writedataM` | 32 | store data — must be the **forwarded** `rd2` (see §6.3) |
| `writeregM` | 5 | destination register |

### MEM/WB — produced by MEM, consumed by WB
| Field | Width | Why |
|---|---|---|
| `regwrite, mem2reg` | 1 each | writeback controls |
| `readdataW` | 32 | value loaded from `dmem` |
| `aluoutW` | 32 | ALU result |
| `writeregW` | 5 | destination register |

### Recommended module: a register with stall + flush

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

Instantiate one per field group, or one wide register per stage and slice it.
Having `en`/`flush` from day one means Step 3 only wires control signals —
no structural rewrite.

---

## 4. What moves where (code-specific)

| Current single-cycle item (`datapath.sv`) | Pipeline home |
|---|---|
| `flopr pcreg`, `adder pcadd1` | IF |
| `pcmux` (jump), `pcbrmux` (branch) | IF (PC-next mux) — selects use signals produced in ID/EX |
| `signext`, `sl2`, jump-target concat | ID (or EX for `sl2`; simplest: ID computes target, EX computes branch target) |
| `regfile rf`, `wrmux` | ID (write port is fed by WB) |
| `srcbmux`, `alu` | EX |
| `pcadd2`, `pcbrmux` control | EX (branch target + `pcsrcE = branchE & zeroE`) |
| `dmem` (top.sv) | MEM |
| `resmux`, regfile write | WB |

### 4.1 Interface changes (internal only)

Control must decode the **ID-stage** instruction, which lives in the IF/ID
register *inside* `datapath`. So `datapath` exports `instrD`, and `mips` wires
`controller` to it. This keeps the required hierarchy — `controller` and
`datapath` stay siblings under `mips`; the controller is **not** moved inside
the datapath.

| Module | Before | After |
|---|---|---|
| `datapath` | in: `pcsrc`, `instr`; out: `zero` | in: `branch` (replaces `pcsrc`), `instrF` (fresh fetch); out: `instrD` (ID-stage instr), `aluoutM`, `writedataM` (`zero` may be dropped) |
| `controller` | in: `zero`; out: `pcsrc = branch & zero` | out: `branch` (maindec already computes it internally); no `zero` input, no `pcsrc` output |
| `mips` | controller decodes `instr` from imem; passes `pcsrc` to datapath | controller decodes `datapath.instrD`; passes `branch` to datapath; control outputs come back as datapath inputs |
| `top`, `testbench` | — | **unchanged** (top-level interface and TB port map stay identical) |

### 4.2 Section skeleton (already present as comments in `datapath.sv`)

```systemverilog
module datapath (...);
    // 1. FETCH (IF)                -> 2. IF/ID registers
    //    pcreg, pcadd1, PC-next muxes (branch target from EX, jump target from ID)
    // 2. IF/ID: pcplus4D, instrD
    // 3. DECODE + REGISTER FILE    -> 4. ID/EX registers
    //    regfile read, signext, writereg mux, jump target
    // 4. ID/EX: controls (incl. branch), pcplus4E, rd1E, rd2E, signimmE,
    //    rsE, rtE, writeregE
    // 5. EXECUTE                   -> 6. EX/MEM registers
    //    forward muxes (Step 3), alu, zero, pcbranch adder, pcsrcE
    // 6. EX/MEM: controls, aluoutM, writedataM (forwarded rd2), writeregM
    // 7. MEMORY (address/store data; dmem itself stays in top.sv)
    // 8. MEM/WB: regwriteW, mem2regW, readdataW, aluoutW, writeregW
    // 9. WRITEBACK: result_w mux drives the regfile write port
endmodule
```

---

## 5. What is a hazard?

A hazard is a situation where the next instruction in program order cannot
execute correctly in the next clock cycle because of overlap with an older
instruction.

Three flavors:

1. **Data hazard (RAW — read after write).** A younger instruction reads a
   register an older instruction hasn't written back yet.
   Example from `memfile.dat` (word numbers):
   ```
   w4: and $5,$3,$4      ; writes $5 in WB
   w5: add $5,$5,$4      ; needs old $5 in EX, two cycles too early
   ```
2. **Control hazard.** A branch/jump changes the PC, but younger instructions
   are already in the pipe.
   ```
   w8:  beq $4,$0,+1     ; taken → next instruction should be w10
   w9:  addi $5,$0,0     ; fetched/decoded already — wrong path
   ```
3. **Structural hazard.** Two instructions need the same hardware in the same
   cycle. This design has separate `imem`/`dmem` and a regfile with 2 read +
   1 write port, so there is **no problematic structural hazard**. (One subtle
   case: WB writes a register while ID reads it in the same cycle — that works
   because the write happens on the clock edge and the read is combinational
   afterwards. Keep it in mind when you debug.)

### The specific hazards in the provided program

| Sequence | Hazard | Fix |
|---|---|---|
| w4 `and $5` → w5 `add $5,$5,$4` | RAW, distance 1 | forward EX/MEM → EX |
| w5 `add $5` → w6 `beq $5,$7` | RAW into branch compare | forward EX/MEM → EX (branch resolved in EX) |
| w11 `add $7` → w12 `sub $7,$7,$2` | RAW, distance 1 | forward EX/MEM → EX |
| w12 `sub $7` → w13 `sw $7,...` | RAW into **store data** | forward EX/MEM → the value written to `dmem` (§6.3) |
| w8 `beq` taken | control | flush IF/ID + ID/EX, redirect PC |
| w15 `j` | control | flush IF/ID, redirect PC |
| w14 `lw $2` → w17 `sw $2` | load-use at distance 3 | **no stall needed** (WB value visible to ID read); if a test uses distance 1, stall (§8) |

---

## 6. Data hazards, and why forwarding works

Without help, `add` needs `$5` in EX at cycle 7, but `and` only writes it in WB
at cycle 8. However, `and`'s ALU result **already exists** at the end of its EX
cycle — it's sitting in the **EX/MEM** register during cycle 7, and in the
**MEM/WB** register during cycle 8. Forwarding just adds muxes in front of the
ALU that pick the value from those pipeline registers instead of the regfile.

Two things make this work:
- The producing instruction's result is carried in EX/MEM (`aluoutM`) and
  MEM/WB (`aluoutW` or `readdataW` for loads).
- The consuming instruction's source register numbers (`rsE`, `rtE`) are in
  ID/EX, so we can compare them.

### 6.1 Forwarding conditions (hazard unit)

```systemverilog
// priority: EX/MEM is the most recent producer
always_comb begin
    forward_a = 2'b00;
    if      (ex_mem.regwrite && ex_mem.writeregM != 0 && ex_mem.writeregM == id_ex.rsE) forward_a = 2'b10;
    else if (mem_wb.regwrite && mem_wb.writeregW != 0 && mem_wb.writeregW == id_ex.rsE) forward_a = 2'b01;
end
// identical logic for forward_b using id_ex.rtE
```

- `writereg != 0` matters: `$0` is hardwired, forwarding it would inject a
  bogus value (harmless here but wrong style).
- Priority matters: if both EX/MEM and MEM/WB match, EX/MEM is the newer value.

### 6.2 Forwarding muxes in EX

```systemverilog
always_comb begin
    src_a = (forward_a == 2'b10) ? ex_mem.aluoutM :
            (forward_a == 2'b01) ? result_w     : id_ex.rd1E;

    src_b_forwarded = (forward_b == 2'b10) ? ex_mem.aluoutM :
                      (forward_b == 2'b01) ? result_w     : id_ex.rd2E;
end

assign src_b   = id_ex.alusrc ? id_ex.signimmE : src_b_forwarded; // ALU input
assign result_w = mem_wb.mem2reg ? mem_wb.readdataW : mem_wb.aluoutW; // WB value
```

`result_w` is the WB mux (`resmux`) output — define it once and reuse it for
both writeback and forwarding.

### 6.3 Store-data forwarding (required for the provided program!)

`sw` writes `rt`'s value to memory. The value that goes to `dmem` must be the
**forwarded** `rd2`, not the stale `ID/EX.rd2E`:

```systemverilog
// when the store reaches MEM, its data was captured in EX/MEM:
ex_mem.writedataM <= src_b_forwarded;   // NOT id_ex.rd2E
```

If you forget this, w13's `sw $7,...` stores the old `$7` and the testbench
expects `7` at address `0x50` — the exact failure the lab's expected array will
catch.

---

## 7. Load-use hazard: stall one cycle

`lw $2, 0x50($0)` followed immediately by an instruction that uses `$2` cannot
be fixed by forwarding: the loaded data doesn't exist until the end of MEM.
The standard fix is to **stall** for one cycle, which creates a bubble so the
consumer reads the value from MEM/WB forwarding (or from the regfile).

Detect it while the load is in EX and the consumer is in ID:

```systemverilog
assign load_use = id_ex.mem2reg && (id_ex.writeregE != 0) &&
                  ((id_ex.writeregE == if_id.instrD[25:21]) ||
                   (id_ex.writeregE == if_id.instrD[20:16]));
```

Actions when `load_use`:
- `StallF = 1` → PC holds (don't fetch again).
- `StallD = 1` → IF/ID holds (consumer stays in ID).
- `FlushE = 1` → clear ID/EX (insert bubble between load and consumer).

Cycle picture (load in EX at cycle c):
```
cycle:   c            c+1          c+2
EX:      lw           bubble       consumer (gets forwarded lw data)
MEM:     ...          lw           bubble
ID:      consumer     consumer     ...
IF:      next         next (held)  next
```

Note: the lab only *requires* full handling for ADD/`beq`; stalling is the
accepted fallback for everything else, including load-use.

---

## 8. Control hazards: flush

### 8.1 Branch resolved in EX

When `beq` reaches EX, two younger instructions are already in the pipe
(one in ID, one in IF). If the branch is taken:

- compute `pcsrcE = id_ex.branch & zero` in EX,
- branch target `pcbranchE = id_ex.pcplus4E + (id_ex.signimmE << 2)`,
- at the end of the cycle: `PC <= pcsrcE ? pcbranchE : pcplus4F`,
- **flush IF/ID and ID/EX** (clear them → bubbles),
- the two wrong-path instructions disappear; penalty = 2 cycles.

`controller.sv` must expose `branch` (it currently keeps it internal and only
outputs `pcsrc = branch & zero`). Add an `output logic branch` port and carry
it through ID/EX; compute `pcsrcE` in the datapath's EX stage instead.

### 8.2 Jump resolved in ID

`j` has no condition and its target needs only `instrD[25:0]`, so resolve it in
ID: at the end of the ID cycle, `PC <= jump target` and **flush IF/ID** only
(one wrong-path instruction). `controller.jump` is already decoded in ID.

### 8.3 Flush vs stall summary

| Event | PC | IF/ID | ID/EX | Effect |
|---|---|---|---|---|
| load-use stall | hold | hold | clear | consumer repeats ID next cycle |
| branch taken (EX) | ← target | clear | clear | 2 bubbles |
| jump (ID) | ← target | clear | — | 1 bubble |

Clearing "controls to zero" is what makes a bubble: `regwrite=0`, `memwrite=0`,
etc. Data fields in a flushed register don't matter because nothing acts on
them. For IF/ID, clearing `instrD` to 0 decodes as the canonical NOP
(`sll $0,$0,0`). Optional robustness: guard the regfile write with
`wa3 != 0` so NOPs can never dirty `$0`.

---

## 9. Step 2 build order (skeleton first, hazards later)

The section banners and `TODO:` field lists are already in `datapath.sv`.
Do these as separate commits; the sim is allowed to fail until Step 3:

1. **Sections 1–2 (IF + IF/ID).** Add `pipe_reg`; register `pcplus4D`/`instrD`;
   export `instrD`; wire `controller` in `mips` to decode it.
2. **Sections 3–4 (ID + ID/EX).** `regfile`, `signext`, `writereg` mux, jump
   target; pipe controls/`rd1`/`rd2`/`signimm`/`rs`/`rt`/`writereg`.
3. **Sections 5–6 (EX + EX/MEM).** ALU, `pcbranch` adder, `pcsrcE`; pipe
   controls, `aluoutM`, `writedataM` (forwarded `rd2`), `writeregM`. Move the
   PC-next muxes into IF (branch target from EX, jump target from ID).
4. **Sections 7–9 (MEM + MEM/WB + WB).** `readdataW`, `result_w` mux, regfile
   write.
5. Run `make sim-part1` (wrong results are fine at this point) and commit
   "pipeline skeleton".

## 10. Step 3 build order (hazards)

1. **Forwarding unit + EX muxes** (§6). Test: baseline program should now get
   `sw` values right except control hazards.
2. **Load-use stall** (§7). Test: add a `lw`→use distance-1 sequence.
3. **Branch flush** (§8.1), then **jump flush** (§8.2). Test: baseline program
   should fully pass (`TEST COMPLETE`, writes `0x50=7`, `0x54=7`).

## 11. Worked example — baseline program, cycles 8–12

Assuming no stalls, `wN` enters IF at cycle N.

```
cycle:        8     9     10     11     12
w8  beq:     EX    MEM    WB
w9  addi:    ID    ID*   (flushed)
w10 slt:     IF    IF*   IF     ID     EX
w11 add:                       IF     ID
w12 sub:                              IF
```
- At cycle 10 the branch is in EX and resolves **taken** (target w10):
  `pcsrcE=1` → PC ← target; IF/ID and ID/EX flushed; w9 and the first fetch of
  w10 become bubbles.
- At cycle 11 the correct w10 is re-fetched, so w10 reaches EX at cycle 13.
- Penalty: 2 cycles (classic EX-resolved branch).
- Meanwhile w5→w6 (`add`→`beq`) is handled by forwarding into the EX compare;
  if you only forward the ALU A input, the branch compares stale data and goes
  the wrong way — a classic first-attempt bug.

## 12. Verification plan

1. Baseline: `make sim-part1` → two successful writes + `TEST COMPLETE`.
2. Forwarding test: chain of dependent `ADD`s that store each result to a
   distinct address; extend `expected_data`/`expected_addr` in the testbench.
3. Flush test: `beq` chain (taken and not-taken), with `sw` markers on the
   wrong-path instructions so a flush bug writes an unexpected address/value.
4. Waveforms for the report: full `lw` flow, ADD forwarding, BEQ flushing —
   annotate the forwarding/flush events on the signals from §3.

## 13. Pitfalls checklist

- Forgetting store-data forwarding (§6.3) — baseline `sw` fails.
- Forwarding priority (EX/MEM over MEM/WB) and `writereg != 0`.
- Branch compare using unforwarded operands.
- Flushing only one of IF/ID / ID/EX on a taken branch (2 wrong instructions!).
- Clearing ID/EX while the *load itself* is in EX — stalls must clear the
  register receiving the **consumer**, not the load.
- Using `<=` in `always_comb` (see controller discussion) — use `=` there.
- Assuming the `j` in the provided program can be ignored — it flushes a
  wrong-path instruction; without handling, the program executes `w16` too.
- Regfile write race: a consumer 3 instructions behind its producer reads the
  old value if the regfile writes on `posedge`. Write on `negedge` (first half),
  read combinationally (second half) — see `pipeline-implementation.md` §4.4.
