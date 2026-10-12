// LOST presenta la solicitud durante EX y procesa la respuesta registrada
// por una memoria de lectura sincrona durante el ciclo siguiente.
module lost_unit #(
    parameter integer DATA_WIDTH = pkg_vliw::DATA_WIDTH,
    parameter integer ADDR_WIDTH = pkg_vliw::ADDR_WIDTH
) (
    input  logic                             clk_i,
    input  logic                             rst_ni,
    input  logic                             nop_flag_i,
    input  pkg_vliw::lost_inst_t             instruction_i,
    input  logic [pkg_vliw::SLOT_WIDTH-1:0] immediate_i,
    input  logic [ADDR_WIDTH-1:0]            base_address_i,
    input  logic [DATA_WIDTH-1:0]            store_data_i,
    input  logic [DATA_WIDTH-1:0]            memory_read_data_i,

    // Solicitud combinacional, estable antes del flanco que captura la RAM.
    output logic [ADDR_WIDTH-1:0]            effective_address_o,
    output logic [ADDR_WIDTH-1:0]            memory_address_o,
    output logic                             memory_read_enable_o,
    output logic [3:0]                       memory_write_enable_o,
    output logic [DATA_WIDTH-1:0]            memory_write_data_o,
    output logic                             invalid_address_o,

    // Respuesta del load solicitada en el flanco anterior.
    output logic                             load_valid_o,
    output logic [2:0]                       load_rd_o,
    output logic [DATA_WIDTH-1:0]            load_data_o
);
    import pkg_vliw::*;

    logic [ADDR_WIDTH-1:0] offset_extended;
    logic [ADDR_WIDTH-1:0] incoming_address;
    logic incoming_valid;
    logic word_aligned;
    logic half_aligned;

    // La RAM registra read_data en el mismo flanco en que LOST guarda estos
    // metadatos. La direccion de la solicitud no pasa por un registro previo.
    logic load_pending_q;
    logic [2:0] load_rd_q;
    logic [3:0] load_function_q;
    logic [1:0] load_lane_q;
    logic [4:0] load_byte_shift;
    logic [DATA_WIDTH-1:0] selected_word;
    logic [DATA_WIDTH-1:0] signed_byte_data;
    logic [DATA_WIDTH-1:0] unsigned_byte_data;
    logic [DATA_WIDTH-1:0] signed_half_data;
    logic [DATA_WIDTH-1:0] unsigned_half_data;

    assign offset_extended = instruction_i.immediate
        ? {{(ADDR_WIDTH-SLOT_WIDTH){immediate_i[SLOT_WIDTH-1]}}, immediate_i}
        : {{(ADDR_WIDTH-3){instruction_i.offset[2]}}, instruction_i.offset};
    assign incoming_address = base_address_i + offset_extended;
    assign incoming_valid = rst_ni && !nop_flag_i && instruction_i.opcode == OPCODE_LOST;
    assign effective_address_o = incoming_address;
    assign memory_address_o = {incoming_address[ADDR_WIDTH-1:2], 2'b00};
    assign word_aligned = incoming_address[1:0] == 2'b00;
    assign half_aligned = incoming_address[0] == 1'b0;

    // EX: la mascara selecciona los bytes de la palabra alineada. Un acceso
    // desalineado se senala en el ciclo de solicitud y no llega a la RAM.
    always_comb begin
        memory_read_enable_o = 1'b0;
        memory_write_enable_o = 4'b0000;
        memory_write_data_o = '0;
        invalid_address_o = 1'b0;

        if (incoming_valid) begin
            case (instruction_i.funct)
                LOST_LOW, LOST_LOB, LOST_LOBU, LOST_LOH, LOST_LOHU: begin
                    if ((instruction_i.funct == LOST_LOW && !word_aligned) ||
                        ((instruction_i.funct == LOST_LOH ||
                          instruction_i.funct == LOST_LOHU) && !half_aligned)) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_read_enable_o = 1'b1;
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
                    memory_write_enable_o = 4'b0001 << incoming_address[1:0];
                    memory_write_data_o = store_data_i << {incoming_address[1:0], 3'b000};
                end
                LOST_STH: begin
                    if (!half_aligned) begin
                        invalid_address_o = 1'b1;
                    end else begin
                        memory_write_enable_o = 4'b0011 << incoming_address[1:0];
                        memory_write_data_o = store_data_i << {incoming_address[1:0], 3'b000};
                    end
                end
                default: begin
                    // Las funciones reservadas no generan solicitudes.
                end
            endcase
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            load_pending_q <= 1'b0;
            load_rd_q <= '0;
            load_function_q <= '0;
            load_lane_q <= '0;
        end else begin
            load_pending_q <= memory_read_enable_o;
            load_rd_q <= instruction_i.rd;
            load_function_q <= instruction_i.funct;
            load_lane_q <= incoming_address[1:0];
        end
    end

    // Respuesta: read_data y los metadatos registrados pertenecen al mismo load.
    assign load_rd_o = load_pending_q ? load_rd_q : '0;
    assign load_byte_shift = {load_lane_q, 3'b000};
    assign selected_word = memory_read_data_i >> load_byte_shift;
    assign signed_byte_data = {{(DATA_WIDTH-8){selected_word[7]}}, selected_word[7:0]};
    assign unsigned_byte_data = {{(DATA_WIDTH-8){1'b0}}, selected_word[7:0]};
    assign signed_half_data = {{(DATA_WIDTH-16){selected_word[15]}}, selected_word[15:0]};
    assign unsigned_half_data = {{(DATA_WIDTH-16){1'b0}}, selected_word[15:0]};

    always_comb begin
        load_valid_o = load_pending_q;
        load_data_o = '0;
        if (load_pending_q) begin
            case (load_function_q)
                LOST_LOW:  load_data_o = memory_read_data_i;
                LOST_LOB:  load_data_o = signed_byte_data;
                LOST_LOBU: load_data_o = unsigned_byte_data;
                LOST_LOH:  load_data_o = signed_half_data;
                LOST_LOHU: load_data_o = unsigned_half_data;
                default:  load_data_o = '0;
            endcase
        end
    end
endmodule
