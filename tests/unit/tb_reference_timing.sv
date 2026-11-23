`timescale 1ns/1ps

/** @brief Verifica E1/EN, backpressure, campos retenidos, stores unicos y reset. */
module tb_reference_timing;
    import pkg_memory::*;
    parameter integer RESPONSE_CYCLES = 1;
    logic clk = 0, rst_n = 0, accept_enable = 0, req_valid = 0;
    logic req_ready, req_write = 0, rsp_valid, rsp_ready = 0, rsp_error;
    address_t req_addr = DATA_BASE_ADDRESS;
    word_t req_wdata = 32'h00AB0000, rsp_rdata;
    byte_mask_t req_wstrb = 4'b0100;
    always #5 clk = !clk;
    cpu_memory_reference #(.MEMORY_BYTES(16), .RESPONSE_CYCLES(RESPONSE_CYCLES)) dut (
        .clk_i(clk), .rst_ni(rst_n), .accept_enable_i(accept_enable),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_addr_i(req_addr),
        .req_write_i(req_write), .req_wdata_i(req_wdata), .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
        .rsp_rdata_o(rsp_rdata), .rsp_error_o(rsp_error)
    );

    /** @brief Muestrea antes del flanco; cambia campos solo despues de aceptar. */
    task automatic transact(input logic write_access, input address_t address,
                            input logic expected_error, input word_t expected_data);
        req_write = write_access;
        req_addr = address;
        req_wdata = 32'h00AB0000;
        req_wstrb = write_access ? 4'b0100 : 4'b0000;
        req_valid = 1;
        rsp_ready = 0;
        for (integer edge_index = 1; edge_index <= RESPONSE_CYCLES; edge_index++) begin
            #1;
            if (rsp_valid !== (edge_index == RESPONSE_CYCLES))
                $fatal(1, "Latencia %0d: respuesta fuera de E%0d", RESPONSE_CYCLES, edge_index);
            if (edge_index == RESPONSE_CYCLES &&
                (rsp_error !== expected_error || rsp_rdata !== expected_data))
                $fatal(1, "Respuesta incorrecta: error=%b dato=%h", rsp_error, rsp_rdata);
            if (edge_index > 1 && req_ready)
                $fatal(1, "Aceptacion habilitada con una demanda pendiente");
            if (write_access && !expected_error && dut.read_word(DATA_BASE_ADDRESS) !== 32'h12345678)
                $fatal(1, "Store aplicado antes del flanco de servicio");
            @(posedge clk);
            #1;
            req_valid = 0;
            req_write = !write_access;
            req_addr = DATA_BASE_ADDRESS + 12;
            req_wdata = '1;
            req_wstrb = '1;
            @(negedge clk);
        end
        if (write_access && !expected_error) begin
            if (dut.read_word(DATA_BASE_ADDRESS) !== 32'h12AB5678)
                $fatal(1, "No se aplicaron direccion/dato/mascara aceptados");
            /** Un cambio de prueba permite detectar si se repite el store retenido. */
            dut.write_word(DATA_BASE_ADDRESS, 32'h55667788, 4'b1111);
        end
        repeat (3) begin
            #1;
            if (!rsp_valid || req_ready || rsp_error !== expected_error || rsp_rdata !== expected_data)
                $fatal(1, "Respuesta retenida inestable");
            @(posedge clk);
            #1;
            if (dut.read_word(DATA_BASE_ADDRESS) !== 32'h55667788)
                $fatal(1, "Store repetido o acceso erroneo modifico memoria");
            @(negedge clk);
        end
        rsp_ready = 1;
        @(posedge clk);
        #1;
        if (rsp_valid || !req_ready) $fatal(1, "Respuesta no se libero al consumir");
        @(negedge clk);
    endtask

    initial begin
        #1;
        dut.write_word(DATA_BASE_ADDRESS, 32'h12345678, 4'b1111);
        @(negedge clk);
        rst_n = 1;
        req_valid = 1;
        repeat (2) begin
            #1;
            if (req_ready || rsp_valid) $fatal(1, "Se acepto durante bloqueo de entrada");
            @(negedge clk);
        end
        accept_enable = 1;
        transact(1, DATA_BASE_ADDRESS, 0, 0);
        transact(0, DATA_BASE_ADDRESS, 0, 32'h55667788);
        transact(1, DATA_BASE_ADDRESS + 16, 1, 0);
        req_valid = 1;
        /** E1 ya termina el store: alli se cancela una lectura retenida. */
        req_write = (RESPONSE_CYCLES > 1);
        req_addr = DATA_BASE_ADDRESS;
        rsp_ready = 0;
        @(posedge clk);
        #1;
        rst_n = 0;
        req_valid = 0;
        #1;
        if (req_ready || rsp_valid) $fatal(1, "Reset no inhibio los canales");
        @(negedge clk);
        rst_n = 1;
        repeat (RESPONSE_CYCLES + 1) begin
            @(posedge clk);
            #1;
            if (rsp_valid) $fatal(1, "Respuesta anterior al reset reaparecio");
            if (dut.read_word(DATA_BASE_ADDRESS) !== 32'h55667788)
                $fatal(1, "Reset borro datos o no cancelo un store pendiente");
        end
        $display("tb_reference_timing: PASS E%0d", RESPONSE_CYCLES);
        $finish;
    end
endmodule
