/**
 * @brief Conexion estructural de los skeletons de la jerarquia del Proyecto II.
 * @param WRITE_BUFFER_DEPTH Entradas de WB; cuatro por defecto.
 * @param EVICTION_BUFFER_DEPTH Entradas de EB; ocho por defecto.
 * @param L2_MAX_INFLIGHT Operaciones L2 aceptadas; rango 1..4.
 * @param MEM_CLOCK_DIV Ciclos CPU por ciclo de memoria; dos por defecto.
 * @param MEM_READ_FIRST_WORD_CYCLES Latencia inicial de lectura en ciclos CPU.
 * @param MEM_WRITE_FIRST_WORD_CYCLES Latencia inicial de escritura en ciclos CPU.
 * @param MEM_TIMEOUT_CYCLES Tiempo hasta resultado disponible en ciclos CPU.
 * @param DATA_INIT_FILE Imagen opcional de bytes de memoria principal.
 * @param DATA_INIT_BYTES Cantidad de bytes inicializados; cero usa toda imagen.
 * @details La conexion conserva porygon_system y el nucleo existentes. Todos
 * los canales de linea y metricas estan en clk_i; el controlador genera el
 * reloj y reset de main_memory. Los modulos instanciados son skeletons sin
 * logica funcional. La integracion con CPU corresponde a P2-09/P2-11.
 * @see docs/ii-proyecto/skeletons.md
 */
module data_memory_hierarchy #(
    parameter integer WRITE_BUFFER_DEPTH = pkg_memory::WRITE_BUFFER_DEPTH_DEFAULT,
    parameter integer EVICTION_BUFFER_DEPTH = pkg_memory::EVICTION_BUFFER_DEPTH_DEFAULT,
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT,
    parameter integer MEM_CLOCK_DIV = pkg_memory::MEM_CLOCK_DIV_DEFAULT,
    parameter integer MEM_READ_FIRST_WORD_CYCLES = pkg_memory::MEM_READ_FIRST_WORD_CYCLES_DEFAULT,
    parameter integer MEM_WRITE_FIRST_WORD_CYCLES = pkg_memory::MEM_WRITE_FIRST_WORD_CYCLES_DEFAULT,
    parameter integer MEM_TIMEOUT_CYCLES = pkg_memory::MEM_TIMEOUT_CYCLES_DEFAULT,
    parameter DATA_INIT_FILE = "",
    parameter integer DATA_INIT_BYTES = 0
) (
    input logic clk_i,
    input logic rst_ni,

    /** @brief Frontera CPU -> L1; direcciones fisicas y stores por byte. */
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

    /**
     * @brief Control de medicion y eventos del nucleo adaptado en P2-09.
     * @details El productor CPU usa dmem_rsp_origin_o como origen de dmem_done;
     * este sideband no interviene en aceptar ni completar el acceso funcional.
     */
    input logic perf_start_i,
    input logic perf_stop_i,
    input logic perf_stop_error_i,
    input pkg_metrics::cpu_events_t cpu_events_i,
    output logic perf_running_o,
    output logic perf_snapshot_valid_o,
    output logic perf_overflow_o,
    output logic perf_failed_o,
    output pkg_metrics::snapshot_t perf_snapshot_o
);
    localparam integer L2_ID_W = pkg_memory::id_width(L2_MAX_INFLIGHT);
    localparam integer EB_ID_W = pkg_memory::id_width(EVICTION_BUFFER_DEPTH);

    // L1 -> WB: victima y consulta RAW.
    logic wb_push_valid, wb_push_ready, wb_push_dirty;
    pkg_memory::address_t wb_push_base;
    pkg_memory::line_t wb_push_data;
    logic wb_probe_valid, wb_probe_hit, wb_probe_busy;
    pkg_memory::address_t wb_probe_base;

    // WB -> retorno: forwarding de una entrada aun no en servicio.
    logic wb_fwd_valid, wb_fwd_ready, wb_fwd_dirty;
    pkg_memory::address_t wb_fwd_base;
    pkg_memory::line_t wb_fwd_data;

    // L1 <-> L2: demanda y promocion exclusiva.
    logic l2_get_valid, l2_get_ready;
    pkg_memory::address_t l2_get_base;
    logic [L2_ID_W-1:0] l2_get_accept_id;
    logic l2_fill_valid, l2_fill_ready, l2_fill_dirty, l2_fill_error;
    logic [L2_ID_W-1:0] l2_fill_id;
    pkg_memory::address_t l2_fill_base;
    pkg_memory::line_t l2_fill_data;

    // WB <-> L2: instalacion y confirmacion independiente de la aceptacion.
    logic wb_install_valid, wb_install_ready, wb_install_dirty;
    pkg_memory::address_t wb_install_base;
    pkg_memory::line_t wb_install_data;
    logic [L2_ID_W-1:0] wb_install_accept_id;
    logic wb_done_valid, wb_done_ready;
    logic [L2_ID_W-1:0] wb_done_id;

    // L2 <-> EB: victima sucia y conflicto de la lectura de memoria.
    logic eb_push_valid, eb_push_ready, eb_push_dirty;
    pkg_memory::address_t eb_push_base;
    pkg_memory::line_t eb_push_data;
    logic eb_probe_valid, eb_probe_hit;
    pkg_memory::address_t eb_probe_base;

    // Controlador -> L1: datos directos; L2 observa el mismo handshake.
    logic mem_rd_req_valid, mem_rd_req_ready;
    logic [L2_ID_W-1:0] mem_rd_req_id;
    pkg_memory::address_t mem_rd_req_base;
    logic mem_rd_rsp_valid, mem_rd_rsp_ready, mem_rd_rsp_error;
    logic [L2_ID_W-1:0] mem_rd_rsp_id;
    pkg_memory::address_t mem_rd_rsp_base;
    pkg_memory::line_t mem_rd_rsp_data;

    // EB <-> controlador: conservacion de la entrada hasta confirmacion.
    logic mem_wr_req_valid, mem_wr_req_ready;
    logic [EB_ID_W-1:0] mem_wr_req_id;
    pkg_memory::address_t mem_wr_req_base;
    pkg_memory::line_t mem_wr_req_data;
    logic mem_wr_rsp_valid, mem_wr_rsp_ready, mem_wr_rsp_error;
    logic [EB_ID_W-1:0] mem_wr_rsp_id;
    pkg_memory::address_t mem_wr_rsp_base;

    // Retorno comun hacia la entrada reservada de L1.
    logic fill_valid, fill_ready, fill_dirty, fill_error;
    pkg_memory::address_t fill_base;
    pkg_memory::line_t fill_data;
    pkg_memory::fill_source_t fill_source;
    logic [L2_ID_W-1:0] fill_id;

    // Frontera de palabras en el dominio lento; CDC pertenece al controlador.
    logic ram_clk, ram_rst_n;
    pkg_memory::address_t ram_address;
    logic ram_read_enable, ram_read_valid, ram_out_of_range;
    pkg_memory::byte_mask_t ram_write_enable;
    pkg_memory::word_t ram_write_data, ram_read_data;

    pkg_metrics::l1_events_t l1_events;
    pkg_metrics::l2_events_t l2_events;
    pkg_metrics::wb_events_t wb_events;
    pkg_metrics::eb_events_t eb_events;
    pkg_metrics::mem_events_t mem_events;
    pkg_metrics::error_event_t return_error;
    pkg_metrics::configuration_t configuration;

    // Metadatos constantes de esta configuracion con ambas caches.
    assign configuration.cpu_hz = pkg_memory::CPU_HZ;
    assign configuration.memory_bytes = pkg_memory::MEMORY_BYTES;
    assign configuration.l1_bytes = pkg_memory::L1_BYTES;
    assign configuration.l1_ways = pkg_memory::L1_WAYS;
    assign configuration.l2_bytes = pkg_memory::L2_BYTES;
    assign configuration.l2_ways = pkg_memory::L2_WAYS;
    assign configuration.line_bytes = pkg_memory::LINE_BYTES;
    assign configuration.write_buffer_depth = WRITE_BUFFER_DEPTH;
    assign configuration.eviction_buffer_depth = EVICTION_BUFFER_DEPTH;
    assign configuration.l2_max_inflight = L2_MAX_INFLIGHT;
    assign configuration.mem_clock_div = MEM_CLOCK_DIV;
    assign configuration.mem_read_first_word_cycles = MEM_READ_FIRST_WORD_CYCLES;
    assign configuration.mem_write_first_word_cycles = MEM_WRITE_FIRST_WORD_CYCLES;
    assign configuration.mem_timeout_cycles = MEM_TIMEOUT_CYCLES;
    assign configuration.reference_without_cache = 1'b0;

    cache_l1 #(
        .L2_MAX_INFLIGHT(L2_MAX_INFLIGHT)
    ) u_l1 (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .dmem_req_valid_i(dmem_req_valid_i),
        .dmem_req_ready_o(dmem_req_ready_o),
        .dmem_req_addr_i(dmem_req_addr_i),
        .dmem_req_write_i(dmem_req_write_i),
        .dmem_req_wdata_i(dmem_req_wdata_i),
        .dmem_req_wstrb_i(dmem_req_wstrb_i),
        .dmem_rsp_valid_o(dmem_rsp_valid_o),
        .dmem_rsp_ready_i(dmem_rsp_ready_i),
        .dmem_rsp_rdata_o(dmem_rsp_rdata_o),
        .dmem_rsp_error_o(dmem_rsp_error_o),
        .dmem_rsp_origin_o(dmem_rsp_origin_o),
        .wb_push_valid_o(wb_push_valid),
        .wb_push_ready_i(wb_push_ready),
        .wb_push_base_o(wb_push_base),
        .wb_push_data_o(wb_push_data),
        .wb_push_dirty_o(wb_push_dirty),
        .wb_probe_valid_o(wb_probe_valid),
        .wb_probe_base_o(wb_probe_base),
        .wb_probe_hit_i(wb_probe_hit),
        .wb_probe_busy_i(wb_probe_busy),
        .l2_get_valid_o(l2_get_valid),
        .l2_get_ready_i(l2_get_ready),
        .l2_get_base_o(l2_get_base),
        .l2_get_accept_id_i(l2_get_accept_id),
        .fill_valid_i(fill_valid),
        .fill_ready_o(fill_ready),
        .fill_base_i(fill_base),
        .fill_data_i(fill_data),
        .fill_dirty_i(fill_dirty),
        .fill_error_i(fill_error),
        .fill_source_i(fill_source),
        .fill_id_i(fill_id),
        .perf_events_o(l1_events)
    );

    write_buffer #(
        .WRITE_BUFFER_DEPTH(WRITE_BUFFER_DEPTH),
        .L2_MAX_INFLIGHT(L2_MAX_INFLIGHT)
    ) u_write_buffer (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .wb_push_valid_i(wb_push_valid),
        .wb_push_ready_o(wb_push_ready),
        .wb_push_base_i(wb_push_base),
        .wb_push_data_i(wb_push_data),
        .wb_push_dirty_i(wb_push_dirty),
        .wb_probe_valid_i(wb_probe_valid),
        .wb_probe_base_i(wb_probe_base),
        .wb_probe_hit_o(wb_probe_hit),
        .wb_probe_busy_o(wb_probe_busy),
        .wb_fwd_valid_o(wb_fwd_valid),
        .wb_fwd_ready_i(wb_fwd_ready),
        .wb_fwd_base_o(wb_fwd_base),
        .wb_fwd_data_o(wb_fwd_data),
        .wb_fwd_dirty_o(wb_fwd_dirty),
        .wb_install_valid_o(wb_install_valid),
        .wb_install_ready_i(wb_install_ready),
        .wb_install_base_o(wb_install_base),
        .wb_install_data_o(wb_install_data),
        .wb_install_dirty_o(wb_install_dirty),
        .wb_install_accept_id_i(wb_install_accept_id),
        .wb_done_valid_i(wb_done_valid),
        .wb_done_ready_o(wb_done_ready),
        .wb_done_id_i(wb_done_id),
        .perf_events_o(wb_events)
    );

    cache_l2 #(
        .L2_MAX_INFLIGHT(L2_MAX_INFLIGHT)
    ) u_l2 (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .l2_get_valid_i(l2_get_valid),
        .l2_get_ready_o(l2_get_ready),
        .l2_get_base_i(l2_get_base),
        .l2_get_accept_id_o(l2_get_accept_id),
        .l2_fill_valid_o(l2_fill_valid),
        .l2_fill_ready_i(l2_fill_ready),
        .l2_fill_id_o(l2_fill_id),
        .l2_fill_base_o(l2_fill_base),
        .l2_fill_data_o(l2_fill_data),
        .l2_fill_dirty_o(l2_fill_dirty),
        .l2_fill_error_o(l2_fill_error),
        .wb_install_valid_i(wb_install_valid),
        .wb_install_ready_o(wb_install_ready),
        .wb_install_base_i(wb_install_base),
        .wb_install_data_i(wb_install_data),
        .wb_install_dirty_i(wb_install_dirty),
        .wb_install_accept_id_o(wb_install_accept_id),
        .wb_done_valid_o(wb_done_valid),
        .wb_done_ready_i(wb_done_ready),
        .wb_done_id_o(wb_done_id),
        .eb_push_valid_o(eb_push_valid),
        .eb_push_ready_i(eb_push_ready),
        .eb_push_base_o(eb_push_base),
        .eb_push_data_o(eb_push_data),
        .eb_push_dirty_o(eb_push_dirty),
        .eb_probe_valid_o(eb_probe_valid),
        .eb_probe_base_o(eb_probe_base),
        .eb_probe_hit_i(eb_probe_hit),
        .mem_rd_req_valid_o(mem_rd_req_valid),
        .mem_rd_req_ready_i(mem_rd_req_ready),
        .mem_rd_req_id_o(mem_rd_req_id),
        .mem_rd_req_base_o(mem_rd_req_base),
        .mem_rd_rsp_valid_i(mem_rd_rsp_valid),
        .mem_rd_rsp_ready_i(mem_rd_rsp_ready),
        .mem_rd_rsp_id_i(mem_rd_rsp_id),
        .mem_rd_rsp_base_i(mem_rd_rsp_base),
        .mem_rd_rsp_error_i(mem_rd_rsp_error),
        .perf_events_o(l2_events)
    );

    eviction_buffer #(
        .EVICTION_BUFFER_DEPTH(EVICTION_BUFFER_DEPTH)
    ) u_eviction_buffer (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .eb_push_valid_i(eb_push_valid),
        .eb_push_ready_o(eb_push_ready),
        .eb_push_base_i(eb_push_base),
        .eb_push_data_i(eb_push_data),
        .eb_push_dirty_i(eb_push_dirty),
        .eb_probe_valid_i(eb_probe_valid),
        .eb_probe_base_i(eb_probe_base),
        .eb_probe_hit_o(eb_probe_hit),
        .mem_wr_req_valid_o(mem_wr_req_valid),
        .mem_wr_req_ready_i(mem_wr_req_ready),
        .mem_wr_req_id_o(mem_wr_req_id),
        .mem_wr_req_base_o(mem_wr_req_base),
        .mem_wr_req_data_o(mem_wr_req_data),
        .mem_wr_rsp_valid_i(mem_wr_rsp_valid),
        .mem_wr_rsp_ready_o(mem_wr_rsp_ready),
        .mem_wr_rsp_id_i(mem_wr_rsp_id),
        .mem_wr_rsp_base_i(mem_wr_rsp_base),
        .mem_wr_rsp_error_i(mem_wr_rsp_error),
        .perf_events_o(eb_events)
    );

    memory_controller #(
        .L2_MAX_INFLIGHT(L2_MAX_INFLIGHT),
        .EVICTION_BUFFER_DEPTH(EVICTION_BUFFER_DEPTH),
        .MEM_CLOCK_DIV(MEM_CLOCK_DIV),
        .MEM_READ_FIRST_WORD_CYCLES(MEM_READ_FIRST_WORD_CYCLES),
        .MEM_WRITE_FIRST_WORD_CYCLES(MEM_WRITE_FIRST_WORD_CYCLES),
        .MEM_TIMEOUT_CYCLES(MEM_TIMEOUT_CYCLES)
    ) u_memory_controller (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .mem_rd_req_valid_i(mem_rd_req_valid),
        .mem_rd_req_ready_o(mem_rd_req_ready),
        .mem_rd_req_id_i(mem_rd_req_id),
        .mem_rd_req_base_i(mem_rd_req_base),
        .eb_probe_hit_i(eb_probe_hit),
        .mem_rd_rsp_valid_o(mem_rd_rsp_valid),
        .mem_rd_rsp_ready_i(mem_rd_rsp_ready),
        .mem_rd_rsp_id_o(mem_rd_rsp_id),
        .mem_rd_rsp_base_o(mem_rd_rsp_base),
        .mem_rd_rsp_data_o(mem_rd_rsp_data),
        .mem_rd_rsp_error_o(mem_rd_rsp_error),
        .mem_wr_req_valid_i(mem_wr_req_valid),
        .mem_wr_req_ready_o(mem_wr_req_ready),
        .mem_wr_req_id_i(mem_wr_req_id),
        .mem_wr_req_base_i(mem_wr_req_base),
        .mem_wr_req_data_i(mem_wr_req_data),
        .mem_wr_rsp_valid_o(mem_wr_rsp_valid),
        .mem_wr_rsp_ready_i(mem_wr_rsp_ready),
        .mem_wr_rsp_id_o(mem_wr_rsp_id),
        .mem_wr_rsp_base_o(mem_wr_rsp_base),
        .mem_wr_rsp_error_o(mem_wr_rsp_error),
        .ram_clk_o(ram_clk),
        .ram_rst_no(ram_rst_n),
        .ram_address_o(ram_address),
        .ram_read_enable_o(ram_read_enable),
        .ram_write_enable_o(ram_write_enable),
        .ram_write_data_o(ram_write_data),
        .ram_read_data_i(ram_read_data),
        .ram_read_valid_i(ram_read_valid),
        .ram_out_of_range_i(ram_out_of_range),
        .perf_events_o(mem_events)
    );

    main_memory #(
        .MEMORY_BYTES(pkg_memory::MEMORY_BYTES),
        .BASE_ADDRESS(pkg_memory::DATA_BASE_ADDRESS),
        .INIT_FILE(DATA_INIT_FILE),
        .INIT_BYTES(DATA_INIT_BYTES)
    ) u_main_memory (
        .clk_i(ram_clk),
        .rst_ni(ram_rst_n),
        .address_i(ram_address),
        .read_enable_i(ram_read_enable),
        .write_enable_i(ram_write_enable),
        .write_data_i(ram_write_data),
        .read_data_o(ram_read_data),
        .read_valid_o(ram_read_valid),
        .out_of_range_o(ram_out_of_range)
    );

    line_return #(
        .L2_MAX_INFLIGHT(L2_MAX_INFLIGHT)
    ) u_line_return (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .wb_fwd_valid_i(wb_fwd_valid),
        .wb_fwd_ready_o(wb_fwd_ready),
        .wb_fwd_base_i(wb_fwd_base),
        .wb_fwd_data_i(wb_fwd_data),
        .wb_fwd_dirty_i(wb_fwd_dirty),
        .l2_fill_valid_i(l2_fill_valid),
        .l2_fill_ready_o(l2_fill_ready),
        .l2_fill_id_i(l2_fill_id),
        .l2_fill_base_i(l2_fill_base),
        .l2_fill_data_i(l2_fill_data),
        .l2_fill_dirty_i(l2_fill_dirty),
        .l2_fill_error_i(l2_fill_error),
        .mem_rd_rsp_valid_i(mem_rd_rsp_valid),
        .mem_rd_rsp_ready_o(mem_rd_rsp_ready),
        .mem_rd_rsp_id_i(mem_rd_rsp_id),
        .mem_rd_rsp_base_i(mem_rd_rsp_base),
        .mem_rd_rsp_data_i(mem_rd_rsp_data),
        .mem_rd_rsp_error_i(mem_rd_rsp_error),
        .fill_valid_o(fill_valid),
        .fill_ready_i(fill_ready),
        .fill_base_o(fill_base),
        .fill_data_o(fill_data),
        .fill_dirty_o(fill_dirty),
        .fill_error_o(fill_error),
        .fill_source_o(fill_source),
        .fill_id_o(fill_id),
        .perf_error_o(return_error)
    );

    performance_counters #(
        .L2_MAX_INFLIGHT(L2_MAX_INFLIGHT),
        .EVICTION_BUFFER_DEPTH(EVICTION_BUFFER_DEPTH)
    ) u_performance_counters (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .perf_start_i(perf_start_i),
        .perf_stop_i(perf_stop_i),
        .perf_stop_error_i(perf_stop_error_i),
        .configuration_i(configuration),
        .cpu_events_i(cpu_events_i),
        .l1_events_i(l1_events),
        .l2_events_i(l2_events),
        .wb_events_i(wb_events),
        .eb_events_i(eb_events),
        .mem_events_i(mem_events),
        .return_error_i(return_error),
        .perf_running_o(perf_running_o),
        .perf_snapshot_valid_o(perf_snapshot_valid_o),
        .perf_overflow_o(perf_overflow_o),
        .perf_failed_o(perf_failed_o),
        .perf_snapshot_o(perf_snapshot_o)
    );
endmodule
