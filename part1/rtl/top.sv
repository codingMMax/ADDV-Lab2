
module top(
    input clk, reset,
    output [31:0] writedata, dataadr,
    output memwrite

);

    logic [31:0] pc, instr, readdata;

    // instantiate processor and memories
    mips mips (clk, reset, pc, instr, memwrite, dataadr, writedata, readdata);
    imem imem(pc[7:2], instr);
    dmem dmem(clk, memwrite, dataadr, writedata, readdata);

endmodule

module mips(
    input clk, reset,
    output [31:0] pc,
    input [31:0] instr,
    output      memwrite,
    output [31:0] aluout, writedata,
    input [31:0] readdata

);

    logic mem2reg, pcsrc, alusrc, regdst, regwrite, jump, zero;
    logic [2:0] alucontrol;

    controller controller(instr[31:26], instr[5:0], zero, mem2reg, 
                memwrite, pcsrc, alusrc, regdst, regwrite, jump, alucontrol);

    datapath dp(clk, reset, mem2reg, pcsrc, alusrc, regdst, regwrite, jump, 
                alucontrol, zero, pc, instr, aluout, writedata, readdata);

endmodule


module dmem (

    input clk, 
    input we,
    input [31:0] addr, writedata,
    output [31:0] readdata
);
    logic[31:0] RAM[63:0];
    logic[5:0] word_addr;
    assign word_addr = addr[7:2];
    assign readdata = RAM[word_addr];

    always_ff @( posedge clk ) begin : blockName
        if (we)
            RAM[word_addr] <= writedata;
    end

endmodule

module imem(
    input [5:0] addr,
    output [31:0] readdata

);
    logic [31:0] RAM[63:0];

    initial begin
        $readmemh("mem/memfile.dat", RAM);
    end

    assign readdata = RAM[addr];

endmodule