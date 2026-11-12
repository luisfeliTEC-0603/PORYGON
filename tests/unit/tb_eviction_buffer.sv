/**
 * @brief Primer incremento de P2-04: capacidad, captura y reset.
 * @param DEPTH Numero de lineas que puede conservar el buffer.
 * @details La prueba completa de drenado y respuestas se anadira despues.
 */
module tb_eviction_buffer;
    import pkg_memory::*;

`ifndef TB_DEPTH
`define TB_DEPTH EVICTION_BUFFER_DEPTH_DEFAULT
`endif
    parameter integer DEPTH = `TB_DEPTH;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic push_valid = 1'b0;
    logic push_ready;
    address_t push_base = DATA_BASE_ADDRESS;
    line_t push_data = '0;

    always #5 clk = ~clk;

    eviction_buffer #(.EVICTION_BUFFER_DEPTH(DEPTH)) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .eb_push_valid_i(push_valid), .eb_push_ready_o(push_ready),
        .eb_push_base_i(push_base), .eb_push_data_i(push_data),
        .eb_push_dirty_i(1'b1),
        .eb_probe_valid_i(1'b0), .eb_probe_base_i('0),
        .eb_probe_hit_o(),
        .mem_wr_req_valid_o(), .mem_wr_req_ready_i(1'b0),
        .mem_wr_req_id_o(), .mem_wr_req_base_o(),
        .mem_wr_req_data_o(),
        .mem_wr_rsp_valid_i(1'b0), .mem_wr_rsp_ready_o(),
        .mem_wr_rsp_id_i('0), .mem_wr_rsp_base_i('0),
        .mem_wr_rsp_error_i(1'b0), .perf_events_o()
    );

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        for (integer i = 0; i < DEPTH; i++) begin
            push_base = DATA_BASE_ADDRESS + i * LINE_BYTES;
            push_data = i + 1;
            push_valid = 1'b1;
            #1;
            if (!push_ready)
                $fatal(1, "No se acepto la entrada %0d", i);
            @(posedge clk);
            @(negedge clk);
        end
        #1;
        if (push_ready)
            $fatal(1, "El buffer lleno acepto otra victima");
        rst_n = 1'b0;
        #1;
        if (push_ready)
            $fatal(1, "Reset no cancelo las entradas");
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        if (!push_ready)
            $fatal(1, "Reset no libero la capacidad");
        $display("PASS: capacidad %0d y reset", DEPTH);
        $finish;
    end
endmodule
