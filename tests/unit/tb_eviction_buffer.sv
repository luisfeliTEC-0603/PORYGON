/**
 * @brief Verifica FIFO, RAW, respuestas, metricas y reset de P2-04.
 * @param DEPTH Numero de lineas que puede conservar el buffer.
 * @details Las respuestas simuladas permiten completar escrituras fuera de
 * orden sin depender del controlador real de P2-03.
 */
module tb_eviction_buffer;
    import pkg_memory::*;

`ifndef TB_DEPTH
`define TB_DEPTH EVICTION_BUFFER_DEPTH_DEFAULT
`endif
    parameter integer DEPTH = `TB_DEPTH;
    localparam address_t A = DATA_BASE_ADDRESS;
    localparam address_t B = DATA_BASE_ADDRESS + LINE_BYTES;
    localparam address_t C = DATA_BASE_ADDRESS + 2 * LINE_BYTES;
    localparam address_t D = DATA_BASE_ADDRESS + 3 * LINE_BYTES;
    localparam address_t F = DATA_BASE_ADDRESS + (DEPTH + 2) * LINE_BYTES;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic push_valid = 1'b0;
    logic push_ready;
    address_t push_base = DATA_BASE_ADDRESS;
    line_t push_data = '0;
    logic probe_valid = 1'b0;
    address_t probe_base = DATA_BASE_ADDRESS;
    logic probe_hit;
    localparam integer ID_W = id_width(DEPTH);
    logic wr_valid, wr_ready = 1'b0;
    logic [ID_W-1:0] wr_id;
    address_t wr_base;
    line_t wr_data;
    logic rsp_valid = 1'b0, rsp_ready;
    logic [ID_W-1:0] rsp_id = '0;
    address_t rsp_base = '0;
    logic rsp_error = 1'b0;
    pkg_metrics::eb_events_t events;
    logic track_events = 1'b0;
    integer enqueued_events = 0, sent_events = 0, written_events = 0;
    integer write_errors = 0, protocol_errors = 0;
    integer push_wait_expected = 0, push_wait_seen = 0;
    integer send_wait_expected = 0, send_wait_seen = 0;
    integer raw_wait_expected = 0, raw_wait_seen = 0;
    logic [ID_W-1:0] id_a, id_b, id_c, id_d, id_f, id_other;

    always #5 clk = ~clk;

    eviction_buffer #(.EVICTION_BUFFER_DEPTH(DEPTH)) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .eb_push_valid_i(push_valid), .eb_push_ready_o(push_ready),
        .eb_push_base_i(push_base), .eb_push_data_i(push_data),
        .eb_push_dirty_i(1'b1),
        .eb_probe_valid_i(probe_valid), .eb_probe_base_i(probe_base),
        .eb_probe_hit_o(probe_hit),
        .mem_wr_req_valid_o(wr_valid), .mem_wr_req_ready_i(wr_ready),
        .mem_wr_req_id_o(wr_id), .mem_wr_req_base_o(wr_base),
        .mem_wr_req_data_o(wr_data),
        .mem_wr_rsp_valid_i(rsp_valid), .mem_wr_rsp_ready_o(rsp_ready),
        .mem_wr_rsp_id_i(rsp_id), .mem_wr_rsp_base_i(rsp_base),
        .mem_wr_rsp_error_i(rsp_error), .perf_events_o(events)
    );

    function automatic line_t line_pattern(input integer tag);
        line_t value;
        for (integer word_index = 0; word_index < WORDS_PER_LINE; word_index++)
            value[word_index * 32 +: 32] = 32'hA500_0000 | (tag << 8) | word_index;
        return value;
    endfunction

    /** @brief Cuenta pulsos y compara esperas con las reglas de metrics.md. */
    always @(posedge clk) begin
        if (track_events && rst_n) begin
            if (events.enqueued.valid) enqueued_events++;
            if (events.write_accept.valid) sent_events++;
            if (events.write_done.valid) written_events++;
            if (events.write_error) write_errors++;
            if (events.error.valid) protocol_errors++;
            push_wait_expected += push_valid && !push_ready;
            send_wait_expected += wr_valid && !wr_ready;
            raw_wait_expected += probe_valid && probe_hit;
            push_wait_seen += events.state.push_wait;
            send_wait_seen += events.state.send_wait;
            raw_wait_seen += events.state.raw_wait;
            if (events.state.capacity != DEPTH)
                $fatal(1, "Capacidad de metricas incorrecta");
        end
    end

    task automatic push_line(input address_t base, input line_t data);
        @(negedge clk);
        push_base = base;
        push_data = data;
        push_valid = 1'b1;
        #1;
        if (!push_ready || !events.enqueued.valid)
            $fatal(1, "No se acepto la victima %h", base);
        @(posedge clk);
        #1;
        push_valid = 1'b0;
    endtask

    task automatic accept_line(input address_t base, input line_t data,
                               output logic [ID_W-1:0] accepted_id);
        @(negedge clk);
        #1;
        if (!wr_valid || wr_base !== base || wr_data !== data)
            $fatal(1, "Oferta FIFO incorrecta para %h", base);
        accepted_id = wr_id;
        repeat (2) begin
            @(posedge clk);
            #1;
            if (!wr_valid || wr_id !== accepted_id ||
                wr_base !== base || wr_data !== data)
                $fatal(1, "Oferta cambio durante la espera para %h", base);
        end
        @(negedge clk);
        wr_ready = 1'b1;
        #1;
        if (!events.write_accept.valid)
            $fatal(1, "Falto evento de envio para %h", base);
        @(posedge clk);
        #1;
        wr_ready = 1'b0;
    endtask

    task automatic respond(input logic [ID_W-1:0] id,
                           input address_t base, input logic error);
        @(negedge clk);
        rsp_id = id;
        rsp_base = base;
        rsp_error = error;
        rsp_valid = 1'b1;
        #1;
        if (!rsp_ready || events.write_done.valid !== !error ||
            events.write_error !== error)
            $fatal(1, "Respuesta o evento incorrecto para %h", base);
        @(posedge clk);
        #1;
        rsp_valid = 1'b0;
    endtask

    task automatic check_probe(input address_t base, input logic expected_hit);
        @(negedge clk);
        probe_base = base;
        probe_valid = 1'b1;
        #1;
        if (probe_hit !== expected_hit)
            $fatal(1, "Consulta RAW incorrecta para %h", base);
        @(posedge clk);
        #1;
        probe_valid = 1'b0;
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        for (integer i = 0; i < DEPTH; i++) begin
            push_base = DATA_BASE_ADDRESS + i * LINE_BYTES;
            push_data = i + 1;
            push_valid = 1'b1;
            probe_valid = 1'b1;
            probe_base = push_base;
            #1;
            if (!push_ready || !probe_hit)
                $fatal(1, "No se acepto o detecto el push %0d", i);
            @(posedge clk);
            @(negedge clk);
            push_valid = 1'b0;
            #1;
            if (!probe_hit)
                $fatal(1, "RAW no encontro la entrada guardada %0d", i);
        end
        probe_base = DATA_BASE_ADDRESS + DEPTH * LINE_BYTES;
        push_base = probe_base;
        push_valid = 1'b1;
        #1;
        if (push_ready || probe_hit)
            $fatal(1, "El buffer lleno acepto o consulto una victima nueva");
        push_valid = 1'b0;
        probe_base = DATA_BASE_ADDRESS;
        #1;
        if (!probe_hit)
            $fatal(1, "RAW perdio una entrada ocupada");
        probe_valid = 1'b0;
        #1;
        if (probe_hit)
            $fatal(1, "RAW respondio sin consulta valida");
        probe_valid = 1'b1;
        rst_n = 1'b0;
        #1;
        if (push_ready || probe_hit)
            $fatal(1, "Reset no cancelo las entradas o la consulta");
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        if (!push_ready || probe_hit)
            $fatal(1, "Reset no libero capacidad o dejo un RAW viejo");
        probe_valid = 1'b0;
        track_events = 1'b1;

        push_line(A, line_pattern(1));
        push_line(B, line_pattern(2));
        push_line(C, line_pattern(3));
        if (events.state.occupancy != 3)
            $fatal(1, "Ocupacion inicial incorrecta");
        accept_line(A, line_pattern(1), id_a);
        accept_line(B, line_pattern(2), id_b);
        accept_line(C, line_pattern(3), id_c);
        if (id_a == id_b || id_a == id_c || id_b == id_c)
            $fatal(1, "IDs de escrituras pendientes repetidos");
        if (wr_valid)
            $fatal(1, "Se repitio una solicitud ya aceptada");
        check_probe(A, 1'b1);
        check_probe(B, 1'b1);
        check_probe(C, 1'b1);

        @(negedge clk);
        rsp_valid = 1'b1;
        rsp_id = id_b;
        rsp_base = C;
        #1;
        if (!events.error.valid || events.error.kind != pkg_metrics::ERROR_PROTOCOL ||
            events.write_done.valid || events.state.occupancy != 3)
            $fatal(1, "Respuesta con base equivocada altero el buffer");
        @(posedge clk);
        #1;
        rsp_valid = 1'b0;
        check_probe(B, 1'b1);

        respond(id_b, B, 1'b0);
        check_probe(B, 1'b0);
        check_probe(A, 1'b1);
        respond(id_a, A, 1'b0);
        check_probe(A, 1'b0);
        respond(id_c, C, 1'b1);
        check_probe(C, 1'b1);
        if (wr_valid || events.state.occupancy != 1)
            $fatal(1, "La entrada fallida se retiro o se reenvio");

        for (integer i = 3; i < DEPTH + 2; i++)
            push_line(DATA_BASE_ADDRESS + i * LINE_BYTES, line_pattern(i + 1));
        @(negedge clk);
        push_base = F;
        push_data = line_pattern(DEPTH + 3);
        push_valid = 1'b1;
        probe_base = F;
        probe_valid = 1'b1;
        #1;
        if (push_ready || probe_hit || !events.state.push_wait ||
            events.state.occupancy != DEPTH)
            $fatal(1, "Buffer lleno acepto una victima adicional");
        @(posedge clk);
        #1;
        push_valid = 1'b0;
        probe_valid = 1'b0;

        accept_line(D, line_pattern(4), id_d);
        @(negedge clk);
        rsp_valid = 1'b1;
        rsp_id = id_d;
        rsp_base = D;
        rsp_error = 1'b0;
        push_valid = 1'b1;
        push_base = F;
        push_data = line_pattern(DEPTH + 3);
        probe_valid = 1'b1;
        probe_base = F;
        #1;
        if (!rsp_ready || !push_ready || !probe_hit ||
            !events.write_done.valid || !events.enqueued.valid)
            $fatal(1, "No se sustituyo la entrada liberada en el mismo flanco");
        @(posedge clk);
        #1;
        rsp_valid = 1'b0;
        push_valid = 1'b0;
        probe_valid = 1'b0;
        if (events.state.occupancy != DEPTH)
            $fatal(1, "La sustitucion altero la ocupacion");
        check_probe(D, 1'b0);
        check_probe(F, 1'b1);

        for (integer i = 4; i < DEPTH + 2; i++)
            accept_line(DATA_BASE_ADDRESS + i * LINE_BYTES,
                        line_pattern(i + 1), id_other);
        accept_line(F, line_pattern(DEPTH + 3), id_f);
        if (id_f != id_d || wr_valid)
            $fatal(1, "No se reutilizo el ID libre o se altero el FIFO");

        if (enqueued_events != DEPTH + 3 || sent_events != DEPTH + 3 ||
            written_events != 3 || write_errors != 1 || protocol_errors != 1)
            $fatal(1, "Conteos de eventos incorrectos: %0d %0d %0d %0d %0d",
                   enqueued_events, sent_events, written_events,
                   write_errors, protocol_errors);
        if (push_wait_expected != push_wait_seen ||
            send_wait_expected != send_wait_seen ||
            raw_wait_expected != raw_wait_seen ||
            push_wait_seen == 0 || send_wait_seen == 0 || raw_wait_seen == 0)
            $fatal(1, "Conteos de espera incorrectos");

        @(negedge clk);
        rst_n = 1'b0;
        rsp_valid = 1'b1;
        rsp_id = id_f;
        rsp_base = F;
        probe_valid = 1'b1;
        probe_base = F;
        #1;
        if (push_ready || rsp_ready || wr_valid || probe_hit ||
            events.state.occupancy != 0)
            $fatal(1, "Reset no cancelo el trabajo pendiente");
        rsp_valid = 1'b0;
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        if (!push_ready || wr_valid || probe_hit)
            $fatal(1, "Aparecio una entrega anterior tras reset");
        $display("PASS: profundidad %0d, FIFO, RAW, errores, metricas y reset", DEPTH);
        $finish;
    end
endmodule
