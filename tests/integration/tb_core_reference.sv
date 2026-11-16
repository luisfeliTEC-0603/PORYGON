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
    localparam integer ORIGIN = (RESPONSE_CYCLES == 1) ? pkg_metrics::ORIGIN_L1 :
                               (RESPONSE_CYCLES == 9) ? pkg_metrics::ORIGIN_L2 : pkg_metrics::ORIGIN_MEMORY;
    pkg_metrics::cpu_events_t events;
    pkg_metrics::demand_origin_t origin;
    logic rom_error;
    localparam logic [127:0] PASSWORD = 128'h146317BBDA48DB07A9A67018DFF0F76A;
    localparam slot_t FEISTEL = {3'd3, 3'd4, CRYPTO_FEISTEL, 5'b0, OPCODE_CRYPTO};
    localparam slot_t MUL = {3'd6, 3'd0, MATH_MUL, 1'b1, 1'b1, OPCODE_MATH};
    logic clk = 0, rst_n = 0, accept_enable = 0;
    logic req_valid, req_ready, req_write, rsp_valid, rsp_ready, rsp_error, memory_error;
    logic read_enable;
    logic authenticated;
    logic stop_done, halted, crypto_error, closing_crypto_error;
    address_t pc, req_addr, stopped_pc;
    word_t req_wdata, rsp_rdata;
    pkg_memory::byte_mask_t req_wstrb;
    bundle_t bundle;
    integer cycles, advances, requests, responses, accepted_at, errors;
    integer stop_pulses, closed_at, marker_cycle, expected_close, expected_accesses;
    integer rf_writes [0:RF_WRITE_PORTS-1];
    integer vault_writes;
    integer total_bundles, total_instructions, total_nops, total_literals, begins, completed_demands;
    integer branch_completions, delay_cycles, wait_accept, wait_miss, wait_response;
    integer instruction_errors, alignment_errors;
    address_t last_instruction_address, last_alignment_address;
    issued_op_t held_ex [0:NUM_UNITS-1];
    logic [5*$bits(wb_channel_t)-1:0] held_wb;
    logic [BUNDLE_WIDTH+2*ADDR_WIDTH:0] held_fetch;
    logic [ADDR_WIDTH+DATA_WIDTH+$bits(pkg_memory::byte_mask_t):0] held_request;
    always #5 clk = ~clk;

    /** @brief Compara fronteras completas antes/despues de cada flanco congelado. */
    always @(posedge clk) begin
        if (rst_n && dut.memory_operation_active && !dut.pipeline_advance) begin
            held_fetch = {pc, dut.id_pc, dut.id_valid, bundle};
            held_wb = {dut.alu0_wb, dut.alu1_wb, dut.load_wb, dut.crypto_left_wb, dut.crypto_right_wb};
            held_request = {req_addr, req_wdata, req_wstrb, req_write};
            for (integer index = 0; index < NUM_UNITS; index++) begin
                held_ex[index] = dut.ex_operation[index];
            end
            #1;
            if (rst_n) begin
                if ({pc, dut.id_pc, dut.id_valid, bundle} !== held_fetch ||
                    {dut.alu0_wb, dut.alu1_wb, dut.load_wb, dut.crypto_left_wb, dut.crypto_right_wb} !== held_wb ||
                    {req_addr, req_wdata, req_wstrb, req_write} !== held_request)
                    $fatal(1, "Stall altero fetch, WB o campos de solicitud");
                for (integer index = 0; index < NUM_UNITS; index++) begin
                    if (dut.ex_operation[index] !== held_ex[index])
                        $fatal(1, "Stall altero instruccion/operandos/PC en unidad %0d", index);
                end
            end
        end
    end

    vliw_processor dut (
        .clk_i(clk), .rst_ni(rst_n), .instruction_bundle_i(bundle),
        .instruction_error_i(rom_error), .dmem_rsp_origin_i(origin), .perf_events_o(events),
        .dmem_req_valid_o(req_valid), .dmem_req_ready_i(req_ready),
        .dmem_req_addr_o(req_addr), .dmem_req_write_o(req_write),
        .dmem_req_wdata_o(req_wdata), .dmem_req_wstrb_o(req_wstrb),
        .dmem_rsp_valid_i(rsp_valid), .dmem_rsp_ready_o(rsp_ready),
        .dmem_rsp_rdata_i(rsp_rdata), .dmem_rsp_error_i(rsp_error),
        .dmem_error_o(memory_error), .instruction_address_o(pc),
        .stop_done_o(stop_done), .halted_o(halted), .access_error_o(crypto_error),
        .authenticated_o(authenticated),
        .instruction_read_enable_o(read_enable)
    );
    instruction_memory #(.MEMORY_BYTES(512), .INIT_BUNDLES(28),
        .INIT_FILE("tests/programs/top/top_integration.mem")) rom (
        .clk_i(clk), .rst_ni(rst_n), .address_i(pc),
        .read_enable_i(read_enable), .bundle_o(bundle), .out_of_range_o(rom_error)
    );
    cpu_memory_reference #(.MEMORY_BYTES(16), .RESPONSE_CYCLES(RESPONSE_CYCLES), .RESPONSE_ORIGIN(ORIGIN)) memory (
        .clk_i(clk), .rst_ni(rst_n), .accept_enable_i(accept_enable),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_addr_i(req_addr),
        .req_write_i(req_write), .req_wdata_i(req_wdata), .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
        .rsp_rdata_o(rsp_rdata), .rsp_error_o(rsp_error), .rsp_origin_o(origin)
    );

    /** @brief Muestrea handshakes y habilitadores RF antes del flanco efectivo. */
    always @(posedge clk) begin
        if (!rst_n) begin
            {cycles, advances, requests, responses, errors, stop_pulses, closed_at, vault_writes} = '0;
            {total_bundles, total_instructions, total_nops, total_literals, begins, completed_demands} = '0;
            {branch_completions, delay_cycles, wait_accept, wait_miss, wait_response} = '0;
            {instruction_errors, alignment_errors, last_instruction_address, last_alignment_address} = '0;
            for (integer port_index = 0; port_index < RF_WRITE_PORTS; port_index++) begin
                rf_writes[port_index] = 0;
            end
        end else begin
            cycles++;
            if (events.instruction_error.valid) begin
                instruction_errors++;
                last_instruction_address = events.instruction_error.address;
            end
            if (events.alignment_error.valid) begin
                alignment_errors++;
                last_alignment_address = events.alignment_error.address;
            end
            total_bundles += events.done_bundles;
            total_instructions += events.done_instructions;
            total_nops += events.done_nop_slots;
            total_literals += events.done_literal_slots;
            begins += int'(events.dmem_begin);
            completed_demands += int'(events.dmem_done);
            branch_completions += int'(events.branch_done);
            delay_cycles += int'(events.branch_delay);
            case (events.wait_reason)
                pkg_metrics::WAIT_ACCEPT: wait_accept++;
                pkg_metrics::WAIT_MISS: wait_miss++;
                pkg_metrics::WAIT_RESPONSE: wait_response++;
                default: begin end
            endcase
            if (events.stall && (events.stage_transfers != '0 || events.done_instructions != 0))
                $fatal(1, "Metricas contaron avances o instrucciones durante stall");
            if (events.dmem_done && !memory_error && events.dmem_origin !== origin)
                $fatal(1, "Procedencia incorrecta al completar demanda");
            if (memory_error && (!events.dmem_error || events.dmem_origin !== pkg_metrics::ORIGIN_ERROR))
                $fatal(1, "Respuesta fallida no emitio evento de error unico");
            if (halted && events !== '0) $fatal(1, "Eventos despues de stop_done");
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
            if (dut.u_execution.u_crypto.u_key_vault.write_commit) vault_writes++;
            if (stop_done) begin
                stop_pulses++;
                closed_at = cycles;
                closing_crypto_error = crypto_error;
            end
            for (integer port_index = 0; port_index < RF_WRITE_PORTS; port_index++) begin
                if (dut.write_enable[port_index]) rf_writes[port_index]++;
                if (!dut.pipeline_advance && dut.write_enable[port_index])
                    $fatal(1, "Escritura RF durante stall");
            end
        end
    end

    /** @brief Feistel en WB y MUL en EX1 sobreviven al load y al WRITE retenidos. */
    task automatic check_crypto_hold;
        if (!authenticated || dut.u_execution.u_crypto.u_key_vault.auth_timer_q !== 32 ||
            dut.u_execution.u_crypto.u_key_vault.keys_q[0][0] !== '0 ||
            dut.crypto_left_wb !== {1'b1, 3'd3, 32'd0, 32'd240, FEISTEL} ||
            dut.crypto_right_wb !== {1'b1, 3'd4, 32'd1, 32'd240, FEISTEL} ||
            dut.u_execution.mul_tag1_q.pc !== 32'd240 ||
            dut.u_execution.mul_tag1_q.instruction !== MUL)
            $fatal(1, "La espera altero sesion, llave o resultados/procedencia pendientes");
    endtask

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
            if (total_bundles != 43 || total_instructions != 17 || total_literals != 11 || total_nops != 144 ||
                begins != 6 || completed_demands != 6 || branch_completions != 2 || delay_cycles != 4 ||
                wait_accept != 2*run || wait_miss != 6*(RESPONSE_CYCLES-1) || wait_response != 0)
                $fatal(1, "Metricas imagen: b=%0d i=%0d n=%0d l=%0d inicio=%0d fin=%0d saltos=%0d delay=%0d wait=%0d/%0d/%0d", total_bundles, total_instructions, total_nops, total_literals, begins, completed_demands, branch_completions, delay_cycles, wait_accept, wait_miss, wait_response);
        end
        /** Marcador en PC=48: las instrucciones en ID/IF intentarian alterar RF/RAM. */
        for (integer mode = 0; mode < 8; mode++) begin
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
            /** Destinos r0 cuentan y conservan su latencia aunque no escriban RF. */
            6: rom.memory[6] = {16'b0, 16'd7, {3'd0, 3'd0, MATH_MOV, 1'b0, 1'b1, OPCODE_MATH}, 16'h0002};
            7: rom.memory[6] = {16'b0, 16'd3, {3'd0, 3'd0, MATH_MUL, 1'b1, 1'b1, OPCODE_MATH}, 16'h0002};
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
            expected_close = marker_cycle + ((mode == 1 || mode == 7) ? 3 : ((mode == 2 || mode == 3 || mode == 6) ? 1 : 0));
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
            if (total_bundles != 7 || total_instructions != 3 + (mode != 0) + (mode == 1) ||
                total_literals != 2 + (mode == 1 || mode == 2 || mode == 4 || mode >= 6) ||
                total_bundles*NUM_SLOTS != total_instructions + total_nops + total_literals ||
                begins != expected_accesses || completed_demands != expected_accesses ||
                branch_completions != 1 || delay_cycles != 0)
                $fatal(1, "Se contaron bundles cancelados o se perdio una finalizacion del cierre");
            if (dut.u_register_file.registers_q[0] !== '0)
                $fatal(1, "Una finalizacion r0 modifico su valor arquitectonico");
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
        /** Credenciales via LSU y LOPW; todos los efectos pasan por el RTL real. */
        rst_n = 0;
        for (integer index = 6; index < 64; index++) begin
            rom.memory[index] = '0;
        end
        for (integer index = 0; index < 4; index++) begin
            memory.write_word(DATA_BASE_ADDRESS + 4*index, PASSWORD[32*index +: 32], 4'b1111);
            rom.memory[6+5*index] = {32'b0, 16'(4*index),
                {3'd2, 3'd1, LOST_LOW, 3'b0, 1'b1, OPCODE_LOST}};
            rom.memory[9+5*index] = {48'b0,
                {3'd2, 3'd0, CRYPTO_LOPW, 2'(index), 3'b0, OPCODE_CRYPTO}};
        end
        rom.memory[26] = 64'h3;
        rom.memory[27] = {16'd7, {3'd6, 3'd0, MATH_MOV, 1'b1, 1'b1, OPCODE_MATH},
                         16'd1, {3'd3, 3'd0, MATH_MOV, 1'b0, 1'b1, OPCODE_MATH}};
        rom.memory[29] = {48'b0, {3'd0, 3'd0, CRYPTO_FEISTEL, 5'b0, OPCODE_CRYPTO}};
        rom.memory[30] = {16'b0, FEISTEL, 16'd3, MUL};
        rom.memory[31] = {32'b0, {3'd6, 3'd0, CRYPTO_WRITE, 5'b0, OPCODE_CRYPTO},
                         {3'd5, 3'd1, LOST_LOW, 3'b0, 1'b0, OPCODE_LOST}};
        rom.memory[32] = 64'h2;
        repeat (2) @(negedge clk);
        accept_enable = 1;
        rst_n = 1;
        wait (authenticated);
        @(negedge clk);
        accept_enable = 0;
        wait (req_valid);
        repeat (3) begin
            @(posedge clk);
            #1;
            check_crypto_hold();
        end
        @(negedge clk);
        accept_enable = 1;
        wait (rsp_valid);
        #1;
        check_crypto_hold();
        wait (halted);
        #1;
        if (requests != 5 || responses != 5 || errors || crypto_error ||
            dut.u_register_file.registers_q[3] !== 0 || dut.u_register_file.registers_q[4] !== 1 ||
            dut.u_register_file.registers_q[5] !== 32'hDFF0F76A ||
            dut.u_register_file.registers_q[6] !== 21 ||
            dut.u_execution.u_crypto.u_key_vault.keys_q[0][0] !== 7)
            $fatal(1, "Feistel/MUL/WRITE/load no completaron correctamente al reanudar");
        if (rf_writes[WB_ALU0] != 2 || rf_writes[WB_ALU1] != 3 || rf_writes[WB_LSU] != 5 ||
            rf_writes[WB_CRYPTO_L] != 1 || rf_writes[WB_CRYPTO_R] != 1 || vault_writes != 1)
            $fatal(1, "Resultados RF o efecto de boveda repetidos/perdidos");
        if (total_bundles != 33 || total_instructions != 19 || total_nops != 104 || total_literals != 9 ||
            begins != 5 || completed_demands != 5 || branch_completions != 1)
            $fatal(1, "Metricas CRYPTO/MUL: b=%0d i=%0d n=%0d l=%0d", total_bundles, total_instructions, total_nops, total_literals);
        /** Reset con EX1 y WB retenidos: E1 bloquea oferta; E9/E48 cancelan demanda aceptada. */
        rst_n = 0;
        repeat (2) @(negedge clk);
        rst_n = 1;
        wait (authenticated);
        @(negedge clk);
        accept_enable = 0;
        wait (req_valid);
        @(negedge clk);
        if (RESPONSE_CYCLES > 1) begin
            accept_enable = 1;
            @(posedge clk);
            #1;
        end
        rst_n = 0;
        rom.memory[0] = 64'h2;
        repeat (2) @(negedge clk);
        rst_n = 1;
        accept_enable = 1;
        wait (halted);
        repeat (RESPONSE_CYCLES + 1) @(posedge clk);
        #1;
        if (requests || responses || errors || authenticated || crypto_error ||
            req_valid || rsp_valid ||
            dut.u_register_file.registers_q[3] !== '0 ||
            dut.u_register_file.registers_q[4] !== '0 || dut.u_register_file.registers_q[6] !== '0 ||
            dut.u_execution.u_crypto.u_key_vault.keys_q[0][0] !== '0)
            $fatal(1, "Reset no cancelo la demanda o reaparecieron efectos antiguos");
        if (total_bundles != 1 || total_instructions != 1 || total_nops != 3 || total_literals != 0 ||
            begins != 0 || completed_demands != 0)
            $fatal(1, "Reset no cancelo metadatos/eventos anteriores");
        /** Desalineacion local: diagnostico y cierre sin solicitar memoria. */
        rst_n = 0;
        rom.memory[0] = 64'h40002024;
        for (integer index = 6; index < 64; index++) begin
            rom.memory[index] = '0;
        end
        rom.memory[6] = {32'b0, {3'd3, 3'd1, LOST_LOW, 3'd1, 1'b0, OPCODE_LOST}, 16'h0002};
        repeat (2) @(negedge clk);
        rst_n = 1;
        wait (halted);
        #1;
        if (alignment_errors != 1 || last_alignment_address !== DATA_BASE_ADDRESS+1 ||
            requests || begins || completed_demands || total_instructions != 4)
            $fatal(1, "Acceso desalineado llego a memoria o perdio diagnostico/finalizacion");
        /** Error ROM de ID retenido mientras la segunda demanda congela EX. */
        rst_n = 0;
        rom.memory[6] = {32'b0, 16'h1000, {3'd7, 3'd0, MATH_MOV, 1'b0, 1'b1, OPCODE_MATH}};
        rom.memory[9] = {48'b0, {3'd7, 8'b0, JUMP_JR, 1'b0, OPCODE_JUMP}};
        rom.memory[10] = {48'b0, {3'd3, 3'd1, LOST_LOW, 3'b0, 1'b0, OPCODE_LOST}};
        rom.memory[11] = {48'b0, {3'd4, 3'd1, LOST_LOW, 3'b0, 1'b0, OPCODE_LOST}};
        repeat (2) @(negedge clk);
        rst_n = 1;
        wait (requests == 1);
        @(negedge clk);
        accept_enable = 0;
        wait (req_valid);
        repeat (2) @(posedge clk);
        #1;
        if (instruction_errors || events.instruction_error.valid)
            $fatal(1, "Error ROM emitido antes de admitir el bundle retenido");
        @(negedge clk);
        accept_enable = 1;
        wait (events.instruction_error.valid);
        @(posedge clk);
        #1;
        if (instruction_errors != 1 || last_instruction_address !== 32'h1000 || responses != 2)
            $fatal(1, "Error ROM retenido no conservo PC o se emitio mas de una vez");
        rst_n = 0;
        $display("tb_core_reference: PASS E%0d, efectos, metricas, reset y diagnosticos", RESPONSE_CYCLES);
        $finish;
    end
    initial begin
        #20000;
        $fatal(1, "Timeout tb_core_reference");
    end
endmodule
