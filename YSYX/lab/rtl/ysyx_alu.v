// 32-bit ALU building block for the RV32E core: op selected by a 4-bit code matching funct3/funct7[5].
`default_nettype none

module ysyx_alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,   // {alt, funct3}
    output reg  [31:0] y
);
    wire [4:0] shamt = b[4:0];
    wire alt = op[3];
    wire signed [31:0] sra = $signed(a) >>> shamt;
    always @(*) begin
        case (op[2:0])
            3'b000: y = alt ? (a - b) : (a + b);
            3'b001: y = a << shamt;
            3'b010: y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            3'b011: y = (a < b) ? 32'd1 : 32'd0;
            3'b100: y = a ^ b;
            3'b101: y = alt ? sra : (a >> shamt);
            3'b110: y = a | b;
            default: y = a & b;
        endcase
    end
endmodule

`default_nettype wire
