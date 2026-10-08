
module top(
    input clk, reset,
    output [31:0] writedata, dataadr,
    output memwrite

);

    logic [31:0] pcF, instrF, readdataM;

    // instantiate processor and memories
    mips mips (clk, reset, pcF, instrF, memwrite, dataadr, writedata, readdataM);
    imem imem(pcF[7:2], instrF);
    dmem dmem(clk, memwrite, dataadr, writedata, readdataM);

endmodule


module mips(
    input clk, reset,
    output [31:0] pcF,
    input [31:0] instrF,
    output memwriteM,
    output [31:0] aluoutM, storeDataM,
    input [31:0] readdataM
);
    logic mem2regD, memwriteD, branchD, alusrcD, regdstD, regwriteD, jumpD;
    logic [2:0] alucontrolD;
    logic [31:0] instrD;

    controller c(
        .op(instrD[31:26]), .funct(instrD[5:0]),
        .mem2reg(mem2regD), .memwrite(memwriteD), .branch(branchD),
        .alusrc(alusrcD), .regdst(regdstD), .regwrite(regwriteD),
        .jump(jumpD), .alucontrol(alucontrolD)
    );

    datapath dp(
        .clk(clk), .reset(reset),
        .branchD(branchD), .jumpD(jumpD),
        .mem2regD(mem2regD), .memwriteD(memwriteD), .alusrcD(alusrcD),
        .regdstD(regdstD), .regwriteD(regwriteD), .alucontrolD(alucontrolD),
        .instrF(instrF), .readdataM(readdataM),
        .pcF(pcF), .instrD(instrD),
        .aluoutM(aluoutM), .storeDataM(storeDataM), .memwriteM(memwriteM)
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
