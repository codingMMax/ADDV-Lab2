# ADDV Lab #2 — Single-Cycle MIPS with SRAM

RTL for Lab #2: a single-cycle MIPS processor with instruction/data memories.

## Contents

| File | Description |
|---|---|
| `top.v` | Top-level with behavioral memories (`imem` loads `memfile.dat`) |
| `top_with_sram.v` | Top-level variant using the OpenRAM `SRAM_32x64_1rw` macro |
| `controller.v` | Main controller/decoder (`controller`, `maindec`, `aludec`) |
| `datapath.v` | MIPS datapath (`datapath`, `regfile`, `alu`, `adder`, `mux2`, `sl2`, `signext`, `flopr`) |
| `testbench.v` | `MIPS_Testbench` |
| `memfile.dat` | Program image for instruction memory |
| `sram_32x64/` | OpenRAM 32x64 1RW SRAM macro: `.v`, `.db`, `.lib` (TT 1.1 V, 25 C) |
