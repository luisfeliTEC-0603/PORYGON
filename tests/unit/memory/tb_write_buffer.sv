`timescale 1ns/1ps

/**
 * @brief Prueba aislada del Write Buffer: reset (WB-1), insercion (WB-2) y forwarding (WB-3).
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

    task automatic check_empty;
        if (dut.count_q !== '0 || dut.fwd_active_q !== 1'b0)
            $fatal(1, "Reset incompleto: count_q o fwd_active_q activos");
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

        // Al llenar las 4 entradas: wb_push_ready_o debe bajar a 0 y activar push_wait
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

        // Verificar que las 4 entradas originales siguen intactas y en orden FIFO
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

        // Encolar A (0x1000, limpia), B (0x1020, sucia), C (0x1040, limpia)
        for (integer i = 0; i < 3; i++) begin
            @(negedge clk);
            push_valid = 1'b1;
            push_base = 32'h0001_1000 + (i * 32);
            push_data = {8{32'hAAAA_0000 + i}};
            push_dirty = (i == 1);
            @(posedge clk); #1;
        end
        push_valid = 1'b0;

        // Consulta miss (0x1080) -> hit=0, busy=0, fwd_valid=0
        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_1080;
        #1;
        if (dut.wb_probe_hit_o !== 1'b0 || dut.wb_probe_busy_o !== 1'b0 ||
            dut.wb_fwd_valid_o !== 1'b0)
            $fatal(1, "Consulta miss reporto hit o forwarding indebido");

        // Consulta sobre entrada intermedia B (0x1020) con fwd_ready=0 -> retiene oferta
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
        // Aunque probe_valid baje, la oferta retenida conserva base, data y dirty
        probe_valid = 1'b0;
        probe_base = 32'b0;
        #1;
        if (dut.wb_fwd_valid_o !== 1'b1 || dut.wb_fwd_base_o !== 32'h0001_1020 ||
            dut.wb_fwd_data_o !== {8{32'hAAAA_0001}} || dut.wb_fwd_dirty_o !== 1'b1)
            $fatal(1, "Oferta wb_fwd no mantuvo campos estables mientras fwd_ready=0");

        // L1 acepta forwarding -> emite pulso unico y retira B dejando [A, C]
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

        // Verificar que una entrada en servicio (inflight=1) reporta hit=1, busy=1 y sin forwarding
        dut.entry_inflight_q[0] = 1'b1;
        @(negedge clk);
        probe_valid = 1'b1;
        probe_base = 32'h0001_1000;
        #1;
        if (dut.wb_probe_hit_o !== 1'b1 || dut.wb_probe_busy_o !== 1'b1 ||
            dut.wb_fwd_valid_o !== 1'b0 || dut.perf_events_o.state.raw_wait !== 1'b1)
            $fatal(1, "Entrada en servicio no reporto hit+busy sin forwarding");
        probe_valid = 1'b0;

        $display("PASS WB: reset inicial, repetido y frontera de canales (WB-1)");
        $display("PASS WB: insercion FIFO limpia/sucia y limite de capacidad (WB-2)");
        $display("PASS WB: consulta probe, forwarding intermedio con retencion y compactacion (WB-3)");
        $finish;
    end
endmodule