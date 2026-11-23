`timescale 1ns/1ps

/** @brief Comprueba datos y bytes con el controlador temporal inactivo. */
module tb_reference_storage;
    import pkg_memory::*;
    cpu_memory_reference #(.MEMORY_BYTES(16)) dut (
        .clk_i(1'b0), .rst_ni(1'b0), .accept_enable_i(1'b0), .req_valid_i(1'b0),
        .req_addr_i(32'b0), .req_write_i(1'b0), .req_wdata_i(32'b0),
        .req_wstrb_i(4'b0), .rsp_ready_i(1'b0)
    );
    cpu_memory_reference #(
        .MEMORY_BYTES(4),
        .INIT_FILE("tests/programs/top/top_data.mem")
    ) initialized (
        .clk_i(1'b0), .rst_ni(1'b0), .accept_enable_i(1'b0), .req_valid_i(1'b0),
        .req_addr_i(32'b0), .req_write_i(1'b0), .req_wdata_i(32'b0),
        .req_wstrb_i(4'b0), .rsp_ready_i(1'b0)
    );

    task automatic expect_word(input address_t address, input word_t expected);
        if (dut.read_word(address) !== expected)
            $fatal(1, "Referencia addr=%h: recibido=%h esperado=%h",
                   address, dut.read_word(address), expected);
    endtask

    initial begin
        #1;
        if (initialized.read_word(DATA_BASE_ADDRESS) !== 32'h12345678)
            $fatal(1, "La imagen de bytes no se cargo con el formato existente");
        expect_word(DATA_BASE_ADDRESS, 32'b0);
        dut.write_word(DATA_BASE_ADDRESS, 32'h80FF017F, 4'b1111);
        expect_word(DATA_BASE_ADDRESS, 32'h80FF017F);
        if ({dut.memory[3], dut.memory[2], dut.memory[1], dut.memory[0]} !== 32'h80FF017F)
            $fatal(1, "Los bytes de referencia no estan en little endian");
        dut.write_word(DATA_BASE_ADDRESS, 32'h00AB0000, 4'b0100);
        expect_word(DATA_BASE_ADDRESS, 32'h80AB017F);
        dut.write_word(DATA_BASE_ADDRESS, 32'hBEEF0000, 4'b1100);
        expect_word(DATA_BASE_ADDRESS, 32'hBEEF017F);
        dut.write_word(DATA_BASE_ADDRESS, 32'hFFFFFFFF, 4'b0000);
        expect_word(DATA_BASE_ADDRESS, 32'hBEEF017F);
        if (!dut.address_valid(DATA_BASE_ADDRESS + 12) ||
            dut.address_valid(DATA_BASE_ADDRESS + 1) ||
            dut.address_valid(DATA_BASE_ADDRESS - 4) ||
            dut.address_valid(DATA_BASE_ADDRESS + 16))
            $fatal(1, "Validacion de rango/alineacion incorrecta");
        dut.write_word(DATA_BASE_ADDRESS + 1, 32'hFFFFFFFF, 4'b1111);
        expect_word(DATA_BASE_ADDRESS, 32'hBEEF017F);
        dut.write_word(DATA_BASE_ADDRESS + 12, 32'h12345678, 4'b1111);
        expect_word(DATA_BASE_ADDRESS + 12, 32'h12345678);
        expect_word(DATA_BASE_ADDRESS + 16, 32'b0);
        $display("tb_reference_storage: PASS");
        $finish;
    end
endmodule
