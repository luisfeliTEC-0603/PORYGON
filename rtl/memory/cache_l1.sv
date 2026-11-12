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
     * @details Cada conjunto contiene L1_WAYS bloques de LINE_BYTES bytes.
     * La direccion se divide en tag, indice de conjunto y offset de bloque;
     * con la configuracion actual son 21, 6 y 5 bits respectivamente.
     */
    localparam integer SET_COUNT = pkg_memory::L1_BYTES /
        (pkg_memory::L1_WAYS * pkg_memory::LINE_BYTES);
    localparam integer BLOCK_OFFSET_W = $clog2(pkg_memory::LINE_BYTES);
    localparam integer SET_INDEX_W = $clog2(SET_COUNT);
    localparam integer TAG_W = $bits(pkg_memory::address_t) -
        SET_INDEX_W - BLOCK_OFFSET_W;

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
     * @brief Reset asincrono activo bajo de la validez y el reemplazo.
     * @details Invalidar todas las vias deja la cache vacia sin borrar datos
     * ni tags: estos no podran usarse hasta instalar un bloque valido.
     * Dirty se limpia para facilitar inspeccion. LRU inicia en via 0, pero
     * la seleccion futura debe preferir siempre una via invalida.
     * Por ahora, fuera de reset estos registros conservan su valor; aun no
     * hay aceptacion de accesos, instalacion ni actualizacion de reemplazo.
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

    // TODO P2-06: demanda, entrada reservada, respuesta y control de accesos.
    // Las salidas del skeleton todavia no tienen comportamiento funcional.
endmodule
