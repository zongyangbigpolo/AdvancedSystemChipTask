`timescale 1ns/1ps
`default_nettype none

module tb;
    reg clk = 1'b0;
    reg rst = 1'b1;
    wire halted, commit_valid, commit_wen, illegal;
    wire [31:0] commit_pc, commit_wdata, a0_value;
    wire [3:0] commit_rd;

    ysyx_lab_core #(.MEM_WORDS(1024)) dut (
        .clk(clk), .rst(rst), .halted(halted),
        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_wen(commit_wen),
        .commit_rd(commit_rd), .commit_wdata(commit_wdata),
        .illegal(illegal), .a0_value(a0_value)
    );

    reg [1023:0] hex_file, trace_file;
    integer fd, cycles, max_cycles, k;

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("HEX=%s", hex_file)) begin $display("missing +HEX"); $finish; end
        if (!$value$plusargs("TRACE=%s", trace_file)) begin $display("missing +TRACE"); $finish; end
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 200000;
        for (k = 0; k < 1024; k = k + 1) dut.mem[k] = 32'd0;
        $readmemh(hex_file, dut.mem);
        fd = $fopen(trace_file, "w");
        cycles = 0;
        // Release reset on a falling edge and sample after combinational settling to avoid posedge races.
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        forever begin
            #1;
            if (illegal) begin
                $fwrite(fd, "ILLEGAL %08x\n", commit_pc);
                $display("RESULT ILLEGAL pc=%08x cycles=%0d", commit_pc, cycles);
                $fclose(fd); $finish;
            end
            if (halted) begin
                $fwrite(fd, "HALT %08x\n", a0_value);
                $display("RESULT %s a0=%0d cycles=%0d", a0_value == 0 ? "HIT_GOOD_TRAP" : "HIT_BAD_TRAP", a0_value, cycles);
                $fclose(fd); $finish;
            end
            if (commit_valid) begin
                if (commit_wen) $fwrite(fd, "%08x x%0d=%08x\n", commit_pc, commit_rd, commit_wdata);
                else            $fwrite(fd, "%08x -\n", commit_pc);
            end
            cycles = cycles + 1;
            @(negedge clk);
            if (cycles >= max_cycles) begin
                $display("RESULT TIMEOUT cycles=%0d", cycles);
                $fclose(fd); $finish;
            end
        end
    end
endmodule

`default_nettype wire
