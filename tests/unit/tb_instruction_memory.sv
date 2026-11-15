`timescale 1ns/1ps

/**
 * @brief Comprueba la frontera registrada de ROM, retencion, errores y reset.
 * @details Usa la imagen existente; el primer bundle es 0x0000000040002024.
 * Los cambios de direccion entre flancos no deben modificar el bundle.
 */
module tb_instruction_memory;
    import pkg_vliw::*;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic read_enable = 1'b0;
    address_t address = '0;
    bundle_t bundle;
    logic access_error;

    always #5 clk = ~clk;

    instruction_memory #(
        .INIT_FILE("tests/programs/top/top_integration.mem"),
        .INIT_BUNDLES(28)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .address_i(address),
        .read_enable_i(read_enable),
        .bundle_o(bundle),
        .out_of_range_o(access_error)
    );

    task automatic check_read(
        input address_t next_address,
        input logic next_enable,
        input bundle_t expected_bundle,
        input logic expected_error
    );
        bundle_t held_bundle;
        @(negedge clk);
        held_bundle = bundle;
        address = next_address;
        read_enable = next_enable;
        #1;
        if (bundle !== held_bundle)
            $fatal(1, "La ROM cambio el bundle antes del flanco de lectura");
        @(posedge clk);
        #1;
        if (bundle !== expected_bundle || access_error !== expected_error)
            $fatal(1, "ROM addr=%08h: bundle=%016h error=%b, esperados=%016h/%b",
                   address, bundle, access_error, expected_bundle, expected_error);
    endtask

    initial begin
        @(negedge clk);
        if (bundle !== '0 || access_error !== 1'b0)
            $fatal(1, "Reset no invalido la salida de ROM");
        rst_n = 1'b1;
        check_read(TEXT_BASE_ADDRESS, 1'b1, 64'h0000000040002024, 1'b0);
        check_read(TEXT_BASE_ADDRESS + BUNDLE_BYTES, 1'b0, 64'h0000000040002024, 1'b0);
        check_read(TEXT_BASE_ADDRESS + BUNDLE_BYTES, 1'b1, '0, 1'b0);
        check_read(TEXT_BASE_ADDRESS + MEMORY_BYTES - BUNDLE_BYTES, 1'b1, '0, 1'b0);
        check_read(TEXT_BASE_ADDRESS + 1, 1'b1, '0, 1'b1);
        check_read(TEXT_BASE_ADDRESS, 1'b0, '0, 1'b0);
        check_read(TEXT_BASE_ADDRESS + MEMORY_BYTES, 1'b1, '0, 1'b1);
        rst_n = 1'b0;
        #1;
        if (bundle !== '0 || access_error !== 1'b0)
            $fatal(1, "Reset no cancelo el diagnostico pendiente");
        rst_n = 1'b1;
        check_read(TEXT_BASE_ADDRESS, 1'b1, 64'h0000000040002024, 1'b0);
        $display("tb_instruction_memory: PASS (lectura, retencion, limites, errores y reset)");
        $finish;
    end
endmodule
