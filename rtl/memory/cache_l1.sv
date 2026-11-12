`timescale 1ns/1ps

/**
 * @brief L1-D en implementacion: 4 KiB, dos vias, LRU y write-back/allocate.
 * @param L2_MAX_INFLIGHT Limite 1..4; determina el ancho de ids L2.
 * @input clk_i, rst_ni Reloj CPU y reset activo bajo.
 * @details Una demanda CPU pendiente. Hit en EX de un ciclo; req y rsp pueden
 * transferirse en el mismo flanco. Un miss reserva una entrada de 32 bytes.
 * Las ofertas con valid && !ready conservan todos sus campos. Reset cancela
 * reservas y operaciones; las metricas siguen activas durante stalls de CPU.
 * @see docs/ii-proyecto/cpu-memory-contract.md
 * @see docs/ii-proyecto/interfaces.md secciones 2, 3 y 8.
 */
module cache_l1 #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /**
     * @brief Solicitud y respuesta de palabra CPU; nombres desde L1.
     * @input dmem_req_* Direccion alineada, store desplazado y mascara de bytes.
     * @output dmem_rsp_* Una respuesta por solicitud; dato cero en store/error.
     * @output dmem_rsp_origin_o Sideband de metricas, calificado por rsp_valid.
     */
    input logic dmem_req_valid_i,
    output logic dmem_req_ready_o,
    input pkg_memory::address_t dmem_req_addr_i,
    input logic dmem_req_write_i,
    input pkg_memory::word_t dmem_req_wdata_i,
    input pkg_memory::byte_mask_t dmem_req_wstrb_i,
    output logic dmem_rsp_valid_o,
    input logic dmem_rsp_ready_i,
    output pkg_memory::word_t dmem_rsp_rdata_o,
    output logic dmem_rsp_error_o,
    output pkg_metrics::demand_origin_t dmem_rsp_origin_o,

    /** @brief Victima completa: el handshake wb_push libera su via de L1. */
    output logic wb_push_valid_o,
    input logic wb_push_ready_i,
    output pkg_memory::address_t wb_push_base_o,
    output pkg_memory::line_t wb_push_data_o,
    output logic wb_push_dirty_o,

    /** @brief Consulta combinacional RAW; busy obliga a esperar instalacion. */
    output logic wb_probe_valid_o,
    output pkg_memory::address_t wb_probe_base_o,
    input logic wb_probe_hit_i,
    input logic wb_probe_busy_i,

    /** @brief Demanda de bloque; accept_id solo es valido al aceptar l2_get. */
    output logic l2_get_valid_o,
    input logic l2_get_ready_i,
    output pkg_memory::address_t l2_get_base_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] l2_get_accept_id_i,

    /**
     * @brief Retorno seleccionado WB/L2/memoria al espacio reservado.
     * @details El handshake transfiere responsabilidad a L1. Se comprueban
     * base e id antes de aceptar; id no se usa para FILL_WB. Un error no instala.
     */
    input logic fill_valid_i,
    output logic fill_ready_o,
    input pkg_memory::address_t fill_base_i,
    input pkg_memory::line_t fill_data_i,
    input logic fill_dirty_i,
    input logic fill_error_i,
    input pkg_memory::fill_source_t fill_source_i,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] fill_id_i,

    /** @brief Eventos CPU-domain de aceptacion, victima y errores propios. */
    output pkg_metrics::l1_events_t perf_events_o
);
    /**
     * @brief Geometria derivada de los parametros compartidos.
     * @details Cada conjunto tiene L1_WAYS vias; cada via puede almacenar
     * un bloque de LINE_BYTES bytes.
     * La direccion se divide en tag, indice de conjunto y offset de bloque;
     * con la configuracion actual son 21, 6 y 5 bits respectivamente.
     */
    localparam integer SET_COUNT = pkg_memory::L1_BYTES /
        (pkg_memory::L1_WAYS * pkg_memory::LINE_BYTES);
    localparam integer BLOCK_OFFSET_W = $clog2(pkg_memory::LINE_BYTES);
    localparam integer SET_INDEX_W = $clog2(SET_COUNT);
    localparam integer TAG_W = $bits(pkg_memory::address_t) -
        SET_INDEX_W - BLOCK_OFFSET_W;
    localparam integer WAY_INDEX_W = pkg_memory::id_width(pkg_memory::L1_WAYS);
    localparam integer L2_ID_W = pkg_memory::id_width(L2_MAX_INFLIGHT);

    /**
     * @brief Frontera de reset para las ofertas y aceptaciones de L1.
     * @details El emisor presenta valid y el receptor ready; solo ambos a uno
     * en el flanco positivo transfieren una operacion. Con rst_ni=0, L1 baja
     * su lado de cada canal y evita transferencias aunque el vecino lo active.
     * La consulta WB no tiene handshake, pero tambien se desactiva en reset.
     */
    logic req_ready_internal;
    logic rsp_valid_internal;
    logic wb_push_valid_internal;
    logic wb_probe_valid_internal;
    logic l2_get_valid_internal;
    logic fill_ready_internal;

    assign dmem_req_ready_o = rst_ni && req_ready_internal;
    assign dmem_rsp_valid_o = rst_ni && rsp_valid_internal;
    assign wb_push_valid_o = rst_ni && wb_push_valid_internal;
    assign wb_probe_valid_o = rst_ni && wb_probe_valid_internal;
    assign l2_get_valid_o = rst_ni && l2_get_valid_internal;
    assign fill_ready_o = rst_ni && fill_ready_internal;

    /**
     * @brief Datos y metadatos registrados, indexados por conjunto y via.
     * @details valid autoriza el uso de tag/datos; dirty indica cambios que
     * deben conservarse al desalojar. La victima permanecera en su propia via
     * hasta que WB la acepte, sin duplicarla en otro registro de bloque.
     * lru_victim identifica la via a reemplazar cuando ambas estan validas:
     * acceder a via 0 dejara victima 1 y acceder a via 1 dejara victima 0.
     */
    pkg_memory::line_t block_data_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic [TAG_W-1:0] block_tag_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic block_valid_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic block_dirty_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic lru_victim_q [0:SET_COUNT-1];

    /**
     * @brief Fase de la demanda atendida por L1, no estado de un bloque.
     * @details El enum da nombres a cuatro valores de dos bits. El hit de un
     * ciclo se completa en L1_IDLE sin recorrer las fases de miss.
     */
    typedef enum logic [1:0] {
        L1_IDLE,             /** Sin demanda; permite comenzar una busqueda. */
        L1_GET_BLOCK,        /** Consultar WB u ofrecer la solicitud a L2. */
        L1_WAIT_BLOCK,       /** L2 acepto: esperar el bloque sin repetir pedido. */
        L1_COMPLETE_ACCESS   /** Resolver instalacion y respuesta pendientes. */
    } l1_state_t;

    l1_state_t state_q;
    l1_state_t next_state;

    /** @brief Una demanda pendiente y su via destino. */
    logic pending_valid_q;
    pkg_memory::address_t pending_addr_q;
    logic pending_write_q;
    pkg_memory::word_t pending_wdata_q;
    pkg_memory::byte_mask_t pending_wstrb_q;
    logic [WAY_INDEX_W-1:0] destination_way_q;
    logic l2_offered_q;

    /** @brief Identificador recibido exclusivamente al aceptar L2 la solicitud. */
    logic [L2_ID_W-1:0] l2_id_q;
    logic l2_id_valid_q;

    /** @brief Espacio de un bloque y resultado CPU retenido: recursos distintos. */
    logic input_reserved_q;
    logic input_valid_q;
    pkg_memory::line_t input_data_q;
    logic input_dirty_q;
    pkg_memory::fill_source_t input_source_q;
    logic response_valid_q;
    pkg_memory::word_t response_data_q;
    logic response_error_q;
    pkg_metrics::demand_origin_t response_origin_q;

    /**
     * @brief Decodificacion de direccion, busqueda de hit/victima y estado de miss.
     * @details Extrae conjunto [10:5], tag [31:11] y palabra [4:2]. Compara
     * tags en paralelo en ambas vias y deriva los campos de la demanda pendiente.
     */
    logic [SET_INDEX_W-1:0] req_set;
    logic [TAG_W-1:0] req_tag;
    logic [2:0] req_word_idx;
    pkg_memory::address_t req_block_base;
    logic [SET_INDEX_W-1:0] pending_set;
    logic [TAG_W-1:0] pending_tag;
    logic [2:0] pending_word_idx;
    pkg_memory::address_t pending_block_base;
    logic req_addr_in_range;
    logic [pkg_memory::L1_WAYS-1:0] way_hit;
    logic hit_any;
    logic [WAY_INDEX_W-1:0] hit_way;
    logic [WAY_INDEX_W-1:0] victim_way;
    pkg_memory::line_t hit_block_data;
    pkg_memory::word_t hit_word;
    pkg_memory::word_t merged_store_word;
    logic load_hit_now;
    logic store_hit_now;
    logic miss_now;
    logic dmem_req_handshake;
    logic dmem_rsp_handshake;
    logic l2_get_handshake;
    logic wb_push_handshake;
    logic fill_handshake;

    logic dest_way_valid;
    pkg_memory::address_t dest_way_base;
    pkg_memory::line_t dest_way_data;
    logic dest_way_dirty;
    logic way_available_now;

    logic fill_source_valid;
    logic fill_match;
    pkg_memory::line_t raw_install_line;
    logic raw_install_dirty;
    pkg_memory::fill_source_t raw_install_source;
    pkg_memory::line_t final_install_line;
    logic final_install_dirty;
    pkg_memory::word_t miss_rsp_word;
    pkg_metrics::demand_origin_t miss_rsp_origin;
    logic install_now;
    logic store_in_input_now;

    assign req_set = dmem_req_addr_i[BLOCK_OFFSET_W +: SET_INDEX_W];
    assign req_tag = dmem_req_addr_i[BLOCK_OFFSET_W + SET_INDEX_W +: TAG_W];
    assign req_word_idx = dmem_req_addr_i[4:2];
    assign req_block_base = {dmem_req_addr_i[31:BLOCK_OFFSET_W], {BLOCK_OFFSET_W{1'b0}}};

    assign pending_set = pending_addr_q[BLOCK_OFFSET_W +: SET_INDEX_W];
    assign pending_tag = pending_addr_q[BLOCK_OFFSET_W + SET_INDEX_W +: TAG_W];
    assign pending_word_idx = pending_addr_q[4:2];
    assign pending_block_base = {pending_addr_q[31:BLOCK_OFFSET_W], {BLOCK_OFFSET_W{1'b0}}};

    assign req_addr_in_range =
        (dmem_req_addr_i >= pkg_memory::DATA_BASE_ADDRESS) &&
        (dmem_req_addr_i < (pkg_memory::DATA_BASE_ADDRESS + pkg_memory::MEMORY_BYTES));
    assign dmem_req_handshake = dmem_req_valid_i && dmem_req_ready_o;
    assign dmem_rsp_handshake = dmem_rsp_valid_o && dmem_rsp_ready_i;
    assign l2_get_handshake = l2_get_valid_o && l2_get_ready_i;
    assign wb_push_handshake = wb_push_valid_o && wb_push_ready_i;
    assign fill_handshake = fill_valid_i && fill_ready_o;

    assign way_hit[0] = block_valid_q[req_set][0] &&
                        (block_tag_q[req_set][0] == req_tag);
    assign way_hit[1] = block_valid_q[req_set][1] &&
                        (block_tag_q[req_set][1] == req_tag);
    assign hit_any = |way_hit;
    assign hit_way = way_hit[1] ? 1'b1 : 1'b0;
    assign victim_way = !block_valid_q[req_set][0] ? 1'b0 :
                        (!block_valid_q[req_set][1] ? 1'b1 : lru_victim_q[req_set]);

    assign dest_way_valid = block_valid_q[pending_set][destination_way_q];
    assign dest_way_base = {block_tag_q[pending_set][destination_way_q],
                            pending_set, {BLOCK_OFFSET_W{1'b0}}};
    assign dest_way_data = block_data_q[pending_set][destination_way_q];
    assign dest_way_dirty = block_dirty_q[pending_set][destination_way_q];
    assign way_available_now = !dest_way_valid || wb_push_handshake;

    assign fill_source_valid =
        ((fill_source_i == pkg_memory::FILL_WB) && !l2_id_valid_q) ||
        (((fill_source_i == pkg_memory::FILL_L2) ||
          (fill_source_i == pkg_memory::FILL_MEMORY)) &&
         l2_id_valid_q && (fill_id_i == l2_id_q));
    assign fill_match = (fill_base_i == pending_block_base) && fill_source_valid;

    always_comb begin
        hit_block_data = block_data_q[req_set][hit_way];
        hit_word = hit_block_data[32 * req_word_idx +: 32];
        for (integer byte_idx = 0; byte_idx < 4; byte_idx++) begin
            merged_store_word[8 * byte_idx +: 8] = dmem_req_wstrb_i[byte_idx] ?
                dmem_req_wdata_i[8 * byte_idx +: 8] :
                hit_word[8 * byte_idx +: 8];
        end
        load_hit_now = (state_q == L1_IDLE) && dmem_req_valid_i &&
                       !dmem_req_write_i && req_addr_in_range && hit_any;
        store_hit_now = (state_q == L1_IDLE) && dmem_req_valid_i &&
                        dmem_req_write_i && req_addr_in_range && hit_any;
        miss_now = (state_q == L1_IDLE) && dmem_req_valid_i &&
                   req_addr_in_range && !hit_any;

        raw_install_line = input_valid_q ? input_data_q : fill_data_i;
        raw_install_dirty = input_valid_q ? input_dirty_q : fill_dirty_i;
        if (input_valid_q) begin
            raw_install_source = input_source_q;
        end else begin
            raw_install_source = fill_source_i;
        end

        final_install_line = raw_install_line;
        if (pending_write_q) begin
            for (integer byte_idx = 0; byte_idx < 4; byte_idx++) begin
                if (pending_wstrb_q[byte_idx]) begin
                    final_install_line[32 * pending_word_idx + 8 * byte_idx +: 8] =
                        pending_wdata_q[8 * byte_idx +: 8];
                end
            end
        end
        final_install_dirty = pending_write_q ? 1'b1 : raw_install_dirty;
        miss_rsp_word = pending_write_q ? 32'b0 :
                        final_install_line[32 * pending_word_idx +: 32];

        case (raw_install_source)
            pkg_memory::FILL_WB: miss_rsp_origin = pkg_metrics::ORIGIN_WB;
            pkg_memory::FILL_L2: miss_rsp_origin = pkg_metrics::ORIGIN_L2;
            pkg_memory::FILL_MEMORY: miss_rsp_origin = pkg_metrics::ORIGIN_MEMORY;
            default: miss_rsp_origin = pkg_metrics::ORIGIN_ERROR;
        endcase
    end

    /**
     * @brief Control combinacional de salidas, intenciones y proximo estado (L1-3..L1-6).
     * @details Valores por defecto inactivos evitan latches. Gestiona hits E1,
     * consultas WB, solicitudes L2, desalojo de victimas y recepcion/instalacion.
     */
    always_comb begin
        req_ready_internal = 1'b0;
        rsp_valid_internal = 1'b0;
        wb_push_valid_internal = 1'b0;
        wb_probe_valid_internal = 1'b0;
        l2_get_valid_internal = 1'b0;
        fill_ready_internal = 1'b0;

        dmem_rsp_rdata_o = 32'b0;
        dmem_rsp_error_o = 1'b0;
        dmem_rsp_origin_o = pkg_metrics::ORIGIN_L1;
        wb_push_base_o = 32'b0;
        wb_push_data_o = '0;
        wb_push_dirty_o = 1'b0;
        wb_probe_base_o = 32'b0;
        l2_get_base_o = 32'b0;
        perf_events_o = '0;
        next_state = state_q;

        install_now = 1'b0;
        store_in_input_now = 1'b0;

        // Desalojo continuo de victima mientras siga ocupando la via destino
        if (pending_valid_q && dest_way_valid) begin
            wb_push_valid_internal = 1'b1;
            wb_push_base_o = dest_way_base;
            wb_push_data_o = dest_way_data;
            wb_push_dirty_o = dest_way_dirty;
            if (wb_push_handshake) begin
                perf_events_o.eviction.valid = 1'b1;
                perf_events_o.eviction.base = dest_way_base;
                perf_events_o.eviction.dirty = dest_way_dirty;
            end
        end

        case (state_q)
            L1_IDLE: begin
                if (load_hit_now) begin
                    req_ready_internal = 1'b1;
                    rsp_valid_internal = 1'b1;
                    dmem_rsp_rdata_o = hit_word;
                    if (dmem_req_handshake) begin
                        perf_events_o.access_valid = 1'b1;
                        perf_events_o.access_write = 1'b0;
                        perf_events_o.access_result = pkg_metrics::ACCESS_HIT;
                    end
                end else if (store_hit_now) begin
                    req_ready_internal = 1'b1;
                    rsp_valid_internal = 1'b1;
                    if (dmem_req_handshake) begin
                        perf_events_o.access_valid = 1'b1;
                        perf_events_o.access_write = 1'b1;
                        perf_events_o.access_result = pkg_metrics::ACCESS_HIT;
                    end
                end else if (miss_now) begin
                    req_ready_internal = 1'b1;
                    wb_probe_valid_internal = 1'b1;
                    wb_probe_base_o = req_block_base;
                    if (!wb_probe_hit_i) begin
                        l2_get_valid_internal = 1'b1;
                        l2_get_base_o = req_block_base;
                    end
                    if (dmem_req_handshake) begin
                        perf_events_o.access_valid = 1'b1;
                        perf_events_o.access_write = dmem_req_write_i;
                        perf_events_o.access_result = pkg_metrics::ACCESS_MISS;
                        if (!wb_probe_hit_i && l2_get_handshake) begin
                            next_state = L1_WAIT_BLOCK;
                        end else begin
                            next_state = L1_GET_BLOCK;
                        end
                    end
                end
            end

            L1_GET_BLOCK: begin
                wb_probe_valid_internal = !l2_offered_q;
                wb_probe_base_o = pending_block_base;
                if (!l2_offered_q && wb_probe_hit_i && !wb_probe_busy_i) begin
                    fill_ready_internal = input_reserved_q && !input_valid_q;
                    if (fill_handshake && fill_match && !fill_error_i) begin
                        if (way_available_now) begin
                            install_now = 1'b1;
                            rsp_valid_internal = 1'b1;
                            dmem_rsp_rdata_o = miss_rsp_word;
                            dmem_rsp_origin_o = miss_rsp_origin;
                            if (dmem_rsp_handshake) begin
                                    next_state = L1_IDLE;
                                end else begin
                                    next_state = L1_COMPLETE_ACCESS;
                                end
                        end else begin
                            store_in_input_now = 1'b1;
                            next_state = L1_COMPLETE_ACCESS;
                        end
                    end
                end else if (l2_offered_q || !wb_probe_hit_i) begin
                    l2_get_valid_internal = 1'b1;
                    l2_get_base_o = pending_block_base;
                    if (l2_get_handshake) begin
                        next_state = L1_WAIT_BLOCK;
                    end
                end
            end

            L1_WAIT_BLOCK: begin
                fill_ready_internal = input_reserved_q && !input_valid_q;
                if (fill_handshake && fill_match && !fill_error_i) begin
                    if (way_available_now) begin
                        install_now = 1'b1;
                        rsp_valid_internal = 1'b1;
                        dmem_rsp_rdata_o = miss_rsp_word;
                        dmem_rsp_origin_o = miss_rsp_origin;
                        if (dmem_rsp_handshake) begin
                            next_state = L1_IDLE;
                        end else begin
                            next_state = L1_COMPLETE_ACCESS;
                        end
                    end else begin
                        store_in_input_now = 1'b1;
                        next_state = L1_COMPLETE_ACCESS;
                    end
                end
            end

            L1_COMPLETE_ACCESS: begin
                if (input_valid_q && way_available_now) begin
                    install_now = 1'b1;
                    rsp_valid_internal = 1'b1;
                    dmem_rsp_rdata_o = miss_rsp_word;
                    dmem_rsp_origin_o = miss_rsp_origin;
                    if (dmem_rsp_handshake) begin
                        next_state = L1_IDLE;
                    end
                end else if (response_valid_q) begin
                    rsp_valid_internal = 1'b1;
                    dmem_rsp_rdata_o = response_data_q;
                    dmem_rsp_error_o = response_error_q;
                    dmem_rsp_origin_o = response_origin_q;
                    if (dmem_rsp_handshake) begin
                        next_state = L1_IDLE;
                    end
                end
            end
        endcase
    end

    /** @brief Registro de fase del control con reset asincrono a L1_IDLE. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= L1_IDLE;
        end else begin
            state_q <= next_state;
        end
    end

    /**
     * @brief Seguimiento de demanda pendiente, entrada reservada e id L2.
     * @details Reset domina incluso con valid/ready activos. Libera id L2 al
     * aceptar el retorno y limpia reservas al completarse la respuesta CPU.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pending_valid_q <= 1'b0;
            pending_addr_q <= '0;
            pending_write_q <= 1'b0;
            pending_wdata_q <= '0;
            pending_wstrb_q <= '0;
            destination_way_q <= '0;
            l2_offered_q <= 1'b0;
            l2_id_q <= '0;
            l2_id_valid_q <= 1'b0;
            input_reserved_q <= 1'b0;
            input_valid_q <= 1'b0;
            input_data_q <= '0;
            input_dirty_q <= 1'b0;
            input_source_q <= pkg_memory::FILL_WB;
            response_valid_q <= 1'b0;
            response_data_q <= '0;
            response_error_q <= 1'b0;
            response_origin_q <= pkg_metrics::ORIGIN_L1;
        end else begin
            if (dmem_req_handshake && miss_now) begin
                pending_valid_q <= 1'b1;
                pending_addr_q <= dmem_req_addr_i;
                pending_write_q <= dmem_req_write_i;
                pending_wdata_q <= dmem_req_wdata_i;
                pending_wstrb_q <= dmem_req_wstrb_i;
                destination_way_q <= victim_way;
                input_reserved_q <= 1'b1;
                l2_offered_q <= l2_get_valid_o && !l2_get_ready_i;
            end else if (state_q == L1_GET_BLOCK && l2_get_valid_o && !l2_get_ready_i) begin
                l2_offered_q <= 1'b1;
            end

            if (l2_get_handshake) begin
                l2_id_q <= l2_get_accept_id_i;
                l2_id_valid_q <= 1'b1;
                l2_offered_q <= 1'b0;
            end

            if (fill_handshake && fill_match) begin
                l2_id_valid_q <= 1'b0;
                if (store_in_input_now) begin
                    input_valid_q <= 1'b1;
                    input_data_q <= fill_data_i;
                    input_dirty_q <= fill_dirty_i;
                    input_source_q <= fill_source_i;
                end
            end

            if (install_now) begin
                input_valid_q <= 1'b0;
                input_reserved_q <= 1'b0;
                if (!dmem_rsp_handshake) begin
                    response_valid_q <= 1'b1;
                    response_data_q <= miss_rsp_word;
                    response_error_q <= 1'b0;
                    response_origin_q <= miss_rsp_origin;
                end
            end

            if (dmem_rsp_handshake && (state_q != L1_IDLE)) begin
                pending_valid_q <= 1'b0;
                input_reserved_q <= 1'b0;
                input_valid_q <= 1'b0;
                response_valid_q <= 1'b0;
            end
        end
    end

    /**
     * @brief Reset de validez/reemplazo, desalojo de victima, hit e instalacion.
     * @details Invalidar todas las vias deja la cache vacia. En desalojo limpia
     * la via victima; en hit actualiza LRU/store; en instalacion escribe tag,
     * datos, valid, dirty y actualiza LRU una sola vez.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (integer set_index = 0; set_index < SET_COUNT; set_index++) begin
                lru_victim_q[set_index] <= 1'b0;
                for (integer way = 0; way < pkg_memory::L1_WAYS; way++) begin
                    block_valid_q[set_index][way] <= 1'b0;
                    block_dirty_q[set_index][way] <= 1'b0;
                end
            end
        end else begin
            if (wb_push_handshake && !install_now) begin
                block_valid_q[pending_set][destination_way_q] <= 1'b0;
                block_dirty_q[pending_set][destination_way_q] <= 1'b0;
            end

            if (dmem_req_handshake && (load_hit_now || store_hit_now)) begin
                lru_victim_q[req_set] <= ~hit_way;
                if (store_hit_now) begin
                    block_data_q[req_set][hit_way][32 * req_word_idx +: 32] <=
                        merged_store_word;
                    block_dirty_q[req_set][hit_way] <= 1'b1;
                end
            end else if (install_now) begin
                block_data_q[pending_set][destination_way_q] <= final_install_line;
                block_tag_q[pending_set][destination_way_q] <= pending_tag;
                block_valid_q[pending_set][destination_way_q] <= 1'b1;
                block_dirty_q[pending_set][destination_way_q] <= final_install_dirty;
                lru_victim_q[pending_set] <= ~destination_way_q;
            end
        end
    end

    // Siguiente paso: implementar L1-7 (respuesta retenida en hit, errores y reset en vuelo).
endmodule