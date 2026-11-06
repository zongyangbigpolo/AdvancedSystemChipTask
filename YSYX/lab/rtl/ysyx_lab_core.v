// RV32E single-cycle core: RV32I base integer subset limited to x0-x15, word load/store, EBREAK halt.
`default_nettype none

module ysyx_lab_core #(
    parameter MEM_WORDS = 1024
) (
    input  wire        clk,
    input  wire        rst,
    output reg         halted,
    output wire        commit_valid,
    output wire [31:0] commit_pc,
    output wire        commit_wen,
    output wire [3:0]  commit_rd,
    output wire [31:0] commit_wdata,
    output wire        illegal,
    output wire [31:0] a0_value
);
    localparam OP_LUI = 7'b0110111, OP_AUIPC = 7'b0010111, OP_JAL = 7'b1101111,
               OP_JALR = 7'b1100111, OP_BRANCH = 7'b1100011, OP_LOAD = 7'b0000011,
               OP_STORE = 7'b0100011, OP_IMM = 7'b0010011, OP_REG = 7'b0110011,
               OP_SYSTEM = 7'b1110011;

    reg [31:0] mem [0:MEM_WORDS-1];
    reg [31:0] regs [1:15];
    reg [31:0] pc;

    wire [31:0] inst   = mem[pc[31:2] % MEM_WORDS];
    wire [6:0]  opcode = inst[6:0];
    wire [2:0]  funct3 = inst[14:12];
    wire [6:0]  funct7 = inst[31:25];
    wire [4:0]  rd_f   = inst[11:7];
    wire [4:0]  rs1_f  = inst[19:15];
    wire [4:0]  rs2_f  = inst[24:20];

    wire [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_u = {inst[31:12], 12'b0};
    wire [31:0] imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

    wire [31:0] src1 = (rs1_f[3:0] == 4'd0) ? 32'd0 : regs[rs1_f[3:0]];
    wire [31:0] src2 = (rs2_f[3:0] == 4'd0) ? 32'd0 : regs[rs2_f[3:0]];

    wire is_reg   = opcode == OP_REG;
    wire [31:0] alu_b = is_reg ? src2 : imm_i;
    wire [4:0]  shamt = alu_b[4:0];
    wire        alt   = is_reg ? funct7[5] : (funct3 == 3'b101 && funct7[5]);

    // Keep the arithmetic shift in its own signed context; inside a mixed ternary it would be evaluated as unsigned.
    wire signed [31:0] sra_out = $signed(src1) >>> shamt;

    reg [31:0] alu_out;
    always @(*) begin
        case (funct3)
            3'b000: alu_out = (is_reg && alt) ? src1 - alu_b : src1 + alu_b;
            3'b001: alu_out = src1 << shamt;
            3'b010: alu_out = ($signed(src1) < $signed(alu_b)) ? 32'd1 : 32'd0;
            3'b011: alu_out = (src1 < alu_b) ? 32'd1 : 32'd0;
            3'b100: alu_out = src1 ^ alu_b;
`ifdef INJECT_SRA_BUG
            3'b101: alu_out = src1 >> shamt;
`else
            3'b101: alu_out = alt ? sra_out : (src1 >> shamt);
`endif
            3'b110: alu_out = src1 | alu_b;
            default: alu_out = src1 & alu_b;
        endcase
    end

    reg take_branch;
    always @(*) begin
        case (funct3)
            3'b000: take_branch = src1 == src2;
            3'b001: take_branch = src1 != src2;
            3'b100: take_branch = $signed(src1) < $signed(src2);
            3'b101: take_branch = $signed(src1) >= $signed(src2);
            3'b110: take_branch = src1 < src2;
            3'b111: take_branch = src1 >= src2;
            default: take_branch = 1'b0;
        endcase
    end

    wire [31:0] load_addr  = src1 + imm_i;
    wire [31:0] store_addr = src1 + imm_s;
    wire [31:0] load_data  = mem[load_addr[31:2] % MEM_WORDS];

    wire regs_ok = !rd_f[4] && !rs1_f[4] && !rs2_f[4];
    reg legal, wen;
    reg [31:0] wdata, next_pc;
    always @(*) begin
        legal = 1'b1; wen = 1'b0; wdata = 32'd0; next_pc = pc + 32'd4;
        case (opcode)
            OP_LUI:    begin wen = 1'b1; wdata = imm_u; legal = !rd_f[4]; end
            OP_AUIPC:  begin wen = 1'b1; wdata = pc + imm_u; legal = !rd_f[4]; end
            OP_JAL:    begin wen = 1'b1; wdata = pc + 32'd4; next_pc = pc + imm_j; legal = !rd_f[4]; end
            OP_JALR:   begin wen = 1'b1; wdata = pc + 32'd4; next_pc = (src1 + imm_i) & ~32'd1;
                             legal = funct3 == 3'b000 && !rd_f[4] && !rs1_f[4]; end
            OP_BRANCH: begin if (take_branch) next_pc = pc + imm_b;
                             legal = funct3 != 3'b010 && funct3 != 3'b011 && !rs1_f[4] && !rs2_f[4]; end
            OP_LOAD:   begin wen = 1'b1; wdata = load_data;
                             legal = funct3 == 3'b010 && load_addr[1:0] == 2'b00 && !rd_f[4] && !rs1_f[4]; end
            OP_STORE:  legal = funct3 == 3'b010 && store_addr[1:0] == 2'b00 && !rs1_f[4] && !rs2_f[4];
            OP_IMM:    begin wen = 1'b1; wdata = alu_out; legal = !rd_f[4] && !rs1_f[4];
                             if (funct3 == 3'b001 && funct7 != 7'b0) legal = 1'b0;
                             if (funct3 == 3'b101 && funct7 != 7'b0 && funct7 != 7'b0100000) legal = 1'b0; end
            OP_REG:    begin wen = 1'b1; wdata = alu_out; legal = regs_ok &&
                             (funct7 == 7'b0 || (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))); end
            OP_SYSTEM: legal = inst == 32'h00100073;
            default:   legal = 1'b0;
        endcase
        if (!legal) wen = 1'b0;
    end

    wire is_ebreak = inst == 32'h00100073;
    assign illegal       = !halted && !rst && !legal;
    assign commit_valid  = !halted && !rst && legal && !is_ebreak;
    assign commit_pc     = pc;
    assign commit_wen    = wen && rd_f[3:0] != 4'd0;
    assign commit_rd     = rd_f[3:0];
    assign commit_wdata  = wdata;
    assign a0_value      = regs[10];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'h0;
            halted <= 1'b0;
            for (i = 1; i < 16; i = i + 1) regs[i] <= 32'd0;
        end else if (!halted) begin
            if (is_ebreak || !legal) begin
                halted <= 1'b1;
            end else begin
                if (commit_wen) regs[rd_f[3:0]] <= wdata;
                if (opcode == OP_STORE) mem[store_addr[31:2] % MEM_WORDS] <= src2;
                pc <= next_pc;
            end
        end
    end
endmodule

`default_nettype wire
