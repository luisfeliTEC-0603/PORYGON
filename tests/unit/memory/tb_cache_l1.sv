`timescale 1ns/1ps

/**
 * @brief Prueba aislada del primer incremento: invalidacion por reset.
 * @details No genera accesos CPU ni modela vecinos todavia. La preparacion
 * jerarquica de metadatos representa bloques ocupados solo para comprobar un
 * segundo reset; no constituye una instalacion funcional de cache.
 */
module tb_cache_l1;
    localparam integer SET_COUNT = pkg_memory::L1_BYTES /
        (pkg_memory::L1_WAYS * pkg_memory::LINE_BYTES);
    logic clk = 1'b0;
    logic rst_n = 1'b1;

    always #5 clk = ~clk;

    /** Entradas inactivas: los canales funcionales siguen pendientes. */
    cache_l1 dut (
        .clk_i(clk), .rst_ni(rst_n),
        .dmem_req_valid_i(1'b0), .dmem_req_addr_i(32'b0),
        .dmem_req_write_i(1'b0), .dmem_req_wdata_i(32'b0),
        .dmem_req_wstrb_i(4'b0), .dmem_rsp_ready_i(1'b0),
        .wb_push_ready_i(1'b0), .wb_probe_hit_i(1'b0),
        .wb_probe_busy_i(1'b0), .l2_get_ready_i(1'b0),
        .l2_get_accept_id_i(2'b0), .fill_valid_i(1'b0),
        .fill_base_i(32'b0), .fill_data_i(256'b0),
        .fill_dirty_i(1'b0), .fill_error_i(1'b0),
        .fill_source_i(pkg_memory::FILL_WB), .fill_id_i(2'b0)
    );

    /** Revisa todas las vias; !== tambien detecta valores desconocidos. */
    task automatic check_empty;
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
        /** Segundo reset entre flancos: debe invalidar sin esperar posedge. */
        #1 rst_n = 1'b0;
        #1 check_empty();
        #1 rst_n = 1'b1;
        @(negedge clk);
        check_empty();
        $display("PASS L1: reset inicial, repetido y conservacion de invalidez");
        $finish;
    end
endmodule
