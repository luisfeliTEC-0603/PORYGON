/**
 * @brief Pruebas autochecking de la RAM usada por main_memory.
 * @details Comprueba lectura sincrona, mascara por byte, rango y reset.
 * El controlador de lineas y sus latencias se prueban por separado.
 */
module tb_main_memory;
    import pkg_memory::*;

    localparam address_t BASE = DATA_BASE_ADDRESS;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    address_t address = BASE;
    logic read_enable = 1'b0;
    byte_mask_t write_enable = '0;
    word_t write_data = '0;
    word_t read_data;
    logic read_valid;
    logic out_of_range;

    always #5 clk = ~clk;

    main_memory dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .address_i(address),
        .read_enable_i(read_enable),
        .write_enable_i(write_enable),
        .write_data_i(write_data),
        .read_data_o(read_data),
        .read_valid_o(read_valid),
        .out_of_range_o(out_of_range)
    );

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) $fatal(1, "%s", message);
    endtask

    initial begin
        @(negedge clk);
        rst_n = 1'b1;
        write_enable = 4'b1111;
        write_data = 32'hAABBCCDD;
        tick();

        @(negedge clk);
        write_enable = '0;
        read_enable = 1'b1;
        tick();
        check(read_valid && read_data == 32'hAABBCCDD,
              "lectura de la palabra completa");

        @(negedge clk);
        read_enable = 1'b0;
        write_enable = 4'b0011;
        write_data = 32'h11223344;
        tick();

        @(negedge clk);
        write_enable = '0;
        read_enable = 1'b1;
        tick();
        check(read_valid && read_data == 32'hAABB3344,
              "la mascara debe conservar los dos bytes altos");

        @(negedge clk);
        address = BASE + MEMORY_BYTES;
        #1;
        check(out_of_range, "solicitud fuera de rango debe indicarse");
        tick();
        check(!read_valid && read_data == '0,
              "lectura fuera de rango no debe devolver dato valido");

        @(negedge clk);
        address = BASE;
        tick();
        check(read_valid && read_data == 32'hAABB3344,
              "acceso fuera de rango no debe alterar la RAM");

        @(negedge clk);
        rst_n = 1'b0;
        read_enable = 1'b0;
        tick();
        check(!read_valid && read_data == '0,
              "reset debe limpiar la respuesta registrada");

        @(negedge clk);
        rst_n = 1'b1;
        read_enable = 1'b1;
        tick();
        check(read_valid && read_data == 32'hAABB3344,
              "reset no debe borrar los bytes almacenados");

        $display("PASS tb_main_memory");
        $finish;
    end
endmodule
