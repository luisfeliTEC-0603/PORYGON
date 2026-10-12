// LOST calcula la dirección en EX1 y guarda la operación para EX2.
// EX2 controla el acceso a memoria y selecciona el dato de una carga.
// Los anchos por defecto vienen del paquete; la máscara de cuatro bytes
// corresponde a la palabra de 32 bits definida por la ISA.
module lost_unit #(
    parameter integer DATA_WIDTH = pkg_vliw::DATA_WIDTH,
    parameter integer ADDR_WIDTH = pkg_vliw::ADDR_WIDTH
) (
    input  logic                               clk_i,
    input  logic                               rst_ni,

    // Dispatch entrega el slot y el literal; el banco de registros entrega
    // Reg[rs] como base y Reg[rd] como dato de un store.
    input  logic                               nop_flag_i,
    input  pkg_vliw::lost_inst_t               instruction_i,
    input  logic [pkg_vliw::SLOT_WIDTH-1:0]   immediate_i,
    input  logic [ADDR_WIDTH-1:0]              base_address_i,
    input  logic [DATA_WIDTH-1:0]              store_data_i,

    // La memoria entrega una palabra alineada; LOST elige dentro de ella
    // el byte, la media palabra o la palabra que solicita la instrucción.
    input  logic [DATA_WIDTH-1:0]              memory_read_data_i,
    output logic [ADDR_WIDTH-1:0]              effective_address_o,
    output logic [ADDR_WIDTH-1:0]              memory_address_o,
    output logic                               memory_read_enable_o,
    output logic [3:0]                         memory_write_enable_o,
    output logic [DATA_WIDTH-1:0]              memory_write_data_o,

    // Un load válido produce un dato para writeback. Una dirección desalineada
    // cancela el acceso y se señala por separado.
    output logic                               load_valid_o,
    output logic [DATA_WIDTH-1:0]              load_data_o,
    output logic                               invalid_address_o
);
    import pkg_vliw::*;

    logic [ADDR_WIDTH-1:0] offset_extended;
    logic [ADDR_WIDTH-1:0] incoming_address;
    logic [ADDR_WIDTH-1:0] effective_address_q;
    logic [DATA_WIDTH-1:0] store_data_q;
    logic [3:0] function_q;
    logic active_q;
    logic [4:0] byte_shift;
    logic [DATA_WIDTH-1:0] selected_word;
    logic [1:0] byte_lane;
    logic word_aligned;
    logic half_aligned;
    logic [DATA_WIDTH-1:0] signed_byte_data;
    logic [DATA_WIDTH-1:0] unsigned_byte_data;
    logic [DATA_WIDTH-1:0] signed_half_data;
    logic [DATA_WIDTH-1:0] unsigned_half_data;

    // EX1: el bit imm elige entre el offset corto y el slot literal.
    // Ambos desplazamientos se extienden con signo antes de sumar la base.
    assign offset_extended = instruction_i.immediate
        ? {{(ADDR_WIDTH-SLOT_WIDTH){immediate_i[SLOT_WIDTH-1]}}, immediate_i}
        : {{(ADDR_WIDTH-3){instruction_i.offset[2]}}, instruction_i.offset};
    assign incoming_address = base_address_i + offset_extended;

    // Registro EX1/EX2: un NOP impide aceptar una operación nueva, pero no
    // cancela la que ya se encuentra en EX2.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            effective_address_q <= '0;
            store_data_q <= '0;
            function_q <= '0;
            active_q <= 1'b0;
        end else begin
            active_q <= !nop_flag_i && instruction_i.opcode == OPCODE_LOST;
            effective_address_q <= incoming_address;
            store_data_q <= store_data_i;
            function_q <= instruction_i.funct;
        end
    end

    // EX2: la memoria recibe la dirección alineada de la palabra; los bits
    // bajos conservados seleccionan el byte o la media palabra solicitada.
    assign effective_address_o = effective_address_q;
    assign memory_address_o = {effective_address_o[ADDR_WIDTH-1:2], 2'b00};
    assign byte_lane = effective_address_o[1:0];
    assign byte_shift = {byte_lane, 3'b000};
    assign selected_word = memory_read_data_i >> byte_shift;
    assign word_aligned = byte_lane == 2'b00;
    assign half_aligned = byte_lane[0] == 1'b0;
    assign signed_byte_data = {{(DATA_WIDTH-8){selected_word[7]}}, selected_word[7:0]};
    assign unsigned_byte_data = {{(DATA_WIDTH-8){1'b0}}, selected_word[7:0]};
    assign signed_half_data = {{(DATA_WIDTH-16){selected_word[15]}}, selected_word[15:0]};
    assign unsigned_half_data = {{(DATA_WIDTH-16){1'b0}}, selected_word[15:0]};

    // Cada bit de la máscara habilita un byte de la palabra de 32 bits.
    // Las salidas quedan inactivas ante NOP, función reservada o desalineación.
    always_comb begin
        memory_read_enable_o = 1'b0;
        memory_write_enable_o = 4'b0000;
        memory_write_data_o = '0;
        load_valid_o = 1'b0;
        load_data_o = '0;
        invalid_address_o = 1'b0;

        if (active_q) begin
            case (function_q)
                LOST_LOW: begin
                    if (!word_aligned) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_read_enable_o = 1'b1;
                        load_valid_o = 1'b1;
                        load_data_o = memory_read_data_i;
                    end
                end
                LOST_LOB: begin
                    memory_read_enable_o = 1'b1;
                    load_valid_o = 1'b1;
                    load_data_o = signed_byte_data;
                end
                LOST_LOBU: begin
                    memory_read_enable_o = 1'b1;
                    load_valid_o = 1'b1;
                    load_data_o = unsigned_byte_data;
                end
                LOST_LOH: begin
                    if (!half_aligned) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_read_enable_o = 1'b1;
                        load_valid_o = 1'b1;
                        load_data_o = signed_half_data;
                    end
                end
                LOST_LOHU: begin
                    if (!half_aligned) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_read_enable_o = 1'b1;
                        load_valid_o = 1'b1;
                        load_data_o = unsigned_half_data;
                    end
                end
                LOST_STW: begin
                    if (!word_aligned) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_write_enable_o = 4'b1111;
                        memory_write_data_o = store_data_q;
                    end
                end
                LOST_STB: begin
                    // En little endian, el byte de la dirección menor va
                    // en los bits menos significativos de la palabra.
                    memory_write_enable_o = 4'b0001 << byte_lane;
                    memory_write_data_o = store_data_q << byte_shift;
                end
                LOST_STH: begin
                    if (!half_aligned) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_write_enable_o = 4'b0011 << byte_lane;
                        memory_write_data_o = store_data_q << byte_shift;
                    end
                end
                default: begin
                    // Las funciones reservadas no acceden a memoria.
                end
            endcase
        end
    end
endmodule
