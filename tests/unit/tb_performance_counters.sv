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
        mem_ev.complete.valid = 1'b1;
        tick();
        for (int k = 0; k < 5; k++) begin
            mem_ev.read_rsp_wait = 1'b1;
            tick();
        end
        stop_window();
        expect64("caso7.mem_completas", snap.mem.reads_complete, 1);
        expect64("caso7.espera_respuesta", snap.mem.read_rsp_wait_cycles, 5);

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
        tick();
        wb_ev.state.occupancy = 32'd2;
        eb_ev.state.occupancy = 32'd3;
        l2_ev.inflight = 32'd1;
        mem_ev.reads_pending = 32'd1;
        mem_ev.writes_pending = 32'd2;
        mem_ev.read_responses_pending = 32'd1;
        mem_ev.write_responses_pending = 32'd0;
        perf_stop = 1'b1;
        tick();
        expect32("pendiente.wb", snap.pending.wb_entries, 2);
        expect32("pendiente.eb", snap.pending.eb_entries, 3);
        expect32("pendiente.l2", snap.pending.l2_inflight, 1);
        expect32("pendiente.mem_lecturas", snap.pending.mem_reads, 1);
        expect32("pendiente.mem_escrituras", snap.pending.mem_writes, 2);
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

        // --- Reset a mitad de medicion -------------------------------------
        start_window();
        idle(3);
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        #1;
        expect1("reset_medio.running", running, 1'b0);
        expect1("reset_medio.snapshot_valid", snapshot_valid, 1'b0);
        expect1("reset_medio.overflow", overflow, 1'b0);
        expect1("reset_medio.failed", failed, 1'b0);
        expect64("reset_medio.ciclos", snap.cpu.cycles, 0);
        rst_n = 1'b1;
        @(negedge clk);

        if (errors != 0)
            $fatal(1, "%0d comprobaciones fallaron", errors);
        $display("PASS: ventana, contadores, cierre, errores y saturacion");
        $finish;
    end
endmodule
