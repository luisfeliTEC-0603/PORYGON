`timescale 1ns/1ps

/**
 * @brief Ejecuta la imagen existente del sistema contra la referencia CPU-L1.
 * @details Dos pasadas: aceptacion inmediata y bloqueo inicial de dos ciclos.
 * El tiempo se mide en flancos reales desde cada aceptacion, incluyendo E1.
 * Compara efectos arquitectonicos y prohíbe escrituras RF durante stalls.
 * Verifica cierre exacto con marcador, load/MUL, ALU, error CRYPTO y stores.
 */
module tb_core_reference;
    import pkg_vliw::*;
    parameter integer RESPONSE_CYCLES = 1;
    logic clk = 0, rst_n = 0, accept_enable = 0;
    logic req_valid, req_ready, req_write, rsp_valid, rsp_ready, rsp_error, memory_error;
    logic read_enable;
    logic stop_done, halted, crypto_error, closing_crypto_error;
    address_t pc, req_addr, stopped_pc;
    word_t req_wdata, rsp_rdata;
    pkg_memory::byte_mask_t req_wstrb;
    bundle_t bundle;
    integer cycles, advances, requests, responses, accepted_at, errors;
    integer stop_pulses, closed_at, marker_cycle, expected_close, expected_accesses;
    always #5 clk = ~clk;

    vliw_processor dut (
        .clk_i(clk), .rst_ni(rst_n), .instruction_bundle_i(bundle),
        .dmem_req_valid_o(req_valid), .dmem_req_ready_i(req_ready),
        .dmem_req_addr_o(req_addr), .dmem_req_write_o(req_write),
        .dmem_req_wdata_o(req_wdata), .dmem_req_wstrb_o(req_wstrb),
        .dmem_rsp_valid_i(rsp_valid), .dmem_rsp_ready_o(rsp_ready),
        .dmem_rsp_rdata_i(rsp_rdata), .dmem_rsp_error_i(rsp_error),
        .dmem_error_o(memory_error), .instruction_address_o(pc),
        .stop_done_o(stop_done), .halted_o(halted), .access_error_o(crypto_error),
        .instruction_read_enable_o(read_enable)
    );
    instruction_memory #(.MEMORY_BYTES(512), .INIT_BUNDLES(28),
        .INIT_FILE("tests/programs/top/top_integration.mem")) rom (
        .clk_i(clk), .rst_ni(rst_n), .address_i(pc),
        .read_enable_i(read_enable), .bundle_o(bundle)
    );
    cpu_memory_reference #(.MEMORY_BYTES(8), .RESPONSE_CYCLES(RESPONSE_CYCLES)) memory (
        .clk_i(clk), .rst_ni(rst_n), .accept_enable_i(accept_enable),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_addr_i(req_addr),
        .req_write_i(req_write), .req_wdata_i(req_wdata), .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
        .rsp_rdata_o(rsp_rdata), .rsp_error_o(rsp_error)
    );

    /** @brief Muestrea handshakes y habilitadores RF antes del flanco efectivo. */
    always @(posedge clk) begin
        if (!rst_n) begin
            {cycles, advances, requests, responses, errors, stop_pulses, closed_at} = '0;
        end else begin
            cycles++;
            if (dut.pipeline_advance) advances++;
            if (req_valid && req_ready) begin
                requests++;
                accepted_at = cycles;
            end
            if (rsp_valid && rsp_ready) begin
                if (cycles - accepted_at + 1 != RESPONSE_CYCLES || !dut.pipeline_advance)
                    $fatal(1, "Respuesta fuera de E%0d o nucleo sin avance", RESPONSE_CYCLES);
                responses++;
            end
            if (memory_error) errors++;
            if (stop_done) begin
                stop_pulses++;
                closed_at = cycles;
                closing_crypto_error = crypto_error;
            end
            for (integer port_index = 0; port_index < RF_WRITE_PORTS; port_index++) begin
                if (!dut.pipeline_advance && dut.write_enable[port_index])
                    $fatal(1, "Escritura RF durante stall");
            end
        end
    end

    initial begin
        #1;
        for (integer run = 0; run < 2; run++) begin
            rst_n = 0;
            accept_enable = (run == 0);
            memory.write_word(DATA_BASE_ADDRESS, 32'h12345678, 4'b1111);
            memory.write_word(DATA_BASE_ADDRESS + 4, 32'b0, 4'b1111);
            @(negedge clk);
            rst_n = 1;
            if (run == 1) begin
                wait (req_valid);
                repeat (3) @(negedge clk);
                accept_enable = 1;
            end
            wait (advances == 45);
            @(negedge clk);
            if (requests != 6 || responses != 6 || errors != 1)
                $fatal(1, "Accesos repetidos/perdidos: req=%0d rsp=%0d err=%0d", requests, responses, errors);
            if (dut.u_register_file.registers_q[3] !== 32'h12345678 ||
                dut.u_register_file.registers_q[4] !== 32'h12347878 ||
                dut.u_register_file.registers_q[6] !== 32'd3 ||
                dut.u_register_file.registers_q[7] !== 32'h2223)
                $fatal(1, "Estado RF final incorrecto para la imagen top_integration");
            if (memory.read_word(DATA_BASE_ADDRESS + 4) !== 32'h12347878)
                $fatal(1, "Stores o mascara little endian incorrectos");
        end
        /** Marcador en PC=48: las instrucciones en ID/IF intentarian alterar RF/RAM. */
        for (integer mode = 0; mode < 6; mode++) begin
            rst_n = 0;
            accept_enable = 0;
            for (integer index = 6; index < 64; index++) begin
                rom.memory[index] = '0;
            end
            case (mode)
            /** Marcador sin operaciones adicionales. */
            0: rom.memory[6] = 64'h2;
            /** Load y producto comparten el bundle de terminacion. */
            1: rom.memory[6] =
                {16'd3, {3'd1, 3'd0, MATH_MUL, 1'b1, 1'b1, OPCODE_MATH},
                 {3'd3, 3'd1, LOST_LOW, 3'b000, 1'b0, OPCODE_LOST}, 16'h0002};
            /** MOV r2, 7 termina en el siguiente WB. */
            2: rom.memory[6] = {16'b0, 16'd7, {3'd2, 3'd0, MATH_MOV, 1'b0, 1'b1, OPCODE_MATH}, 16'h0002};
            /** WRITE sin autenticacion deja un diagnostico registrado. */
            3: rom.memory[6] = {32'b0, 16'h0083, 16'h0002};
            /** Store alineado a base+4, con literal de desplazamiento. */
            4: rom.memory[6] = {16'b0, 16'd4, {3'd3, 3'd1, LOST_STW, 3'b000, 1'b1, OPCODE_LOST}, 16'h0002};
            /** Load desde r0: direccion fuera del segmento de datos. */
            5: rom.memory[6] = {32'b0, {3'd3, 3'd0, LOST_LOW, 3'b000, 1'b0, OPCODE_LOST}, 16'h0002};
            endcase
            expected_accesses = (mode == 1 || mode == 4 || mode == 5);
            rom.memory[7] = {32'b0, 16'h5555, 16'hE024};
            rom.memory[8] = {48'b0, {3'd3, 3'd1, LOST_STW, 3'b000, 1'b0, OPCODE_LOST}};
            repeat (2) @(negedge clk);
            rst_n = 1;
            wait (dut.branch_operation.valid);
            @(negedge clk);
            if (expected_accesses) begin
                repeat (2) begin
                    @(posedge clk);
                    #1;
                    if (dut.stop_requested_q || dut.stop_fire || stop_done || halted)
                        $fatal(1, "El marcador se ejecuto antes de completar memoria");
                end
                @(negedge clk);
                accept_enable = 1;
            end
            wait (dut.stop_fire);
            #1;
            if (read_enable) $fatal(1, "Fetch habilitado en el flanco del marcador");
            marker_cycle = cycles + 1;
            expected_close = marker_cycle + ((mode == 1) ? 3 : ((mode == 2 || mode == 3) ? 1 : 0));
            @(posedge clk);
            #1;
            stopped_pc = pc;
            if (!dut.stop_requested_q || dut.id_valid || read_enable)
                $fatal(1, "La parada no cancelo fetch/ID en el flanco del marcador");
            for (integer unit_index = 0; unit_index < NUM_UNITS; unit_index++) begin
                if (dut.ex_operation[unit_index] !== '0)
                    $fatal(1, "Un slot posterior al marcador entro a EX");
            end
            wait (halted);
            #1;
            if (closed_at != expected_close || stop_pulses != 1 || stop_done || dut.pipeline_advance)
                $fatal(1, "Cierre modo=%0d en ciclo=%0d esperado=%0d pulsos=%0d", mode, closed_at, expected_close, stop_pulses);
            if (mode == 2 && dut.u_register_file.registers_q[2] !== 32'd7)
                $fatal(1, "Cierre anterior al ultimo WB de ALU");
            if (mode == 3 && !closing_crypto_error)
                $fatal(1, "Cierre no incluyo el diagnostico CRYPTO");
            if (mode == 4 && memory.read_word(DATA_BASE_ADDRESS + 4) !== '0)
                $fatal(1, "Cierre anterior a completar store");
            if (!dut.stop_requested_q || pc !== stopped_pc || read_enable ||
                requests != expected_accesses || responses != expected_accesses || errors != (mode == 5) ||
                dut.u_register_file.registers_q[7] !== '0)
                $fatal(1, "Trabajo posterior al marcador produjo efectos o reabrio fetch");
            if (mode == 1 && (dut.u_register_file.registers_q[1] !== 32'h30000 ||
                dut.u_register_file.registers_q[3] !== 32'h12345678))
                $fatal(1, "Load/MUL del marcador no completaron durante el drenaje");
            if (memory.read_word(DATA_BASE_ADDRESS) !== 32'h12345678)
                $fatal(1, "Un store posterior al marcador modifico memoria");
            repeat (2) @(posedge clk);
            #1;
            if (!halted || stop_done || stop_pulses != 1 || read_enable)
                $fatal(1, "La parada completa no se mantuvo hasta reset");
        end
        $display("tb_core_reference: PASS E%0d, aceptacion y cierre exacto", RESPONSE_CYCLES);
        $finish;
    end
    initial begin
        #20000;
        $fatal(1, "Timeout tb_core_reference");
    end
endmodule
