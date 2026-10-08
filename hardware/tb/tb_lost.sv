`timescale 1ns/1ps

module tb_lost;
    import pkg_vliw::*;

    logic clk = 1'b0;
    logic valid;
    lost_inst_t instruction;
    logic [15:0] immediate;
    address_t base_address;
    word_t store_data;
    word_t memory_read_data;
    address_t effective_address;
    address_t memory_address;
    logic memory_read_enable;
    logic [3:0] memory_write_enable;
    word_t memory_write_data;
    logic load_valid;
    word_t load_data;
    logic invalid_address;

    // RAM de prueba: 64 KiB, lectura directa y escritura en flanco positivo.
    // Las pruebas usan direcciones del segmento de datos 0x10000-0x1FFFF.
    logic [31:0] memory_words [0:16383];

    always #5 clk = ~clk;

    assign memory_read_data = memory_words[memory_address[15:2]];

    always @(posedge clk) begin
        if (memory_write_enable[0])
            memory_words[memory_address[15:2]][7:0] <= memory_write_data[7:0];
        if (memory_write_enable[1])
            memory_words[memory_address[15:2]][15:8] <= memory_write_data[15:8];
        if (memory_write_enable[2])
            memory_words[memory_address[15:2]][23:16] <= memory_write_data[23:16];
        if (memory_write_enable[3])
            memory_words[memory_address[15:2]][31:24] <= memory_write_data[31:24];
    end

    lost_unit u_lost (
        .valid_i(valid),
        .instruction_i(instruction),
        .immediate_i(immediate),
        .base_address_i(base_address),
        .store_data_i(store_data),
        .memory_read_data_i(memory_read_data),
        .effective_address_o(effective_address),
        .memory_address_o(memory_address),
        .memory_read_enable_o(memory_read_enable),
        .memory_write_enable_o(memory_write_enable),
        .memory_write_data_o(memory_write_data),
        .load_valid_o(load_valid),
        .load_data_o(load_data),
        .invalid_address_o(invalid_address)
    );

    task automatic issue(
        input logic [3:0] funct,
        input logic [2:0] offset,
        input logic use_immediate,
        input logic [15:0] literal,
        input address_t base,
        input word_t data
    );
        begin
            instruction = {3'd1, 3'd2, funct, offset, use_immediate, OPCODE_LOST};
            immediate = literal;
            base_address = base;
            store_data = data;
            valid = 1'b1;
        end
    endtask

    task automatic check_word(
        input string name,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        begin
            if (actual !== expected) begin
                $fatal(1, "%s: recibido %08h, esperado %08h", name, actual, expected);
            end
        end
    endtask

    task automatic expect_load(input string name, input word_t expected);
        begin
            #1;
            if (memory_read_enable !== 1'b1 || load_valid !== 1'b1 ||
                memory_write_enable !== 4'b0000 || invalid_address !== 1'b0) begin
                $fatal(1, "%s: señales incorrectas para lectura", name);
            end
            check_word(name, load_data, expected);
        end
    endtask

    task automatic expect_store(
        input string name,
        input address_t expected_address,
        input logic [3:0] expected_mask,
        input word_t expected_data
    );
        begin
            #1;
            check_word(name, memory_address, expected_address);
            check_word(name, {28'b0, memory_write_enable}, {28'b0, expected_mask});
            check_word(name, memory_write_data, expected_data);
            if (memory_read_enable !== 1'b0 || load_valid !== 1'b0 ||
                invalid_address !== 1'b0) begin
                $fatal(1, "%s: señales incorrectas para escritura", name);
            end
        end
    endtask

    task automatic expect_invalid(input string name);
        begin
            #1;
            if (invalid_address !== 1'b1 || memory_read_enable !== 1'b0 ||
                memory_write_enable !== 4'b0000 || load_valid !== 1'b0) begin
                $fatal(1, "%s: acceso desalineado no rechazado", name);
            end
        end
    endtask

    task automatic commit_store;
        begin
            @(posedge clk);
            #1;
            valid = 1'b0;
            #1;
        end
    endtask

    initial begin
        $dumpfile("build/tb_lost.vcd");
        $dumpvars(0, tb_lost);

        valid = 1'b0;
        instruction = '0;
        immediate = '0;
        base_address = '0;
        store_data = '0;
        memory_words[8] = 32'b0;
        memory_words[9] = 32'hAABB_CCDD;

        // Este patrón contiene bytes positivos y negativos para probar
        // las extensiones de signo y de ceros.
        issue(LOST_STW, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'h80FF_017F);
        expect_store("stw", 32'h0001_0020, 4'b1111, 32'h80FF_017F);
        commit_store();
        check_word("stw RAM", memory_words[8], 32'h80FF_017F);

        issue(LOST_LOW, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("low", 32'h80FF_017F);
        issue(LOST_LOB, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 0", 32'h0000_007F);
        issue(LOST_LOB, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 1", 32'h0000_0001);
        issue(LOST_LOB, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 2", 32'hFFFF_FFFF);
        issue(LOST_LOB, 3'd3, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 3", 32'hFFFF_FF80);
        issue(LOST_LOBU, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lobu byte 2", 32'h0000_00FF);
        issue(LOST_LOBU, 3'd3, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lobu byte 3", 32'h0000_0080);
        issue(LOST_LOH, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("loh mitad baja", 32'h0000_017F);
        issue(LOST_LOH, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("loh mitad alta", 32'hFFFF_80FF);
        issue(LOST_LOHU, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lohu mitad alta", 32'h0000_80FF);

        issue(LOST_STB, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'h0000_00AA);
        expect_store("stb", 32'h0001_0020, 4'b0010, 32'h0000_AA00);
        commit_store();
        check_word("stb RAM", memory_words[8], 32'h80FF_AA7F);

        issue(LOST_STH, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'h0000_1234);
        expect_store("sth", 32'h0001_0020, 4'b1100, 32'h1234_0000);
        commit_store();
        check_word("sth RAM", memory_words[8], 32'h1234_AA7F);

        // FFFC ocupa 16 bits en el slot siguiente y representa -4.
        issue(LOST_LOW, 3'd0, 1'b1, 16'hFFFC, 32'h0001_0024, 32'b0);
        expect_load("lowi offset negativo", 32'h1234_AA7F);
        check_word("dirección con -4", effective_address, 32'h0001_0020);
        issue(LOST_LOB, 3'd7, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("offset corto 7", 32'hFFFF_FFAA);

        issue(LOST_STB, 3'd0, 1'b1, 16'd3, 32'h0001_0020, 32'h0000_00EE);
        expect_store("stbi offset positivo", 32'h0001_0020, 4'b1000, 32'hEE00_0000);
        commit_store();
        check_word("stbi RAM", memory_words[8], 32'hEE34_AA7F);
        issue(LOST_LOBU, 3'd0, 1'b1, 16'd3, 32'h0001_0020, 32'b0);
        expect_load("lobui offset positivo", 32'h0000_00EE);

        // Palabras: múltiplos de 4. Medias palabras: múltiplos de 2.
        issue(LOST_LOW, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_invalid("low desalineado");
        issue(LOST_LOH, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_invalid("loh desalineado");
        issue(LOST_LOHU, 3'd3, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_invalid("lohu desalineado");
        issue(LOST_STW, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'hDEAD_BEEF);
        expect_invalid("stw desalineado");
        issue(LOST_STH, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'h0000_BEEF);
        expect_invalid("sth desalineado");
        @(posedge clk);
        #1;
        check_word("RAM tras errores", memory_words[8], 32'hEE34_AA7F);

        valid = 1'b0;
        #1;
        if (memory_read_enable !== 1'b0 || memory_write_enable !== 4'b0000 ||
            load_valid !== 1'b0 || invalid_address !== 1'b0) begin
            $fatal(1, "unidad inactiva con señales activas");
        end

        issue(4'b1111, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        #1;
        if (memory_read_enable !== 1'b0 || memory_write_enable !== 4'b0000 ||
            load_valid !== 1'b0 || invalid_address !== 1'b0) begin
            $fatal(1, "función reservada con señales activas");
        end

        $display("tb_lost: PASS");
        $finish;
    end
endmodule
