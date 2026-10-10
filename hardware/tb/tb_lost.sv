`timescale 1ns/1ps

module tb_lost;
    import pkg_vliw::*;

    logic clk = 1'b0;
    logic rst_n;
    logic nop_flag;
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
    integer cycle_count = 0;
    integer checks_passed = 0;
    string current_case;

    // RAM de prueba: 64 KiB, lectura directa y escritura en flanco positivo.
    // Las pruebas usan direcciones del segmento de datos 0x10000-0x1FFFF.
    logic [31:0] memory_words [0:16383];

    always #5 clk = ~clk;
    always @(posedge clk) cycle_count <= cycle_count + 1;

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
        .clk_i(clk),
        .rst_ni(rst_n),
        .nop_flag_i(nop_flag),
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
        input string name,
        input logic [3:0] funct,
        input logic [2:0] offset,
        input logic use_immediate,
        input logic [15:0] literal,
        input address_t base,
        input word_t data
    );
        begin
            // Las entradas se presentan en EX1 y se capturan en su flanco final.
            @(negedge clk);
            instruction = {3'd1, 3'd2, funct, offset, use_immediate, OPCODE_LOST};
            immediate = literal;
            base_address = base;
            store_data = data;
            nop_flag = 1'b0;
            current_case = name;
            $display("[EX1 C%0d] %s: funct=%04b base=%08h off=%0d imm=%b literal=%04h dato=%08h",
                cycle_count, name, funct, base, $signed(offset), use_immediate, literal, data);
            @(posedge clk);
            #1;
            nop_flag = 1'b1;
        end
    endtask

    task automatic check_word(
        input string name,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        begin
            if (actual !== expected) begin
                $fatal(1, "[FAIL C%0d] %s: recibido=%08h esperado=%08h",
                    cycle_count, name, actual, expected);
            end
            checks_passed = checks_passed + 1;
            $display("[OK C%0d] %s: %08h", cycle_count, name, actual);
        end
    endtask

    task automatic expect_load(input string name, input word_t expected);
        begin
            #1;
            if (memory_read_enable !== 1'b1 || load_valid !== 1'b1 ||
                memory_write_enable !== 4'b0000 || invalid_address !== 1'b0) begin
                $fatal(1, "[FAIL C%0d] %s: read=%b valid=%b mask=%04b error=%b; esperado 1,1,0000,0",
                    cycle_count, name, memory_read_enable, load_valid,
                    memory_write_enable, invalid_address);
            end
            checks_passed = checks_passed + 1;
            $display("[EX2 C%0d] %s: direccion=%08h palabra=%08h dato=%08h",
                cycle_count, name, effective_address, memory_read_data, load_data);
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
            check_word($sformatf("%s direccion de RAM", name), memory_address, expected_address);
            check_word($sformatf("%s mascara", name),
                {28'b0, memory_write_enable}, {28'b0, expected_mask});
            check_word($sformatf("%s dato", name), memory_write_data, expected_data);
            if (memory_read_enable !== 1'b0 || load_valid !== 1'b0 ||
                invalid_address !== 1'b0) begin
                $fatal(1, "[FAIL C%0d] %s: read=%b valid=%b error=%b; esperado 0,0,0",
                    cycle_count, name, memory_read_enable, load_valid, invalid_address);
            end
            checks_passed = checks_passed + 1;
            $display("[EX2 C%0d] %s: direccion=%08h RAM=%08h mascara=%04b dato=%08h",
                cycle_count, name, effective_address, memory_address,
                memory_write_enable, memory_write_data);
        end
    endtask

    task automatic expect_invalid(input string name);
        begin
            #1;
            if (invalid_address !== 1'b1 || memory_read_enable !== 1'b0 ||
                memory_write_enable !== 4'b0000 || load_valid !== 1'b0) begin
                $fatal(1, "[FAIL C%0d] %s: direccion=%08h error=%b read=%b mask=%04b valid=%b; esperado 1,0,0000,0",
                    cycle_count, name, effective_address, invalid_address,
                    memory_read_enable, memory_write_enable, load_valid);
            end
            checks_passed = checks_passed + 1;
            $display("[EX2 C%0d] %s: direccion=%08h rechazada por desalineacion",
                cycle_count, name, effective_address);
        end
    endtask

    task automatic commit_store;
        address_t committed_address;
        begin
            committed_address = memory_address;
            @(posedge clk);
            #1;
            $display("[RAM C%0d] %s: direccion=%08h palabra=%08h",
                cycle_count, current_case, committed_address,
                memory_words[committed_address[15:2]]);
        end
    endtask

    task automatic expect_inactive(input string name);
        begin
            #1;
            if (memory_read_enable !== 1'b0 || memory_write_enable !== 4'b0000 ||
                load_valid !== 1'b0 || invalid_address !== 1'b0) begin
                $fatal(1, "[FAIL C%0d] %s: read=%b mask=%04b valid=%b error=%b; esperado 0,0000,0,0",
                    cycle_count, name, memory_read_enable, memory_write_enable,
                    load_valid, invalid_address);
            end
            checks_passed = checks_passed + 1;
            $display("[OK C%0d] %s: sin lectura, escritura ni resultado", cycle_count, name);
        end
    endtask

    initial begin
        $dumpfile("build/tb_lost.vcd");
        $dumpvars(0, tb_lost);

        rst_n = 1'b0;
        nop_flag = 1'b1;
        instruction = '0;
        immediate = '0;
        base_address = '0;
        store_data = '0;
        memory_words[8] = 32'b0;
        memory_words[9] = 32'hAABB_CCDD;
        #2;
        rst_n = 1'b1;

        // Este patrón contiene bytes positivos y negativos para probar
        // las extensiones de signo y de ceros.
        $display("\n=== Escritura y lectura de palabra ===");
        issue("stw", LOST_STW, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'h80FF_017F);
        expect_store("stw", 32'h0001_0020, 4'b1111, 32'h80FF_017F);
        check_word("stw antes de cerrar EX2", memory_words[8], 32'b0);
        commit_store();
        check_word("stw RAM", memory_words[8], 32'h80FF_017F);

        issue("low", LOST_LOW, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("low", 32'h80FF_017F);
        $display("\n=== Seleccion de bytes y medias palabras ===");
        issue("lob byte 0", LOST_LOB, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 0", 32'h0000_007F);
        issue("lob byte 1", LOST_LOB, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 1", 32'h0000_0001);
        issue("lob byte 2", LOST_LOB, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 2", 32'hFFFF_FFFF);
        issue("lob byte 3", LOST_LOB, 3'd3, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lob byte 3", 32'hFFFF_FF80);
        issue("lobu byte 2", LOST_LOBU, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lobu byte 2", 32'h0000_00FF);
        issue("lobu byte 3", LOST_LOBU, 3'd3, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lobu byte 3", 32'h0000_0080);
        issue("loh mitad baja", LOST_LOH, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("loh mitad baja", 32'h0000_017F);
        issue("loh mitad alta", LOST_LOH, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("loh mitad alta", 32'hFFFF_80FF);
        issue("lohu mitad alta", LOST_LOHU, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_load("lohu mitad alta", 32'h0000_80FF);

        $display("\n=== Escrituras parciales ===");
        issue("stb", LOST_STB, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'h0000_00AA);
        expect_store("stb", 32'h0001_0020, 4'b0010, 32'h0000_AA00);
        commit_store();
        check_word("stb RAM", memory_words[8], 32'h80FF_AA7F);

        issue("sth", LOST_STH, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'h0000_1234);
        expect_store("sth", 32'h0001_0020, 4'b1100, 32'h1234_0000);
        commit_store();
        check_word("sth RAM", memory_words[8], 32'h1234_AA7F);

        // 3'b100 representa -4 en complemento a dos de 3 bits.
        // El literal no debe afectar la dirección cuando imm = 0.
        $display("\n=== Offsets con signo e inmediato ===");
        issue("offset corto -4", LOST_LOW, 3'b100, 1'b0, 16'h1234, 32'h0001_0024, 32'b0);
        expect_load("offset corto -4", 32'h1234_AA7F);
        check_word("dirección con off -4", effective_address, 32'h0001_0020);
        issue("lowi offset -5", LOST_LOW, 3'd0, 1'b1, 16'hFFFB, 32'h0001_0025, 32'b0);
        expect_load("lowi offset -5", 32'h1234_AA7F);
        check_word("dirección con imm -5", effective_address, 32'h0001_0020);
        issue("offset corto -1", LOST_LOB, 3'b111, 1'b0, 16'b0, 32'h0001_0028, 32'b0);
        expect_load("offset corto -1", 32'hFFFF_FFAA);

        issue("stbi offset +4", LOST_STB, 3'd0, 1'b1, 16'd4, 32'h0001_001F, 32'h0000_00EE);
        expect_store("stbi offset +4", 32'h0001_0020, 4'b1000, 32'hEE00_0000);
        commit_store();
        check_word("stbi RAM", memory_words[8], 32'hEE34_AA7F);
        issue("lobui offset +4", LOST_LOBU, 3'd0, 1'b1, 16'd4, 32'h0001_001F, 32'b0);
        expect_load("lobui offset +4", 32'h0000_00EE);

        // Palabras: múltiplos de 4. Medias palabras: múltiplos de 2.
        $display("\n=== Direcciones desalineadas ===");
        issue("low desalineado", LOST_LOW, 3'd2, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_invalid("low desalineado");
        issue("loh desalineado", LOST_LOH, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_invalid("loh desalineado");
        issue("lohu desalineado", LOST_LOHU, 3'd3, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_invalid("lohu desalineado");
        issue("stw desalineado", LOST_STW, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'hDEAD_BEEF);
        expect_invalid("stw desalineado");
        issue("sth desalineado", LOST_STH, 3'd1, 1'b0, 16'b0, 32'h0001_0020, 32'h0000_BEEF);
        expect_invalid("sth desalineado");
        @(posedge clk);
        #1;
        check_word("RAM tras errores", memory_words[8], 32'hEE34_AA7F);

        $display("\n=== NOP y funcion reservada ===");
        nop_flag = 1'b1;
        expect_inactive("unidad sin instruccion");

        // Un NOP debe bloquear el store antes del flanco que termina EX1.
        @(negedge clk);
        instruction = {3'd1, 3'd2, LOST_STW, 3'd0, 1'b0, OPCODE_LOST};
        base_address = 32'h0001_0020;
        store_data = 32'hDEAD_BEEF;
        nop_flag = 1'b1;
        @(posedge clk);
        expect_inactive("NOP bloquea stw");
        @(posedge clk);
        #1;
        check_word("RAM tras NOP", memory_words[8], 32'hEE34_AA7F);

        issue("funct reservado", 4'b1111, 3'd0, 1'b0, 16'b0, 32'h0001_0020, 32'b0);
        expect_inactive("funct reservado");

        $display("\ntb_lost: PASS (%0d comprobaciones)", checks_passed);
        $finish;
    end
endmodule
