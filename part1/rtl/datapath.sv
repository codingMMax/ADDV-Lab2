module datapath(
    input  logic        clk, reset,
    input  logic        branchD, jumpD,
    input  logic        mem2regD, memwriteD, alusrcD, regdstD, regwriteD,
    input  logic [2:0]  alucontrolD,
    input  logic [31:0] instrF, readdataM,
    output logic [31:0] pcF, instrD,
    output logic [31:0] aluoutM, storeDataM,
    output logic        memwriteM
);
    // =====================================================================
    // PIPELINED MIPS DATAPATH — stage map (keep this order)
    // Naming: F = IF, D = ID, E = EX, M = MEM, W = WB
    // Reference: docs/pipeline-guide.md (naming convention appendix)
    //
    //   1. FETCH (IF)              -> 2. IF/ID pipeline registers
    //   3. DECODE + REGISTER FILE  -> 4. ID/EX pipeline registers
    //   5. EXECUTE                 -> 6. EX/MEM pipeline registers
    //   7. MEMORY                  -> 8. MEM/WB pipeline registers
    //   9. WRITEBACK
    // =====================================================================

    // IF stage signals
    logic [31:0] pcplus4F, pcnextF, pcjumpD, pcplus4D;
    // ID stage signals
    logic [31:0] rd1D, rd2D, signimmD;
    logic [4:0] destD;

    // ID --> EX
    logic regwriteE, mem2regE, memwriteE, alusrcE, branchE;
    logic [2:0] alucontrolE;
    logic [31:0] pcplus4E, rd1E, rd2E, signimmE;
    logic [4:0] rsE, rtE, destE;

    // EX stage
    logic [31:0] aluSrcAE, aluSrcBE, rtFwdE, aluoutE, storeDataE, pcbranchE;
    logic zeroE, pcsrcE;

    // EX --> MEM (aluoutM/storeDataM/memwriteM are output ports)
    logic regwriteM, mem2regM;
    logic [4:0] destM;

    // MEM --> WB
    logic regwriteW, mem2regW;
    logic [31:0] readdataW, aluoutW;
    logic [4:0]  destW;

    // WB
    logic [31:0] resultW;
    // hazard control
    logic StallF, StallD, FlushD, FlushE;
    logic [1:0] fwdAE, fwdBE;
    logic loadUseE;
    // valid chain (measurement only): pulses high in WB once per retired instruction
    logic validF, validD, validE, validM, validW;


    // =====================================================================
    // 1. FETCH (IF) — PC register, PC+4 adder, PC-next muxes
    // =====================================================================
    assign pcjumpD = {pcplus4D[31:28], instrD[25:0], 2'b00};
    assign pcnextF = pcsrcE ? pcbranchE : (jumpD ? pcjumpD : pcplus4F);
    pipe_reg #(32) pcreg(clk, reset, ~StallF, 1'b0, pcnextF, pcF);
    adder pcadd1(pcF, 32'b100, pcplus4F);

    // =====================================================================
    // 2. IF/ID PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(32) if_id_pcplus4(clk, reset, ~StallD, FlushD, pcplus4F, pcplus4D);
    pipe_reg #(32) if_id_instr  (clk, reset, ~StallD, FlushD, instrF,   instrD);

    // =====================================================================
    // 3. DECODE + REGISTER FILE (ID) — controller (in mips) decodes instrD,
    //    regfile read, signext, dest mux, jump target
    // =====================================================================
    regfile rf(clk, regwriteW, instrD[25:21], instrD[20:16], destW, resultW, rd1D, rd2D);
    mux2 #(5) wrmux(instrD[20:16], instrD[15:11], regdstD, destD);
    signext se(instrD[15:0], signimmD);

    // =====================================================================
    // 4. ID/EX PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(1)  id_ex_regwrite (clk, reset, 1'b1, FlushE, regwriteD,      regwriteE);
    pipe_reg #(1)  id_ex_mem2reg  (clk, reset, 1'b1, FlushE, mem2regD,       mem2regE);
    pipe_reg #(1)  id_ex_memwrite (clk, reset, 1'b1, FlushE, memwriteD,      memwriteE);
    pipe_reg #(1)  id_ex_alusrc   (clk, reset, 1'b1, FlushE, alusrcD,        alusrcE);
    pipe_reg #(1)  id_ex_branch   (clk, reset, 1'b1, FlushE, branchD,        branchE);
    pipe_reg #(3)  id_ex_aluctrl  (clk, reset, 1'b1, FlushE, alucontrolD,    alucontrolE);
    pipe_reg #(32) id_ex_pcplus4  (clk, reset, 1'b1, FlushE, pcplus4D,       pcplus4E);
    pipe_reg #(32) id_ex_rd1      (clk, reset, 1'b1, FlushE, rd1D,           rd1E);
    pipe_reg #(32) id_ex_rd2      (clk, reset, 1'b1, FlushE, rd2D,           rd2E);
    pipe_reg #(32) id_ex_signimm  (clk, reset, 1'b1, FlushE, signimmD,       signimmE);
    pipe_reg #(5)  id_ex_rs       (clk, reset, 1'b1, FlushE, instrD[25:21],  rsE);
    pipe_reg #(5)  id_ex_rt       (clk, reset, 1'b1, FlushE, instrD[20:16],  rtE);
    pipe_reg #(5)  id_ex_dest     (clk, reset, 1'b1, FlushE, destD,          destE);

    // =====================================================================
    // 5. EXECUTE (EX) — forward muxes, ALU, zero, branch target,
    //    pcsrcE = branchE & zeroE
    // =====================================================================
    always_comb begin
        fwdAE = 2'b00;
        if      (regwriteM && destM != 0 && destM == rsE) fwdAE = 2'b10;
        else if (regwriteW && destW != 0 && destW == rsE) fwdAE = 2'b01;
    end
    always_comb begin
        fwdBE = 2'b00;
        if      (regwriteM && destM != 0 && destM == rtE) fwdBE = 2'b10;
        else if (regwriteW && destW != 0 && destW == rtE) fwdBE = 2'b01;
    end

    assign aluSrcAE = (fwdAE == 2'b10) ? aluoutM :
                      (fwdAE == 2'b01) ? resultW : rd1E;
    assign rtFwdE   = (fwdBE == 2'b10) ? aluoutM :
                      (fwdBE == 2'b01) ? resultW : rd2E;

    mux2 #(32) srcbmux(rtFwdE, signimmE, alusrcE, aluSrcBE);
    alu alu0(aluSrcAE, aluSrcBE, alucontrolE, aluoutE, zeroE);

    adder pcadd2(pcplus4E, {signimmE[29:0], 2'b00}, pcbranchE);
    assign pcsrcE = branchE & zeroE;

    assign storeDataE = rtFwdE;   // forwarded rt is the store data

    // =====================================================================
    // 6. EX/MEM PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(1)  ex_mem_regwrite (clk, reset, 1'b1, 1'b0, regwriteE,  regwriteM);
    pipe_reg #(1)  ex_mem_mem2reg  (clk, reset, 1'b1, 1'b0, mem2regE,   mem2regM);
    pipe_reg #(1)  ex_mem_memwrite (clk, reset, 1'b1, 1'b0, memwriteE,  memwriteM);
    pipe_reg #(32) ex_mem_aluout   (clk, reset, 1'b1, 1'b0, aluoutE,    aluoutM);
    pipe_reg #(32) ex_mem_storedata(clk, reset, 1'b1, 1'b0, storeDataE, storeDataM);
    pipe_reg #(5)  ex_mem_dest     (clk, reset, 1'b1, 1'b0, destE,      destM);

    // =====================================================================
    // 7. MEMORY (MEM) — aluoutM = address, storeDataM = store data
    //    (dmem itself stays in top.sv; the ports above drive it)
    // =====================================================================

    // =====================================================================
    // 8. MEM/WB PIPELINE REGISTERS
    // =====================================================================
    pipe_reg #(1)  mem_wb_regwrite(clk, reset, 1'b1, 1'b0, regwriteM,  regwriteW);
    pipe_reg #(1)  mem_wb_mem2reg (clk, reset, 1'b1, 1'b0, mem2regM,   mem2regW);
    pipe_reg #(32) mem_wb_readdata(clk, reset, 1'b1, 1'b0, readdataM,  readdataW);
    pipe_reg #(32) mem_wb_aluout  (clk, reset, 1'b1, 1'b0, aluoutM,    aluoutW);
    pipe_reg #(5)  mem_wb_dest    (clk, reset, 1'b1, 1'b0, destM,      destW);

    // =====================================================================
    // 9. WRITEBACK (WB) — resultW drives the regfile write port (section 3)
    // =====================================================================
    assign resultW = mem2regW ? readdataW : aluoutW;

    // =====================================================================
    // Valid chain (measurement only) — one pulse in WB per retired instruction
    // =====================================================================
    assign validF = 1'b1;
    pipe_reg #(1) if_id_valid  (clk, reset, ~StallD, FlushD, validF, validD);
    pipe_reg #(1) id_ex_valid  (clk, reset, 1'b1,    FlushE, validD, validE);
    pipe_reg #(1) ex_mem_valid (clk, reset, 1'b1,    1'b0,   validE, validM);
    pipe_reg #(1) mem_wb_valid (clk, reset, 1'b1,    1'b0,   validM, validW);

    // =====================================================================
    // Hazard logic: load-use stall + control-hazard flush
    // =====================================================================
    assign loadUseE = mem2regE && (destE != 0) &&
                      ((destE == instrD[25:21]) || (destE == instrD[20:16]));
    assign StallF = loadUseE;
    assign StallD = loadUseE;
    assign FlushE = pcsrcE | loadUseE;
    assign FlushD = pcsrcE | jumpD;
endmodule


module pipe_reg #(parameter WIDTH = 32)(
    input logic clk, reset, en, flush,
    input logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);
    always_ff @(posedge clk, posedge reset)
        if (reset) q <= 0;
        else if (flush) q <= 0;
        else if (en)    q<= d;
endmodule



// =====================================================================
// Helper modules (same as reference; add `pipe_reg` here in Step 2)
// =====================================================================
module regfile(

    input clk,
    input we3,
    input [4:0] ra1, ra2, wa3,
    input [31:0] wd3,
    output [31:0] rd1, rd2

);

    reg [31:0] rf[31:0];

    always_ff @(posedge clk) begin
        if (we3) rf[wa3] <= wd3;
    end

    assign rd1 = (ra1 != 0) ? ((we3 && wa3 == ra1)? wd3 : rf[ra1]): 0;
    assign rd2 = (ra2 != 0) ? ((we3 && wa3 == ra2)? wd3 : rf[ra2]): 0;

endmodule


module alu(
    input [31:0] a,
    input [31:0] b,
    input [2:0] control,
    output logic [31:0] result,
    output zero
);
    // define LAU ops
    localparam ALU_AND = 3'b000;
    localparam ALU_OR  = 3'b001;
    localparam ALU_ADD = 3'b010;
    localparam ALU_SUB = 3'b110;
    localparam ALU_SLT = 3'b111;

    always_comb begin
        case(control)
            ALU_AND: result = a & b;
            ALU_OR:  result = a | b;
            ALU_ADD: result = a + b;
            ALU_SUB: result = a - b;
            ALU_SLT: result = ($signed(a) < $signed(b)); // signed less than
            default: result = 32'bx; // undefined operation
        endcase
    end


    assign zero = (result == 32'b0);

endmodule

//////////////////////////////////////////////////////////////////////
// Adder Module
//////////////////////////////////////////////////////////////////////
module adder (
    input [31:0] a, b,
    output [31:0] y
);
    assign y = a + b;
endmodule


//////////////////////////////////////////////////////////////////////
// 2-to-1 Multiplexer Module
//////////////////////////////////////////////////////////////////////
module mux2 # (parameter WIDTH = 8) (
    input [WIDTH-1:0] d0, d1,
    input s,
    output [WIDTH-1:0] y
);
    assign y = s ? d1 : d0;
endmodule

//////////////////////////////////////////////////////////////////////
// Shift Left by 2 Module
//////////////////////////////////////////////////////////////////////
module sl2 (
    input [31:0] a,
    output [31:0] y
);
    // shift left by 2
    assign y = {a[29:0], 2'b00};
endmodule


//////////////////////////////////////////////////////////////////////
// Sign Extension Module
//////////////////////////////////////////////////////////////////////
module signext (
    input [15:0] a,
    output [31:0] y
);
    assign y = {{16{a[15]}}, a};
endmodule


// flop register module
module flopr # (parameter WIDTH = 8)(
    input clk, reset,
    input [WIDTH-1:0] d,
    output reg [WIDTH-1:0] q
);
    always_ff @ (posedge clk, posedge reset)
        if (reset) q <= 0;
        else q <= d;
endmodule
