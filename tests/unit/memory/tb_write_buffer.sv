`timescale 1ns/1ps

/**
 * @brief Prueba aislada del Write Buffer: reset inicial/repetido y frontera de canales (WB-1).
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
        if (dut.count_q !== '0)
            $fatal(1, "Reset incompleto: count_q != 0");
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

        $display("PASS WB: reset inicial, repetido y frontera de canales (WB-1)");
        $finish;
    end
endmodule