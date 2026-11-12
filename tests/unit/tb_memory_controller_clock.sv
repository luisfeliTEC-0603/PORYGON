/**
 * @brief Comprueba el divisor de reloj del controlador de memoria.
 * @details Verifica periodos 2 y 5, fase inicial y reset de ambos dominios.
 * Los canales de solicitudes se prueban en incrementos posteriores.
 */
module tb_memory_controller_clock;
    logic cpu_clk = 1'b0;
    logic rst_n = 1'b1;
    logic ram_clk_div2;
    logic ram_clk_div5;
    logic ram_rst_div2;
    logic ram_rst_div5;

    always #5 cpu_clk = ~cpu_clk;

    memory_controller #(.MEM_CLOCK_DIV(2)) dut_div2 (
        .clk_i(cpu_clk),
        .rst_ni(rst_n),
        .ram_clk_o(ram_clk_div2),
        .ram_rst_no(ram_rst_div2)
    );

    memory_controller #(.MEM_CLOCK_DIV(5)) dut_div5 (
        .clk_i(cpu_clk),
        .rst_ni(rst_n),
        .ram_clk_o(ram_clk_div5),
        .ram_rst_no(ram_rst_div5)
    );

    task automatic check_cycle(input integer cycle_number);
        logic expected_div2;
        logic expected_div5;
        expected_div2 = ((cycle_number - 1) % 2) < 1;
        expected_div5 = ((cycle_number - 1) % 5) < 3;
        if (ram_clk_div2 !== expected_div2)
            $fatal(1, "div2: ciclo %0d, esperado %b, recibido %b",
                   cycle_number, expected_div2, ram_clk_div2);
        if (ram_clk_div5 !== expected_div5)
            $fatal(1, "div5: ciclo %0d, esperado %b, recibido %b",
                   cycle_number, expected_div5, ram_clk_div5);
        if (ram_rst_div2 !== (cycle_number >= 3))
            $fatal(1, "div2: reset RAM se libera tras dos subidas");
        if (ram_rst_div5 !== (cycle_number >= 6))
            $fatal(1, "div5: reset RAM se libera tras dos subidas");
    endtask

    initial begin
        #1 rst_n = 1'b0;
        #1;
        if (ram_clk_div2 !== 1'b0 || ram_clk_div5 !== 1'b0 ||
            ram_rst_div2 !== 1'b0 || ram_rst_div5 !== 1'b0)
            $fatal(1, "reset debe dejar relojes y reset RAM en cero");

        #1 rst_n = 1'b1;
        for (integer cycle_number = 1; cycle_number <= 15; cycle_number++) begin
            @(posedge cpu_clk);
            #1;
            check_cycle(cycle_number);
        end

        @(negedge cpu_clk);
        rst_n = 1'b0;
        #1;
        if (ram_clk_div2 !== 1'b0 || ram_clk_div5 !== 1'b0 ||
            ram_rst_div2 !== 1'b0 || ram_rst_div5 !== 1'b0)
            $fatal(1, "reset durante el funcionamiento debe bajar ambas salidas");

        @(negedge cpu_clk);
        rst_n = 1'b1;
        for (integer cycle_number = 1; cycle_number <= 5; cycle_number++) begin
            @(posedge cpu_clk);
            #1;
            check_cycle(cycle_number);
        end

        $display("PASS tb_memory_controller_clock");
        $finish;
    end
endmodule
