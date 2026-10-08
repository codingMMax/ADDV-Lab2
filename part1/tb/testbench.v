///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Testbench template for MIPS processor
// - This testbench uses two arrays (expected_data and expected_addr) to store data and addresses of expected operations
// - It samples every clock cycle where memwrite is high (handles back-to-back stores)
//   and checks the write against the expected values.
//
// Program selection (compile-time):
//   default            -> mem/memfile.dat        (baseline, 2 stores)
//   +define+FWD_TEST   -> mem/forwarding_test.dat (ADD chain, 5 stores)
//   +define+FLUSH_TEST -> mem/flushing_test.dat  (BEQ taken/not-taken, 2 stores)
//
// At the end it prints cycles, retired instructions, CPI and IPC.
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
module MIPS_Testbench ();
    reg clk;
    reg reset;
    wire [31:0] writedata, dataadr;
    wire memwrite;

    integer i;
    integer j;

    // performance counters
    integer cycle_count;
    integer instr_count;
    integer stop_count;

    // expected memory writes
`ifdef FWD_TEST
    parameter N = 5;
`elsif FLUSH_TEST
    parameter N = 2;
`else
    parameter N = 2;
`endif

    reg [31:0] expected_data[N:1];
    reg [31:0] expected_addr[N:1]; 
    
    // Instantiate top module
    top dut(
        .clk(clk),
        .reset(reset),
        .writedata(writedata),
        .dataadr(dataadr),
        .memwrite(memwrite)
    );
    
    // Initialize expected data and addresses
    initial begin
`ifdef FWD_TEST
        expected_data[1] = 32'd3;  expected_addr[1] = 32'h40;
        expected_data[2] = 32'd4;  expected_addr[2] = 32'h44;
        expected_data[3] = 32'd7;  expected_addr[3] = 32'h48;
        expected_data[4] = 32'd11; expected_addr[4] = 32'h4c;
        expected_data[5] = 32'd18; expected_addr[5] = 32'h50;
`elsif FLUSH_TEST
        expected_data[1] = 32'd4;  expected_addr[1] = 32'h4c;
        expected_data[2] = 32'd6;  expected_addr[2] = 32'h50;
`else
        expected_data[1] = 32'h7;
        expected_addr[1] = 32'h50;

        expected_data[2] = 32'h7;
        expected_addr[2] = 32'h54;
`endif
    end

    // Waveform dump for Verdi (novas.fsdb)
    initial begin
        $fsdbDumpvars(0, MIPS_Testbench);
    end

    // Clock generation
    always begin
        clk <= 1'b0; 
        #5;
        clk <= 1'b1; 
        #5;
    end

    // Performance counters: cycles since reset, instructions retired (WB valid)
    initial begin
        cycle_count = 0;
        instr_count = 0;
        stop_count = 0;
    end

    always @(posedge clk) begin
        if (!reset && !stop_count)
            cycle_count = cycle_count + 1;
        if (!stop_count && dut.mips.dp.validW)
            instr_count = instr_count + 1;
    end
    
    // Monitor memory writes: sample each cycle where memwrite is high
    always begin
        // Initialize reset
        reset = 1'b1;
        @(posedge clk);
        @(posedge clk);
        reset = 1'b0;

        i = 1;
        while (i <= N) begin
            @(negedge clk);
            if (memwrite) begin
                // Check if both data and address are expected values
                if (dataadr == expected_addr[i] && writedata == expected_data[i]) begin
                    $display("Memory write %0d successful : wrote %h to address %h", i, writedata, dataadr);
                end else begin
                    $display("ERROR: Memory write %0d : wrote %h to address %h ; Expected %h to address %h)", 
                             i, writedata, dataadr, expected_data[i], expected_addr[i]);
                end
                i = i + 1;
            end
        end
        // let the last store retire, then freeze the counters
        repeat (2) @(posedge clk);
        stop_count = 1;
        $display("TEST COMPLETE");
        $display("PERF: cycles=%0d instructions=%0d CPI=%f IPC=%f",
                 cycle_count, instr_count, cycle_count*1.0/instr_count, instr_count*1.0/cycle_count);
        $finish;
    end
endmodule
