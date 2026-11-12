`timescale 1ns/1ps

/**
 * @brief Prueba aislada completa del Write Buffer: WB-1..WB-5.
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

    task automatic check_empty;
        if (dut.count_q !== '0 || dut.fwd_active_q !== 1'b0 || dut.install_active_q !== 1'b0)
            $fatal(1, "Reset incompleto: count_q o retenciones activas");
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

        /** 2. WB-2: Insercion FIFO de 4 victimas (limpias/sucias) y limite de capacidad */
        for (integer i = 0; i < DEPTH; i++) begin
            @(negedge clk);
            push_valid = 1'b1;
            push_base = 32'h0001_1000 + (i * 32);
            push_data = {8{32'h1111_0000 + i}};
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
        push_data = {8{32'hDEAD_BEEF}};
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
                dut.entry_data_q[i] !== {8{32'h1111_0000 + i}} ||
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
            push_data = {8{32'hAAAA_0000 + i}};
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
            dut.wb_fwd_data_o !== {8{32'hAAAA_0001}} || dut.wb_fwd_dirty_o !== 1'b1)
            $fatal(1, "Forwarding de entrada intermedia B fallo en datos o dirty");
        if (dut.perf_events_o.forwarded.valid !== 1'b0)
            $fatal(1, "Evento forwarded emitido prematuramente sin handshake");

        @(posedge clk); #1;
        probe_valid = 1'b0;
        probe_base = 32'b0;
        #1;
        if (dut.wb_fwd_valid_o !== 1'b1 || dut.wb_fwd_base_o !== 32'h0001_1020 ||
            dut.wb_fwd_data_o !== {8{32'hAAAA_0001}} || dut.wb_fwd_dirty_o !== 1'b1)
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
            dut.entry_base_q[1] !== 32'h0001_1040 || dut.entry_dirty_q[1] !== 1'b0)
            $fatal(1, "Compactacion FIFO tras forwarding intermedio fallo: no quedaron [A, C]");

        /** 4. WB-4: Prioridad fwd vs drenado, servicio sin ready, orden FIFO y done fuera de orden */
        #1 rst_n = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();

        @(negedge clk);
        push_valid = 1'b1;
        push_base = 32'h0001_2000;
        push_data = {8{32'hBBBB_0000}};
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
            push_data = {8{32'hCCCC_0000 + i}};
            push_dirty = i[0];
            install_ready = 1'b0;
            @(posedge clk); #1;
        end
        push_valid = 1'b0;

        // Retencion de oferta wb_install con ready=0 durante multiples ciclos
        for (integer cyc = 0; cyc < 3; cyc++) begin
            @(posedge clk); #1;
            if (dut.wb_install_valid_o !== 1'b1 || dut.wb_install_base_o !== 32'h0001_3000 ||
                dut.wb_install_data_o !== {8{32'hCCCC_0000}} || dut.wb_install_dirty_o !== 1'b0 ||
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

        // Confirmacion wb_done con ID no asociado (id=3) no debe aceptarse
        @(negedge clk);
        done_valid = 1'b1;
        done_id = 2'd3;
        #1;
        if (dut.wb_done_ready_o !== 1'b0)
            $fatal(1, "wb_done acepto identificador sin entrada asociada");

        // Confirmacion wb_done fuera de orden para B (id=2) antes que A (id=1)
        done_id = 2'd2;
        #1;
        if (dut.wb_done_ready_o !== 1'b1 || dut.perf_events_o.install_done.valid !== 1'b1 ||
            dut.perf_events_o.install_done.id !== 32'd2)
            $fatal(1, "wb_done fuera de orden para B no fue aceptado correctamente");
        @(posedge clk); #1;
        done_valid = 1'b0;

        if (dut.count_q !== 3'd2 ||
            dut.entry_base_q[0] !== 32'h0001_3000 || dut.entry_l2_id_q[0] !== 2'd1 ||
            dut.entry_id_valid_q[0] !== 1'b1 || dut.entry_inflight_q[0] !== 1'b1 ||
            dut.entry_base_q[1] !== 32'h0001_3040 || dut.entry_inflight_q[1] !== 1'b1)
            $fatal(1, "Retiro fuera de orden de B altero [A, C] o sus asociaciones");

        /** 5. WB-5: Simultaneidad done + push, reset en servicio y profundidad custom */
        // Aceptar C con id=3 y confirmar A (id=1) mientras entra D (0x3060)
        @(negedge clk);
        install_ready = 1'b1;
        install_accept_id = 2'd3;
        done_valid = 1'b1;
        done_id = 2'd1;
        push_valid = 1'b1;
        push_base = 32'h0001_3060;
        push_data = {8{32'hDDDD_0003}};
        push_dirty = 1'b1;
        @(posedge clk); #1;
        install_ready = 1'b0;
        done_valid = 1'b0;
        push_valid = 1'b0;

        if (dut.count_q !== 3'd2 ||
            dut.entry_base_q[0] !== 32'h0001_3040 || dut.entry_l2_id_q[0] !== 2'd3 ||
            dut.entry_base_q[1] !== 32'h0001_3060 || dut.entry_inflight_q[1] !== 1'b0)
            $fatal(1, "Simultaneidad install+done+push corrompio cola o identificadores");

        // Reset mientras D esta ofreciendose en wb_install_valid_o=1 -> al soltar no reaparece
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
            push2_data = {8{32'hEEEE_0000 + i}};
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

        $display("PASS WB: reset inicial, repetido y frontera de canales (WB-1)");
        $display("PASS WB: insercion FIFO limpia/sucia y limite de capacidad (WB-2)");
        $display("PASS WB: consulta probe, forwarding intermedio con retencion y compactacion (WB-3)");
        $display("PASS WB: prioridad fwd, servicio sin ready, orden FIFO y done fuera de orden (WB-4)");
        $display("PASS WB: retencion install, simultaneidad, reset en servicio y depth=2 (WB-5)");
        $finish;
    end
endmodule