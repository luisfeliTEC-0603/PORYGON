/**
 * @brief Comprueba la captura de una solicitud de lectura de linea.
 * @details Verifica reset, conflicto EB y un solo handshake por solicitud.
 * La asociacion de id/base se comprobara al implementar la respuesta externa.
 */
module tb_memory_controller_read_accept;
    import pkg_memory::*;

    logic cpu_clk = 1'b0;
    logic rst_n = 1'b1;
    logic read_valid = 1'b0;
    logic read_ready;
    logic [id_width(L2_MAX_INFLIGHT_DEFAULT)-1:0] read_id = '0;
    address_t read_base = DATA_BASE_ADDRESS;
    logic write_valid = 1'b0;
    logic eb_probe_hit = 1'b0;
    logic ram_clk;
    logic ram_rst_n;

    always #5 cpu_clk = ~cpu_clk;

    memory_controller dut (
        .clk_i(cpu_clk),
        .rst_ni(rst_n),
        .mem_rd_req_valid_i(read_valid),
        .mem_rd_req_ready_o(read_ready),
        .mem_rd_req_id_i(read_id),
        .mem_rd_req_base_i(read_base),
        .eb_probe_hit_i(eb_probe_hit),
        .mem_wr_req_valid_i(write_valid),
        .ram_clk_o(ram_clk),
        .ram_rst_no(ram_rst_n)
    );

    task automatic tick;
        @(posedge cpu_clk);
        #1;
    endtask

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) $fatal(1, "%s", message);
    endtask

    initial begin
        #1 rst_n = 1'b0;
        #1;
        check(!read_ready, "reset debe bloquear la lectura");

        #1 rst_n = 1'b1;
        @(posedge ram_rst_n);
        #1;
        check(read_ready, "RAM liberada debe permitir lectura sin conflicto");

        @(negedge cpu_clk);
        read_valid = 1'b1;
        read_id = 2'd2;
        eb_probe_hit = 1'b1;
        #1;
        check(!read_ready, "conflicto EB debe bloquear la lectura");
        tick();

        @(negedge cpu_clk);
        eb_probe_hit = 1'b0;
        #1;
        check(read_ready, "lectura debe poder aceptarse al desaparecer el conflicto");
        tick();
        check(!read_ready, "solo una lectura puede aceptarse");

        @(negedge cpu_clk);
        read_id = 2'd1;
        read_base = DATA_BASE_ADDRESS + LINE_BYTES;
        tick();
        check(!read_ready, "mantener valid no debe duplicar la aceptacion");

        @(negedge cpu_clk);
        rst_n = 1'b0;
        #1;
        check(!read_ready, "reset debe bloquear nuevas solicitudes");

        rst_n = 1'b1;
        @(posedge ram_rst_n);
        #1;
        check(read_ready, "reset debe liberar la reserva anterior");

        $display("PASS tb_memory_controller_read_accept");
        $finish;
    end
endmodule
