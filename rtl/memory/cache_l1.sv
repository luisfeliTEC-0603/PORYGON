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
     * Estas senales internas recibiran la logica funcional en los siguientes
     * incrementos; aun no tienen productor. No se fija comportamiento normal
     * mediante valores por defecto que simulen una cache funcional.
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
     * La lectura combinacional y las actualizaciones se incorporan despues.
     */
    pkg_memory::line_t block_data_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic [TAG_W-1:0] block_tag_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic block_valid_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic block_dirty_q [0:SET_COUNT-1][0:pkg_memory::L1_WAYS-1];
    logic lru_victim_q [0:SET_COUNT-1];

    /**
     * @brief Fase de la demanda atendida por L1, no estado de un bloque.
     * @details El enum da nombres a cuatro valores de dos bits. Las fases
     * describen el recorrido aprobado: libre, conseguir bloque, esperar su
     * retorno tras aceptar L2 y completar el acceso. No son etapas de pipeline
     * ni obligan a gastar un ciclo en cada una. El hit de un ciclo podra
     * completarse en L1_IDLE sin recorrer las fases de miss.
     */
    typedef enum logic [1:0] {
        L1_IDLE,             /** Sin demanda; permite comenzar una busqueda. */
        L1_GET_BLOCK,        /** Consultar WB u ofrecer la solicitud a L2. */
        L1_WAIT_BLOCK,       /** L2 acepto: esperar el bloque sin repetir pedido. */
        L1_COMPLETE_ACCESS   /** Resolver instalacion y respuesta pendientes. */
    } l1_state_t;

    /**
     * @brief Registro que recuerda la fase entre flancos de reloj.
     * @details Reset empieza en L1_IDLE: no queda una busqueda anterior activa.
     * Las transiciones y salidas de control se conectaran al implementar
     * aceptacion y busqueda en los siguientes incrementos.
     */
    l1_state_t state_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= L1_IDLE;
        end
    end

    /**
     * @brief Una demanda pendiente y su via destino.
     * @details pending_valid calificara los campos capturados al aceptar un
     * miss. La direccion conserva tambien la palabra dentro del bloque.
     * Dato/mascara se necesitan para completar un store tras recibirlo.
     * La captura de la demanda y la eleccion de via quedan pendientes.
     */
    logic pending_valid_q;
    pkg_memory::address_t pending_addr_q;
    logic pending_write_q;
    pkg_memory::word_t pending_wdata_q;
    pkg_memory::byte_mask_t pending_wstrb_q;
    logic [WAY_INDEX_W-1:0] destination_way_q;

    /**
     * @brief Identificador recibido exclusivamente al aceptar L2 la solicitud.
     * @details El valor del puerto accept_id fuera del handshake no se usa.
     * Esta validez no es la validez de un bloque de cache. La finalizacion
     * liberara el id en el control de miss futuro; reset lo cancela ahora.
     */
    logic [L2_ID_W-1:0] l2_id_q;
    logic l2_id_valid_q;

    /**
     * @brief Espacio de un bloque y resultado CPU retenido: recursos distintos.
     * @details input_reserved comprometera espacio antes de pedir el bloque;
     * input_valid indicara que ya llegaron sus datos. response_valid calificara
     * una respuesta pendiente de consumo. Sus capturas/liberaciones funcionales
     * se incorporaran con los accesos; por ahora solo se define su reset.
     */
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
     * @brief Inicializacion del seguimiento y captura del id en el flanco.
     * @details Reset domina incluso con valid/ready activos. Con ready solo
     * no hay aceptacion; con valid solo, L2 aun no asigno un id utilizable.
     * Tras el handshake se conservan id y validez durante la espera.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pending_valid_q <= 1'b0;
            pending_addr_q <= '0;
            pending_write_q <= 1'b0;
            pending_wdata_q <= '0;
            pending_wstrb_q <= '0;
            destination_way_q <= '0;
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
        end else if (l2_get_valid_o && l2_get_ready_i) begin
            l2_id_q <= l2_get_accept_id_i;
            l2_id_valid_q <= 1'b1;
        end
    end

    /**
     * @brief Reset asincrono activo bajo de la validez y el reemplazo.
     * @details Invalidar todas las vias deja la cache vacia sin borrar datos
     * ni tags: estos no podran usarse hasta instalar un bloque valido.
     * Dirty se limpia para facilitar inspeccion. LRU inicia en via 0, pero
     * la seleccion futura debe preferir siempre una via invalida.
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
        end
    end

    // Siguiente paso aprobado: implementar L1-3 (busqueda combinacional y load hit).
endmodule