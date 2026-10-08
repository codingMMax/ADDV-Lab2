
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
`ifdef FWD_TEST
        $readmemh("mem/forwarding_test.dat", RAM);
`elsif FLUSH_TEST
        $readmemh("mem/flushing_test.dat", RAM);
`else
        $readmemh("mem/memfile.dat", RAM);
`endif
    end

    assign readdata = RAM[addr];

endmodule