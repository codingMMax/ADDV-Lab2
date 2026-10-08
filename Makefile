# ADDV Lab 2 — MIPS processor
#
# Requires the tool environment first:
#     bash:   source setup.sh
#     tcsh:   source env.cshrc
#
# Usage:
#     make sim-ref             # compile + simulate the provided single-cycle design
#     make sim-part1           # compile + simulate the Part 1 pipelined design
#     make compile-part1-verdi # Part 1 compile with Verdi database (-kdb)
#     make waves-part1         # open Verdi on the Part 1 FSDB
#     make clean               # remove build artifacts

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

VCS        ?= $(VCS_HOME)/bin/vcs
VERDI      ?= $(VERDI_HOME)/bin/verdi
VCSFLAGS   ?= -full64 -sverilog -debug_access+all
VERDIFLAGS ?= -dbdir ./simv.daidir -ssf novas.fsdb -nologo

# Non-pipelined reference (in reference/)
REF_SRCS = top.v controller.v datapath.v testbench.v

# Part 1 design (update these to .sv files after the SystemVerilog conversion)
P1_SRCS = rtl/top.sv rtl/controller.sv rtl/datapath.sv tb/testbench.v

.PHONY: all sim-ref sim-part1 sim-fwd sim-flush compile-part1-verdi waves-part1 synth-ref synth-ref-sram synth-part1 synth-part1-sram synth-clean clean

all: sim-ref

sim-ref:
	cd reference && $(VCS) $(VCSFLAGS) $(REF_SRCS) 2>&1 | tee compile.log
	cd reference && ./simv | tee run.log

sim-part1:
	cd part1 && $(VCS) $(VCSFLAGS) $(P1_SRCS) 2>&1 | tee compile.log
	cd part1 && ./simv | tee run.log

# Hazard test programs (see part1/mem/*.txt for the assembly listings)
sim-fwd:
	cd part1 && $(VCS) $(VCSFLAGS) +define+FWD_TEST $(P1_SRCS) 2>&1 | tee compile.log
	cd part1 && ./simv | tee run.log

sim-flush:
	cd part1 && $(VCS) $(VCSFLAGS) +define+FLUSH_TEST $(P1_SRCS) 2>&1 | tee compile.log
	cd part1 && ./simv | tee run.log

compile-part1-verdi:
	cd part1 && $(VCS) $(VCSFLAGS) -kdb -lca $(P1_SRCS) 2>&1 | tee compile_verdi.log

waves-part1:
	cd part1 && $(VERDI) $(VERDIFLAGS)

# ---------------------------------------------------------------- synthesis
DC ?= dc_shell

synth-ref:
	cd reference/synth && $(DC) -f compile_dc.tcl 2>&1 | tee synth.log

synth-ref-sram:
	cd reference/synth && $(DC) -f compile_with_sram.tcl 2>&1 | tee synth_sram.log

synth-part1:
	cd part1/synth && $(DC) -f compile_dc.tcl 2>&1 | tee synth.log

synth-part1-sram:
	cd part1/synth && $(DC) -f compile_with_sram.tcl 2>&1 | tee synth_sram.log

synth-clean:
	cd reference/synth && rm -rf WORK *.rep *.log *.svf command.log default.svf alib-*
	cd part1/synth && rm -rf WORK *.rep *.log *.svf command.log default.svf alib-*

clean:
	cd reference && rm -rf csrc simv simv.daidir ucli.key novas.* verdiLog *.log
	cd part1 && rm -rf csrc simv simv.daidir ucli.key novas.* verdiLog *.log
