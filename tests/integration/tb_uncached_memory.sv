`timescale 1ns/1ps

/**
 * @brief Referencia P2-12 real: datos, mascara, trafico, tiempos y metricas.
 * @details CPU de prueba de una demanda; controlador y RAM son los del sistema.
 * Las fuerzas solo inyectan bloqueos/errores/reset en sus fronteras reales.
 */
module tb_uncached_memory;
    parameter integer DIV = 2;
    parameter integer READ_FIRST = 25;
    parameter integer WRITE_FIRST = 25;
    parameter integer TIMEOUT_MODE = 0;
    localparam integer R = READ_FIRST + 7*DIV;
    localparam integer W = WRITE_FIRST + 7*DIV;
    localparam integer READ_PHASE = (DIV-READ_FIRST%DIV)%DIV;
    localparam integer WRITE_PHASE = (DIV-1-WRITE_FIRST%DIV+DIV)%DIV;
    localparam integer GAP = 1+(WRITE_PHASE-(READ_PHASE+R+1)%DIV+DIV)%DIV;
    localparam logic [31:0] BASE = pkg_memory::DATA_BASE_ADDRESS;
    logic clk = 0, rst_n, req_valid = 0, req_write = 0, rsp_ready = 1;
    logic req_ready, rsp_valid, rsp_error, start = 0, stop = 0;
    logic running, snapshot_valid, failed, overflow;
    pkg_memory::address_t address = BASE;
    pkg_memory::word_t data = 0, result;
    pkg_memory::byte_mask_t mask = 0;
    pkg_metrics::demand_origin_t origin;
    pkg_metrics::snapshot_t snapshot, frozen;
    pkg_metrics::cpu_events_t events;
    logic demand_started_q = 0;
    logic [7:0] expected_bytes [0:pkg_memory::MEMORY_BYTES-1];
    integer requests = 0, responses = 0, reads = 0, writes = 0, diagnostic_count = 0;
    integer elapsed_sum = 0, successful = 0, cycle = 0, read_at, write_at;
    time released_at;
    always #5 clk = ~clk;

    data_memory_hierarchy #(
        .REFERENCE_WITHOUT_CACHE(1'b1), .L2_MAX_INFLIGHT(3), .EVICTION_BUFFER_DEPTH(5),
        .MEM_CLOCK_DIV(DIV), .MEM_READ_FIRST_WORD_CYCLES(READ_FIRST),
        .MEM_WRITE_FIRST_WORD_CYCLES(WRITE_FIRST)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n), .dmem_req_valid_i(req_valid), .dmem_req_ready_o(req_ready),
        .dmem_req_addr_i(address), .dmem_req_write_i(req_write),
        .dmem_req_wdata_i(data), .dmem_req_wstrb_i(mask),
        .dmem_rsp_valid_o(rsp_valid), .dmem_rsp_ready_i(rsp_ready),
        .dmem_rsp_rdata_o(result), .dmem_rsp_error_o(rsp_error), .dmem_rsp_origin_o(origin),
        .perf_start_i(start), .perf_stop_i(stop), .perf_stop_error_i(1'b0), .cpu_events_i(events),
        .perf_running_o(running), .perf_snapshot_valid_o(snapshot_valid),
        .perf_failed_o(failed), .perf_overflow_o(overflow), .perf_snapshot_o(snapshot)
    );

    /** @brief Productor CPU de prueba; los conteos esperados se calculan aparte. */
    always_comb begin
        events = '0;
        if (rst_n) begin
            events.dmem_begin = req_valid && !demand_started_q;
            events.dmem_write = req_write;
            events.dmem_done = rsp_valid && rsp_ready;
            events.dmem_error = rsp_error;
            events.dmem_origin = origin;
            events.stall = (req_valid || demand_started_q) && !(rsp_valid && rsp_ready);
            if (events.stall) begin
                if (rsp_valid) events.wait_reason = pkg_metrics::WAIT_RESPONSE;
                else if (req_valid && !req_ready) events.wait_reason = pkg_metrics::WAIT_ACCEPT;
                else events.wait_reason = pkg_metrics::WAIT_MISS;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) demand_started_q <= 0;
        else if (events.dmem_done) demand_started_q <= 0;
        else if (events.dmem_begin) demand_started_q <= 1;
    end

    always @(posedge clk) begin
        cycle++;
        if (rst_n) begin
            requests += int'(req_valid && req_ready);
            responses += int'(rsp_valid && rsp_ready);
            diagnostic_count += int'(dut.return_error.valid);
            if (responses > requests) $fatal(1, "Respuesta sin demanda");
            if (dut.mem_events.accept.valid) begin
                if (dut.mem_events.accept.write) begin writes++; write_at = cycle; end
                else begin reads++; read_at = cycle; end
            end
            if (dut.mem_events.complete.valid && dut.mem_events.complete_error == pkg_metrics::ERROR_NONE) begin
                if (dut.mem_events.complete.write ? cycle-write_at != W+1 : cycle-read_at != R)
                    $fatal(1, "Tiempo de burst distinto del contrato");
            end
            if (TIMEOUT_MODE && dut.mem_events.complete.valid &&
                dut.mem_events.complete_error == pkg_metrics::ERROR_TIMEOUT) begin
                $display("UNCACHED_TIMEOUT_OK mode=%0d", TIMEOUT_MODE);
                $fflush();
            end
        end else if (req_ready || rsp_valid || dut.mem_rd_req_valid || dut.mem_wr_req_valid ||
                     dut.mem_rd_rsp_ready || dut.mem_wr_rsp_ready)
            $fatal(1, "Transferencia durante reset");
    end

    task automatic reset_system(input logic initialize);
        @(negedge clk);
        rst_n = 0; req_valid = 0; rsp_ready = 1; start = 0; stop = 0;
        repeat (3) @(negedge clk);
        if (initialize)
            for (integer i = 0; i < pkg_memory::MEMORY_BYTES; i++) begin
                expected_bytes[i] = 8'(i ^ (i>>8) ^ 137);
                dut.u_main_memory.u_storage.memory[i] = expected_bytes[i];
            end
        {requests, responses, reads, writes, diagnostic_count, elapsed_sum, successful} = '0;
        rst_n = 1; start = 1; released_at = $time;
        @(negedge clk);
        start = 0;
        repeat (3*DIV) @(negedge clk);
    endtask

    function automatic pkg_memory::word_t expected_word(input pkg_memory::address_t addr);
        for (integer i = 0; i < 4; i++) expected_word[8*i +: 8] = expected_bytes[addr-BASE+i];
    endfunction

    task automatic compare_memory;
        for (integer i = 0; i < pkg_memory::MEMORY_BYTES; i++)
            if (dut.u_main_memory.u_storage.memory[i] !== expected_bytes[i])
                $fatal(1, "Byte no preservado: offset=%h actual=%h esperado=%h", i,
                       dut.u_main_memory.u_storage.memory[i], expected_bytes[i]);
    endtask

    task automatic access(input pkg_memory::address_t addr, input logic write_access,
                          input pkg_memory::word_t value, input pkg_memory::byte_mask_t lanes,
                          input logic expect_error, input logic check_timing);
        integer elapsed, expected_time;
        logic accepted, done;
        pkg_memory::word_t expected;
        @(negedge clk);
        /** Fase independiente del DUT: se deriva del reloj/reset del testbench. */
        if (check_timing)
            while ((DIV-1+integer'(($time-released_at)/10))%DIV != READ_PHASE) @(negedge clk);
        address = addr; req_write = write_access; data = value; mask = lanes; req_valid = 1;
        expected = (expect_error || write_access) ? 0 : expected_word(addr);
        expected_time = write_access ? 1+R+GAP+W+1 : 1+R;
        elapsed = 0; accepted = 0; done = 0;
        while (!done && elapsed < 700) begin
            @(posedge clk);
            elapsed++;
            if (req_valid && req_ready) accepted = 1;
            if (rsp_valid && rsp_ready) begin
                if (!accepted || result !== expected || rsp_error !== expect_error)
                    $fatal(1, "Respuesta addr=%h dato=%h esperado=%h error=%b esperado=%b", addr, result, expected, rsp_error, expect_error);
                if (expect_error ? origin != pkg_metrics::ORIGIN_ERROR : origin != pkg_metrics::ORIGIN_REFERENCE)
                    $fatal(1, "Procedencia incorrecta");
                if (check_timing && elapsed != expected_time)
                    $fatal(1, "Tiempo CPU E%0d esperado E%0d (R=%0d W=%0d G=%0d)", elapsed, expected_time, R, W, GAP);
                done = 1;
            end
            @(negedge clk);
            if (accepted) req_valid = 0;
        end
        if (!done) $fatal(1, "Demanda sin progreso");
        if (!expect_error) begin
            successful++; elapsed_sum += elapsed;
            if (write_access)
                for (integer i = 0; i < 4; i++)
                    if (lanes[i]) expected_bytes[addr-BASE+i] = value[8*i +: 8];
        end
    endtask

    task automatic check_reset_cancellation;
        repeat (R+W+2*DIV) @(negedge clk);
        if (rsp_valid || responses || requests || reads || writes)
            $fatal(1, "Reset dejo reaparecer trabajo antiguo");
        compare_memory();
    endtask

    initial begin
        reset_system(1);
        if (TIMEOUT_MODE) begin
            fork
                begin
                    wait (dut.mem_events.accept.valid && dut.mem_events.accept.write == (TIMEOUT_MODE == 2));
                    @(negedge clk);
                    force dut.u_memory_controller.ram_clk_o = 1'b0;
                end
                access(BASE+28, TIMEOUT_MODE == 2, 32'h12345678, 4'hf, 0, 0);
            join
            $fatal(1, "Falto timeout del controlador");
        end
        access(BASE+28, 0, 0, 0, 0, 1);
        access(BASE+28, 1, 32'ha1b2c3d4, 4'hf, 0, 1);
        compare_memory();
        /** Todas las mascaras, incluidas byte/media palabra y la mascara cero. */
        for (integer lanes = 0; lanes < 16; lanes++) begin
            access(BASE+32+(lanes%8)*4, 1, 32'h12345678 ^ (32'h01010101*lanes), 4'(lanes), 0, 0);
            compare_memory();
            access(BASE+32+(lanes%8)*4, 0, 0, 0, 0, 0);
        end
        for (integer word_index = 0; word_index < 8; word_index++)
            access(BASE+32+4*word_index, 0, 0, 0, 0, 0);
        access(BASE+pkg_memory::MEMORY_BYTES-4, 1, 32'hfedcba98, 4'hf, 0, 0);
        compare_memory();

        /** Cierre: contadores exactos, capacidades ausentes y pendientes cero. */
        stop = 1;
        @(negedge clk);
        stop = 0;
        if (!snapshot_valid || running || failed || overflow || snapshot.configuration.reference_without_cache !== 1 ||
            snapshot.configuration.l1_bytes || snapshot.configuration.l2_bytes ||
            snapshot.configuration.write_buffer_depth || snapshot.configuration.eviction_buffer_depth ||
            snapshot.configuration.l2_max_inflight || snapshot.configuration.mem_clock_div != DIV ||
            snapshot.configuration.mem_read_first_word_cycles != READ_FIRST ||
            snapshot.configuration.mem_write_first_word_cycles != WRITE_FIRST ||
            snapshot.l1 !== '0 || snapshot.l2 !== '0 || snapshot.wb !== '0 || snapshot.eb !== '0 || snapshot.pending !== '0)
            $fatal(1, "Configuracion/pendientes/contadores de cache incorrectos");
        if (snapshot.dmem.completed != successful || snapshot.dmem.failed ||
            snapshot.dmem.latency_sum != elapsed_sum || snapshot.mem.reads != successful ||
            snapshot.mem.reads != reads || snapshot.mem.writes != writes ||
            snapshot.mem.read_words != 8*reads || snapshot.mem.write_words != 8*writes ||
            snapshot.mem.reads_complete != reads || snapshot.mem.writes_complete != writes ||
            snapshot.mem.read_cycles != R*reads || snapshot.mem.write_cycles != W*writes)
            $fatal(1, "Conteos de acceso/trafico/latencia incorrectos");
        frozen = snapshot;
        repeat (5) @(negedge clk);
        if (snapshot !== frozen) $fatal(1, "Snapshot cambio despues del cierre");

        /** Sin cache: un segundo load de la misma palabra vuelve a usar memoria. */
        reset_system(1);
        access(BASE, 0, 0, 0, 0, 1);
        access(BASE, 0, 0, 0, 0, 1);
        if (reads != 2) $fatal(1, "Se reutilizo una linea entre demandas");
        access(BASE-4, 0, 0, 0, 1, 0);
        access(BASE+pkg_memory::MEMORY_BYTES, 1, 32'hffffffff, 4'hf, 1, 0);
        if (reads != 2 || writes || diagnostic_count != 2) $fatal(1, "Direccion invalida genero trafico");

        /** Respuesta retenida: controller liberado y palabra/origen estables. */
        reset_system(1);
        rsp_ready = 0;
        fork
            begin
                @(posedge clk);
                while (!rsp_valid) @(posedge clk);
                repeat (6) begin
                    @(negedge clk);
                    if (!rsp_valid || result !== expected_word(BASE+4) || req_ready ||
                        rsp_error || origin != pkg_metrics::ORIGIN_REFERENCE)
                        $fatal(1, "Respuesta retenida alterada");
                end
                rsp_ready = 1;
            end
            access(BASE+4, 0, 0, 0, 0, 0);
        join
        if (reads != 1 || requests != 1 || responses != 1) $fatal(1, "Respuesta retenida duplicada");

        /** Fallo de lectura de un store: no debe emitir ninguna escritura. */
        reset_system(1);
        force dut.ram_read_valid = 1'b0;
        access(BASE, 1, 32'hffffffff, 4'hf, 1, 0);
        release dut.ram_read_valid;
        if (writes || !failed) $fatal(1, "Store escribio tras lectura fallida o no marco fallo");
        compare_memory();

        /** Error de escritura real informado por el controlador. */
        reset_system(1);
        fork
            begin
                wait (dut.mem_wr_req_valid && dut.mem_wr_req_ready);
                @(negedge clk);
                force dut.ram_out_of_range = 1'b1;
            end
            access(BASE+28, 1, 32'habcdabcd, 4'hf, 1, 0);
        join
        release dut.ram_out_of_range;
        if (writes != 1 || !failed) $fatal(1, "No se propago el fallo de escritura");

        /** Oferta de lectura bloqueada: campos estables y reset antes de aceptar. */
        reset_system(1);
        force dut.mem_rd_req_ready = 1'b0;
        @(negedge clk);
        address = BASE; req_write = 0; mask = 0; req_valid = 1;
        @(negedge clk); req_valid = 0;
        repeat (4) begin
            @(negedge clk);
            if (!dut.mem_rd_req_valid || dut.mem_rd_req_base != BASE || dut.mem_rd_req_id != 0)
                $fatal(1, "Oferta de lectura inestable");
        end
        reset_system(0);
        release dut.mem_rd_req_ready;
        check_reset_cancellation();

        /** Reset a mitad de lectura, oferta/escritura y respuesta retenida. */
        for (integer mode = 0; mode < 4; mode++) begin
            reset_system(1);
            if (mode == 1) force dut.mem_wr_req_ready = 1'b0;
            if (mode == 3) rsp_ready = 0;
            @(negedge clk);
            address = BASE+28; req_write = mode == 1 || mode == 2; data = 32'h12345678; mask = 4'hf; req_valid = 1;
            @(negedge clk); req_valid = 0;
            case (mode)
                0: wait (dut.mem_events.word.valid && !dut.mem_events.word.write);
                1: wait (dut.mem_wr_req_valid);
                2: wait (dut.mem_events.word.valid && dut.mem_events.word.write);
                3: wait (rsp_valid);
            endcase
            reset_system(0);
            if (mode == 1) release dut.mem_wr_req_ready;
            check_reset_cancellation();
        end

        /** Id/base ajenos no se consumen y producen un solo diagnostico. */
        reset_system(1);
        @(negedge clk);
        address = BASE; req_write = 0; req_valid = 1;
        @(negedge clk); req_valid = 0;
        wait (dut.mem_rd_rsp_valid);
        force dut.mem_rd_rsp_id = 2'd2;
        repeat (4) @(negedge clk);
        if (rsp_valid || dut.mem_rd_rsp_ready || diagnostic_count != 1)
            $fatal(1, "Respuesta ajena consumida o diagnostico repetido");
        reset_system(0);
        release dut.mem_rd_rsp_id;
        check_reset_cancellation();
        $display("PASS tb_uncached_memory DIV=%0d READ=%0d WRITE=%0d: datos, mascaras, E%0d/E%0d, metricas, esperas, errores y reset", DIV, READ_FIRST, WRITE_FIRST, 1+R, 1+R+GAP+W+1);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Timeout de testbench uncached");
    end
endmodule
