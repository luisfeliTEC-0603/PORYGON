// Tipos y constantes compartidos por dispatch, unidades funcionales y registros.
package pkg_vliw;

    parameter integer DATA_WIDTH        = 32;
    parameter integer ADDR_WIDTH        = 32;
    parameter integer NUM_REGS          = 8;
    parameter integer RF_READ_PORTS     = 10;
    parameter integer RF_WRITE_PORTS    = 5;
    parameter integer NUM_SLOTS         = 4;
    parameter integer SLOT_WIDTH        = 16;
    parameter integer BUNDLE_WIDTH      = 64;
    parameter integer MEMORY_BYTES      = 65536;

    localparam logic [ADDR_WIDTH-1:0] TEXT_BASE_ADDRESS = 32'h0000_0000;
    localparam logic [ADDR_WIDTH-1:0] DATA_BASE_ADDRESS = 32'h0001_0000;

    // Dispatcher has to know what units are busy in order to send NOP to unoccupied unit
    localparam logic [SLOT_WIDTH-1:0] NOP_ENCODING = 16'h0000;

    typedef logic [DATA_WIDTH-1:0] word_t;
    typedef logic [ADDR_WIDTH-1:0] address_t;
    typedef logic [SLOT_WIDTH-1:0] slot_t;
    typedef logic [BUNDLE_WIDTH-1:0] bundle_t;
    typedef logic [$clog2(NUM_REGS)-1:0] reg_index_t;

    localparam integer NUM_UNITS = 5;
    localparam integer UNIT_ALU0 = 0;
    localparam integer UNIT_ALU1 = 1;
    localparam integer UNIT_LSU = 2;
    localparam integer UNIT_BRUH = 3;
    localparam integer UNIT_CRYPTO = 4;
    localparam integer WB_ALU0 = 0;
    localparam integer WB_ALU1 = 1;
    localparam integer WB_LSU = 2;
    localparam integer WB_CRYPTO_L = 3;
    localparam integer WB_CRYPTO_R = 4;
    localparam integer BUNDLE_BYTES = BUNDLE_WIDTH / 8;
    // Dos bundles jovenes para instruction_memory combinacional + IF/ID + ID/EX.
    localparam integer BRANCH_NOP_BUNDLES = 2;
    localparam address_t RESET_PC = TEXT_BASE_ADDRESS;

    /**
     * @brief Operacion capturada en ID/EX desde el estado previo del RF.
     * @details El slot conserva funciones y destinos, incluido el segundo
     * destino Feistel. Los operandos dejan de depender del RF al emitir.
     */
    typedef struct packed {
        logic valid;
        slot_t instruction;
        slot_t immediate;
        word_t operand_a;
        word_t operand_b;
        address_t pc;
    } issued_op_t;

    /**
     * @brief Canal de resultado con procedencia para WB y depuracion.
     * @details valid califica dato, destino, instruccion y PC conjuntamente.
     * No representa una solicitud que pueda esperar o ser arbitrada.
     */
    typedef struct packed {
        logic valid;
        reg_index_t destination;
        word_t data;
        address_t pc;
        slot_t instruction;
    } wb_channel_t;

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
        MATH_NEZ  = 6'b001111,
        MATH_MULH = 6'b010000
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

    typedef enum logic [2:0] {
        CRYPTO_AUTH    = 3'b000,
        CRYPTO_WRITE   = 3'b001,
        CRYPTO_FEISTEL = 3'b010,
        CRYPTO_PWD     = 3'b011,
        CRYPTO_RVK     = 3'b100,
        CRYPTO_LOPW    = 3'b101
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
        logic [2:0] funct;
        // [6:5]: ronda, subllave o palabra de credencial, según funct.
        logic [1:0] round_or_subkey;
        logic [1:0] key_index;
        logic reserved;
        opcode_t opcode;
    } crypto_inst_t;

endpackage
