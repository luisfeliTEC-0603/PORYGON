/**
 * @brief Sistema de simulacion con nucleo, memoria de instrucciones y datos.
 *
 * @details Conserva vliw_processor como nucleo reusable con interfaces de
 * memoria explicitas. Conecta ROM sincrona y jerarquia exclusiva CPU-L1.
 * El error de texto se registra junto con el PC de la lectura correspondiente.
 * El entorno inicia la medicion antes de habilitar fetch. El ultimo flanco
 * del programa cierra la medicion; un watchdog puede forzar un cierre fallido.
 * La jerarquia conserva su reloj/reset durante las esperas del nucleo.
 * @see docs/ii-proyecto/cpu-memory-contract.md
 */
module porygon_system #(
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] INITIAL_PC = pkg_vliw::RESET_PC,
    parameter INSTRUCTION_INIT_FILE = "",
    parameter integer INSTRUCTION_INIT_BUNDLES = 0,
    parameter DATA_INIT_FILE = "",
    parameter integer DATA_INIT_BYTES = 0,
    parameter bit REFERENCE_WITHOUT_CACHE = 1'b0,
    parameter integer WRITE_BUFFER_DEPTH = pkg_memory::WRITE_BUFFER_DEPTH_DEFAULT,
    parameter integer EVICTION_BUFFER_DEPTH = pkg_memory::EVICTION_BUFFER_DEPTH_DEFAULT,
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT,
    parameter integer MEM_CLOCK_DIV = pkg_memory::MEM_CLOCK_DIV_DEFAULT,
    parameter integer MEM_READ_FIRST_WORD_CYCLES = pkg_memory::MEM_READ_FIRST_WORD_CYCLES_DEFAULT,
    parameter integer MEM_WRITE_FIRST_WORD_CYCLES = pkg_memory::MEM_WRITE_FIRST_WORD_CYCLES_DEFAULT,
    parameter integer MEM_TIMEOUT_CYCLES = pkg_memory::MEM_TIMEOUT_CYCLES_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,
    output logic authenticated_o,
    output logic auth_failed_o,
    output logic access_error_o,
    output pkg_vliw::address_t crypto_event_pc_o,
    output logic invalid_address_o,
    output pkg_vliw::address_t invalid_address_pc_o,
    output logic instruction_access_error_o,
    output pkg_vliw::address_t instruction_access_error_pc_o,
    output logic data_access_error_o,
    output pkg_vliw::address_t data_access_error_pc_o,

    /** @brief Inicio externo; stop incluye tambien stop_done del nucleo. */
    input logic perf_start_i,
    input logic perf_stop_i,
    input logic perf_stop_error_i,
    output logic stop_done_o,
    output logic halted_o,
    output pkg_metrics::cpu_events_t cpu_events_o,
    output logic perf_running_o,
    output logic perf_snapshot_valid_o,
    output logic perf_overflow_o,
    output logic perf_failed_o,
    output pkg_metrics::snapshot_t perf_snapshot_o
);
    import pkg_vliw::*;

    bundle_t instruction_bundle;
    address_t instruction_address;
    logic instruction_read_enable;
    word_t data_read_data;
    logic data_req_valid, data_req_ready, data_req_write;
    logic data_rsp_valid, data_rsp_ready, data_rsp_error;
    address_t data_address;
    logic [3:0] data_write_enable;
    word_t data_write_data;
    pkg_metrics::demand_origin_t data_rsp_origin;
    logic core_started_q, core_rst_n;

    /**
     * @brief E0 prepara la medicion con CPU aun en reset; fetch comienza en E1.
     * @details No se deriva ningun control funcional del observador P2-10.
     * Un nuevo programa requiere reset, igual que la parada del nucleo.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) core_started_q <= 1'b0;
        else if (perf_start_i) core_started_q <= 1'b1;
    end
    assign core_rst_n = rst_ni && core_started_q;

    assign data_access_error_pc_o = invalid_address_pc_o;

    /** @brief PC de respuesta: avanza en paralelo al bundle y error de ROM. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            instruction_access_error_pc_o <= INITIAL_PC;
        end else if (instruction_read_enable) begin
            instruction_access_error_pc_o <= instruction_address;
        end
    end

    instruction_memory #(
        .MEMORY_BYTES(MEMORY_BYTES),
        .BASE_ADDRESS(TEXT_BASE_ADDRESS),
        .INIT_FILE(INSTRUCTION_INIT_FILE),
        .INIT_BUNDLES(INSTRUCTION_INIT_BUNDLES)
    ) u_instruction_memory (
        .clk_i(clk_i),
        .rst_ni(core_rst_n),
        .address_i(instruction_address),
        .read_enable_i(instruction_read_enable),
        .bundle_o(instruction_bundle),
        .out_of_range_o(instruction_access_error_o)
    );

    data_memory_hierarchy #(
        .REFERENCE_WITHOUT_CACHE(REFERENCE_WITHOUT_CACHE),
        .WRITE_BUFFER_DEPTH(WRITE_BUFFER_DEPTH),
        .EVICTION_BUFFER_DEPTH(EVICTION_BUFFER_DEPTH),
        .L2_MAX_INFLIGHT(L2_MAX_INFLIGHT),
        .MEM_CLOCK_DIV(MEM_CLOCK_DIV),
        .MEM_READ_FIRST_WORD_CYCLES(MEM_READ_FIRST_WORD_CYCLES),
        .MEM_WRITE_FIRST_WORD_CYCLES(MEM_WRITE_FIRST_WORD_CYCLES),
        .MEM_TIMEOUT_CYCLES(MEM_TIMEOUT_CYCLES),
        .DATA_INIT_FILE(DATA_INIT_FILE),
        .DATA_INIT_BYTES(DATA_INIT_BYTES)
    ) u_data_memory (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .dmem_req_valid_i(data_req_valid), .dmem_req_ready_o(data_req_ready),
        .dmem_req_addr_i(data_address), .dmem_req_write_i(data_req_write),
        .dmem_req_wstrb_i(data_write_enable), .dmem_req_wdata_i(data_write_data),
        .dmem_rsp_valid_o(data_rsp_valid), .dmem_rsp_ready_i(data_rsp_ready),
        .dmem_rsp_rdata_o(data_read_data), .dmem_rsp_error_o(data_rsp_error),
        .dmem_rsp_origin_o(data_rsp_origin),
        .cpu_events_i(cpu_events_o), .perf_start_i(perf_start_i),
        .perf_stop_i(stop_done_o || perf_stop_i), .perf_stop_error_i(perf_stop_error_i),
        .perf_running_o(perf_running_o), .perf_snapshot_valid_o(perf_snapshot_valid_o),
        .perf_overflow_o(perf_overflow_o), .perf_failed_o(perf_failed_o),
        .perf_snapshot_o(perf_snapshot_o)
    );

    vliw_processor #(
        .INITIAL_PC(INITIAL_PC)
    ) u_processor (
        .clk_i(clk_i),
        .rst_ni(core_rst_n),
        .instruction_error_i(instruction_access_error_o),
        .dmem_rsp_origin_i(data_rsp_origin),
        .perf_events_o(cpu_events_o),
        .stop_done_o(stop_done_o), .halted_o(halted_o),
        .dmem_req_valid_o(data_req_valid), .dmem_req_ready_i(data_req_ready),
        .dmem_rsp_valid_i(data_rsp_valid), .dmem_rsp_ready_o(data_rsp_ready),
        .dmem_rsp_error_i(data_rsp_error), .dmem_error_o(data_access_error_o),
        .instruction_bundle_i(instruction_bundle),
        .dmem_rsp_rdata_i(data_read_data),
        .instruction_address_o(instruction_address),
        .instruction_read_enable_o(instruction_read_enable),
        .dmem_req_addr_o(data_address),
        .dmem_req_write_o(data_req_write),
        .dmem_req_wstrb_o(data_write_enable),
        .dmem_req_wdata_o(data_write_data),
        .authenticated_o(authenticated_o),
        .auth_failed_o(auth_failed_o),
        .access_error_o(access_error_o),
        .crypto_event_pc_o(crypto_event_pc_o),
        .invalid_address_o(invalid_address_o),
        .invalid_address_pc_o(invalid_address_pc_o)
    );
endmodule
