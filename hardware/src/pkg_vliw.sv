package pkg_vliw;

    parameter integer DATA_WIDTH = 32;
    parameter integer ADDR_WIDTH = 32;
    parameter integer NUM_REGS = 8;
    parameter integer NUM_SLOTS = 4;
    parameter integer SLOT_WIDTH = 16;
    parameter integer BUNDLE_WIDTH = 64;
    parameter integer MEMORY_BYTES = 65536;

    // Dispatcher has to know what units are busy in order to send NOP to unoccupied unit
    localparam logic [SLOT_WIDTH-1:0] NOP_ENCODING = 16'h0000;

    typedef logic [DATA_WIDTH-1:0] word_t;
    typedef logic [ADDR_WIDTH-1:0] address_t;
    typedef logic [SLOT_WIDTH-1:0] slot_t;
    typedef logic [BUNDLE_WIDTH-1:0] bundle_t;
    typedef logic [$clog2(NUM_REGS)-1:0] reg_index_t;

    typedef enum logic [1:0] {
        OPCODE_MATH   = 2'b00,
        OPCODE_LOST   = 2'b01,
        OPCODE_JUMP   = 2'b10,
        OPCODE_CRYPTO = 2'b11
    } opcode_t;

    typedef enum logic [5:0] {
        MATH_NOP  = 6'b000000,
        MATH_MOV  = 6'b000001,
        MATH_SUM  = 6'b000010,
        MATH_DIFF = 6'b000011,
        MATH_AND  = 6'b000100,
        MATH_OR   = 6'b000101,
        MATH_XOR  = 6'b000110,
        MATH_NOT  = 6'b000111,
        MATH_SHL  = 6'b001000,
        MATH_SHR  = 6'b001001,
        MATH_SAR  = 6'b001010,
        MATH_MUL  = 6'b001011,
        MATH_GTN  = 6'b001100,
        MATH_LTN  = 6'b001101,
        MATH_EOR  = 6'b001110,
        MATH_NEZ  = 6'b001111
    } math_funct_t;

    typedef enum logic [3:0] {
        LOST_LOW  = 4'b0000,
        LOST_LOB  = 4'b0001,
        LOST_LOBU = 4'b0010,
        LOST_LOH  = 4'b0011,
        LOST_LOHU = 4'b0100,
        LOST_STW  = 4'b0101,
        LOST_STB  = 4'b0110,
        LOST_STH  = 4'b0111
    } lost_funct_t;

    typedef enum logic [1:0] {
        JUMP_J   = 2'b00,
        JUMP_JZ  = 2'b01,
        JUMP_JNZ = 2'b10,
        JUMP_JR  = 2'b11
    } jump_funct_t;

    typedef enum logic [3:0] {
        CRYPTO_AUTH    = 4'b0000,
        CRYPTO_WRITE   = 4'b0001,
        CRYPTO_FEISTEL = 4'b0010,
        CRYPTO_PWD     = 4'b0011,
        CRYPTO_RVK     = 4'b0100
    } crypto_funct_t;

    typedef struct packed {
        logic [2:0] rs1;
        logic [2:0] rs2;
        logic [5:0] funct;
        logic pipe;
        logic immediate;
        opcode_t opcode;
    } math_inst_t;

    typedef struct packed {
        logic [2:0] rd;
        logic [2:0] rs;
        logic [3:0] funct;
        logic [2:0] offset;
        logic immediate;
        opcode_t opcode;
    } lost_inst_t;

    typedef struct packed {
        logic [2:0] rd;
        logic [7:0] offset;
        logic [1:0] funct;
        logic immediate;
        opcode_t opcode;
    } jump_inst_t;

    typedef struct packed {
        logic [2:0] rs1;
        logic [2:0] rs2;
        logic [3:0] funct;
        logic [1:0] round_or_subkey;
        logic [1:0] key_index;
        opcode_t opcode;
    } crypto_inst_t;

endpackage