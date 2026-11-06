`timescale 1ns/1ps
`default_nettype none

// Reads "a b op expected" vectors (hex) and compares the ALU output; reports mismatches and PASS/FAIL.
module alu_tb;
    reg [31:0] a, b, expected;
    reg [3:0]  op;
    wire [31:0] y;
    integer fd, code, total, bad;
    reg [1023:0] vec_file;

    ysyx_alu dut (.a(a), .b(b), .op(op), .y(y));

    initial begin
        if (!$value$plusargs("VEC=%s", vec_file)) begin $display("missing +VEC"); $finish; end
        fd = $fopen(vec_file, "r");
        if (fd == 0) begin $display("cannot open %0s", vec_file); $finish; end
        total = 0; bad = 0;
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h %h %h\n", a, b, op, expected);
            if (code == 4) begin
                #1;
                total = total + 1;
                if (y !== expected) begin
                    bad = bad + 1;
                    if (bad <= 5)
                        $display("MISMATCH a=%08x b=%08x op=%01x got=%08x exp=%08x", a, b, op, y, expected);
                end
            end
        end
        $fclose(fd);
        $display("ALU_RESULT total=%0d mismatch=%0d %s", total, bad, bad == 0 ? "PASS" : "FAIL");
        $finish;
    end
endmodule

`default_nettype wire
