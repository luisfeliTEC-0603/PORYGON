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
    logic invalid_address;
    logic load_valid;
    logic [2:0] load_rd;
    word_t load_data;
    integer checks_passed = 0;

    // RAM de prueba: lee y escribe en el flanco positivo. read_data conserva
    // la ultima respuesta hasta que se capture otra lectura.
    logic [31:0] memory_words [0:16383];

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (memory_read_enable)
            memory_read_data <= memory_words[memory_address[15:2]];
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
        .invalid_address_o(invalid_address),
        .load_valid_o(load_valid),
        .load_rd_o(load_rd),
        .load_data_o(load_data)
    );

    task automatic check_word(
        input string name,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        if (actual !== expected)
            $fatal(1, "%s: recibido=%08h esperado=%08h", name, actual, expected);
        checks_passed = checks_passed + 1;
    endtask

    task automatic issue(
        input logic [2:0] rd,
        input logic [3:0] funct,
        input logic [2:0] offset,
        input logic use_immediate,
        input logic [15:0] literal,
        input address_t base,
        input word_t data
    );
        @(negedge clk);
        instruction = {rd, 3'd2, funct, offset, use_immediate, OPCODE_LOST};
        immediate = literal;
        base_address = base;
        store_data = data;
        nop_flag = 1'b0;
        #1;
    endtask

    task automatic expect_request(
        input string name,
        input address_t expected_effective,
        input logic expected_read,
        input logic [3:0] expected_write,
        input word_t expected_data,
        input logic expected_invalid
    );
        check_word($sformatf("%s effective", name), effective_address, expected_effective);
        check_word($sformatf("%s memory", name), memory_address,
            {expected_effective[31:2], 2'b00});
        if (memory_read_enable !== expected_read ||
            memory_write_enable !== expected_write ||
            memory_write_data !== expected_data ||
            invalid_address !== expected_invalid)
            $fatal(1, "%s: read=%b write=%04b data=%08h invalid=%b",
                name, memory_read_enable, memory_write_enable,
                memory_write_data, invalid_address);
        checks_passed = checks_passed + 1;
    endtask

    task automatic capture_request;
        @(posedge clk);
        #1;
    endtask

    task automatic expect_load(
        input string name,
        input logic [2:0] expected_rd,
        input word_t expected_data
    );
        if (load_valid !== 1'b1 || load_rd !== expected_rd ||
            load_data !== expected_data)
            $fatal(1, "%s: valid=%b rd=%0d data=%08h; esperado rd=%0d data=%08h",
                name, load_valid, load_rd, load_data, expected_rd, expected_data);
        checks_passed = checks_passed + 1;
    endtask

    task automatic expect_no_load(input string name);
        if (load_valid !== 1'b0 || load_rd !== 3'b000 || load_data !== 32'b0)
            $fatal(1, "%s: respuesta inesperada valid=%b rd=%0d data=%08h",
                name, load_valid, load_rd, load_data);
        checks_passed = checks_passed + 1;
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
        memory_read_data = '0;
        memory_words[8] = '0;
        memory_words[9] = 32'hAABB_CCDD;
        #2;
        rst_n = 1'b1;

        issue(3'd1, LOST_STW, 3'd0, 1'b0, 16'b0,
            32'h0001_0020, 32'h80FF_017F);
        expect_request("stw", 32'h0001_0020, 1'b0, 4'b1111,
            32'h80FF_017F, 1'b0);
        check_word("stw antes del flanco", memory_words[8], 32'b0);
        capture_request();
        check_word("stw despues del flanco", memory_words[8], 32'h80FF_017F);
        expect_no_load("stw");

        issue(3'd3, LOST_LOW, 3'd0, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("low", 32'h0001_0020, 1'b1, 4'b0000, 32'b0, 1'b0);
        expect_no_load("low antes del flanco");
        capture_request();
        expect_load("low", 3'd3, 32'h80FF_017F);

        issue(3'd5, LOST_LOB, 3'd2, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lob", 32'h0001_0022, 1'b1, 4'b0000, 32'b0, 1'b0);
        expect_load("respuesta previa sigue estable", 3'd3, 32'h80FF_017F);
        capture_request();
        expect_load("lob", 3'd5, 32'hFFFF_FFFF);

        issue(3'd6, LOST_LOBU, 3'd3, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lobu", 32'h0001_0023, 1'b1, 4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("lobu", 3'd6, 32'h0000_0080);

        issue(3'd2, LOST_LOH, 3'd2, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("loh", 32'h0001_0022, 1'b1, 4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("loh", 3'd2, 32'hFFFF_80FF);

        issue(3'd7, LOST_LOHU, 3'd2, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lohu", 32'h0001_0022, 1'b1, 4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("lohu", 3'd7, 32'h0000_80FF);

        issue(3'd1, LOST_LOB, 3'd0, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lob byte 0", 32'h0001_0020, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("lob byte 0", 3'd1, 32'h0000_007F);

        issue(3'd2, LOST_LOB, 3'd1, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lob byte 1", 32'h0001_0021, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("lob byte 1", 3'd2, 32'h0000_0001);

        issue(3'd3, LOST_LOBU, 3'd2, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lobu byte 2", 32'h0001_0022, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("lobu byte 2", 3'd3, 32'h0000_00FF);

        issue(3'd4, LOST_LOH, 3'd0, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("loh mitad baja", 32'h0001_0020, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("loh mitad baja", 3'd4, 32'h0000_017F);

        issue(3'd5, LOST_LOHU, 3'd0, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lohu mitad baja", 32'h0001_0020, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("lohu mitad baja", 3'd5, 32'h0000_017F);

        issue(3'd1, LOST_STB, 3'd1, 1'b0, 16'b0,
            32'h0001_0020, 32'h0000_00AA);
        expect_request("stb", 32'h0001_0021, 1'b0, 4'b0010,
            32'h0000_AA00, 1'b0);
        capture_request();
        check_word("stb RAM", memory_words[8], 32'h80FF_AA7F);
        check_word("read_data estable sin lectura", memory_read_data, 32'h80FF_017F);
        expect_no_load("stb");

        issue(3'd1, LOST_STH, 3'd2, 1'b0, 16'b0,
            32'h0001_0020, 32'h0000_1234);
        expect_request("sth", 32'h0001_0022, 1'b0, 4'b1100,
            32'h1234_0000, 1'b0);
        capture_request();
        check_word("sth RAM", memory_words[8], 32'h1234_AA7F);

        // off=-4 ignora el literal; imm=-5 ignora off.
        issue(3'd3, LOST_LOW, 3'b100, 1'b0, 16'h1234,
            32'h0001_0024, 32'b0);
        expect_request("off negativo", 32'h0001_0020, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("off negativo", 3'd3, 32'h1234_AA7F);

        issue(3'd4, LOST_LOW, 3'd3, 1'b1, 16'hFFFB,
            32'h0001_0025, 32'b0);
        expect_request("imm negativo", 32'h0001_0020, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("imm negativo", 3'd4, 32'h1234_AA7F);

        issue(3'd1, LOST_STB, 3'd0, 1'b1, 16'd4,
            32'h0001_001F, 32'h0000_00EE);
        expect_request("stbi", 32'h0001_0023, 1'b0, 4'b1000,
            32'hEE00_0000, 1'b0);
        capture_request();
        check_word("stbi RAM", memory_words[8], 32'hEE34_AA7F);

        issue(3'd4, LOST_LOBU, 3'd0, 1'b1, 16'd4,
            32'h0001_001F, 32'b0);
        expect_request("lobui", 32'h0001_0023, 1'b1,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_load("lobui", 3'd4, 32'h0000_00EE);

        issue(3'd3, LOST_LOW, 3'd1, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("low desalineado", 32'h0001_0021, 1'b0,
            4'b0000, 32'b0, 1'b1);
        capture_request();
        expect_no_load("low desalineado");

        issue(3'd3, LOST_LOH, 3'd1, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("loh desalineado", 32'h0001_0021, 1'b0,
            4'b0000, 32'b0, 1'b1);
        capture_request();
        expect_no_load("loh desalineado");

        issue(3'd3, LOST_LOHU, 3'd1, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("lohu desalineado", 32'h0001_0021, 1'b0,
            4'b0000, 32'b0, 1'b1);
        capture_request();
        expect_no_load("lohu desalineado");

        issue(3'd1, LOST_STW, 3'd1, 1'b0, 16'b0,
            32'h0001_0020, 32'hDEAD_BEEF);
        expect_request("stw desalineado", 32'h0001_0021, 1'b0,
            4'b0000, 32'b0, 1'b1);
        capture_request();
        check_word("RAM tras desalineacion", memory_words[8], 32'hEE34_AA7F);

        issue(3'd1, LOST_STH, 3'd1, 1'b0, 16'b0,
            32'h0001_0020, 32'h0000_BEEF);
        expect_request("sth desalineado", 32'h0001_0021, 1'b0,
            4'b0000, 32'b0, 1'b1);
        capture_request();
        check_word("RAM tras sth desalineado", memory_words[8], 32'hEE34_AA7F);

        issue(3'd1, LOST_STW, 3'd0, 1'b0, 16'b0,
            32'h0001_0020, 32'hDEAD_BEEF);
        nop_flag = 1'b1;
        #1;
        expect_request("NOP", 32'h0001_0020, 1'b0,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        check_word("RAM tras NOP", memory_words[8], 32'hEE34_AA7F);

        issue(3'd1, 4'b1111, 3'd0, 1'b0, 16'b0,
            32'h0001_0020, 32'b0);
        expect_request("funcion reservada", 32'h0001_0020, 1'b0,
            4'b0000, 32'b0, 1'b0);
        capture_request();
        expect_no_load("funcion reservada");

        $display("tb_lost: PASS (%0d comprobaciones)", checks_passed);
        $finish;
    end
endmodule
