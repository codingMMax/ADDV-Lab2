// TODO(pipeline): drop the `zero` input and `pcsrc` output; expose `branch`
//                 instead (pcsrcE = branchE & zeroE is computed in the EX stage).
//                 mips decodes the datapath's `instrD` output (ID-stage instr).
module controller(
    input [5:0] op, funct,
    output mem2reg, memwrite,
    output branch, alusrc,
    output regdst, regwrite,
    output jump,
    output [2:0] alucontrol
);

    logic [1:0] aluop;
    maindec md (op, mem2reg, memwrite, branch, alusrc, regdst, regwrite, jump, aluop);
    aludec ad (funct, aluop, alucontrol);
    
endmodule


module maindec(
    input [5:0] op,
    output mem2reg, memwrite,
    output branch, alusrc,
    output regdst, regwrite,
    output jump,
    output [1:0] aluop
);

    reg [8:0] controls;
    
    assign {regwrite, regdst, alusrc, branch, memwrite, mem2reg, jump, aluop} = controls;

    always_comb
        case(op)
            6'b000000: controls = 9'b110000010; //Rtyp
            6'b100011: controls = 9'b101001000; //LW
            6'b101011: controls = 9'b001010000; //SW
            6'b000100: controls = 9'b000100001; //BEQ
            6'b001000: controls = 9'b101000000; //ADDI
            6'b000010: controls = 9'b000000100; //J
            default: controls = 9'bxxxxxxxxx; //???
        endcase
endmodule


module aludec (
    input [5:0] funct,
    input [1:0] aluop,
    output logic [2:0] alucontrol
);
    always_comb
        case (aluop)
            2'b00: alucontrol = 3'b010; // add
            2'b01: alucontrol = 3'b110; // sub
            default: case(funct) // RTYPE
                6'b100000: alucontrol = 3'b010; // ADD
                6'b100010: alucontrol = 3'b110; // SUB
                6'b100100: alucontrol = 3'b000; // AND
                6'b100101: alucontrol = 3'b001; // OR
                6'b101010: alucontrol = 3'b111; // SLT
                default: alucontrol = 3'bxxx; // ???
            endcase
        endcase
endmodule