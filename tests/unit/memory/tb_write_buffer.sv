`timescale 1ns/1ps

/**
 * @brief Prueba aislada completa del Write Buffer: WB-1..WB-5 + protocolo y simultaneidad.
 */
module tb_write_buffer;
    localparam integer DEPTH = pkg_memory::WRITE_BUFFER_DEPTH_DEFAULT;

    logic clk = 1'b0;
    logic rst_n = 1'b1;

    logic push_valid = 1'b0;
    logic [31:0] push_base = 32'b0;
    logic [255:0] push_data = 256'b0;
    logic push_dirty = 1'b0;

    logic probe_valid = 1'b0;
    logic [31:0] probe_base = 32'b0;

    logic fwd_ready = 1'b0;
    logic install_ready = 1'b0;
    logic [1:0] install_accept_id = 2'b0;
    logic done_valid = 1'b0;
    logic [1:0] done_id = 2'b0;

    // Instancia secundaria con profundidad custom (2) para validar parametrizacion
    logic push2_valid = 1'b0;
    logic [31:0] push2_base = 32'b0;
    logic [255:0] push2_data = 256'b0;
    logic push2_dirty = 1'b0;
    wire push2_ready;

    // Contadores para validacion de metricas en prueba 7
    integer cnt_enq;
    integer cnt_fwd;
    integer cnt_acc;
    integer cnt_done;
    integer cnt_push_wait;
    integer cnt_send_wait;
    integer cnt_raw_wait;

    always #5 clk = ~clk;

    write_buffer dut (
        .clk_i(clk), .rst_ni(rst_n),
        .wb_push_valid_i(push_valid), .wb_push_base_i(push_base),
        .wb_push_data_i(push_data), .wb_push_dirty_i(push_dirty),
        .wb_probe_valid_i(probe_valid), .wb_probe_base_i(probe_base),
        .wb_fwd_ready_i(fwd_ready), .wb_install_ready_i(install_ready),
        .wb_install_accept_id_i(install_accept_id),
        .wb_done_valid_i(done_valid), .wb_done_id_i(done_id)
    );

    write_buffer #(.WRITE_BUFFER_DEPTH(2)) dut_depth2 (
        .clk_i(clk), .rst_ni(rst_n),
        .wb_push_valid_i(push2_valid), .wb_push_ready_o(push2_ready),
        .wb_push_base_i(push2_base), .wb_push_data_i(push2_data),
        .wb_push_dirty_i(push2_dirty), .wb_probe_valid_i(1'b0),
        .wb_probe_base_i(32'b0), .wb_fwd_ready_i(1'b0),
        .wb_install_ready_i(1'b0), .wb_install_accept_id_i(2'b0),
        .wb_done_valid_i(1'b0), .wb_done_id_i(2'b0)
    );

    /** Genera una linea de 32 bytes con sus 8 palabras distintas por patron. */
    function automatic logic [255:0] make_line(input logic [31:0] seed);
        logic [255:0] line;
        for (integer w = 0; w < 8; w++) begin
            line[32 * w +: 32] = seed + (w * 32'h0101_0001);
        end
        return line;
    endfunction

    task automatic check_empty;
        if (dut.count_q !== '0 || dut.fwd_active_q !== 1'b0 || dut.install_active_q !== 1'b0 ||
            dut.done_err_reported_q !== 1'b0)
            $fatal(1, "Reset incompleto: count_q, retenciones o diagnostico activos");
        if (!rst_n && {dut.wb_push_ready_o, dut.wb_fwd_valid_o,
                       dut.wb_install_valid_o, dut.wb_done_ready_o} !== 4'b0)
            $fatal(1, "Reset permite handshake en canales WB");
        if ({dut.wb_probe_hit_o, dut.wb_probe_busy_o} !== 2'b0)
            $fatal(1, "Reset deja hit o busy activos");
        for (integer i = 0; i < DEPTH; i++) begin
            if ({dut.entry_valid_q[i], dut.entry_dirty_q[i],
                 dut.entry_inflight_q[i], dut.entry_id_valid_q[i]} !== 4'b0)
                $fatal(1, "Reset incompleto en flags de entrada %0d", i);
            if ({dut.entry_base_q[i], dut.entry_data_q[i], dut.entry_l2_id_q[i]} !== '0)
                $fatal(1, "Reset incompleto en campos de entrada %0d", i);
        end
    endtask

    initial begin
        /** 1. Reset inicial y repetido con vecinos e intenciones activos */
        #1 rst_n = 1'b0;
        #1 check_empty();
        #1 rst_n = 1'b1;
        @(negedge clk);

        dut.count_q = 3'd4;
        dut.fwd_active_q = 1'b1;
        dut.install_active_q = 1'b1;
        dut.done_err_reported_q = 1'b1;
        for (integer i = 0; i < DEPTH; i++) begin
            dut.entry_valid_q[i] = 1'b1;
            dut.entry_base_q[i] = 32'h0001_0000 + (i * 32);
            dut.entry_data_q[i] = '1;
            dut.entry_dirty_q[i] = 1'b1;
            dut.entry_inflight_q[i] = 1'b1;
            dut.entry_id_valid_q[i] = 1'b1;
            dut.entry_l2_id_q[i] = 2'd3;
        end

        force dut.push_ready_internal = 1'b1;
        force dut.fwd_valid_internal = 1'b1;
        force dut.install_valid_internal = 1'b1;
        force dut.done_ready_internal = 1'b1;
        push_valid = 1'b1;
        fwd_ready = 1'b1;
        install_ready = 1'b1;
        done_valid = 1'b1;

        #1 rst_n = 1'b0;
        #1 check_empty();
        @(posedge clk); #1 check_empty();

        release dut.push_ready_internal;
        release dut.fwd_valid_internal;
        release dut.install_valid_internal;
        release dut.done_ready_internal;
        push_valid = 1'b0;
        fwd_ready = 1'b0;
        install_ready = 1'b0;
        done_valid = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        /** 2. WB-2: Insercion FIFO de 4 victimas (32B distintos) y limite de capacidad */
        for (integer i = 0; i < DEPTH; i++) begin
            @(negedge clk);
            push_valid = 1'b1;
            push_base = 32'h0001_1000 + (i * 32);
            push_data = make_line(32'h1111_0000 + (i << 8));
            push_dirty = i[0];
            #1;
            if (dut.wb_push_ready_o !== 1'b1 || dut.perf_events_o.enqueued.valid !== 1'b1 ||
                dut.perf_events_o.enqueued.base !== push_base ||
                dut.perf_events_o.enqueued.dirty !== push_dirty)
                $fatal(1, "Fallo en aceptacion o metrica al encolar entrada %0d", i);
            @(posedge clk); #1;
        end

        @(negedge clk);
        push_valid = 1'b1;
        push_base = 32'h0001_9900;
        push_data = make_line(32'hDEAD_BEEF);
        push_dirty = 1'b1;
        #1;
        if (dut.wb_push_ready_o !== 1'b0 || dut.perf_events_o.state.push_wait !== 1'b1 ||
            dut.perf_events_o.enqueued.valid !== 1'b0)
            $fatal(1, "WB lleno no bloqueo push_ready o emitio enqueued invalido");
        @(posedge clk); #1;
        push_valid = 1'b0;

        if (dut.count_q !== 3'd4)
            $fatal(1, "count_q alterado al rechazar 5ta entrada");
        for (integer i = 0; i < DEPTH; i++) begin
            if (dut.entry_valid_q[i] !== 1'b1 ||
                dut.entry_base_q[i] !== (32'h0001_1000 + (i * 32)) ||
                dut.entry_data_q[i] !== make_line(32'h1111_0000 + (i << 8)) ||
                dut.entry_dirty_q[i] !== i[0])
                $fatal(1, "Entrada %0d alterada o fuera de orden", i);
        end

        /** 3. WB-3: Consulta probe, forwarding intermedio con retencion y compactacion */
        #1 rst_n = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        for (integer i = 0; i < 3; i++) begin
            @(negedge clk);
            push_valid = 1'b1;
            push_base = 32'h0001_1000 + (i * 32);
            push_data = make_line(32'hAAAA_0000 + (i << 8));
            push_dirty = (i == 1);
            @(posedge clk); #1;
        end
        push_valid = 1'b0;

        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_1080;
        #1;
        if (dut.wb_probe_hit_o !== 1'b0 || dut.wb_probe_busy_o !== 1'b0 ||
            dut.wb_fwd_valid_o !== 1'b0)
            $fatal(1, "Consulta miss reporto hit o forwarding indebido");

        probe_base = 32'h0001_1020;
        fwd_ready = 1'b0;
        #1;
        if (dut.wb_probe_hit_o !== 1'b1 || dut.wb_probe_busy_o !== 1'b0 ||
            dut.wb_fwd_valid_o !== 1'b1 || dut.wb_fwd_base_o !== 32'h0001_1020 ||
            dut.wb_fwd_data_o !== make_line(32'hAAAA_0100) || dut.wb_fwd_dirty_o !== 1'b1)
            $fatal(1, "Forwarding de entrada intermedia B fallo en datos o dirty");
        if (dut.perf_events_o.forwarded.valid !== 1'b0)
            $fatal(1, "Evento forwarded emitido prematuramente sin handshake");

        @(posedge clk); #1;
        probe_valid = 1'b0;
        probe_base = 32'b0;
        #1;
        if (dut.wb_fwd_valid_o !== 1'b1 || dut.wb_fwd_base_o !== 32'h0001_1020 ||
            dut.wb_fwd_data_o !== make_line(32'hAAAA_0100) || dut.wb_fwd_dirty_o !== 1'b1)
            $fatal(1, "Oferta wb_fwd no mantuvo campos estables mientras fwd_ready=0");

        @(negedge clk);
        fwd_ready = 1'b1;
        #1;
        if (dut.perf_events_o.forwarded.valid !== 1'b1 ||
            dut.perf_events_o.forwarded.base !== 32'h0001_1020 ||
            dut.perf_events_o.forwarded.dirty !== 1'b1)
            $fatal(1, "Evento forwarded no emitido en el flanco de entrega");
        @(posedge clk); #1;
        fwd_ready = 1'b0;
        if (dut.count_q !== 3'd2 || dut.wb_fwd_valid_o !== 1'b0 ||
            dut.entry_base_q[0] !== 32'h0001_1000 || dut.entry_dirty_q[0] !== 1'b0 ||
            dut.entry_data_q[0] !== make_line(32'hAAAA_0000) ||
            dut.entry_base_q[1] !== 32'h0001_1040 || dut.entry_dirty_q[1] !== 1'b0 ||
            dut.entry_data_q[1] !== make_line(32'hAAAA_0200))
            $fatal(1, "Compactacion FIFO tras forwarding intermedio fallo: no quedaron [A, C]");

        /** 4. WB-4: Prioridad fwd vs drenado, servicio sin ready, orden FIFO y done fuera de orden */
        #1 rst_n = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        @(negedge clk);
        push_valid = 1'b1;
        push_base = 32'h0001_2000;
        push_data = make_line(32'hBBBB_0000);
        push_dirty = 1'b1;
        @(posedge clk); #1;
        push_valid = 1'b0;

        probe_valid = 1'b1;
        probe_base = 32'h0001_2000;
        fwd_ready = 1'b1;
        #1;
        if (dut.wb_fwd_valid_o !== 1'b1 || dut.wb_fwd_base_o !== 32'h0001_2000 ||
            dut.wb_install_valid_o !== 1'b0)
            $fatal(1, "Prioridad fallo: drenado presento A pese a forwarding activo");
        @(posedge clk); #1;
        probe_valid = 1'b0;
        fwd_ready = 1'b0;

        // Encolar [A, B, C] completos en orden
        for (integer i = 0; i < 3; i++) begin
            @(negedge clk);
            push_valid = 1'b1;
            push_base = 32'h0001_3000 + (i * 32);
            push_data = make_line(32'hCCCC_0000 + (i << 8));
            push_dirty = i[0];
            install_ready = 1'b0;
            @(posedge clk); #1;
        end
        push_valid = 1'b0;

        // Retencion de oferta wb_install con ready=0 durante multiples ciclos
        for (integer cyc = 0; cyc < 3; cyc++) begin
            @(posedge clk); #1;
            if (dut.wb_install_valid_o !== 1'b1 || dut.wb_install_base_o !== 32'h0001_3000 ||
                dut.wb_install_data_o !== make_line(32'hCCCC_0000) ||
                dut.wb_install_dirty_o !== 1'b0 ||
                dut.perf_events_o.state.send_wait !== 1'b1)
                $fatal(1, "Oferta wb_install no mantuvo campos estables en ciclo %0d", cyc);
        end

        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_3000;
        #1;
        if (dut.wb_probe_hit_o !== 1'b1 || dut.wb_probe_busy_o !== 1'b1 ||
            dut.wb_fwd_valid_o !== 1'b0 || dut.perf_events_o.state.raw_wait !== 1'b1)
            $fatal(1, "Entrada A en servicio (con ready=0) permitio forwarding o no reporto busy");
        probe_valid = 1'b0;

        @(negedge clk);
        install_ready = 1'b1;
        install_accept_id = 2'd1;
        #1;
        if (dut.perf_events_o.install_accept.valid !== 1'b1 ||
            dut.perf_events_o.install_accept.id !== 32'd1)
            $fatal(1, "Evento install_accept incorrecto para A");
        @(posedge clk); #1;
        if (dut.count_q !== 3'd3 || dut.entry_base_q[0] !== 32'h0001_3000 ||
            dut.entry_id_valid_q[0] !== 1'b1 || dut.entry_l2_id_q[0] !== 2'd1 ||
            dut.wb_install_valid_o !== 1'b1 || dut.wb_install_base_o !== 32'h0001_3020)
            $fatal(1, "Tras aceptar A, no retuvo entrada ni presento B en orden");

        @(negedge clk);
        install_accept_id = 2'd2;
        @(posedge clk); #1;
        if (dut.wb_install_valid_o !== 1'b1 || dut.wb_install_base_o !== 32'h0001_3040)
            $fatal(1, "Tras aceptar B, no presento C en orden");
        install_ready = 1'b0;

        // Confirmacion wb_done con ID no asociado (id=3) sostenida durante varios flancos reales
        @(negedge clk);
        done_valid = 1'b1;
        done_id = 2'd3;
        #1;
        if (dut.wb_done_ready_o !== 1'b0 ||
            dut.perf_events_o.install_done.valid !== 1'b0 ||
            dut.perf_events_o.error.valid !== 1'b1 ||
            dut.perf_events_o.error.kind !== pkg_metrics::ERROR_PROTOCOL)
            $fatal(1, "wb_done con ID invalido no emitio ERROR_PROTOCOL inicial o acepto");

        for (integer wait_c = 0; wait_c < 3; wait_c++) begin
            @(posedge clk); #1;
            if (dut.wb_done_ready_o !== 1'b0 ||
                dut.perf_events_o.install_done.valid !== 1'b0 ||
                dut.perf_events_o.error.valid !== 1'b0 ||
                dut.count_q !== 3'd3 ||
                dut.entry_base_q[0] !== 32'h0001_3000 || dut.entry_l2_id_q[0] !== 2'd1 ||
                dut.entry_base_q[1] !== 32'h0001_3020 || dut.entry_l2_id_q[1] !== 2'd2)
                $fatal(1, "wb_done invalido repitio diagnostico o altero entradas en ciclo %0d", wait_c);
        end

        // Confirmacion wb_done fuera de orden para B (id=2) antes que A (id=1)
        @(negedge clk);
        done_id = 2'd2;
        #1;
        if (dut.wb_done_ready_o !== 1'b1 || dut.perf_events_o.install_done.valid !== 1'b1 ||
            dut.perf_events_o.install_done.id !== 32'd2 || dut.perf_events_o.error.valid !== 1'b0)
            $fatal(1, "wb_done fuera de orden para B no fue aceptado correctamente");
        @(posedge clk); #1;
        done_valid = 1'b0;

        if (dut.count_q !== 3'd2 ||
            dut.entry_base_q[0] !== 32'h0001_3000 || dut.entry_l2_id_q[0] !== 2'd1 ||
            dut.entry_id_valid_q[0] !== 1'b1 || dut.entry_inflight_q[0] !== 1'b1 ||
            dut.entry_base_q[1] !== 32'h0001_3040 || dut.entry_inflight_q[1] !== 1'b1)
            $fatal(1, "Retiro fuera de orden de B altero [A, C] o sus asociaciones");

        /** 5. WB-5: Simultaneidad done + push, reset en servicio y profundidad custom */
        @(negedge clk);
        install_ready = 1'b1;
        install_accept_id = 2'd3;
        done_valid = 1'b1;
        done_id = 2'd1;
        push_valid = 1'b1;
        push_base = 32'h0001_3060;
        push_data = make_line(32'hDDDD_0300);
        push_dirty = 1'b1;
        @(posedge clk); #1;
        install_ready = 1'b0;
        done_valid = 1'b0;
        push_valid = 1'b0;

        if (dut.count_q !== 3'd2 ||
            dut.entry_base_q[0] !== 32'h0001_3040 || dut.entry_l2_id_q[0] !== 2'd3 ||
            dut.entry_base_q[1] !== 32'h0001_3060 || dut.entry_inflight_q[1] !== 1'b0)
            $fatal(1, "Simultaneidad install+done+push corrompio cola o identificadores");

        if (dut.wb_install_valid_o !== 1'b1 || dut.wb_install_base_o !== 32'h0001_3060)
            $fatal(1, "D no se presento tras liberar A");
        #1 rst_n = 1'b0;
        #1 check_empty();
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();
        if (dut.wb_install_valid_o !== 1'b0 || dut.wb_fwd_valid_o !== 1'b0)
            $fatal(1, "Oferta previa reaparecio tras liberar reset");

        // Validar instancia parametrizada con WRITE_BUFFER_DEPTH = 2
        for (integer i = 0; i < 2; i++) begin
            @(negedge clk);
            push2_valid = 1'b1;
            push2_base = 32'h0001_4000 + (i * 32);
            push2_data = make_line(32'hEEEE_0000 + (i << 8));
            push2_dirty = 1'b1;
            #1;
            if (push2_ready !== 1'b1)
                $fatal(1, "Instancia depth=2 rechazo entrada %0d antes de llenarse", i);
            @(posedge clk); #1;
        end
        push2_valid = 1'b0;
        #1;
        if (push2_ready !== 1'b0 || dut_depth2.perf_events_o.state.capacity !== 32'd2)
            $fatal(1, "Instancia depth=2 no respeto su limite de capacidad");

        /**
         * 6. Cobertura de ofertas retenidas (wb_install y wb_fwd con ready=0)
         * durante compactacion por retiro anterior (wb_done).
         */
        #1 rst_n = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        // Encolar A (0x5000, clean), B (0x5020, dirty), C (0x5040, dirty)
        for (integer i = 0; i < 3; i++) begin
            @(negedge clk);
            push_valid = 1'b1;
            push_base = 32'h0001_5000 + (i * 32);
            push_data = make_line(32'h5500_0000 + (i << 12));
            push_dirty = (i > 0);
            @(posedge clk); #1;
        end
        push_valid = 1'b0;

        // Aceptar A con id=1 -> B se ofrece combinacionalmente con install_ready=0
        @(negedge clk);
        install_ready = 1'b1;
        install_accept_id = 2'd1;
        @(posedge clk); #1;
        install_ready = 1'b0;

        // En el ciclo siguiente con install_ready=0 y probe sobre C con fwd_ready=0:
        // ambos B (en wb_install) y C (en wb_fwd) quedan retenidos en el siguiente flanco
        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_5040;
        fwd_ready = 1'b0;
        @(posedge clk); #1;
        probe_valid = 1'b0;

        if (dut.wb_install_valid_o !== 1'b1 || dut.wb_install_base_o !== 32'h0001_5020 ||
            dut.install_active_q !== 1'b1 || dut.install_held_idx_q !== 2'd1 ||
            dut.wb_fwd_valid_o !== 1'b1 || dut.wb_fwd_base_o !== 32'h0001_5040 ||
            dut.fwd_active_q !== 1'b1 || dut.fwd_held_idx_q !== 2'd2)
            $fatal(1, "B o C no quedaron retenidas antes de compactar");

        // Retiramos A mediante wb_done(id=1): B debe desplazarse de idx 1->0 y C de idx 2->1
        // conservando ambas ofertas activas y todos sus campos intactos
        @(negedge clk);
        done_valid = 1'b1;
        done_id = 2'd1;
        @(posedge clk); #1;
        done_valid = 1'b0;

        if (dut.count_q !== 3'd2 ||
            dut.install_active_q !== 1'b1 || dut.install_held_idx_q !== 2'd0 ||
            dut.wb_install_valid_o !== 1'b1 || dut.wb_install_base_o !== 32'h0001_5020 ||
            dut.wb_install_data_o !== make_line(32'h5500_1000) ||
            dut.wb_install_dirty_o !== 1'b1 ||
            dut.fwd_active_q !== 1'b1 || dut.fwd_held_idx_q !== 2'd1 ||
            dut.wb_fwd_valid_o !== 1'b1 || dut.wb_fwd_base_o !== 32'h0001_5040 ||
            dut.wb_fwd_data_o !== make_line(32'h5500_2000) ||
            dut.wb_fwd_dirty_o !== 1'b1)
            $fatal(1, "Desplazamiento por compactacion altero ofertas retenidas de B o C");

        // Aceptar ambas ofertas retenidas una sola vez
        @(negedge clk);
        install_ready = 1'b1;
        install_accept_id = 2'd2;
        fwd_ready = 1'b1;
        #1;
        if (dut.perf_events_o.install_accept.valid !== 1'b1 ||
            dut.perf_events_o.forwarded.valid !== 1'b1)
            $fatal(1, "Eventos de entrega no emitidos al consumir ofertas retenidas");
        @(posedge clk); #1;
        install_ready = 1'b0;
        fwd_ready = 1'b0;
        if (dut.count_q !== 3'd1 || dut.wb_install_valid_o !== 1'b0 ||
            dut.wb_fwd_valid_o !== 1'b0 || dut.entry_base_q[0] !== 32'h0001_5020)
            $fatal(1, "Consumo de ofertas retenidas tras compactacion dejo estado inconsistente");

        /**
         * 7. Retiros simultaneos (done + fwd + push -> [B(id=2), D]) y acumulacion exacta
         * de eventos y ciclos de espera (push_wait, send_wait, raw_wait).
         */
        cnt_enq = 0;
        cnt_fwd = 0;
        cnt_acc = 0;
        cnt_done = 0;
        cnt_push_wait = 0;
        cnt_send_wait = 0;
        cnt_raw_wait = 0;

        #1 rst_n = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        // Encolar A (0x6000), B (0x6020), C (0x6040), D0 (0x6060) -> llenar las 4 entradas
        for (integer i = 0; i < 4; i++) begin
            @(negedge clk);
            push_valid = 1'b1;
            push_base = 32'h0001_6000 + (i * 32);
            push_data = make_line(32'h6600_0000 + (i << 12));
            push_dirty = i[0];
            install_ready = 1'b0;
            #1;
            cnt_enq += dut.perf_events_o.enqueued.valid;
            cnt_send_wait += dut.perf_events_o.state.send_wait;
            @(posedge clk); #1;
        end

        // Intentar 5to push con buffer lleno -> 1 ciclo de push_wait, sin enqueued
        @(negedge clk);
        push_valid = 1'b1;
        push_base = 32'h0001_6080;
        #1;
        if (dut.perf_events_o.state.occupancy !== 32'd4)
            $fatal(1, "Ocupacion reportada distinta de 4 con buffer lleno");
        cnt_enq += dut.perf_events_o.enqueued.valid;
        cnt_push_wait += dut.perf_events_o.state.push_wait;
        cnt_send_wait += dut.perf_events_o.state.send_wait;
        @(posedge clk); #1;
        push_valid = 1'b0;

        // Consultar A (en servicio con ready=0) -> 1 ciclo de raw_wait
        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_6000;
        #1;
        cnt_raw_wait += dut.perf_events_o.state.raw_wait;
        cnt_send_wait += dut.perf_events_o.state.send_wait;
        @(posedge clk); #1;
        probe_valid = 1'b0;

        // Aceptar A con id=1 (queda A en servicio, se ofrece B)
        @(negedge clk);
        install_ready = 1'b1;
        install_accept_id = 2'd1;
        #1;
        cnt_acc += dut.perf_events_o.install_accept.valid;
        @(posedge clk); #1;
        install_ready = 1'b0;

        // Retirar D0 por forwarding para dejar [A(id=1), B, C] (ocupacion = 3)
        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_6060;
        fwd_ready = 1'b1;
        #1;
        cnt_fwd += dut.perf_events_o.forwarded.valid;
        cnt_send_wait += dut.perf_events_o.state.send_wait;
        @(posedge clk); #1;
        probe_valid = 1'b0;
        fwd_ready = 1'b0;

        if (dut.count_q !== 3'd3 || dut.perf_events_o.state.occupancy !== 32'd3)
            $fatal(1, "Ocupacion antes de simultaneidad esperada=3, obtenida=%0d", dut.count_q);

        // Aceptar B con id=2 para dejar C libre para forwarding
        @(negedge clk);
        install_ready = 1'b1;
        install_accept_id = 2'd2;
        #1;
        cnt_acc += dut.perf_events_o.install_accept.valid;
        @(posedge clk); #1;
        install_ready = 1'b0;

        // Retener fwd de C y luego consumir simultaneamente done(A, id=1) + fwd(C) + push(D)
        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_6040;
        fwd_ready = 1'b0;
        @(posedge clk); #1;
        probe_valid = 1'b0;

        @(negedge clk);
        done_valid = 1'b1;
        done_id = 2'd1;
        fwd_ready = 1'b1;
        push_valid = 1'b1;
        push_base = 32'h0001_60A0;
        push_data = make_line(32'h6600_4000);
        push_dirty = 1'b1;
        #1;
        cnt_done += dut.perf_events_o.install_done.valid;
        cnt_fwd += dut.perf_events_o.forwarded.valid;
        cnt_enq += dut.perf_events_o.enqueued.valid;
        @(posedge clk); #1;
        done_valid = 1'b0;
        fwd_ready = 1'b0;
        push_valid = 1'b0;

        // Resultado esperado: [B(id=2), D]
        if (dut.count_q !== 3'd2 ||
            dut.entry_base_q[0] !== 32'h0001_6020 ||
            dut.entry_data_q[0] !== make_line(32'h6600_1000) ||
            dut.entry_dirty_q[0] !== 1'b1 ||
            dut.entry_inflight_q[0] !== 1'b1 ||
            dut.entry_id_valid_q[0] !== 1'b1 ||
            dut.entry_l2_id_q[0] !== 2'd2 ||
            dut.entry_base_q[1] !== 32'h0001_60A0 ||
            dut.entry_data_q[1] !== make_line(32'h6600_4000) ||
            dut.entry_dirty_q[1] !== 1'b1 ||
            dut.entry_inflight_q[1] !== 1'b0)
            $fatal(1, "Retiros simultaneos + insercion no produjeron [B(id=2), D] intactos");

        // Comprobar totales exactos de eventos y esperas
        if (cnt_enq !== 5 || cnt_fwd !== 2 || cnt_acc !== 2 || cnt_done !== 1 ||
            cnt_push_wait !== 1 || cnt_raw_wait !== 1 || cnt_send_wait !== 6)
            $fatal(1, "Conteo de eventos/esperas inexacto: enq=%0d fwd=%0d acc=%0d done=%0d pw=%0d rw=%0d sw=%0d",
                   cnt_enq, cnt_fwd, cnt_acc, cnt_done, cnt_push_wait, cnt_raw_wait, cnt_send_wait);

        $display("PASS WB: reset inicial, repetido y frontera de canales (WB-1)");
        $display("PASS WB: insercion FIFO limpia/sucia y limite de capacidad (WB-2)");
        $display("PASS WB: consulta probe, forwarding intermedio con retencion y compactacion (WB-3)");
        $display("PASS WB: prioridad fwd, servicio sin ready, orden FIFO, ERROR_PROTOCOL y done fuera de orden (WB-4)");
        $display("PASS WB: simultaneidad, reset en servicio y depth=2 (WB-5)");
        $display("PASS WB: desplazamiento de ofertas retenidas y acumulacion de eventos/esperas");
        $finish;
    end
endmodule