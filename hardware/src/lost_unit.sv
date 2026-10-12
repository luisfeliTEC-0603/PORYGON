// EX1 calcula la dirección y guarda la operación. En EX2, LOST accede
// a la RAM y selecciona el dato. La RAM de prueba escribe al cerrar EX2.
module lost_unit (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     nop_flag_i,
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
    logic [31:0] incoming_address;
    logic [31:0] effective_address_q;
    logic [31:0] store_data_q;
    logic [3:0] function_q;
    logic active_q;
    logic [4:0] byte_shift;
    logic [31:0] selected_word;
    logic [1:0] byte_lane;
    logic word_aligned;
    logic half_aligned;
    logic [31:0] signed_byte_data;
    logic [31:0] unsigned_byte_data;
    logic [31:0] signed_half_data;
    logic [31:0] unsigned_half_data;

    // El offset corto y el inmediato son desplazamientos con signo.
    // Ambos se extienden a 32 bits antes de sumarlos a la base.
    assign offset_32 = instruction_i.immediate
        ? {{16{immediate_i[15]}}, immediate_i}
        : {{29{instruction_i.offset[2]}}, instruction_i.offset};
    assign incoming_address = base_address_i + offset_32;

    // El NOP evita que entre una operación nueva. La operación anterior
    // sigue en EX2 hasta el próximo flanco, aunque nop_flag_i cambie.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            effective_address_q <= 32'b0;
            store_data_q <= 32'b0;
            function_q <= 4'b0;
            active_q <= 1'b0;
        end else begin
            active_q <= !nop_flag_i && instruction_i.opcode == OPCODE_LOST;
            effective_address_q <= incoming_address;
            store_data_q <= store_data_i;
            function_q <= instruction_i.funct;
        end
    end

    // EX2 usa únicamente los valores guardados al terminar EX1.
    assign effective_address_o = effective_address_q;
    assign memory_address_o = {effective_address_o[31:2], 2'b00};
    assign byte_lane = effective_address_o[1:0];
    assign byte_shift = {byte_lane, 3'b000};
    assign selected_word = memory_read_data_i >> byte_shift;
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
