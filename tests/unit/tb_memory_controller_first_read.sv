/**
 * @brief Comprueba las ocho direcciones RAM de una lectura de linea.
 * @details Prueba ambas fases del divisor 2, orden y fin del burst.
 */
module tb_memory_controller_first_read;
    import pkg_memory::*;

    logic cpu_clk = 1'b0;
    logic rst_n = 1'b1;
    logic read_valid = 1'b0;
    logic read_ready;
    logic ram_clk;
    logic ram_rst_n;
    logic ram_read_enable;
    address_t ram_address;
    integer cpu_edges = 0;
    integer accepted_edge = -1;
    integer read_count = 0;
    integer expected_delay = 0;

    always #5 cpu_clk = ~cpu_clk;

    memory_controller dut (
        .clk_i(cpu_clk),
        .rst_ni(rst_n),
        .mem_rd_req_valid_i(read_valid),
        .mem_rd_req_ready_o(read_ready),
        .mem_rd_req_id_i(2'd2),
        .mem_rd_req_base_i(DATA_BASE_ADDRESS),
        .eb_probe_hit_i(1'b0),
        .mem_wr_req_valid_i(1'b0),
        .ram_clk_o(ram_clk),
        .ram_rst_no(ram_rst_n),
        .ram_read_enable_o(ram_read_enable),
        .ram_address_o(ram_address)
    );

    always @(posedge cpu_clk) begin
        cpu_edges = cpu_edges + 1;
        if (read_valid && read_ready) accepted_edge = cpu_edges;
    end

    always @(posedge ram_clk) begin
        if (ram_read_enable) begin
            if (read_count >= WORDS_PER_LINE)
                $fatal(1, "se emitieron mas de ocho lecturas");
            if (accepted_edge < 0 ||
                cpu_edges - accepted_edge !=
                    expected_delay + read_count * MEM_CLOCK_DIV_DEFAULT)
                $fatal(1, "acceso RAM fuera del ciclo esperado");
            if (ram_address !== DATA_BASE_ADDRESS +
                read_count * (LINE_BYTES / WORDS_PER_LINE))
                $fatal(1, "direccion de palabra incorrecta");
            read_count = read_count + 1;
        end
    end

    task automatic run_case(input integer wait_cpu, input integer delay_cpu);
        @(negedge cpu_clk);
        rst_n = 1'b0;
        read_valid = 1'b0;
        accepted_edge = -1;
        read_count = 0;
        expected_delay = delay_cpu;
        @(negedge cpu_clk);
        rst_n = 1'b1;
        @(posedge ram_rst_n);
        repeat (wait_cpu) @(posedge cpu_clk);
        @(negedge cpu_clk);
        read_valid = 1'b1;
        @(posedge cpu_clk);
        #1;
        read_valid = 1'b0;
        wait (read_count == WORDS_PER_LINE);
        repeat (3) @(posedge ram_clk);
        #1;
        if (read_count != WORDS_PER_LINE)
            $fatal(1, "el burst debe terminar despues de ocho palabras");
    endtask

    initial begin
        run_case(0, 23);
        run_case(1, 24);
        $display("PASS tb_memory_controller_first_read");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "timeout esperando el burst de ocho palabras");
    end
endmodule
