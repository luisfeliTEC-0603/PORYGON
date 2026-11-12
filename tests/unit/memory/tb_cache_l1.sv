`timescale 1ns/1ps

/**
 * @brief Prueba aislada de L1-2: invalidacion por reset, captura de id y bloqueo de canales.
 * @details No genera accesos CPU ni modela vecinos todavia. La preparacion
 * jerarquica de metadatos representa bloques ocupados solo para comprobar un
 * segundo reset; no constituye una instalacion funcional de cache.
 */
module tb_cache_l1;
    localparam integer SET_COUNT = pkg_memory::L1_BYTES /
        (pkg_memory::L1_WAYS * pkg_memory::LINE_BYTES);
    logic clk = 1'b0;
    logic rst_n = 1'b1;
    logic l2_ready = 1'b0;
    logic [1:0] l2_accept_id = '0;
    logic peer_active = 1'b0;

    always #5 clk = ~clk;

    /** Entradas inactivas: los canales funcionales siguen pendientes. */
    cache_l1 dut (
        .clk_i(clk), .rst_ni(rst_n),
        .dmem_req_valid_i(peer_active), .dmem_req_addr_i(32'b0),
        .dmem_req_write_i(1'b0), .dmem_req_wdata_i(32'b0),
        .dmem_req_wstrb_i(4'b0), .dmem_rsp_ready_i(peer_active),
        .wb_push_ready_i(peer_active), .wb_probe_hit_i(1'b0),
        .wb_probe_busy_i(1'b0), .l2_get_ready_i(l2_ready),
        .l2_get_accept_id_i(l2_accept_id), .fill_valid_i(peer_active),
        .fill_base_i(32'b0), .fill_data_i(256'b0),
        .fill_dirty_i(1'b0), .fill_error_i(1'b0),
        .fill_source_i(pkg_memory::FILL_WB), .fill_id_i(2'b0)
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
             dut.input_valid_q, dut.response_valid_q} !== 5'b0)
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
        /** El reset y su comprobacion ocurren antes del primer flanco. */
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
        /** Preparacion jerarquica de ocupacion; aun no hay captura funcional. */
        dut.pending_valid_q = 1'b1;
        dut.input_reserved_q = 1'b1;
        dut.input_valid_q = 1'b1;
        dut.response_valid_q = 1'b1;
        dut.pending_addr_q = 32'h00010020;
        dut.input_data_q = '1;
        dut.response_error_q = 1'b1;
        /** Representar una espera anterior; no es una transicion funcional. */
        dut.state_q = dut.L1_WAIT_BLOCK;
        /** Simular intenciones activas: probar las puertas, no el control futuro. */
        force dut.req_ready_internal = 1'b1;
        force dut.rsp_valid_internal = 1'b1;
        force dut.wb_push_valid_internal = 1'b1;
        force dut.wb_probe_valid_internal = 1'b1;
        force dut.l2_get_valid_internal = 1'b1;
        force dut.fill_ready_internal = 1'b1;
        peer_active = 1'b1;
        l2_ready = 1'b1;
        /** Segundo reset entre flancos: debe invalidar sin esperar posedge. */
        #1 rst_n = 1'b0;
        #1 check_empty();
        @(posedge clk); #1 check_empty();
        release dut.req_ready_internal;
        release dut.rsp_valid_internal;
        release dut.wb_push_valid_internal;
        release dut.wb_probe_valid_internal;
        release dut.l2_get_valid_internal;
        release dut.fill_ready_internal;
        peer_active = 1'b0;
        l2_ready = 1'b0;
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();
        /**
         * Instrumentacion aislada: la generacion real de solicitudes aun no
         * existe. Forzar su oferta permite probar solo el registro de id;
         * no demuestra un miss ni una solicitud funcional emitida por L1.
         */
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
        $display("PASS L1: reset inicial, repetido y conservacion de invalidez");
        $display("PASS L1: id valido solo tras aceptacion L2 y cancelado por reset");
        $display("PASS L1: reset bloquea canales con vecinos e intenciones activos");
        $display("PASS L1: control vuelve a LIBRE tras reset inicial y repetido");
        $finish;
    end
endmodule