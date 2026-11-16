`timescale 1ns/1ps

/**
 * @brief Integracion autochecking con bloques reales y referencia de bytes.
 * @details Las fuerzas se limitan a estimular canales de victimas y crear
 * presion controlada; no reemplazan caches, buffers ni controlador por dobles.
 * Los tiempos proceden del contrato CPU-L1 y del burst configurado.
 */
module tb_data_memory_hierarchy;
    parameter integer N = 4;
    parameter integer WB_DEPTH = 4;
    parameter integer EB_DEPTH = 8;
    parameter integer DIV = 2;
    parameter integer READ_FIRST = 25;
    parameter integer WRITE_FIRST = 25;
    localparam logic [31:0] BASE = pkg_memory::DATA_BASE_ADDRESS;
    logic clk = 0, rst_n, req_valid = 0, req_write = 0, rsp_ready = 1;
    logic req_ready, rsp_valid, rsp_error;
    pkg_memory::address_t req_addr = BASE;
    pkg_memory::word_t req_data = 0, rsp_data;
    pkg_memory::byte_mask_t req_mask = 0;
    pkg_metrics::demand_origin_t origin;
    pkg_metrics::cpu_events_t cpu_events = '0;
    logic perf_start = 0, perf_stop = 0;
    logic inject_valid = 0;
    pkg_memory::address_t inject_base = BASE;
    pkg_memory::line_t inject_data = '0;
    logic [7:0] reference_bytes [0:pkg_memory::MEMORY_BYTES-1];
    integer requests = 0, responses = 0, gets = 0, fills = 0;
    integer mem_reads = 0, mem_writes = 0, read_words = 0, write_words = 0;
    integer forwards = 0, raw_waits = 0, eb_waits = 0, wb_full = 0;
    integer mem_read_at, mem_write_at, cycle = 0;
    logic input_used = 0;
    always #5 clk = ~clk;

    data_memory_hierarchy #(
        .L2_MAX_INFLIGHT(N), .WRITE_BUFFER_DEPTH(WB_DEPTH), .EVICTION_BUFFER_DEPTH(EB_DEPTH),
        .MEM_CLOCK_DIV(DIV), .MEM_READ_FIRST_WORD_CYCLES(READ_FIRST),
        .MEM_WRITE_FIRST_WORD_CYCLES(WRITE_FIRST), .MEM_TIMEOUT_CYCLES(256)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n), .dmem_req_valid_i(req_valid), .dmem_req_ready_o(req_ready),
        .dmem_req_addr_i(req_addr), .dmem_req_write_i(req_write),
        .dmem_req_wdata_i(req_data), .dmem_req_wstrb_i(req_mask),
        .dmem_rsp_valid_o(rsp_valid), .dmem_rsp_ready_i(rsp_ready),
        .dmem_rsp_rdata_o(rsp_data), .dmem_rsp_error_o(rsp_error), .dmem_rsp_origin_o(origin),
        .cpu_events_i(cpu_events), .perf_start_i(perf_start), .perf_stop_i(perf_stop),
        .perf_stop_error_i(1'b0)
    );

    /** @brief Comprueba conexiones, entregas unicas y tiempos de los bursts. */
    always @(posedge clk) begin
        cycle++;
        if (rst_n) begin
            if (req_valid && req_ready) requests++;
            if (rsp_valid && rsp_ready) responses++;
            if (responses > requests) $fatal(1, "Respuesta sin solicitud");
            if (dut.l1_events.access_valid !== (req_valid && req_ready) ||
                dut.l2_events.get_accept.valid !== (dut.l2_get_valid && dut.l2_get_ready))
                $fatal(1, "Eventos de aceptacion desconectados");
            if (dut.l2_get_valid && dut.l2_get_ready) gets++;
            if (dut.fill_valid && dut.fill_ready) fills++;
            if (int'(dut.wb_fwd_valid && dut.wb_fwd_ready) +
                int'(dut.l2_fill_valid && dut.l2_fill_ready) +
                int'(dut.mem_rd_rsp_valid && dut.mem_rd_rsp_ready) !=
                int'(dut.fill_valid && dut.fill_ready))
                $fatal(1, "Retorno no exclusivo o confirmacion anticipada");
            if (dut.mem_rd_rsp_valid && dut.mem_rd_rsp_ready &&
                (!dut.l2_events.get_done.valid || dut.fill_source != pkg_memory::FILL_MEMORY))
                $fatal(1, "L2 no observo la entrega directa de memoria a L1");
            if (dut.eb_probe_hit && dut.mem_rd_req_valid && dut.mem_rd_req_ready)
                $fatal(1, "Lectura aceptada con RAW pendiente");
            if (dut.mem_events.accept.valid) begin
                if (dut.mem_events.accept.write) begin
                    mem_writes++;
                    mem_write_at = cycle;
                end else begin
                    mem_reads++;
                    mem_read_at = cycle;
                end
            end
            if (dut.mem_events.word.valid) begin
                if (dut.mem_events.word.write) write_words++;
                else read_words++;
            end
            if (dut.mem_events.complete.valid) begin
                if (dut.mem_events.complete.write) begin
                    /** El aviso de la ultima escritura RAM se muestrea al flanco CPU siguiente. */
                    if (cycle-mem_write_at != WRITE_FIRST+7*DIV+1)
                        $fatal(1, "Aviso de escritura fuera de su cruce de reloj");
                end else if (cycle-mem_read_at != READ_FIRST+7*DIV)
                    $fatal(1, "Burst de lectura fuera del contrato");
            end
            forwards += int'(dut.wb_events.forwarded.valid);
            raw_waits += int'(dut.eb_events.state.raw_wait);
            eb_waits += int'(dut.eb_events.state.push_wait);
            wb_full += int'(dut.wb_events.state.occupancy == WB_DEPTH);
            if (dut.u_l1.input_valid_q) input_used = 1;
            if (dut.return_error.valid || dut.l1_events.error.valid &&
                dut.l1_events.error.kind == pkg_metrics::ERROR_PROTOCOL ||
                dut.l2_events.error.valid || dut.wb_events.error.valid || dut.eb_events.error.valid)
                $fatal(1, "Error de protocolo en la integracion");
        end else if (rsp_valid || req_ready || dut.fill_valid || dut.mem_wr_req_valid)
            $fatal(1, "Transferencia durante reset");
    end

    /** @brief Tras cada flanco, ninguna linea valida se conserva en ambos niveles. */
    always @(negedge clk) if (rst_n) begin
        for (integer set_index = 0; set_index < dut.u_l1.SET_COUNT; set_index++) begin
            for (integer way = 0; way < pkg_memory::L1_WAYS; way++) begin
                if (dut.u_l1.block_valid_q[set_index][way]) begin
                    pkg_memory::address_t line_base;
                    integer l2_set;
                    line_base = (32'(dut.u_l1.block_tag_q[set_index][way]) <<
                        (dut.u_l1.SET_INDEX_W + dut.u_l1.BLOCK_OFFSET_W)) |
                        (set_index << dut.u_l1.BLOCK_OFFSET_W);
                    l2_set = (line_base / pkg_memory::LINE_BYTES) % dut.u_l2.SETS;
                    for (integer l2_way = 0; l2_way < pkg_memory::L2_WAYS; l2_way++)
                        if (dut.u_l2.u_tags.valid_q[l2_set*pkg_memory::L2_WAYS+l2_way] &&
                            dut.u_l2.u_tags.tag_q[l2_set*pkg_memory::L2_WAYS+l2_way] ==
                            (line_base >> (dut.u_l2.OFFSET_W+dut.u_l2.SET_W)))
                            $fatal(1, "Linea valida duplicada en L1 y L2: %h", line_base);
                end
            end
        end
    end

    task automatic reset_system;
        @(negedge clk);
        rst_n = 0;
        req_valid = 0;
        rsp_ready = 1;
        perf_start = 0;
        perf_stop = 0;
        repeat (3) @(negedge clk);
        for (integer index = 0; index < pkg_memory::MEMORY_BYTES; index++) begin
            reference_bytes[index] = 8'(index ^ (index >> 8));
            dut.u_main_memory.u_storage.memory[index] = reference_bytes[index];
        end
        {requests, responses, gets, fills, mem_reads, mem_writes, read_words, write_words} = '0;
        {forwards, raw_waits, eb_waits, wb_full} = '0;
        input_used = 0;
        rst_n = 1;
        perf_start = 1;
        @(negedge clk);
        perf_start = 0;
        repeat (3*DIV) @(negedge clk);
    endtask

    function automatic pkg_memory::word_t reference_word(input pkg_memory::address_t address);
        for (integer byte_index = 0; byte_index < 4; byte_index++)
            reference_word[8*byte_index +: 8] = reference_bytes[address-BASE+byte_index];
    endfunction

    /** @brief Compara cada respuesta con bytes independientes del almacenamiento RTL. */
    task automatic access_word(input pkg_memory::address_t address, input logic write_access,
                               input pkg_memory::word_t data, input pkg_memory::byte_mask_t mask,
                               input integer expected_cycles, input integer expected_origin);
        integer elapsed;
        logic accepted, completed;
        logic invalid;
        pkg_memory::word_t expected;
        @(negedge clk);
        req_valid = 1;
        req_addr = address;
        req_write = write_access;
        req_data = data;
        req_mask = mask;
        invalid = address < BASE || address >= BASE+pkg_memory::MEMORY_BYTES;
        expected = (write_access || invalid) ? 32'b0 : reference_word(address);
        elapsed = 0;
        accepted = 0;
        completed = 0;
        while (!completed && elapsed < 2000) begin
            @(posedge clk);
            elapsed++;
            if (req_valid && req_ready) accepted = 1;
            if (rsp_valid && rsp_ready) begin
                expected = (write_access || invalid) ? 32'b0 : reference_word(address);
                if (!accepted || rsp_error !== invalid || rsp_data !== expected)
                    $fatal(1, "Dato/error addr=%h dato=%h esperado=%h error=%b", address, rsp_data, expected, rsp_error);
                if (expected_cycles > 0 && elapsed != expected_cycles)
                    $fatal(1, "Latencia addr=%h E%0d esperada E%0d", address, elapsed, expected_cycles);
                if (expected_origin >= 0 && int'(origin) != expected_origin)
                    $fatal(1, "Origen addr=%h recibido=%0d esperado=%0d", address, origin, expected_origin);
                completed = 1;
            end
            @(negedge clk);
            if (accepted) req_valid = 0;
        end
        if (!completed) $fatal(1, "Sin progreso addr=%h", address);
        if (write_access && !invalid)
            for (integer byte_index = 0; byte_index < 4; byte_index++)
                if (mask[byte_index]) reference_bytes[address-BASE+byte_index] = data[8*byte_index +: 8];
    endtask

    /** @brief Inyecta una victima por el canal real de WB o EB. */
    task automatic inject_line(input pkg_memory::address_t address, input logic to_eb);
        @(negedge clk);
        inject_base = address;
        for (integer byte_index = 0; byte_index < pkg_memory::LINE_BYTES; byte_index++) begin
            reference_bytes[address-BASE+byte_index] = 8'(address+byte_index+73);
            inject_data[8*byte_index +: 8] = reference_bytes[address-BASE+byte_index];
        end
        inject_valid = 1;
        @(posedge clk);
        if (to_eb ? !dut.eb_push_ready : !dut.wb_push_ready)
            $fatal(1, "Inyeccion sin espacio de buffer");
        @(negedge clk);
        inject_valid = 0;
    endtask

    initial begin
        reset_system();
        if (dut.configuration.write_buffer_depth != WB_DEPTH ||
            dut.configuration.eviction_buffer_depth != EB_DEPTH ||
            dut.configuration.l2_max_inflight != N || dut.configuration.mem_clock_div != DIV ||
            dut.configuration.mem_read_first_word_cycles != READ_FIRST ||
            dut.configuration.mem_write_first_word_cycles != WRITE_FIRST ||
            dut.configuration.mem_timeout_cycles != 256 || dut.configuration.reference_without_cache)
            $fatal(1, "Configuracion exportada distinta de la integrada");
        /** La fase del CDC no agrega espera previa en esta referencia sin contencion. */
        @(negedge clk);
        while (dut.u_memory_controller.divider_count_q !=
               (DIV - READ_FIRST%DIV - pkg_memory::L2_HIT_CYCLES%DIV - 1 + 2*DIV)%DIV)
            @(negedge clk);
        access_word(BASE, 0, 0, 0, 9+READ_FIRST+7*DIV, pkg_metrics::ORIGIN_MEMORY);
        access_word(BASE+4, 0, 0, 0, 1, pkg_metrics::ORIGIN_L1);
        access_word(BASE+4, 1, 32'haabbccdd, 4'b0101, 1, pkg_metrics::ORIGIN_L1);
        access_word(BASE+4, 0, 0, 0, 1, pkg_metrics::ORIGIN_L1);
        access_word(BASE+2048, 0, 0, 0, 0, pkg_metrics::ORIGIN_MEMORY);
        access_word(BASE+4096, 0, 0, 0, 0, pkg_metrics::ORIGIN_MEMORY);
        wait (dut.wb_events.state.occupancy == 0 && dut.l2_events.inflight == 0);
        @(negedge clk);
        access_word(BASE+4, 0, 0, 0, 9, pkg_metrics::ORIGIN_L2);
        access_word(BASE-4, 0, 0, 0, 1, pkg_metrics::ORIGIN_ERROR);
        access_word(BASE+pkg_memory::MEMORY_BYTES, 1, 32'hffffffff, 4'hf, 1, pkg_metrics::ORIGIN_ERROR);
        if (mem_reads != 3 || read_words != 24 || requests != 9 || responses != 9)
            $fatal(1, "Eventos/solicitudes duplicados en caminos L1/L2/memoria");

        /** Retiene una respuesta CPU; ni el store ni la aceptacion se repiten. */
        rsp_ready = 0;
        @(negedge clk);
        req_valid = 1; req_addr = BASE+4; req_write = 0; req_mask = 0;
        @(posedge clk);
        if (!req_ready || !rsp_valid) $fatal(1, "Hit retenido no disponible en E1");
        @(negedge clk);
        req_valid = 0;
        repeat (5) begin
            @(negedge clk);
            if (!rsp_valid || rsp_data !== reference_word(BASE+4) || origin != pkg_metrics::ORIGIN_L1)
                $fatal(1, "Respuesta CPU inestable");
        end
        rsp_ready = 1;
        @(negedge clk);

        /** WB lleno: forwarding recibe en la entrada L1 y libera al origen. */
        reset_system();
        access_word(BASE+2048, 0, 0, 0, 0, -1);
        access_word(BASE+4096, 0, 0, 0, 0, -1);
        force dut.wb_install_valid = 1'b0;
        force dut.wb_push_valid = inject_valid;
        force dut.wb_push_base = inject_base;
        force dut.wb_push_data = inject_data;
        force dut.wb_push_dirty = 1'b1;
        /** La victima inyectada no pertenece a L1 y no debe invalidar su via. */
        force dut.u_l1.wb_push_handshake = 1'b0;
        for (integer index = 0; index < WB_DEPTH; index++)
            inject_line(BASE+32*index, 0);
        release dut.wb_push_valid;
        release dut.wb_push_base;
        release dut.wb_push_data;
        release dut.wb_push_dirty;
        release dut.u_l1.wb_push_handshake;
        access_word(BASE, 0, 0, 0, 0, pkg_metrics::ORIGIN_WB);
        if (forwards != 1 || !input_used || wb_full == 0 || gets != 2)
            $fatal(1, "Forwarding con WB lleno: fwd=%0d input=%b full=%0d gets=%0d", forwards, input_used, wb_full, gets);
        release dut.wb_install_valid;
        wait (dut.wb_events.state.occupancy == 0);

        /** RAW incluso con el push coincidente con la primera oferta de lectura. */
        reset_system();
        force dut.eb_push_valid = inject_valid;
        force dut.eb_push_base = inject_base;
        force dut.eb_push_data = inject_data;
        force dut.eb_push_dirty = 1'b1;
        fork
            begin
                wait (dut.eb_probe_valid);
                inject_line(BASE+8192, 1);
            end
            begin
                /** Esperado actualizado antes de que la lectura termine. */
                access_word(BASE+8192, 0, 0, 0, 0, pkg_metrics::ORIGIN_MEMORY);
            end
        join
        release dut.eb_push_valid;
        release dut.eb_push_base;
        release dut.eb_push_data;
        release dut.eb_push_dirty;
        if (raw_waits == 0 || mem_writes != 1 || write_words != 8 || mem_reads != 1)
            $fatal(1, "No se ejercito RAW con drenado y burst completos");

        /** EB lleno bloquea instalaciones; al reanudar drenado progresa la cadena. */
        reset_system();
        force dut.mem_wr_req_valid = 1'b0;
        force dut.eb_push_valid = inject_valid;
        force dut.eb_push_base = inject_base;
        force dut.eb_push_data = inject_data;
        force dut.eb_push_dirty = 1'b1;
        for (integer index = 0; index < EB_DEPTH; index++) inject_line(BASE+512+32*index, 1);
        release dut.eb_push_valid;
        release dut.eb_push_base;
        release dut.eb_push_data;
        release dut.eb_push_dirty;
        fork
            begin
                @(posedge clk);
                while (!dut.eb_events.state.push_wait) @(posedge clk);
                repeat (12) @(negedge clk);
                release dut.mem_wr_req_valid;
            end
            begin
                for (integer index = 0; index < 12; index++)
                    access_word(BASE+4096*index, 1, 32'hdead0000+index, 4'hf, 0, -1);
            end
        join
        wait (dut.wb_events.state.occupancy == 0 && dut.eb_events.state.occupancy == 0);
        for (integer index = 0; index < 12; index++) access_word(BASE+4096*index, 0, 0, 0, 0, -1);
        if (eb_waits == 0 || mem_writes == 0)
            $fatal(1, "Presion EB: esperas=%0d escrituras=%0d", eb_waits, mem_writes);

        /** Reset en mitad de un burst: no reaparece su respuesta ni su id. */
        reset_system();
        @(negedge clk);
        req_valid = 1; req_addr = BASE; req_write = 0; req_mask = 0;
        @(posedge clk);
        @(negedge clk);
        req_valid = 0;
        wait (dut.mem_events.word.valid);
        reset_system();
        repeat (READ_FIRST+7*DIV+5) @(negedge clk);
        if (rsp_valid || responses || dut.l2_events.inflight || dut.wb_events.state.occupancy ||
            dut.eb_events.state.occupancy) $fatal(1, "Reset dejo trabajo anterior en la jerarquia");
        access_word(BASE, 0, 0, 0, 0, pkg_metrics::ORIGIN_MEMORY);
        if (requests != responses) $fatal(1, "Finalizaciones pendientes");
        $display("PASS tb_data_memory_hierarchy N=%0d WB=%0d EB=%0d DIV=%0d: datos, E1/E9/E%0d, RAW, presion y reset", N, WB_DEPTH, EB_DEPTH, DIV, 9+READ_FIRST+7*DIV);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Timeout tb_data_memory_hierarchy");
    end
endmodule
