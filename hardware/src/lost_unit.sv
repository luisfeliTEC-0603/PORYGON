// Unidad de cargas y almacenes. La RAM entrega una palabra de 32 bits
// alineada; LOST selecciona dentro de ella el byte o la media palabra.
// Las salidas son combinacionales. La RAM hace la escritura con reloj.
module lost_unit (
    input  logic                     valid_i,
    input  pkg_vliw::lost_inst_t     instruction_i,
    input  logic [15:0]              immediate_i,
    input  pkg_vliw::address_t       base_address_i,
    input  pkg_vliw::word_t          store_data_i,
    input  pkg_vliw::word_t          memory_read_data_i,
    output pkg_vliw::address_t       effective_address_o,
    output pkg_vliw::address_t       memory_address_o,
    output logic                     memory_read_enable_o,
    output logic [3:0]               memory_write_enable_o,
    output pkg_vliw::word_t          memory_write_data_o,
    output logic                     load_valid_o,
    output pkg_vliw::word_t          load_data_o,
    output logic                     invalid_address_o
);
    import pkg_vliw::*;

    logic [31:0] offset_32;
    logic [4:0] byte_shift;
    logic [31:0] selected_word;
    logic [1:0] byte_lane;
    logic [3:0] function_code;
    logic active;
    logic word_aligned;
    logic half_aligned;
    logic [31:0] signed_byte_data;
    logic [31:0] unsigned_byte_data;
    logic [31:0] signed_half_data;
    logic [31:0] unsigned_half_data;

    // El inmediato ocupa un solo slot de 16 bits. Se extiende con signo
    // porque la dirección base y el sumador son de 32 bits.
    assign offset_32 = instruction_i.immediate
        ? {{16{immediate_i[15]}}, immediate_i}
        : {29'b0, instruction_i.offset};
    assign effective_address_o = base_address_i + offset_32;

    // La RAM trabaja con palabras alineadas. Los bits [1:0] indican
    // cuál de sus cuatro bytes corresponde a la dirección solicitada.
    assign memory_address_o = {effective_address_o[31:2], 2'b00};
    assign byte_lane = effective_address_o[1:0];
    assign byte_shift = {byte_lane, 3'b000};
    assign selected_word = memory_read_data_i >> byte_shift;
    assign function_code = instruction_i.funct;
    assign active = valid_i && instruction_i.opcode == OPCODE_LOST;
    assign word_aligned = byte_lane == 2'b00;
    assign half_aligned = byte_lane[0] == 1'b0;
    assign signed_byte_data = {{24{selected_word[7]}}, selected_word[7:0]};
    assign unsigned_byte_data = {24'b0, selected_word[7:0]};
    assign signed_half_data = {{16{selected_word[15]}}, selected_word[15:0]};
    assign unsigned_half_data = {16'b0, selected_word[15:0]};

    always_comb begin
        memory_read_enable_o = 1'b0;
        memory_write_enable_o = 4'b0000;
        memory_write_data_o = 32'b0;
        load_valid_o = 1'b0;
        load_data_o = 32'b0;
        invalid_address_o = 1'b0;

        if (active) begin
            case (function_code)
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
                        memory_write_data_o = store_data_i;
                    end
                end
                LOST_STB: begin
                    // En little endian, el byte de la dirección menor va
                    // en los bits menos significativos de la palabra.
                    memory_write_enable_o = 4'b0001 << byte_lane;
                    memory_write_data_o = store_data_i << byte_shift;
                end
                LOST_STH: begin
                    if (!half_aligned) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_write_enable_o = 4'b0011 << byte_lane;
                        memory_write_data_o = store_data_i << byte_shift;
                    end
                end
                default: begin
                    // Las funciones reservadas no acceden a memoria.
                end
            endcase
        end
    end
endmodule
