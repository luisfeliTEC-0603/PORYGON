`timescale 1ns/1ps

/**
 * @brief Prueba aislada de L1-D: reset, id L2, hits (L1-3/L1-4) y miss/fill/WB (L1-5/L1-6).
 */
module tb_cache_l1;
    localparam integer SET_COUNT = pkg_memory::L1_BYTES /
        (pkg_memory::L1_WAYS * pkg_memory::LINE_BYTES);
    logic clk = 1'b0;
    logic rst_n = 1'b1;
    logic req_valid = 1'b0;
    logic [31:0] req_addr = 32'b0;
    logic req_write = 1'b0;
    logic [31:0] req_wdata = 32'b0;
    logic [3:0] req_wstrb = 4'b0;
    logic rsp_ready = 1'b0;
    logic wb_push_ready = 1'b0;
    logic wb_probe_hit = 1'b0;
    logic wb_probe_busy = 1'b0;
    logic l2_ready = 1'b0;
    logic [1:0] l2_accept_id = '0;
    logic fill_valid = 1'b0;
    logic [31:0] fill_base = 32'b0;
    logic [255:0] fill_data = 256'b0;
    logic fill_dirty = 1'b0;
    logic fill_error = 1'b0;
    pkg_memory::fill_source_t fill_source = pkg_memory::FILL_WB;
    logic [1:0] fill_id = 2'b0;

    always #5 clk = ~clk;

    cache_l1 dut (
        .clk_i(clk), .rst_ni(rst_n),
        .dmem_req_valid_i(req_valid), .dmem_req_addr_i(req_addr),
        .dmem_req_write_i(req_write), .dmem_req_wdata_i(req_wdata),
        .dmem_req_wstrb_i(req_wstrb), .dmem_rsp_ready_i(rsp_ready),
        .wb_push_ready_i(wb_push_ready), .wb_probe_hit_i(wb_probe_hit),
        .wb_probe_busy_i(wb_probe_busy), .l2_get_ready_i(l2_ready),
        .l2_get_accept_id_i(l2_accept_id), .fill_valid_i(fill_valid),
        .fill_base_i(fill_base), .fill_data_i(fill_data),
        .fill_dirty_i(fill_dirty), .fill_error_i(fill_error),
        .fill_source_i(fill_source), .fill_id_i(fill_id)
    );

    /** Revisa todas las vias; !== tambien detecta valores desconocidos. */
    task automatic check_empty;
        if (dut.state_q !== dut.L1_IDLE)
            $fatal(1, "El control no comienza libre tras reset");
        if (!rst_n && {dut.dmem_req_ready_o, dut.dmem_rsp_valid_o,
                       dut.wb_push_valid_o, dut.wb_probe_valid_o,
                       dut.l2_get_valid_o, dut.fill_ready_o} !== 6'b0)
            $fatal(1, "Reset permite oferta/aceptacion de L1");
        if ({dut.pending_valid_q, dut.l2_id_valid_q, dut.input_reserved_q,
             dut.input_valid_q, dut.response_valid_q, dut.l2_offered_q} !== 6'b0)
            $fatal(1, "Reset incompleto: seguimiento o reservas activos");
        if ({dut.pending_addr_q, dut.pending_write_q, dut.pending_wdata_q,
             dut.pending_wstrb_q, dut.destination_way_q, dut.l2_id_q,
             dut.input_data_q, dut.input_dirty_q, dut.input_source_q,
             dut.response_data_q, dut.response_error_q,
             dut.response_origin_q} !== '0)
            $fatal(1, "Reset incompleto: campos de seguimiento no reiniciados");
        for (integer s = 0; s < SET_COUNT; s++) begin
            if (dut.lru_victim_q[s] !== 1'b0)
                $fatal(1, "LRU no reiniciado: conjunto %0d", s);
            for (integer w = 0; w < pkg_memory::L1_WAYS; w++) begin
                if (dut.block_valid_q[s][w] !== 1'b0 ||
                    dut.block_dirty_q[s][w] !== 1'b0)
                    $fatal(1, "Reset incompleto: conjunto %0d via %0d", s, w);
            end
        end
    endtask

    initial begin
        /** 1. Reset inicial y repetido */
        #1 rst_n = 1'b0;
        #1 check_empty();
        #1 rst_n = 1'b1;
        @(negedge clk);
        for (integer s = 0; s < SET_COUNT; s++) begin
            dut.lru_victim_q[s] = 1'b1;
            for (integer w = 0; w < pkg_memory::L1_WAYS; w++) begin
                dut.block_valid_q[s][w] = 1'b1;
                dut.block_dirty_q[s][w] = 1'b1;
            end
        end
        dut.pending_valid_q = 1'b1;
        dut.input_reserved_q = 1'b1;
        dut.input_valid_q = 1'b1;
        dut.response_valid_q = 1'b1;
        dut.pending_addr_q = 32'h00010020;
        dut.input_data_q = '1;
        dut.response_error_q = 1'b1;
        dut.state_q = dut.L1_WAIT_BLOCK;

        force dut.req_ready_internal = 1'b1;
        force dut.rsp_valid_internal = 1'b1;
        force dut.wb_push_valid_internal = 1'b1;
        force dut.wb_probe_valid_internal = 1'b1;
        force dut.l2_get_valid_internal = 1'b1;
        force dut.fill_ready_internal = 1'b1;
        req_valid = 1'b1;
        rsp_ready = 1'b1;
        wb_push_ready = 1'b1;
        fill_valid = 1'b1;
        l2_ready = 1'b1;

        #1 rst_n = 1'b0;
        #1 check_empty();
        @(posedge clk); #1 check_empty();

        release dut.req_ready_internal;
        release dut.rsp_valid_internal;
        release dut.wb_push_valid_internal;
        release dut.wb_probe_valid_internal;
        release dut.l2_get_valid_internal;
        release dut.fill_ready_internal;
        req_valid = 1'b0;
        rsp_ready = 1'b0;
        wb_push_ready = 1'b0;
        fill_valid = 1'b0;
        l2_ready = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        /** 2. Captura aislada de id L2 */
        force dut.l2_get_valid_internal = 1'b0;
        l2_ready = 1'b1;
        l2_accept_id = 2'd2;
        @(posedge clk); #1;
        if (dut.l2_id_valid_q !== 1'b0)
            $fatal(1, "Ready sin valid asigno un id");
        @(negedge clk);
        force dut.l2_get_valid_internal = 1'b1;
        l2_ready = 1'b0;
        @(posedge clk); #1;
        if (dut.l2_id_valid_q !== 1'b0)
            $fatal(1, "Oferta no aceptada asigno un id");
        @(negedge clk);
        l2_ready = 1'b1;
        @(posedge clk); #1;
        if (dut.l2_id_valid_q !== 1'b1 || dut.l2_id_q !== 2'd2)
            $fatal(1, "Id no capturado en aceptacion L2");
        @(negedge clk);
        force dut.l2_get_valid_internal = 1'b0;
        l2_accept_id = 2'd3;
        @(posedge clk); #1;
        if (dut.l2_id_q !== 2'd2 || dut.l2_id_valid_q !== 1'b1)
            $fatal(1, "El id cambio sin nueva aceptacion");
        #1 rst_n = 1'b0;
        #1 check_empty();
        release dut.l2_get_valid_internal;

        /** 3. L1-3 (Caso L1-T2): Load hit en las 8 palabras y actualizacion LRU */
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        dut.block_valid_q[1][0] = 1'b1;
        dut.block_tag_q[1][0] = 21'h20;
        for (integer w_idx = 0; w_idx < 8; w_idx++) begin
            dut.block_data_q[1][0][32 * w_idx +: 32] = 32'hA000_0000 + w_idx;
        end

        dut.block_valid_q[1][1] = 1'b1;
        dut.block_tag_q[1][1] = 21'h21;
        for (integer w_idx = 0; w_idx < 8; w_idx++) begin
            dut.block_data_q[1][1][32 * w_idx +: 32] = 32'hB000_0000 + w_idx;
        end

        for (integer w_idx = 0; w_idx < 8; w_idx++) begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b0;
            req_addr = 32'h00010020 + (w_idx * 4);
            rsp_ready = 1'b1;
            #1;
            if (dut.dmem_req_ready_o !== 1'b1 || dut.dmem_rsp_valid_o !== 1'b1)
                $fatal(1, "Load hit palabra %0d no responde en E1", w_idx);
            if (dut.dmem_rsp_rdata_o !== (32'hA000_0000 + w_idx))
                $fatal(1, "Dato incorrecto en palabra %0d: %h", w_idx, dut.dmem_rsp_rdata_o);
            if (dut.dmem_rsp_error_o !== 1'b0 || dut.dmem_rsp_origin_o !== pkg_metrics::ORIGIN_L1)
                $fatal(1, "Error u origen incorrecto en load hit");
            if (dut.perf_events_o.access_valid !== 1'b1 ||
                dut.perf_events_o.access_write !== 1'b0 ||
                dut.perf_events_o.access_result !== pkg_metrics::ACCESS_HIT)
                $fatal(1, "Metrica incorrecta en load hit palabra %0d", w_idx);
            @(posedge clk); #1;
            if (dut.lru_victim_q[1] !== 1'b1)
                $fatal(1, "LRU no apunto a via 1 tras acceder a via 0");
        end

        @(negedge clk);
        req_addr = 32'h00010828;
        #1;
        if (dut.dmem_rsp_rdata_o !== 32'hB000_0002)
            $fatal(1, "Dato incorrecto en via 1: %h", dut.dmem_rsp_rdata_o);
        @(posedge clk); #1;
        if (dut.lru_victim_q[1] !== 1'b0)
            $fatal(1, "LRU no apunto a via 0 tras acceder a via 1");

        req_valid = 1'b0;
        rsp_ready = 1'b0;

        /** 4. L1-4 (Caso L1-T3): Store hit de palabra, byte y media palabra + dirty */
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr = 32'h00010020;
        req_wdata = 32'h0000_CC00;
        req_wstrb = 4'b0010;
        rsp_ready = 1'b1;
        #1;
        if (dut.dmem_req_ready_o !== 1'b1 || dut.dmem_rsp_valid_o !== 1'b1 ||
            dut.dmem_rsp_rdata_o !== 32'b0)
            $fatal(1, "Store hit byte no responde cero en E1");
        if (dut.perf_events_o.access_valid !== 1'b1 ||
            dut.perf_events_o.access_write !== 1'b1 ||
            dut.perf_events_o.access_result !== pkg_metrics::ACCESS_HIT)
            $fatal(1, "Metrica incorrecta en store hit");
        @(posedge clk); #1;
        if (dut.block_dirty_q[1][0] !== 1'b1 || dut.lru_victim_q[1] !== 1'b1)
            $fatal(1, "Store hit no marco dirty o no actualizo LRU");

        @(negedge clk);
        req_wdata = 32'hDEAD_0000;
        req_wstrb = 4'b1100;
        @(posedge clk); #1;

        @(negedge clk);
        req_write = 1'b0;
        req_wstrb = 4'b0000;
        #1;
        if (dut.dmem_rsp_rdata_o !== 32'hDEAD_CC00)
            $fatal(1, "Mezcla de bytes incorrecta en store hit: esperado DEADCC00, obtenido %h",
                   dut.dmem_rsp_rdata_o);
        if (dut.block_data_q[1][0][63:32] !== 32'hA000_0001)
            $fatal(1, "Store hit altero palabras vecinas del bloque");

        @(posedge clk); #1;
        req_valid = 1'b0;
        rsp_ready = 1'b0;

        /** 5. L1-5/L1-6 (L1-T4, L1-T7, L1-T8, L1-T9): Load miss con WB lleno y desalojo */
        // Conjunto 1 tiene ambas vias validas y lru_victim_q[1] == 1'b1 -> victima es via 1 (0x00010820)
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr = 32'h00011024; // Conjunto 1, tag 21'h22 (miss), base 0x00011020, palabra 1
        wb_probe_hit = 1'b0;
        wb_push_ready = 1'b0; // WB lleno al inicio
        l2_ready = 1'b0;
        #1;
        if (dut.dmem_req_ready_o !== 1'b1 || dut.wb_probe_valid_o !== 1'b1 ||
            dut.wb_probe_base_o !== 32'h00011020 || dut.l2_get_valid_o !== 1'b1)
            $fatal(1, "Miss en C0 no consulta WB ni ofrece l2_get correctamente");

        @(posedge clk); #1;
        // Ahora oferta victima 0x00010820 a WB mientras espera aceptacion L2
        if (dut.wb_push_valid_o !== 1'b1 || dut.wb_push_base_o !== 32'h00010820 ||
            dut.wb_push_dirty_o !== 1'b0)
            $fatal(1, "L1 no ofrece victima de via 1 a WB correctamente");

        // L2 acepta con id = 3
        @(negedge clk);
        l2_ready = 1'b1;
        l2_accept_id = 2'd3;
        @(posedge clk); #1;
        l2_ready = 1'b0;

        // Llega retorno desde L2 mientras WB sigue lleno (wb_push_ready = 0)
        @(negedge clk);
        fill_valid = 1'b1;
        fill_base = 32'h00011020;
        fill_source = pkg_memory::FILL_L2;
        fill_id = 2'd3;
        fill_dirty = 1'b0;
        fill_error = 1'b0;
        for (integer w_idx = 0; w_idx < 8; w_idx++) begin
            fill_data[32 * w_idx +: 32] = 32'hC000_0000 + w_idx;
        end
        #1;
        if (dut.fill_ready_o !== 1'b1)
            $fatal(1, "Entrada reservada no acepta fill con WB lleno");
        @(posedge clk); #1;
        fill_valid = 1'b0;
        if (dut.input_valid_q !== 1'b1 || dut.l2_id_valid_q !== 1'b0 ||
            dut.block_tag_q[1][1] !== 21'h21)
            $fatal(1, "Fill no guardado en entrada o sobrescribio victima antes de wb_push");

        // WB se libera y acepta la victima -> instala bloque nuevo y responde a CPU
        @(negedge clk);
        wb_push_ready = 1'b1;
        rsp_ready = 1'b1;
        #1;
        if (dut.perf_events_o.eviction.valid !== 1'b1 ||
            dut.perf_events_o.eviction.base !== 32'h00010820 ||
            dut.dmem_rsp_valid_o !== 1'b1 ||
            dut.dmem_rsp_rdata_o !== 32'hC000_0001 ||
            dut.dmem_rsp_origin_o !== pkg_metrics::ORIGIN_L2)
            $fatal(1, "Instalacion o respuesta CPU incorrecta al liberar WB");

        @(posedge clk); #1;
        wb_push_ready = 1'b0;
        req_valid = 1'b0;
        rsp_ready = 1'b0;
        if (dut.state_q !== dut.L1_IDLE || dut.block_tag_q[1][1] !== 21'h22 ||
            dut.lru_victim_q[1] !== 1'b0)
            $fatal(1, "L1 no volvio a IDLE o no instalo tag/LRU tras load miss");

        /** 6. L1-6 (Casos L1-T5 y L1-T6): Store miss (write-allocate) con forwarding WB */
        // Conjunto 1 tiene lru_victim_q[1] == 1'b0 -> victima es via 0 (sucia: 0x00010020)
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr = 32'h0001182C; // Conjunto 1, tag 21'h23, palabra 3
        req_wdata = 32'h5566_7788;
        req_wstrb = 4'b1111;
        wb_probe_hit = 1'b1; // Bloque esta en WB
        wb_probe_busy = 1'b0;
        #1;
        if (dut.l2_get_valid_o !== 1'b0)
            $fatal(1, "L1 pidio a L2 pese a forwarding disponible en WB");
        @(posedge clk); #1;

        // WB libera victima sucia de via 0 y entrega forwarding simultaneamente
        @(negedge clk);
        wb_push_ready = 1'b1;
        fill_valid = 1'b1;
        fill_base = 32'h00011820;
        fill_source = pkg_memory::FILL_WB;
        fill_dirty = 1'b0;
        for (integer w_idx = 0; w_idx < 8; w_idx++) begin
            fill_data[32 * w_idx +: 32] = 32'hD000_0000 + w_idx;
        end
        rsp_ready = 1'b1;
        #1;
        if (dut.perf_events_o.eviction.dirty !== 1'b1 ||
            dut.dmem_rsp_valid_o !== 1'b1 ||
            dut.dmem_rsp_rdata_o !== 32'b0 ||
            dut.dmem_rsp_origin_o !== pkg_metrics::ORIGIN_WB)
            $fatal(1, "Store miss con forwarding WB fallo en respuesta o desalojo sucio");

        @(posedge clk); #1;
        fill_valid = 1'b0;
        wb_push_ready = 1'b0;
        req_valid = 1'b0;
        rsp_ready = 1'b0;
        wb_probe_hit = 1'b0;
        if (dut.state_q !== dut.L1_IDLE || dut.block_dirty_q[1][0] !== 1'b1 ||
            dut.block_data_q[1][0][127:96] !== 32'h5566_7788)
            $fatal(1, "Write-allocate no instalo bloque sucio con dato escrito");

        $display("PASS L1: reset inicial, repetido y conservacion de invalidez");
        $display("PASS L1: id valido solo tras aceptacion L2 y cancelado por reset");
        $display("PASS L1: reset bloquea canales con vecinos e intenciones activos");
        $display("PASS L1: control vuelve a LIBRE tras reset inicial y repetido");
        $display("PASS L1: load hit en las 8 palabras (E1), origen L1, metricas y LRU (L1-3)");
        $display("PASS L1: store hit en palabra, byte y media palabra (L1-4)");
        $display("PASS L1: miss, seleccion victima, consulta WB y solicitud L2 (L1-5)");
        $display("PASS L1: fill, desalojo WB limpio/sucio, write-allocate y forwarding (L1-6)");
        $finish;
    end
endmodule