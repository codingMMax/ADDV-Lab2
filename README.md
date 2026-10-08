# ADDV Lab #2 — 5-Stage Pipelined MIPS Processor

**Course:** ADDV, Fall 2026 (partner lab)
**Partners:** _Name 1 (ASU ID)_ · _Name 2 (ASU ID)_

This repository holds the Lab #2 work: turning the provided **single-cycle MIPS
processor** into a **5-stage pipelined** SystemVerilog design (Part 1), then
adding a custom **MULADD** instruction and a **performance monitor** (Part 2).

Lab assignment (Notion): <https://adventlab.notion.site/Lab-2-MIPS-Processor-Design-Fall-2026-3c50256590168043829bf9cab2daf6c6>

The design supports: `add`, `sub`, `and`, `or`, `slt`, `lw`, `sw`, `beq`
(the provided program also uses `addi` and `j`).

---

## Repository layout

```
LAB2/
├── README.md                  # this file
├── Makefile                   # sim / Verdi / clean shortcuts
├── setup.sh                   # tool environment for bash (vault server)
├── env.cshrc                  # tool environment for tcsh (Apporto)
├── sram_32x64/                # OpenRAM 32x64 SRAM macro (.v/.db/.lib), shared
├── reference/                 # PROVIDED single-cycle design — do not modify
│   ├── top.v                  #   top, mips, dmem, imem
│   ├── controller.v           #   controller, maindec, aludec
│   ├── datapath.v             #   datapath, regfile, alu, adder, mux2, sl2, signext, flopr
│   ├── testbench.v            #   expected_data / expected_addr checker
│   ├── top_with_sram.v        #   SRAM variant of top (synthesis only)
│   └── memfile.dat            #   instruction memory image (hex words)
├── part1/                     # PART 1 deliverable: 5-stage pipelined MIPS
│   ├── rtl/                   #   design sources (seeded with reference copies)
│   ├── tb/                    #   testbench (update expected arrays)
│   ├── mem/                   #   memfile.dat + MIPS assembly programs (.txt)
│   └── synth/                 #   synthesis scripts (compile_dc.tcl, compile_with_sram.tcl)
├── part2/                     # PART 2 deliverable: MULADD + performance monitor
│   ├── rtl/  tb/  mem/  synth/
└── docs/                      # notes, figures, report material
```

Why this layout: `reference/` stays pristine so you can always re-run the
baseline for the performance comparison, while `part1/` and `part2/` map 1:1 to
the two folders required in the submission zip. `sram_32x64/` is shared by both
parts. `part1/` was seeded with copies of the provided files (only change so
far: `part1/rtl/top.v` loads `mem/memfile.dat` because simulation runs from
`part1/`).

---

## Setup

### Apporto (ECE Cad Lab) — tcsh

```tcsh
tcsh
cd ~/ADDV/LAB2
source env.cshrc
```

### This vault server — bash

```bash
cd /mnt/vault0/jiajunh5/ADDV/LAB2
source setup.sh
```

Both set `VCS_HOME`, `VERDI_HOME`, the tool `PATH`, the Verdi FSDB library path,
and the license variables. `setup.sh` auto-detects the installation
(`/usr/local2/synopsys` on Apporto, `/home/tools/synopsys` on the vault).

---

## Quick start

```bash
make sim-ref        # compile + run the provided single-cycle design
make sim-part1      # compile + run the Part 1 copy
make clean
```

Equivalent raw commands (what the Makefile runs):

```bash
cd reference
vcs -full64 top.v controller.v datapath.v testbench.v
./simv | tee run.log
```

Expected output ends with:

```
Memory write 1 successful : wrote 00000007 to address 00000050
Memory write 2 successful : wrote 00000007 to address 00000054
TEST COMPLETE
```

### Waveforms (Verdi)

1. Add dumping to the testbench (the provided one has none):
   `$fsdbDumpvars;` inside an `initial` block.
2. `make compile-part1-verdi` (adds `-kdb -lca`)
3. `make sim-part1` (creates `novas.fsdb`)
4. `make waves-part1` (opens `simv.daidir` + `novas.fsdb`)

---

## The provided design, explained in plain English

**`top.v`** — the wiring of the whole chip.
- `top`: instantiates `mips` plus two 64×32 memories. Instruction address is
  `pc[7:2]` (word-aligned), and data memory is written on the clock edge.
- `mips`: instantiates `controller` and `datapath` and connects them. It uses
  two implicit wires (`zero`, `pcsrc`) — SystemVerilog will require these to be
  declared as `logic`, which is part of the conversion work.
- `imem`: read-only array initialized by `$readmemh("memfile.dat", RAM)`.
- `dmem`: 64-word array; combinational read, synchronous write when `we=1`.

**`controller.v`** — decides what the datapath does.
- `maindec`: looks at the 6-bit opcode and produces the control bits
  (`regwrite`, `regdst`, `alusrc`, `branch`, `memwrite`, `memtoreg`, `jump`,
  `aluop`). Supported opcodes: R-type, `lw`, `sw`, `beq`, `addi`, `j`.
- `aludec`: turns `aluop` + the R-type `funct` field into one of five ALU
  operations: add, sub, and, or, slt.
- `controller`: `pcsrc = branch & zero` — the branch is taken when the ALU
  result is zero, exactly like `beq`.

**`datapath.v`** — the computational part.
- PC register (`flopr`) with **asynchronous reset**; `pc+4` adder; branch
  target adder; muxes for branch/jump selection.
- `regfile`: 32×32, two combinational read ports, one synchronous write port;
  register 0 always reads as zero.
- `signext` + `sl2` build the branch offset; `mux2` modules select write
  register (`rt` vs `rd`), ALU source (`rt` vs immediate), and writeback data
  (ALU result vs memory read data).
- `alu`: add/sub/and/or/slt (slt is signed) and a `zero` flag.

**`testbench.v`** — a self-checking harness by memory writes.
- Generates a 10 ns clock, asserts reset for two cycles, then watches
  `memwrite`. For each `N` (currently 2) it waits for a write and compares
  `dataadr`/`writedata` against `expected_data`/`expected_addr`. **You must
  extend these arrays when you add instructions to `memfile.dat`.**

**`top_with_sram.v`** — same processor, but `imem`/`dmem` are instantiations of
the OpenRAM `SRAM_32x64_1rw` macro instead of flip-flop arrays (`dmem` maps
`we`→`web0` active-low, `rd`←`dout0`; `imem` is read-only). Used for the SRAM
synthesis experiment only — the SRAM behavioral model is not for functional
simulation.

**Why pipelining:** the single-cycle design has CPI = 1 but a huge critical
path (PC → imem → regfile → ALU → dmem → regfile), so its clock is slow.
Splitting it into IF/ID/EX/MEM/WB shortens the critical path and raises the
clock frequency, at the cost of data/control hazards — which forwarding,
flushing and stalling must handle.

---

## Part 1 — TODO checklist

Work in small steps and keep `make sim-part1` passing after each one; commit at
every checkpoint. Do **not** mix syntax churn (Step 1) with architecture changes
(Step 2) — that makes debugging much harder.

**Step 0 — Understand + baseline**
- [ ] Read the provided code and the book chapter; run `make sim-ref` (expect two
      `Memory write ... successful` lines and `TEST COMPLETE`).
- [ ] Save the baseline simulation log; keep the non-pipelined design for the
      performance table later.
- [ ] Create a working branch: `git checkout -b part1-pipeline`.

**Step 1 — SystemVerilog conversion (no pipelining yet)**
- [ ] Convert `part1/rtl/*.v` → `*.sv` in place: `logic` instead of `reg`/`wire`,
      `always_comb` for decoders/ALU/muxes, `always_ff` for `regfile`/`flopr`,
      `unique case` in the decoders.
- [ ] Declare the currently implicit wires in `mips` (`zero`, `pcsrc`) as `logic`.
- [ ] Update the Makefile: `P1_SRCS` → the `.sv` files and add `-sverilog` to
      `VCSFLAGS`.
- [ ] Acceptance: `make sim-part1` matches the baseline exactly; commit.
      **No pipeline registers in this step.**

**Step 2 — 5-stage pipeline skeleton (behaviour may be wrong until Step 3)**

> Full walkthrough: [`docs/pipeline-guide.md`](docs/pipeline-guide.md) — logical
> vs physical stages, exact pipeline-register contents, hazard taxonomy, and
> forwarding/stall/flush code.
> Code-level walkthrough: [`docs/pipeline-implementation.md`](docs/pipeline-implementation.md) —
> full Step 2 code, checkpoint order, Step 3 hookup, common compile errors.

- [ ] Keep the hierarchy exactly: `testbench → top → mips → {controller, datapath} → imem, dmem`.
- [ ] Structure `datapath` in this order: fetch logic → IF/ID registers →
      decode + register file → ID/EX registers → execute (ALU) → EX/MEM
      registers → memory logic → MEM/WB registers → writeback logic.
- [ ] Add pipeline registers, e.g.: IF/ID (`pcplus4`, `instr`); ID/EX (all
      control bits, `pcplus4`, `rd1`, `rd2`, `signimm`, `rs/rt/rd`); EX/MEM
      (`regwrite/memtoreg/memwrite`, `aluout`, `writedata`, `writereg`); MEM/WB
      (`regwrite/memtoreg`, `readdata`, `aluout`, `writereg`).
- [ ] Commit (the simulation is expected to be wrong at this point).

**Step 3 — Hazard handling**
- [ ] Data hazards: implement forwarding for `ADD` (paths from EX/MEM and
      MEM/WB outputs back to the ALU inputs; EX/MEM has priority when both match).
- [ ] Control hazards: flush IF/ID and ID/EX on a taken `BEQ` and redirect the
      PC to the EX-computed target (`j` needs the same treatment — the provided
      program uses it).
- [ ] Any other hazard (e.g. load-use) may simply stall the pipeline for one cycle.
- [ ] Acceptance: the baseline program passes again; commit.

**Step 4 — Simulation and verification**
- [ ] Put machine code for all supported instructions into `part1/mem/memfile.dat`
      and update `expected_data`/`expected_addr` in the testbench; verify.
- [ ] Add a forwarding test program (back-to-back `ADD`s with data hazards);
      verify forwarding works.
- [ ] Add a flushing test program (a chain of `BEQ`s); verify flushing works.

**Step 5 — Synthesis**
- [ ] Write `part1/synth/compile_dc.tcl` (`gscl45nm`, `analyze -sverilog`,
      reports); synthesize the non-pipelined reference (`reference/`) and the
      pipelined design (`part1/`); read the timing reports (critical path,
      clock period).
- [ ] SRAM experiment: copy `compile_with_sram.tcl` from
      `/usr/local2/COURSES/ADDV/LAB2/` on Apporto (it is not in the starter zip),
      swap in `top_with_sram`, synthesize, and note the lines in that script that
      add the memory-cell library (`SRAM_32x64_1rw.db`).
- [ ] Add `set_dont_touch [get_cells "imem"]` / `set_dont_touch [get_cells "dmem"]`
      so the memories are not optimized away.

**Step 6 — Report + submission**
- [ ] Microarchitecture diagram of the pipeline with the **critical path
      highlighted**.
- [ ] List the signals that flow through each stage for a `lw`.
- [ ] Describe the code changes (pipelining, forwarding for ADD, flushing for BEQ).
- [ ] Performance table: CPI (latency), IPC (throughput), area, clock frequency
      (or critical-path delay) for non-pipelined vs pipelined; plus the improved
      IPC for the forwarding test and the flushing test.
- [ ] Annotated waveforms: full flow of a load, ADD forwarding, BEQ flushing,
      and the simulation terminal output.
- [ ] Zip: README, Makefiles, assembly `.txt` program(s), `memfile.dat`,
      testbench, SystemVerilog design files — **no tool-generated files**
      (`csrc/`, `simv.daidir/`, `*.fsdb`, `*.log`, ...).

---

## Part 2 — TODO checklist

**MULADD instruction** — `MULADD $1, $2, $3` means `$1 ← $2 * $3 + $1`
- [ ] Pick an opcode; figure out how to obtain the third operand (the old `$1`)
      in a pipeline.
- [ ] Add decode + datapath support (multiply, then add); multiply is 32×32→32.
- [ ] Add a MULADD test program and verify it in simulation.
- [ ] Report: describe the changes, paste the added/modified snippets, include an
      annotated waveform of MULADD flowing through the pipeline.

**Performance monitor** — `perfmon $1, flag` reads a counter into a register
- [ ] Create a `performance_monitor` module with a cycle counter and a
      finished-instruction counter.
- [ ] Add the `perfmon` instruction (flag 0 = cycle counter, 1 = instruction
      counter), with its own opcode; verify in simulation.
- [ ] Report: describe the changes, paste the snippets, include an annotated
      `perfmon` waveform.

**Submission (Part 2 zip)** — same code deliverables as Part 1 plus the new
instructions, plus a "contributions of each partner" summary in the report.

---

## Synthesis notes

The starter zip does **not** include a synthesis script. Two scripts are needed:

1. **Non-SRAM synthesis** (`part1/synth/compile_dc.tcl`, you create it):
   - `set target_library "gscl45nm.db"` from
     `$PDK_DIR/osu_soc/lib/files` (OSU/NCSU FreePDK45), like Lab 0.
   - Use `analyze -sverilog` on the `.sv` files, `elaborate top`, `compile`,
     then `report_timing`, `report_area`, `report_power`.
2. **SRAM synthesis** (`part1/synth/compile_with_sram.tcl`): the lab doc says
   this script is provided at `/usr/local2/COURSES/ADDV/LAB2/` on Apporto but
   it is **not in the starter zip** — copy it from there. It maps `imem`/`dmem`
   to the OpenRAM macro using `sram_32x64/SRAM_32x64_1rw.db`. The report asks
   for the exact lines where that memory library is specified.

Typical run:

```bash
source setup.sh
cd part1/synth
dc_shell -f compile_with_sram.tcl | tee synth_sram.log
```

Notes:
- `dc_shell-t` (Lab 0) and `dc_shell` both exist in the installed version; use
  `dc_shell -f` unless the script requires `-t`.
- Add `set_dont_touch [get_cells "imem"]` / `[get_cells "dmem"]` in the SRAM
  script flow so memory macros are preserved.
- Do not simulate `top_with_sram.v` — the SRAM behavioral model is for synthesis
  experiments only.

---

## Git workflow

- `main` — submission-ready code.
- Work on branches (e.g. `part1-pipeline`, `part1-hazards`, `part2-muladd`) and
  open pull requests or commit directly if working solo at the moment.
- `git pull` before starting; commit small and often; never commit generated
  files (`.gitignore` already covers them, and it keeps `part*/mem/*.txt`
  assembly files tracked).
- Push: `git push origin main` (SSH remote is already configured).

## Submission naming (from the lab doc)

- Report: `first_name1_last_name1_first_name2_last_name2_lab1.pdf`
- Zip: `first_name1_last_name1_first_name2_last_name2_lab1.zip`
  (yes, the doc says `lab1` — follow the Canvas announcement if it differs)
- Include the demo-scheduling screenshot in the report, and the per-partner
  contributions summary.
