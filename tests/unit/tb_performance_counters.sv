/**
 * @brief Verifica ventana, contadores, cierre y saturacion de P2-10.
 * @details Los eventos se construyen a mano a partir de pkg_metrics, sin
 * instanciar caches ni buffers, de modo que los valores esperados provienen
 * del contrato y no de otra implementacion. Los casos reproducen los de
 * referencia de docs/ii-proyecto/metrics.md seccion 9.
 */
module tb_performance_counters;
    import pkg_metrics::*;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic perf_start = 1'b0;
    logic perf_stop = 1'b0;
    logic perf_stop_error = 1'b0;
    configuration_t configuration = '0;

    cpu_events_t cpu_ev = '0;
    l1_events_t l1_ev = '0;
    l2_events_t l2_ev = '0;
    wb_events_t wb_ev = '0;
    eb_events_t eb_ev = '0;
    mem_events_t mem_ev = '0;
    error_event_t return_err = '0;

    logic running, snapshot_valid, overflow, failed;
    snapshot_t snap;

    integer errors = 0;

    always #5 clk = ~clk;

    performance_counters dut (
        .clk_i(clk), .rst_ni(rst_n),
        .perf_start_i(perf_start), .perf_stop_i(perf_stop),
        .perf_stop_error_i(perf_stop_error), .configuration_i(configuration),
        .cpu_events_i(cpu_ev), .l1_events_i(l1_ev), .l2_events_i(l2_ev),
        .wb_events_i(wb_ev), .eb_events_i(eb_ev), .mem_events_i(mem_ev),
        .return_error_i(return_err),
        .perf_running_o(running), .perf_snapshot_valid_o(snapshot_valid),
        .perf_overflow_o(overflow), .perf_failed_o(failed),
        .perf_snapshot_o(snap)
    );

    task automatic clear_events();
        cpu_ev = '0; l1_ev = '0; l2_ev = '0;
        wb_ev = '0; eb_ev = '0; mem_ev = '0; return_err = '0;
        wb_ev.state.capacity = pkg_memory::WRITE_BUFFER_DEPTH_DEFAULT;
        eb_ev.state.capacity = pkg_memory::EVICTION_BUFFER_DEPTH_DEFAULT;
        l2_ev.capacity = pkg_memory::L2_MAX_INFLIGHT_DEFAULT;
        perf_start = 1'b0; perf_stop = 1'b0; perf_stop_error = 1'b0;
    endtask

    /**
     * @details Los eventos se cargan despues de un negedge y el observador
     * los muestrea en el posedge siguiente; tick consume ese flanco y deja
     * las entradas limpias para el ciclo que sigue.
     */
    task automatic tick();
        @(posedge clk);
        #1;
        clear_events();
        @(negedge clk);
    endtask

    task automatic idle(input integer n);
        for (int k = 0; k < n; k++) tick();
    endtask

    task automatic start_window();
        perf_start = 1'b1;
        tick();
    endtask

    task automatic stop_window();
        perf_stop = 1'b1;
        tick();
    endtask

    task automatic expect64(input string name, input counter_t got,
                            input counter_t exp);
        if (got !== exp) begin
            errors = errors + 1;
            $display("FAIL  %-32s esperado=%0d obtenido=%0d", name, exp, got);
        end
    endtask

    /** @brief Comparacion de ocupaciones, que usan 32 bits. */
    task automatic expect32(input string name, input occupancy_t got,
                            input occupancy_t exp);
        if (got !== exp) begin
            errors = errors + 1;
            $display("FAIL  %-32s esperado=%0d obtenido=%0d", name, exp, got);
        end
    endtask

    task automatic expect1(input string name, input logic got, input logic exp);
        if (got !== exp) begin
            errors = errors + 1;
            $display("FAIL  %-32s esperado=%0b obtenido=%0b", name, exp, got);
        end
    endtask

    /** @brief Carga un acceso de L1 ya clasificado. */
    task automatic l1_access(input logic write, input access_result_t result);
        l1_ev.access_valid = 1'b1;
        l1_ev.access_write = write;
        l1_ev.access_result = result;
    endtask

    /** @brief Marca un ciclo de congelamiento global por miss en curso. */
    task automatic stall_miss();
        cpu_ev.stall = 1'b1;
        cpu_ev.wait_reason = WAIT_MISS;
    endtask

    /** @brief Compara toda la instantanea, incluidos configuracion y pendientes. */
    task automatic expect_snapshot(input string name, input snapshot_t expected);
        if (snap !== expected) begin
            errors = errors + 1;
            $display("FAIL  %-32s la instantanea cambio", name);
        end
    endtask

    /** @brief La configuracion pertenece a la ventana que acepto start. */
    task automatic check_configuration_freeze();
        snapshot_t frozen;
        configuration = '0;
        configuration.cpu_hz = 100_000_000;
        configuration.mem_clock_div = 2;
        start_window();
        configuration.cpu_hz = 80_000_000;
        configuration.mem_clock_div = 5;
        configuration.reference_without_cache = 1'b1;
        perf_start = 1'b1;
        tick();
        stop_window();
        expect32("config.frecuencia_inicial", snap.configuration.cpu_hz, 100_000_000);
        expect32("config.divisor_inicial", snap.configuration.mem_clock_div, 2);
        expect1("config.tipo_inicial", snap.configuration.reference_without_cache, 1'b0);
        frozen = snap;
        configuration = '0;
        cpu_ev.done_instructions = 8'd9;
        wb_ev.state.occupancy = 32'd4;
        eb_ev.state.occupancy = 32'd8;
        l2_ev.inflight = 32'd4;
        mem_ev.accept.valid = 1'b1;
        return_err.valid = 1'b1;
        tick();
        expect_snapshot("config.congelada_tras_stop", frozen);
        start_window();
        expect32("config.nuevo_inicio", snap.configuration.cpu_hz, 0);
        expect64("config.nuevo_inicio_contadores", snap.cpu.cycles, 0);
        expect1("config.nuevo_inicio_validez", snapshot_valid, 1'b0);
        stop_window();
    endtask

    /**
     * @brief Los retiros y las inserciones de EN afectan los pendientes.
     * @details Dos demandas y una instalacion terminan juntas en L2, aunque
     * get_done solo describa una de las demandas en ese flanco.
     */
    task automatic check_buffer_stop_events();
        start_window();
        mem_ev.accept.valid = 1'b1;
        tick();
        mem_ev.complete.valid = 1'b1;
        tick();
        wb_ev.state.occupancy = 32'd3;
        wb_ev.enqueued.valid = 1'b1;
        wb_ev.forwarded.valid = 1'b1;
        wb_ev.install_done.valid = 1'b1;
        eb_ev.state.occupancy = 32'd3;
        eb_ev.enqueued.valid = 1'b1;
        eb_ev.write_done.valid = 1'b1;
        l2_ev.inflight = 32'd3;
        l2_ev.get_accept.valid = 1'b1;
        l2_ev.promotion.valid = 1'b1;
        l2_ev.get_done.valid = 1'b1;
        mem_ev.read_rsp_consumed = 1'b1;
        perf_stop = 1'b1;
        tick();
        expect32("cierre.wb_dos_retiros_y_alta", snap.pending.wb_entries, 2);
        expect32("cierre.eb_retiro_y_alta", snap.pending.eb_entries, 3);
        expect32("cierre.l2_tres_retiros_y_alta", snap.pending.l2_inflight, 1);
        expect32("cierre.respuesta_consumida", snap.pending.mem_read_responses, 0);
        expect64("cierre.wb_trafico_final", snap.wb.forwarded, 1);
        expect64("cierre.wb_suma_intervalo", snap.wb.occupancy_sum, 3);
        expect64("cierre.wb_max_intervalo", snap.wb.occupancy_max, 3);
        expect64("cierre.l2_suma_intervalo", snap.l2.inflight_sum, 3);
        expect64("cierre.l2_max_intervalo", snap.l2.inflight_max, 3);

        start_window();
        wb_ev.enqueued.valid = 1'b1;
        eb_ev.enqueued.valid = 1'b1;
        l2_ev.get_accept.valid = 1'b1;
        perf_stop = 1'b1;
        tick();
        expect32("cierre.wb_alta_desde_vacio", snap.pending.wb_entries, 1);
        expect32("cierre.eb_alta_desde_vacio", snap.pending.eb_entries, 1);
        expect32("cierre.l2_alta_desde_vacio", snap.pending.l2_inflight, 1);

        start_window();
        wb_ev.state.occupancy = 32'd1;
        wb_ev.install_accept.valid = 1'b1;
        perf_stop = 1'b1;
        tick();
        expect32("cierre.wb_instalar_no_libera", snap.pending.wb_entries, 1);
        expect32("cierre.l2_instalacion_aceptada", snap.pending.l2_inflight, 1);

        start_window();
        l2_ev.inflight = 32'd1;
        l2_ev.get_done.valid = 1'b1;
        perf_stop = 1'b1;
        tick();
        expect32("cierre.l2_get_done_diferido", snap.pending.l2_inflight, 1);
    endtask

    /**
     * @brief Cierra en aceptacion, disponibilidad y consumo de cada canal.
     * @details Las muestras busy del controlador pueden incluir respuestas;
     * los pendientes del reporte deben distinguirlas de transferencias activas.
     */
    task automatic check_memory_stop_events();
        logic write;
        configuration.reference_without_cache = 1'b1;
        for (int channel = 0; channel < 2; channel++) begin
            write = (channel == 1);
            for (int boundary = 0; boundary < 4; boundary++) begin
                start_window();
                mem_ev.accept.valid = 1'b1;
                mem_ev.accept.write = write;
                mem_ev.accept.id = 32'd2;
                if (boundary != 0) begin
                    tick();
                    mem_ev.complete.valid = 1'b1;
                    mem_ev.complete.write = write;
                    mem_ev.complete.id = 32'd2;
                    if (boundary == 2) tick();
                    mem_ev.reads_pending = write ? 0 : 1;
                    mem_ev.writes_pending = write ? 1 : 0;
                    mem_ev.read_responses_pending = write ? 0 : 1;
                    mem_ev.write_responses_pending = write ? 1 : 0;
                    if (boundary >= 2) begin
                        mem_ev.read_rsp_consumed = !write;
                        mem_ev.write_rsp_consumed = write;
                    end
                end
                perf_stop = 1'b1;
                tick();
                expect32($sformatf("mem.%0d.%0d.activa_read", channel, boundary),
                         snap.pending.mem_reads, (!write && boundary == 0) ? 1 : 0);
                expect32($sformatf("mem.%0d.%0d.activa_write", channel, boundary),
                         snap.pending.mem_writes, (write && boundary == 0) ? 1 : 0);
                expect32($sformatf("mem.%0d.%0d.respuesta_read", channel, boundary),
                         snap.pending.mem_read_responses, (!write && boundary == 1) ? 1 : 0);
                expect32($sformatf("mem.%0d.%0d.respuesta_write", channel, boundary),
                         snap.pending.mem_write_responses, (write && boundary == 1) ? 1 : 0);
                expect32("mem.referencia_sin_l2", snap.pending.l2_inflight, 0);
            end
        end

        // Una lectura termina/consume mientras otra operacion se acepta.
        start_window();
        mem_ev.accept.valid = 1'b1;
        tick();
        mem_ev.accept.valid = 1'b1;
        mem_ev.accept.write = 1'b1;
        mem_ev.complete.valid = 1'b1;
        mem_ev.read_rsp_consumed = 1'b1;
        perf_stop = 1'b1;
        tick();
        expect32("mem.simultaneos_lectura_terminada", snap.pending.mem_reads, 0);
        expect32("mem.simultaneos_escritura_aceptada", snap.pending.mem_writes, 1);
        expect32("mem.simultaneos_respuesta_consumida", snap.pending.mem_read_responses, 0);
        expect64("mem.simultaneos_lecturas", snap.mem.reads, 1);
        expect64("mem.simultaneos_escrituras", snap.mem.writes, 1);
        expect64("mem.simultaneos_completas", snap.mem.reads_complete, 1);

        // Mismo id en ambos espacios: consumir la lectura no retira la escritura.
        start_window();
        mem_ev.accept.valid = 1'b1;
        mem_ev.accept.id = 32'd2;
        tick();
        mem_ev.complete.valid = 1'b1;
        mem_ev.complete.id = 32'd2;
        tick();
        mem_ev.accept.valid = 1'b1;
        mem_ev.accept.write = 1'b1;
        mem_ev.accept.id = 32'd2;
        tick();
        mem_ev.complete.valid = 1'b1;
        mem_ev.complete.write = 1'b1;
        mem_ev.complete.id = 32'd2;
        mem_ev.complete_error = ERROR_TIMEOUT;
        mem_ev.word.valid = 1'b1;
        mem_ev.word.write = 1'b1;
        mem_ev.read_rsp_consumed = 1'b1;
        mem_ev.reads_pending = 32'd1;
        mem_ev.writes_pending = 32'd1;
        mem_ev.read_responses_pending = 32'd1;
        mem_ev.write_responses_pending = 32'd1;
        eb_ev.state.occupancy = 32'd1;
        eb_ev.write_error = 1'b1;
        perf_stop = 1'b1;
        tick();
        expect32("mem.ids_separados_lectura", snap.pending.mem_read_responses, 0);
        expect32("mem.ids_separados_escritura", snap.pending.mem_write_responses, 1);
        expect32("mem.error_termina_transferencia", snap.pending.mem_writes, 0);
        expect32("mem.error_conserva_eb", snap.pending.eb_entries, 1);
        expect64("mem.error_conserva_palabras", snap.mem.write_words, 1);
        expect64("mem.error_timeout", snap.mem.timeouts, 1);
        expect64("mem.error_sin_escritura_correcta", snap.eb.written, 0);
        expect1("mem.error_fin_fallido", snap.failed, 1'b1);

        // Ambos canales pueden consumir respuestas independientes en EN.
        start_window();
        mem_ev.accept.valid = 1'b1;
        tick();
        mem_ev.complete.valid = 1'b1;
        tick();
        mem_ev.accept.valid = 1'b1;
        mem_ev.accept.write = 1'b1;
        tick();
        mem_ev.complete.valid = 1'b1;
        mem_ev.complete.write = 1'b1;
        tick();
        mem_ev.read_rsp_consumed = 1'b1;
        mem_ev.write_rsp_consumed = 1'b1;
        perf_stop = 1'b1;
        tick();
        expect32("mem.consumo_doble_read", snap.pending.mem_read_responses, 0);
        expect32("mem.consumo_doble_write", snap.pending.mem_write_responses, 0);
        configuration.reference_without_cache = 1'b0;
    endtask

    /** @brief Verifica las tres causas de espera y contadores auxiliares. */
    task automatic check_auxiliary_counters();
        start_window();
        for (int cycle = 0; cycle < 8; cycle++) begin
            cpu_ev.stage_occupied = 4'b1111;
            if (cycle == 0) cpu_ev.dmem_begin = 1'b1;
            if (cycle < 7) begin
                cpu_ev.stall = 1'b1;
                cpu_ev.stage_mem_stalls = 4'b1111;
                if (cycle < 2) cpu_ev.wait_reason = WAIT_ACCEPT;
                else if (cycle < 5) cpu_ev.wait_reason = WAIT_MISS;
                else cpu_ev.wait_reason = WAIT_RESPONSE;
            end else begin
                cpu_ev.stage_transfers = 4'b1111;
                cpu_ev.dmem_done = 1'b1;
                cpu_ev.dmem_origin = ORIGIN_MEMORY;
                perf_stop = 1'b1;
            end
            tick();
        end
        expect64("esperas.stalls", snap.cpu.stall_cycles, 7);
        expect64("esperas.aceptacion", snap.cpu.wait_accept, 2);
        expect64("esperas.miss", snap.cpu.wait_miss, 3);
        expect64("esperas.consumo", snap.cpu.wait_rsp, 2);
        expect64("esperas.latencia_total", snap.dmem.read_latency_sum, 8);
        expect64("esperas.solo_miss_por_origen", snap.dmem.miss_stalls_mem, 3);
        expect64("etapas.if_ocupada", snap.cpu.stage_if.occupied, 8);
        expect64("etapas.id_ocupada", snap.cpu.stage_id.occupied, 8);
        expect64("etapas.ex_ocupada", snap.cpu.stage_ex.occupied, 8);
        expect64("etapas.wb_ocupada", snap.cpu.stage_wb.occupied, 8);
        expect64("etapas.if_avance", snap.cpu.stage_if.transfers, 1);
        expect64("etapas.id_avance", snap.cpu.stage_id.transfers, 1);
        expect64("etapas.ex_avance", snap.cpu.stage_ex.transfers, 1);
        expect64("etapas.wb_avance", snap.cpu.stage_wb.transfers, 1);
        expect64("etapas.if_stall", snap.cpu.stage_if.mem_stalls, 7);
        expect64("etapas.id_stall", snap.cpu.stage_id.mem_stalls, 7);
        expect64("etapas.ex_stall", snap.cpu.stage_ex.mem_stalls, 7);
        expect64("etapas.wb_stall", snap.cpu.stage_wb.mem_stalls, 7);

        start_window();
        wb_ev.state.occupancy = wb_ev.state.capacity;
        eb_ev.state.occupancy = eb_ev.state.capacity;
        l2_ev.inflight = l2_ev.capacity;
        wb_ev.state.push_wait = 1'b1;
        wb_ev.state.send_wait = 1'b1;
        wb_ev.state.raw_wait = 1'b1;
        eb_ev.state.push_wait = 1'b1;
        eb_ev.state.raw_wait = 1'b1;
        l2_ev.get_wait = 1'b1;
        tick();
        stop_window();
        expect64("buffers.wb_lleno", snap.wb.full_cycles, 1);
        expect64("buffers.eb_lleno", snap.eb.full_cycles, 1);
        expect64("buffers.l2_lleno", snap.l2.full_cycles, 1);
        expect64("buffers.wb_push_wait", snap.wb.push_wait_cycles, 1);
        expect64("buffers.wb_install_wait", snap.wb.install_wait_cycles, 1);
        expect64("buffers.wb_raw_wait", snap.wb.raw_wait_cycles, 1);
        expect64("buffers.eb_push_wait", snap.eb.push_wait_cycles, 1);
        expect64("buffers.eb_raw_wait", snap.eb.raw_wait_cycles, 1);
        expect64("buffers.l2_get_wait", snap.l2.get_wait_cycles, 1);
        expect64("buffers.sin_stall_global", snap.cpu.stall_cycles, 0);

        start_window();
        cpu_ev.dmem_begin = 1'b1;
        cpu_ev.dmem_done = 1'b1;
        cpu_ev.dmem_error = 1'b1;
        l1_access(1'b0, ACCESS_INVALID);
        l1_ev.error.valid = 1'b1;
        l1_ev.error.kind = ERROR_ADDRESS;
        perf_stop = 1'b1;
        tick();
        expect64("demanda_fallida.conteo", snap.dmem.failed, 1);
        expect64("demanda_fallida.sin_exito", snap.dmem.completed, 0);
        expect64("demanda_fallida.sin_latencia", snap.dmem.latency_sum, 0);
        expect64("demanda_fallida.invalida", snap.l1.invalid_reads, 1);
        expect1("demanda_fallida.estado", snap.failed, 1'b1);
    endtask

    initial begin
        $dumpfile("build/waves/performance_counters.vcd");
        $dumpvars(0, tb_performance_counters);

        clear_events();
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        #1;
        expect1("reset.running", running, 1'b0);
        expect1("reset.snapshot_valid", snapshot_valid, 1'b0);
        expect64("reset.cycles", snap.cpu.cycles, 0);
        rst_n = 1'b1;
        @(negedge clk);

        // --- Ventana: el flanco de start no cuenta y el de stop si ---------
        start_window();
        expect1("ventana.running", running, 1'b1);
        idle(4);
        stop_window();
        expect64("ventana.ciclos", snap.cpu.cycles, 5);
        expect1("ventana.running_tras_stop", running, 1'b0);
        expect1("ventana.snapshot_valid", snapshot_valid, 1'b1);

        // Un stop sin medicion activa no reabre ni altera el resultado.
        stop_window();
        expect64("ventana.ciclos_tras_stop_extra", snap.cpu.cycles, 5);

        // --- Caso 1: bundle con dos operaciones, un literal y un NOP -------
        start_window();
        // Un start repetido durante la medicion se ignora.
        perf_start = 1'b1;
        tick();
        cpu_ev.done_bundles = 8'd1;
        cpu_ev.done_instructions = 8'd2;
        cpu_ev.done_literal_slots = 8'd1;
        cpu_ev.done_nop_slots = 8'd1;
        tick();
        stop_window();
        expect64("caso1.bundles", snap.cpu.bundles, 1);
        expect64("caso1.instrucciones", snap.cpu.instructions, 2);
        expect64("caso1.literales", snap.cpu.literal_slots, 1);
        expect64("caso1.nops", snap.cpu.nop_slots, 1);
        expect64("caso1.ciclos", snap.cpu.cycles, 3);

        // --- Eventos simultaneos de modulos distintos ----------------------
        start_window();
        cpu_ev.done_bundles = 8'd2;
        cpu_ev.done_instructions = 8'd5;
        l1_access(1'b0, ACCESS_HIT);
        l2_ev.get_accept.valid = 1'b1;
        l2_ev.lookup.valid = 1'b1;
        l2_ev.lookup_hit = 1'b1;
        wb_ev.enqueued.valid = 1'b1;
        eb_ev.enqueued.valid = 1'b1;
        mem_ev.word.valid = 1'b1;
        tick();
        stop_window();
        expect64("simultaneos.bundles", snap.cpu.bundles, 2);
        expect64("simultaneos.instrucciones", snap.cpu.instructions, 5);
        expect64("simultaneos.l1_read_hits", snap.l1.read_hits, 1);
        expect64("simultaneos.l2_hits", snap.l2.hits, 1);
        expect64("simultaneos.wb_enqueued", snap.wb.enqueued, 1);
        expect64("simultaneos.eb_enqueued", snap.eb.enqueued, 1);
        expect64("simultaneos.mem_read_words", snap.mem.read_words, 1);

        // --- Caso 2: load hit en L1, presentacion y respuesta en el mismo --
        start_window();
        cpu_ev.dmem_begin = 1'b1;
        cpu_ev.dmem_done = 1'b1;
        cpu_ev.dmem_origin = ORIGIN_L1;
        l1_access(1'b0, ACCESS_HIT);
        tick();
        stop_window();
        expect64("caso2.l1_reads", snap.l1.reads, 1);
        expect64("caso2.l1_read_hits", snap.l1.read_hits, 1);
        expect64("caso2.completadas", snap.dmem.completed, 1);
        expect64("caso2.lecturas", snap.dmem.reads_completed, 1);
        expect64("caso2.latencia", snap.dmem.latency_sum, 1);
        expect64("caso2.stalls", snap.cpu.stall_cycles, 0);

        // --- Caso 3: store miss en L1, hit en L2, respuesta en E9 ----------
        start_window();
        cpu_ev.dmem_begin = 1'b1;
        cpu_ev.dmem_write = 1'b1;
        l1_access(1'b1, ACCESS_MISS);
        l2_ev.get_accept.valid = 1'b1;
        l2_ev.lookup.valid = 1'b1;
        l2_ev.lookup_hit = 1'b1;
        stall_miss();
        tick();
        for (int k = 0; k < 7; k++) begin
            stall_miss();
            tick();
        end
        cpu_ev.dmem_done = 1'b1;
        cpu_ev.dmem_origin = ORIGIN_L2;
        tick();
        stop_window();
        expect64("caso3.l1_writes", snap.l1.writes, 1);
        expect64("caso3.l1_write_misses", snap.l1.write_misses, 1);
        expect64("caso3.l2_demandas", snap.l2.demands, 1);
        expect64("caso3.l2_hits", snap.l2.hits, 1);
        expect64("caso3.latencia", snap.dmem.latency_sum, 9);
        expect64("caso3.escrituras", snap.dmem.writes_completed, 1);
        expect64("caso3.stalls", snap.cpu.stall_cycles, 8);
        expect64("caso3.wait_miss", snap.cpu.wait_miss, 8);
        expect64("caso3.miss_l2", snap.dmem.miss_stalls_l2, 8);

        // --- Caso 4: miss en ambos niveles, respuesta en E48 ---------------
        start_window();
        cpu_ev.dmem_begin = 1'b1;
        l1_access(1'b0, ACCESS_MISS);
        l2_ev.get_accept.valid = 1'b1;
        l2_ev.lookup.valid = 1'b1;
        l2_ev.lookup_hit = 1'b0;
        mem_ev.accept.valid = 1'b1;
        mem_ev.read_active = 1'b1;
        stall_miss();
        tick();
        // 38 ciclos mas de transferencia activa; ocho de ellos entregan palabra
        for (int k = 0; k < 38; k++) begin
            stall_miss();
            mem_ev.read_active = 1'b1;
            if (k < 8) mem_ev.word.valid = 1'b1;
            if (k == 37) mem_ev.complete.valid = 1'b1;
            tick();
        end
        // Espera hasta completar los 47 ciclos de congelamiento
        for (int k = 0; k < 8; k++) begin
            stall_miss();
            tick();
        end
        cpu_ev.dmem_done = 1'b1;
        cpu_ev.dmem_origin = ORIGIN_MEMORY;
        l2_ev.inflight = 32'd1;
        mem_ev.read_rsp_consumed = 1'b1;
        tick();
        stop_window();
        expect64("caso4.l1_read_misses", snap.l1.read_misses, 1);
        expect64("caso4.l2_misses", snap.l2.misses, 1);
        expect64("caso4.latencia", snap.dmem.latency_sum, 48);
        expect64("caso4.wait_miss", snap.cpu.wait_miss, 47);
        expect64("caso4.miss_memoria", snap.dmem.miss_stalls_mem, 47);
        expect64("caso4.mem_lecturas", snap.mem.reads, 1);
        expect64("caso4.mem_ciclos", snap.mem.read_cycles, 39);
        expect64("caso4.mem_palabras", snap.mem.read_words, 8);
        expect64("caso4.mem_completas", snap.mem.reads_complete, 1);

        // --- Caso 5: forwarding del write buffer ---------------------------
        start_window();
        cpu_ev.dmem_begin = 1'b1;
        l1_access(1'b0, ACCESS_MISS);
        wb_ev.forwarded.valid = 1'b1;
        tick();
        cpu_ev.dmem_done = 1'b1;
        cpu_ev.dmem_origin = ORIGIN_WB;
        tick();
        stop_window();
        expect64("caso5.l1_read_misses", snap.l1.read_misses, 1);
        expect64("caso5.wb_forwarded", snap.wb.forwarded, 1);
        expect64("caso5.l2_demandas", snap.l2.demands, 0);
        // Invariante del contrato: l1_misses = wb_forwarded + l2_demands
        expect64("caso5.invariante",
                 snap.l1.read_misses + snap.l1.write_misses,
                 snap.wb.forwarded + snap.l2.demands);

        // --- Caso 6: linea sucia drenada por el eviction buffer ------------
        start_window();
        eb_ev.enqueued.valid = 1'b1;
        eb_ev.write_accept.valid = 1'b1;
        eb_ev.write_accept.write = 1'b1;
        mem_ev.accept.valid = 1'b1;
        mem_ev.accept.write = 1'b1;
        tick();
        for (int k = 0; k < 8; k++) begin
            mem_ev.word.valid = 1'b1;
            mem_ev.word.write = 1'b1;
            mem_ev.write_active = 1'b1;
            tick();
        end
        eb_ev.write_done.valid = 1'b1;
        eb_ev.write_done.write = 1'b1;
        mem_ev.complete.valid = 1'b1;
        mem_ev.complete.write = 1'b1;
        mem_ev.write_rsp_consumed = 1'b1;
        tick();
        stop_window();
        expect64("caso6.eb_enqueued", snap.eb.enqueued, 1);
        expect64("caso6.eb_sent", snap.eb.sent, 1);
        expect64("caso6.eb_written", snap.eb.written, 1);
        expect64("caso6.mem_escrituras", snap.mem.writes, 1);
        expect64("caso6.mem_palabras", snap.mem.write_words, 8);
        expect64("caso6.mem_completas", snap.mem.writes_complete, 1);

        // --- Caso 7: respuesta disponible y retenida cinco ciclos ----------
        start_window();
        mem_ev.accept.valid = 1'b1;
        mem_ev.read_active = 1'b1;
        tick();
        mem_ev.complete.valid = 1'b1;
        mem_ev.read_active = 1'b1;
        tick();
        for (int k = 0; k < 5; k++) begin
            mem_ev.read_rsp_wait = 1'b1;
            tick();
        end
        l2_ev.inflight = 32'd1;
        mem_ev.read_rsp_consumed = 1'b1;
        stop_window();
        expect64("caso7.mem_completas", snap.mem.reads_complete, 1);
        expect64("caso7.espera_respuesta", snap.mem.read_rsp_wait_cycles, 5);
        expect64("caso7.transferencia_no_se_extiende", snap.mem.read_cycles, 2);

        // --- Caso 8: dos bundles de retardo, uno congelado tres ciclos -----
        start_window();
        cpu_ev.branch_done = 1'b1;
        cpu_ev.branch_taken = 1'b1;
        tick();
        cpu_ev.branch_delay = 1'b1;
        tick();
        for (int k = 0; k < 3; k++) begin
            stall_miss();
            tick();
        end
        cpu_ev.branch_delay = 1'b1;
        tick();
        stop_window();
        expect64("caso8.saltos", snap.cpu.branches, 1);
        expect64("caso8.tomados", snap.cpu.branches_taken, 1);
        expect64("caso8.retardo", snap.cpu.branch_delay_cycles, 2);
        expect64("caso8.wait_miss", snap.cpu.wait_miss, 3);

        // --- Cierre con trabajo pendiente ----------------------------------
        start_window();
        mem_ev.accept.valid = 1'b1;
        tick();
        mem_ev.complete.valid = 1'b1;
        tick();
        mem_ev.accept.valid = 1'b1;
        mem_ev.accept.write = 1'b1;
        tick();
        wb_ev.state.occupancy = 32'd2;
        eb_ev.state.occupancy = 32'd3;
        l2_ev.inflight = 32'd1;
        mem_ev.reads_pending = 32'd1;
        mem_ev.writes_pending = 32'd1;
        mem_ev.read_responses_pending = 32'd1;
        mem_ev.write_responses_pending = 32'd0;
        perf_stop = 1'b1;
        tick();
        expect32("pendiente.wb", snap.pending.wb_entries, 2);
        expect32("pendiente.eb", snap.pending.eb_entries, 3);
        expect32("pendiente.l2", snap.pending.l2_inflight, 1);
        expect32("pendiente.mem_lecturas", snap.pending.mem_reads, 0);
        expect32("pendiente.mem_escrituras", snap.pending.mem_writes, 1);
        expect32("pendiente.mem_rsp_lectura", snap.pending.mem_read_responses, 1);
        // Las ocupaciones del ultimo flanco tambien entran en sus acumulados.
        expect64("pendiente.wb_max", snap.wb.occupancy_max, 2);
        expect64("pendiente.eb_max", snap.eb.occupancy_max, 3);
        expect64("pendiente.l2_max", snap.l2.inflight_max, 1);

        // --- Errores: varios en un flanco y fallo de memoria ---------------
        start_window();
        l1_ev.error.valid = 1'b1;
        l1_ev.error.kind = ERROR_ADDRESS;
        cpu_ev.alignment_error.valid = 1'b1;
        cpu_ev.alignment_error.kind = ERROR_ALIGNMENT;
        mem_ev.accept.valid = 1'b1;
        tick();
        expect1("errores.failed", failed, 1'b1);
        mem_ev.complete.valid = 1'b1;
        mem_ev.complete_error = ERROR_TIMEOUT;
        tick();
        stop_window();
        expect64("errores.eventos", snap.error_events, 2);
        expect64("errores.mem_timeouts", snap.mem.timeouts, 1);
        expect64("errores.mem_completas", snap.mem.reads_complete, 0);
        expect1("errores.snapshot_failed", snap.failed, 1'b1);

        // --- Cierre fallido externo ----------------------------------------
        start_window();
        idle(2);
        perf_stop_error = 1'b1;
        tick();
        expect1("watchdog.running", running, 1'b0);
        expect1("watchdog.failed", failed, 1'b1);
        expect1("watchdog.snapshot_valid", snapshot_valid, 1'b1);

        // --- Saturacion ----------------------------------------------------
        // Se fuerza el contador de ciclos cerca del maximo; es la unica forma
        // de alcanzar 2**64 sin simular esa cantidad de flancos.
        start_window();
        dut.counters_q[0] = 64'hFFFF_FFFF_FFFF_FFFE;
        tick();
        expect1("saturacion.sin_overflow_aun", overflow, 1'b0);
        tick();
        expect64("saturacion.valor", snap.cpu.cycles, 64'hFFFF_FFFF_FFFF_FFFF);
        expect1("saturacion.overflow", overflow, 1'b1);
        tick();
        expect64("saturacion.se_mantiene", snap.cpu.cycles, 64'hFFFF_FFFF_FFFF_FFFF);
        stop_window();
        expect1("saturacion.overflow_en_snapshot", snap.overflow, 1'b1);

        check_configuration_freeze();
        check_buffer_stop_events();
        check_memory_stop_events();
        check_auxiliary_counters();

        // --- Reset a mitad de medicion -------------------------------------
        start_window();
        mem_ev.accept.valid = 1'b1;
        tick();
        mem_ev.complete.valid = 1'b1;
        tick();
        mem_ev.accept.valid = 1'b1;
        mem_ev.accept.write = 1'b1;
        cpu_ev.dmem_begin = 1'b1;
        stall_miss();
        tick();
        idle(3);
        @(negedge clk);
        configuration.cpu_hz = 100_000_000;
        rst_n = 1'b0;
        @(negedge clk);
        #1;
        expect1("reset_medio.running", running, 1'b0);
        expect1("reset_medio.snapshot_valid", snapshot_valid, 1'b0);
        expect1("reset_medio.overflow", overflow, 1'b0);
        expect1("reset_medio.failed", failed, 1'b0);
        expect64("reset_medio.ciclos", snap.cpu.cycles, 0);
        expect1("reset_medio.instantanea_vacia", snap == '0, 1'b1);
        rst_n = 1'b1;
        @(negedge clk);
        start_window();
        stop_window();
        expect1("reset_medio.sin_pendientes_antiguos", snap.pending == '0, 1'b1);

        if (errors != 0)
            $fatal(1, "%0d comprobaciones fallaron", errors);
        $display("PASS: ventana, contadores, cierre, errores y saturacion");
        $finish;
    end
endmodule
