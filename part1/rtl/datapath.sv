module datapath(
    input clk, reset,
    input mem2reg, pcsrc,
    input alusrc, regdst,
    input regwrite, jump, 
    input [2:0] alucontrol,
    output zero,
    output [31:0] pc,
    input [31:0] instr,
    output [31:0] aluout, writedata,
    input [31:0] readdata
);

    logic [4:0] write2reg;
    logic [31:0] pcnext, pcnextbr, pcplus4, pcbranch;
    logic [31:0] signimm, signimmsh;
    logic [31:0] srca, srcb;
    logic [31:0] result;

    // next PC logic
    flopr #(32) pcreg(clk, reset, pcnext, pc);
    adder pcadd1 (pc, 32'b100, pcplus4);
    sl2 immsh(signimm, signimmsh);
    adder pcadd2(pcplus4, signimmsh, pcbranch);
    mux2 #(32) pcbrmux(pcplus4, pcbranch, pcsrc, pcnextbr);
    mux2 #(32) pcmux(pcnextbr, {pcplus4[31:28], instr[25:0], 2'b00}, jump, pcnext);

    // register file logic
    regfile rf(clk, regwrite, instr[25:21], instr[20:16], write2reg, result, srca, writedata);
    mux2 #(5) wrmux(instr[20:16], instr[15:11], regdst, write2reg);
    mux2 #(32) resmux(aluout, readdata, mem2reg, result);
    signext se(instr[15:0], signimm);
    
    // ALU logic
    mux2 #(32) srcbmux(writedata, signimm, alusrc, srcb);
    alu alu(srca, srcb, alucontrol, aluout, zero);

endmodule

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

    assign rd1 = (ra1 != 0) ? rf[ra1] : 0;
    assign rd2 = (ra2 != 0) ? rf[ra2] : 0;
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