/**
 * @brief LSU en adaptacion al protocolo CPU-L1 en EX.
 * @details La FSM sigue aceptacion y consumo de una sola demanda. Sus campos
 * se derivan de ID/EX, que debe conservarse hasta la finalizacion. Los enables
 * de memoria actuales describen la preparacion; dmem_req_valid_o califica la
 * oferta CPU-L1. El load se selecciona y extiende antes del flanco de consumo;
 * execution_stage lo captura junto con su destino, PC e instruccion al avanzar.
 * La conexion del protocolo y del control de avance al nucleo sigue pendiente.
 * @see docs/ii-proyecto/cpu-memory-contract.md
 */
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

    /** @brief Control CPU-L1; la disponibilidad de captura es independiente del stall. */
    input  logic                             dmem_req_ready_i,
    input  logic                             dmem_rsp_valid_i,
    input  logic                             dmem_rsp_error_i,
    input  logic                             completion_ready_i,
    output logic                             dmem_req_valid_o,
    output logic                             dmem_rsp_ready_o,
    output logic                             dmem_done_o,
    output logic                             dmem_error_o,

    /** @brief Campos preparados combinacionalmente; dmem_req_valid_o califica la oferta. */
    output logic [ADDR_WIDTH-1:0]            effective_address_o,
    output logic [ADDR_WIDTH-1:0]            memory_address_o,
    output logic                             memory_read_enable_o,
    output logic [3:0]                       memory_write_enable_o,
    output logic [DATA_WIDTH-1:0]            memory_write_data_o,
    output logic                             invalid_address_o,

    /** @brief Resultado combinacional para capturar en el flanco de consumo. */
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

    /** @brief Una demanda: los campos permanecen en ID/EX hasta completar. */
    typedef enum logic {OFFER, WAIT_RESPONSE} request_state_t;
    request_state_t request_state_q, request_state_d;
    logic request_fire;

    assign dmem_req_valid_o = rst_ni && (request_state_q == OFFER) &&
                              (memory_read_enable_o || (|memory_write_enable_o));
    assign request_fire = dmem_req_valid_o && dmem_req_ready_i;
    assign dmem_rsp_ready_o = rst_ni && completion_ready_i &&
                              ((request_state_q == WAIT_RESPONSE) || request_fire);
    assign dmem_done_o = dmem_rsp_valid_i && dmem_rsp_ready_o;
    assign dmem_error_o = dmem_done_o && dmem_rsp_error_i;

    /**
     * @brief Consumir tiene prioridad: un hit no deja una demanda pendiente.
     * @details Tras aceptar sin consumir se baja req_valid, aunque EX siga
     * retenido. Una respuesta disponible espera completion_ready_i.
     */
    always_comb begin
        request_state_d = request_state_q;
        if (dmem_done_o) begin
            request_state_d = OFFER;
        end else if (request_fire) begin
            request_state_d = WAIT_RESPONSE;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            request_state_q <= OFFER;
        end else begin
            request_state_q <= request_state_d;
        end
    end

    /** @brief Los metadatos permanecen en ID/EX hasta consumir la respuesta. */
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

    /**
     * @brief Formatea la palabra de respuesta con la operacion retenida en EX.
     * @details Se usa el mismo camino para hit y respuesta tardia. Un store o
     * una respuesta con error completa el acceso sin producir un load valido.
     * Dato y destino solo se usan al capturarse load_valid_o en un flanco.
     */
    assign load_rd_o = load_valid_o ? instruction_i.rd : '0;
    assign load_byte_shift = {incoming_address[1:0], 3'b000};
    assign selected_word = memory_read_data_i >> load_byte_shift;
    assign signed_byte_data = {{(DATA_WIDTH-8){selected_word[7]}}, selected_word[7:0]};
    assign unsigned_byte_data = {{(DATA_WIDTH-8){1'b0}}, selected_word[7:0]};
    assign signed_half_data = {{(DATA_WIDTH-16){selected_word[15]}}, selected_word[15:0]};
    assign unsigned_half_data = {{(DATA_WIDTH-16){1'b0}}, selected_word[15:0]};

    always_comb begin
        load_valid_o = dmem_done_o && memory_read_enable_o && !dmem_rsp_error_i;
        load_data_o = '0;
        if (load_valid_o) begin
            case (instruction_i.funct)
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
