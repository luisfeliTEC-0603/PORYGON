`timescale 1ns/1ps

/**
 * @brief Doble de referencia CPU-L1 de una demanda, solo para simulacion.
 * @details Modela datos y latencia fija, sin etiquetas ni reemplazo de cache.
 * Las palabras son little endian y los stores reciben dato ya desplazado.
 * @param MEMORY_BYTES Capacidad del segmento de datos en bytes.
 * @param BASE_ADDRESS Direccion fisica del primer byte.
 * @param INIT_FILE Imagen de bytes compatible con las herramientas existentes.
 * @param RESPONSE_CYCLES Flanco de respuesta contando aceptacion como E1.
 * @param RESPONSE_ORIGIN Procedencia de respuesta correcta; errores usan ORIGIN_ERROR.
 */
module cpu_memory_reference #(
    parameter integer MEMORY_BYTES = pkg_memory::MEMORY_BYTES,
    parameter pkg_memory::address_t BASE_ADDRESS = pkg_memory::DATA_BASE_ADDRESS,
    parameter INIT_FILE = "",
    parameter integer RESPONSE_CYCLES = 1,
    parameter integer RESPONSE_ORIGIN = pkg_metrics::ORIGIN_REFERENCE
) (
    input logic clk_i,
    input logic rst_ni,
    input logic accept_enable_i,
    input logic req_valid_i,
    output logic req_ready_o,
    input pkg_memory::address_t req_addr_i,
    input logic req_write_i,
    input pkg_memory::word_t req_wdata_i,
    input pkg_memory::byte_mask_t req_wstrb_i,
    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output pkg_memory::word_t rsp_rdata_o,
    output logic rsp_error_o,
    output pkg_metrics::demand_origin_t rsp_origin_o
);
    localparam integer WORD_BYTES = $bits(pkg_memory::word_t) / 8;
    localparam pkg_memory::address_t LAST_WORD_ADDRESS =
        BASE_ADDRESS + MEMORY_BYTES - WORD_BYTES;
    logic [7:0] memory [0:MEMORY_BYTES-1];
    localparam integer COUNT_WIDTH = (RESPONSE_CYCLES > 2) ? $clog2(RESPONSE_CYCLES) : 1;
    typedef struct packed {
        pkg_memory::address_t address;
        logic write;
        pkg_memory::word_t data;
        pkg_memory::byte_mask_t mask;
    } request_t;
    request_t request_q, active_request;
    logic pending_q, serviced_q, request_fire;
    logic [COUNT_WIDTH-1:0] remaining_q;

    /**
     * @brief El hit responde sin registro extra; una espera usa campos retenidos.
     * @details accept_enable solo retrasa aceptacion, nunca un servicio iniciado.
     * Sin otra demanda pendiente los datos de lectura permanecen estables.
     */
    always_comb begin
        req_ready_o = rst_ni && accept_enable_i && !pending_q;
        request_fire = req_valid_i && req_ready_o;
        active_request = pending_q ? request_q :
                         {req_addr_i, req_write_i, req_wdata_i, req_wstrb_i};
        rsp_valid_o = rst_ni && (pending_q ? (remaining_q == '0) :
                                (request_fire && RESPONSE_CYCLES == 1));
        rsp_error_o = rsp_valid_o && !address_valid(active_request.address);
        rsp_rdata_o = '0;
        if (rsp_valid_o && !rsp_error_o && !active_request.write) begin
            rsp_rdata_o = read_word(active_request.address);
        end
    end

    /** @brief Procedencia configurable de simulacion, estable durante la respuesta. */
    always_comb begin
        case (RESPONSE_ORIGIN)
            pkg_metrics::ORIGIN_L1: rsp_origin_o = pkg_metrics::ORIGIN_L1;
            pkg_metrics::ORIGIN_WB: rsp_origin_o = pkg_metrics::ORIGIN_WB;
            pkg_metrics::ORIGIN_L2: rsp_origin_o = pkg_metrics::ORIGIN_L2;
            pkg_metrics::ORIGIN_MEMORY: rsp_origin_o = pkg_metrics::ORIGIN_MEMORY;
            default: rsp_origin_o = pkg_metrics::ORIGIN_REFERENCE;
        endcase
        if (rsp_error_o) begin
            rsp_origin_o = pkg_metrics::ORIGIN_ERROR;
        end
    end

    /**
     * @brief Cuenta relojes reales aunque el nucleo este congelado.
     * @details Aceptar E1 deja N-2: al llegar a cero se responde antes de EN.
     * serviced_q separa terminar servicio de consumir respuesta: store una vez.
     * Reset cancela la demanda y la respuesta, sin borrar la imagen de bytes.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pending_q <= 1'b0;
            serviced_q <= 1'b0;
            remaining_q <= '0;
            request_q <= '0;
        end else begin
            if (request_fire) begin
                request_q <= active_request;
                pending_q <= !(rsp_valid_o && rsp_ready_i);
                remaining_q <= COUNT_WIDTH'((RESPONSE_CYCLES > 1) ? RESPONSE_CYCLES-2 : 0);
                serviced_q <= rsp_valid_o;
            end else if (pending_q) begin
                if (remaining_q != '0) begin
                    remaining_q <= remaining_q - 1'b1;
                end else begin
                    serviced_q <= 1'b1;
                    if (rsp_ready_i) begin
                        pending_q <= 1'b0;
                    end
                end
            end
            if (rsp_valid_o && (!pending_q || !serviced_q) &&
                active_request.write && !rsp_error_o) begin
                write_word(active_request.address, active_request.data, active_request.mask);
            end
        end
    end

    /** @brief Valida rango de palabra completa y alineacion fisica. */
    function automatic logic address_valid(input pkg_memory::address_t address);
        address_valid = (address >= BASE_ADDRESS) && (address <= LAST_WORD_ADDRESS) &&
                        (address[$clog2(WORD_BYTES)-1:0] == '0);
    endfunction

    /** @brief Lee una palabra alineada; un acceso invalido entrega cero. */
    function automatic pkg_memory::word_t read_word(input pkg_memory::address_t address);
        read_word = '0;
        if (address_valid(address)) begin
            for (integer lane = 0; lane < WORD_BYTES; lane++) begin
                read_word[8*lane +: 8] = memory[address-BASE_ADDRESS+lane];
            end
        end
    endfunction

    /**
     * @brief Aplica una escritura por mascara; no modifica accesos invalidos.
     * @details El controlador llama este helper una vez al completar
     * el servicio. Las asignaciones bloqueantes actualizan el modelo de datos.
     */
    task automatic write_word(
        input pkg_memory::address_t address,
        input pkg_memory::word_t data,
        input pkg_memory::byte_mask_t mask
    );
        if (address_valid(address)) begin
            for (integer lane = 0; lane < WORD_BYTES; lane++) begin
                if (mask[lane]) begin
                    memory[address-BASE_ADDRESS+lane] = data[8*lane +: 8];
                end
            end
        end
    endtask

    /** @brief Inicializa una imagen por simulacion; reset no borrara los datos. */
    initial begin
        if (RESPONSE_CYCLES < 1) begin
            $fatal(1, "RESPONSE_CYCLES debe ser positivo");
        end
        for (integer byte_index = 0; byte_index < MEMORY_BYTES; byte_index++) begin
            memory[byte_index] = '0;
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end
endmodule
