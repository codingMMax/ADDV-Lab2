# Lab #2 — Part 1 Report: 5-Stage Pipelined MIPS Processor

**Name 1:** _First Last (ASU ID)_ · **Name 2:** _First Last (ASU ID)_
**Course:** ADDV — Fall 2026
**Date:** _date_

> Figure/screenshot placeholders are marked `<!-- TODO -->`. Numbers come from the
> local synthesis runs (`reference/synth`, `part1/synth`) and simulation
> (`make sim-part1`, `make sim-fwd`, `make sim-flush`).

---

## 1. Microarchitecture and critical path

**Figure 1 — Pipelined MIPS microarchitecture with the critical path highlighted.**

<!-- TODO: insert hand-annotated diagram (book figure is fine).
     Highlight: ID/EX.rt -> forwarding compare -> srcbmux -> ALU(sub) -> zero ->
     pcsrc -> PC-next mux -> PC register (EX stage). -->
![Pipelined microarchitecture](figures/part1_microarch.png)

```
        IF              ID                 EX                    MEM             WB
  ┌───────────┐   ┌───────────┐     ┌───────────────────┐   ┌──────────┐   ┌───────────┐
  │ PC, imem  │──►│ IF/ID     │────►│ ID/EX             │──►│ EX/MEM   │──►│ MEM/WB    │──► regfile
  │ pc+4      │   │ pcplus4D  │     │ controls, rd1E,   │   │ aluoutM, │   │ readdataW │    write
  └───────────┘   │ instrD    │     │ rd2E, signimmE,   │   │ writedata│   │ aluoutW   │
        ▲         └───────────┘     │ rsE, rtE, ...     │   │ writeregM│   │ writeregW │
        │               │           └───────────────────┘   └──────────┘   └───────────┘
        │               ▼                   ▲   dmem            ▲
        │        controller (in mips)       │                   │
        └──── PC-next muxes ◄── pcsrcM? no: pcsrcE/branch flush ─┘
```

The synthesized worst path (report `part1/synth/timing_ff.rep`) is:

```
Startpoint: mips/dp/id_ex_rt/q_reg[1]   (ID/EX register)
Endpoint:   mips/dp/pcreg/q_reg[16]     (PC register)
Path: ID/EX.rt → forwarding compare/mux → srcbmux → ALU(sub) → zero →
      pcsrcE → PC-next muxes → PC register
```

This is the **EX stage**: forwarding selection + ALU (branch comparison) + branch
resolution + PC selection. It is the longest stage because branch resolution was
placed in EX (2-cycle flush instead of 3). Critical path ≈ **1.22 ns** at
1000 MHz target (slack −0.22 ns) → **~820 MHz**.
The single-cycle reference path (PC → imem → regfile → ALU → pcsrc → PC-next)
is ≈ **1.16 ns** (slack −0.16) → **~862 MHz**.

---

## 2. Signals propagated per pipeline stage for a `lw`

`lw $rt, imm($rs)`: `$rt ← mem[$rs + imm]`

| Stage | Work | Signals (this design) |
|---|---|---|
| **IF** | fetch; PC+4 | `pc`, `instrF`, `pcplus4F` |
| **IF/ID** | register | `pcplus4D`, `instrD` |
| **ID** | decode (`controller` from `instrD`), regfile read, sign-extend, write-register mux | `rd1D` (`rs` value), `signimmD`, `writeregD` (=`rt`), controls: `mem2reg=1`, `regwrite=1`, `alusrc=1`, `alucontrol=add` |
| **ID/EX** | register | `mem2regE`, `regwriteE`, `alusrcE`, `alucontrolE`, `rd1E`, `signimmE`, `writeregE`, `pcplus4E`, `rsE`, `rtE` |
| **EX** | address = `rs + imm` | `aluoutE` (address) |
| **EX/MEM** | register | `aluoutM` (address), `mem2regM`, `regwriteM`, `writeregM` (store data unused) |
| **MEM** | data memory read (`dmem` in `top`) | `readdata` |
| **MEM/WB** | register | `readdataW`, `aluoutW`, `mem2regW`, `regwriteW`, `writeregW` |
| **WB** | select load data; write regfile | `resultW = readdataW` → `rf[writeregW]` |

---

## 3. Code changes to enable pipelining (plain English)

**Interface changes (internal only; `top` and the testbench are unchanged).**

1. **The controller now decodes the ID-stage instruction.** The IF/ID register
   lives inside `datapath`, so `datapath` exports `instrD` and `mips` feeds it to
   the `controller` (which stays a sibling module under `mips`, keeping the
   required hierarchy):
   ```systemverilog
   controller c(.op(instrD[31:26]), .funct(instrD[5:0]), ...);
   ```
2. **`pcsrc` became `branch`.** The branch outcome (`zero`) is only known in EX,
   so the controller no longer computes `pcsrc`; it exposes `branch`, which is
   pipelined to EX where `pcsrcE = branchE & zeroE` is computed.
3. **`memwrite` is pipelined.** `dmem` must be written only when the `sw` reaches
   MEM, so the datapath exports `memwriteM` (the EX/MEM control) and `mips`
   routes it to `top.memwrite`.
4. **Pipeline registers.** A parameterized `pipe_reg` (async reset, `en` for
   stall, `flush` for bubbles) implements IF/ID, ID/EX, EX/MEM, MEM/WB:
   ```systemverilog
   pipe_reg #(32) if_id_instr (clk, reset, ~StallD, FlushD, instrF, instrD);
   pipe_reg #(1)  id_ex_branch(clk, reset, 1'b1,   FlushE, branch, branchE);
   ```
5. **PC-next logic moved into IF**, selecting between `pcplus4F`, the EX branch
   target `pcbranchE`, and the ID jump target `pctargetD`. Branch has priority
   over jump (a wrong-path jump in ID must not override a taken branch in EX):
   ```systemverilog
   assign pcnextF = pcsrcE ? pcbranchE : (jump ? pctargetD : pcplus4F);
   ```
6. **The datapath file is organized in the lab-required order** (fetch → IF/ID →
   decode/RF → ID/EX → execute → EX/MEM → memory → MEM/WB → writeback), and the
   hierarchy `testbench → top → mips → {controller, datapath} → imem, dmem` is
   unchanged. All design files use SystemVerilog (`logic`, `always_comb`,
   `always_ff`; synthesis uses `analyze -format sverilog`).

---

## 4. Hazard handling (plain English)

### 4.1 Data hazards — ALU forwarding

> "The instruction in MEM (EX/MEM) or WB (MEM/WB) wrote the register that the
> instruction in EX needs as an operand — take the value from that pipeline
> register instead of the value read from the register file in ID."

Both ALU inputs get forwarding muxes; EX/MEM has priority (it is the newer
value). Implemented in the EX section:

```systemverilog
if (regwriteM && writeregM != 0 && writeregM == rsE) forwardAE = 2'b10;
else if (regwriteW && writeregW != 0 && writeregW == rsE) forwardAE = 2'b01;
...
assign srcAE = (forwardAE == 2'b10) ? aluoutM :
               (forwardAE == 2'b01) ? resultW  : rd1E;
```

`writereg != 0` is checked because `$0` is hardwired; without it a stale `$0`
value could be injected.

### 4.2 Store-data forwarding (required for the baseline program)

> "The `sw` needs the value that an instruction one ahead produced; take the
> forwarded `rt` value, not the value captured in ID."

The store data that reaches `dmem` is the forwarded operand **before** the
`alusrc` mux:

```systemverilog
assign srcBE_raw = (forwardBE == 2'b10) ? aluoutM : ... : rd2E;
mux2 #(32) srcbmux(srcBE_raw, signimmE, alusrcE, srcBE);  // ALU input
assign writedataE = srcBE_raw;                            // store data
```

Without this, `sub $7` → `sw $7` stores the old `$7` and the baseline test
(expects 7 at `0x50`) fails.

### 4.3 Register-file write-through bypass (WB → ID, distance 3)

> "The instruction in WB is writing a register, and that register is exactly the
> one the instruction in ID is reading right now — return the incoming write
> data from the read port."

```systemverilog
assign rd1 = (ra1 != 0) ? ((we3 && wa3 == ra1) ? wd3 : rf[ra1]) : 0;
assign rd2 = (ra2 != 0) ? ((we3 && wa3 == ra2) ? wd3 : rf[ra2]) : 0;
```

This is the classic "write first half, read second half" register file
implemented with a bypass mux on the read ports. It is needed because a
consumer 3 instructions behind its producer (`addi $2` … `or …, $2`) reads the
register file in the same cycle the writeback happens, and by the time it
reaches EX the producer has already left MEM/WB, so ALU forwarding cannot help.

### 4.4 Load-use stall

> "The instruction in EX is a load whose destination register is read by the
> instruction in ID — hold the front-end for one cycle and insert a bubble."

```systemverilog
assign load_use = mem2regE && (writeregE != 0) &&
                  ((writeregE == instrD[25:21]) || (writeregE == instrD[20:16]));
assign StallF = load_use;  assign StallD = load_use;  assign FlushE = load_use;
```

The load's data does not exist until the end of MEM, so the consumer is held in
ID until the value can be forwarded from MEM/WB.

### 4.5 Control hazards — flushing

> "A branch in EX (or a jump in ID) means the instructions behind it were
> fetched from the wrong path — clear them and redirect the PC."

- **BEQ (resolved in EX):** two younger instructions exist (ID and IF). On a
  taken branch we clear IF/ID and ID/EX and set `PC ← pcbranchE`; penalty
  2 cycles.
  ```systemverilog
  assign FlushD = pcsrcE | jump;
  assign FlushE = pcsrcE | load_use;
  ```
- **J (resolved in ID):** one younger instruction (IF). Clear IF/ID and set
  `PC ← pctargetD`; penalty 1 cycle.
- **Priority:** if a taken branch (EX) and a jump (ID) coincide, the jump is on
  the wrong path and must not win — the PC mux checks `pcsrcE` first.

**Correctness of flushing is verified by the flushing test:** its wrong-path
instructions are `sw`s to `0x40/0x44/0x48`; if flushing failed, the testbench
would report unexpected writes. All three runs below pass.

---

## 5. Simulation and verification

### 5.1 Baseline program (all supported instructions)

```
Memory write 1 successful : wrote 00000007 to address 00000050
Memory write 2 successful : wrote 00000007 to address 00000054
TEST COMPLETE
PERF: cycles=22 instructions=16 CPI=1.375000 IPC=0.727273
```

The single-cycle reference finishes the same program at simulation time 160
(16 cycles / 16 instructions → CPI = 1.0).

**Figure 2 — Simulation terminal output.**

<!-- TODO: screenshot of `make sim-part1` output (include the PERF line). -->
![Simulation terminal](figures/part1_sim_terminal.png)

### 5.2 Load instruction through the pipeline

**Figure 3 — `lw` full pipeline flow (annotated).**

<!-- TODO: Verdi waveform of the baseline `lw $2,0x50($0)` (w14) flowing
     IF→ID→EX→MEM→WB; annotate the stage boundaries. -->
![Load pipeline flow](figures/part1_wave_load.png)

### 5.3 Forwarding test — dependent ADD chain

`part1/mem/forwarding_test.txt` (5 back-to-back dependent `add`s, then stores):

```
Memory write 1..5 successful (0x40=3, 0x44=4, 0x48=7, 0x4c=11, 0x50=18)
PERF: cycles=15 instructions=12 CPI=1.250000 IPC=0.800000
```

**Figure 4 — ADD forwarding (annotated).**

<!-- TODO: waveform showing an add consuming the EX/MEM result via the
     forwarding muxes; annotate forwardAE/forwardBE. -->
![ADD forwarding](figures/part1_wave_add_fwd.png)

### 5.4 Flushing test — BEQ taken/not-taken

`part1/mem/flushing_test.txt` (two taken branches, one not-taken, wrong-path
store markers):

```
Memory write 1..2 successful (0x4c=4, 0x50=6)   <- no writes at 0x40/0x44/0x48
PERF: cycles=17 instructions=10 CPI=1.700000 IPC=0.588235
```

**Figure 5 — BEQ flushing (annotated).**

<!-- TODO: waveform of a taken beq; annotate pcsrcE, FlushD/FlushE and the
     squashed wrong-path instructions. -->
![BEQ flushing](figures/part1_wave_beq_flush.png)

---

## 6. Performance comparison

### 6.1 Synthesis (OSU FreePDK45 `gscl45nm`, 1000 MHz target, DC V-2023.12)

| Design | Area (µm²) | Sequential cells | Macros | Critical path | Implied Fmax | Power |
|---|---|---|---|---|---|---|
| Non-pipelined, FF memories | 29,870.48 | 3,107 | 0 | 1.16 ns (slack −0.16) | ~862 MHz | 17.00 mW |
| **Pipelined, FF memories** | **33,860.93** | **3,469** | **0** | **1.22 ns (slack −0.22)** | **~820 MHz** | **25.49 mW** |
| Non-pipelined, SRAM memories | 42,479.79 | 1,056 | 2 | 1.08 ns (slack −0.08) | ~926 MHz | 21.13 mW |
| Pipelined, SRAM memories | 48,507.48 | 1,418 | 2 | 1.23 ns (slack −0.23) | ~813 MHz | 30.19 mW |

**Latency/throughput table (required):**

| Metric | Non-pipelined | Pipelined |
|---|---|---|
| Latency (CPI) | 1.0 (1 cycle per instruction; baseline sim 16 cyc/16 instr) | 1.375 (baseline); 1.25 (forwarding test); 1.70 (flushing test) |
| Throughput (IPC) | 1.0 | 0.727 (baseline); 0.800 (forwarding test); 0.588 (flushing test) |
| Area | 29,870 µm² | 33,861 µm² (+13.4 %) |
| Clock frequency / critical path | ~862 MHz / 1.16 ns | ~820 MHz / 1.22 ns |

**Observations.**

- The pipelined design adds ~13 % area (four pipeline registers plus forwarding
  comparators, branch-target adder, and PC-next logic) and ~50 % power.
- In this implementation the critical path is the **EX stage** (forwarding
  select → ALU → branch compare → PC mux), so the frequency gain over the
  single-cycle design is small (~1.16 ns vs 1.22 ns). The single-cycle path is
  dominated by the same ALU/control chain; the FF-mapped memories and register
  file are relatively fast. Resolving the branch with a dedicated comparator
  (instead of reusing the ALU) or moving the branch to ID would shorten the
  pipelined EX stage and let pipelining show its frequency advantage.
- **SRAM experiment:** mapping `imem`/`dmem` to the OpenRAM macro removes ~2050
  memory flip-flops (sequential cells 3107→1056 and 3469→1418) but the two
  macros' area is larger than the FF arrays at this tiny size (64×32 words), so
  total area increases. SRAMs pay off for larger memories.

### 6.2 Improved IPC from forwarding (ADD sequence)

Same forwarding test program, measured with forwarding **disabled** (stall-only
variant, correct results, producer waited on until WB):

| Version | Cycles | Instructions | CPI | IPC |
|---|---|---|---|---|
| With forwarding (our design) | 15 | 12 | 1.25 | **0.800** |
| Stall-only (no forwarding) | 25 | 12 | 2.08 | 0.480 |

**Forwarding improves IPC by 66.7 %** (0.800 vs 0.480) and removes 10 stall
cycles on this 12-instruction sequence.

### 6.3 Improved IPC from flushing (BEQ sequence)

Same flushing test program, measured with the branch resolved in **MEM**
(3-cycle flush) instead of EX:

| Version | Cycles | Instructions | CPI | IPC |
|---|---|---|---|---|
| EX-resolved branch + flush (our design) | 17 | 10 | 1.70 | **0.588** |
| MEM-resolved branch + flush | 19 | 10 | 1.90 | 0.526 |

**Early branch resolution in EX improves IPC by 11.8 %** (0.588 vs 0.526): each
taken branch costs 2 flush cycles instead of 3.

---

## 7. Synthesis with the SRAM library

`part1/rtl/top_with_sram.sv` replaces `imem`/`dmem` with the OpenRAM
`SRAM_32x64_1rw` macro and is synthesized with `compile_with_sram.tcl`
(`analyze -format sverilog`, `top_with_sram.sv` instead of `top.sv`).
`set_dont_touch [get_cells "imem"]` / `[get_cells "dmem"]` keeps the macros.

**Lines specifying the memory-cell library** — in our equivalent script
(`part1/synth/compile_with_sram.tcl`):

```tcl
32: set SRAM_DIR [file normalize "../../sram_32x64"]
33: set search_path [concat $search_path $OSU_FREEPDK $SRAM_DIR]
37: set link_library [set target_library [concat [list gscl45nm.db] [list SRAM_32x64_1rw.db] [list dw_foundation.sldb]]]
38: set target_library [list gscl45nm.db SRAM_32x64_1rw.db]
```

<!-- TODO: copy the official compile_with_sram.tcl from
     /usr/local2/COURSES/ADDV/LAB2/ on Apporto and cite its exact line numbers
     here instead (the line numbers above are from our equivalent script). -->

Results: see the SRAM rows in §6.1 (area increases for this small memory;
sequential cells drop by ~2,050; the macro count is 2).

---

## 8. Demo, contributions, and submission checklist

**Figure 6 — Demo scheduling confirmation.**

<!-- TODO: screenshot of the 5-minute demo booking confirmation. -->
![Demo schedule](figures/part1_demo_schedule.png)

**Contributions (Part 1):**

<!-- TODO: fill in per-partner contributions, e.g.
     - Partner A: pipeline registers/PC logic, forwarding, ...
     - Partner B: flush/stall logic, test programs, synthesis, ... -->

**ZIP contents (Part 1):**

- [ ] `README` (this repo's README.md describes how to run everything)
- [ ] `Makefile` (sim-ref, sim-part1, sim-fwd, sim-flush, synth-*)
- [ ] MIPS assembly programs: `part1/mem/{baseline,forwarding_test,flushing_test}.txt`
- [ ] `part1/mem/memfile.dat` (+ `forwarding_test.dat`, `flushing_test.dat`)
- [ ] Testbench: `part1/tb/testbench.v`
- [ ] SystemVerilog design files: `part1/rtl/{top,top_with_sram,controller,datapath}.sv`
- [ ] Synthesis scripts: `part1/synth/{compile_dc,compile_with_sram}.tcl`
- [ ] No tool-generated files (`csrc/`, `simv.daidir/`, `*.fsdb`, `*.log`, `*.rep`, `WORK/`)
