/**
 * @brief Nucleo VLIW con IF/ID, ID/EX, ejecucion y cinco puertos WB.
 *
 * @details Usa diez lecturas del RF corregido: dos por unidad despachada.
 * Todas se capturan en el mismo flanco ID/EX, sin forwarding. Los puertos
 * conservan contratos de memoria explicitos. El wrapper de sistema todavia
 * requiere adaptar su conexion de datos anterior a los handshakes CPU-L1.
 *
 * @input clk_i, rst_ni Reloj y reset activo bajo, sostenido por un posedge.
 * @input instruction_error_i Diagnostico ROM registrado junto con instruction_bundle_i.
 * @input dmem_rsp_origin_i Procedencia de observacion, estable con la respuesta.
 * @output perf_events_o Pulsos y estados CPU-domain; no controla el datapath.
 * @input instruction_bundle_i Lectura ROM registrada del PC solicitado en IF.
 * @input dmem_rsp_rdata_i Palabra completa de respuesta CPU-L1.
 * @input dmem_req_ready_i, dmem_rsp_valid_i, dmem_rsp_error_i Handshakes CPU-L1.
 * @output dmem_req_valid_o, dmem_rsp_ready_o Oferta y disposicion de consumo.
 * @output dmem_error_o Diagnostico de respuesta fallida consumida.
 * @output stop_done_o Pulso previo al ultimo flanco, incluye sus finalizaciones.
 * @output halted_o Parada completa registrada, persistente hasta reset.
 * @output instruction_address_o, instruction_read_enable_o Interfaz IF.
 * @output dmem_req_* Direccion alineada, tipo, store desplazado y mascara CPU-L1.
 * @output authenticated_o Nivel de la boveda; *_error_o y auth_failed_o eventos.
 * @output crypto_event_pc_o, invalid_address_pc_o Procedencia de eventos.
 *
 * @note Controla avance de fronteras, resultados y efectos EX por memoria.
 * El temporizador de autenticacion conserva su cuenta durante la espera.
 * El cierre incluye el ultimo efecto del programa y sus eventos de metricas.
 * Sin traps ni arbitraje de hazards; los errores son diagnosticos para simulacion.
 */
module vliw_processor #(
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] INITIAL_PC = pkg_vliw::RESET_PC
) (
    input logic clk_i,
    input logic rst_ni,
    input logic instruction_error_i,
    input pkg_metrics::demand_origin_t dmem_rsp_origin_i,
    input pkg_vliw::bundle_t instruction_bundle_i,
    input pkg_memory::word_t dmem_rsp_rdata_i,
    input logic dmem_req_ready_i,
    input logic dmem_rsp_valid_i,
    input logic dmem_rsp_error_i,
    output logic dmem_req_valid_o,
    output logic dmem_rsp_ready_o,
    output logic dmem_error_o,
    output logic stop_done_o,
    output logic halted_o,
    output pkg_metrics::cpu_events_t perf_events_o,
    output pkg_vliw::address_t instruction_address_o,
    output logic instruction_read_enable_o,
    output pkg_memory::address_t dmem_req_addr_o,
    output logic dmem_req_write_o,
    output pkg_memory::byte_mask_t dmem_req_wstrb_o,
    output pkg_memory::word_t dmem_req_wdata_o,
    output logic authenticated_o,
    output logic auth_failed_o,
    output logic access_error_o,
    output pkg_vliw::address_t crypto_event_pc_o,
    output logic invalid_address_o,
    output pkg_vliw::address_t invalid_address_pc_o
);
    import pkg_vliw::*;

    bundle_t id_bundle;
    address_t id_pc;
    logic id_valid;
    wire slot_t dispatch_slot [0:NUM_UNITS-1];
    wire slot_t dispatch_imm [0:NUM_UNITS-1];
    wire dispatch_nop [0:NUM_UNITS-1];
    wire reg_index_t read_addr [0:RF_READ_PORTS-1];
    wire word_t read_data [0:RF_READ_PORTS-1];
    issued_op_t ex_operation [0:NUM_UNITS-1];
    wb_channel_t alu0_wb, alu1_wb, load_wb, crypto_left_wb, crypto_right_wb;
    wire write_enable [0:RF_WRITE_PORTS-1];
    wire reg_index_t write_addr [0:RF_WRITE_PORTS-1];
    wire word_t write_data [0:RF_WRITE_PORTS-1];
    logic branch_taken;
    address_t branch_target;
    logic pipeline_advance;
    logic memory_operation_active;
    logic dmem_done;
    logic lsu_read_prepared;
    logic stop_requested_q, stop_fire, stop_admission;
    issued_op_t branch_operation;
    logic halted_q, work_after_advance;
    logic ex_bundle_valid_q, mul_operation;
    bundle_t ex_bundle_q;
    pkg_metrics::event_delta_t wb_operations;
    address_t effective_address;

    /** @brief Conserva validez aun para bundles enteramente NOP, solo para observar. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ex_bundle_valid_q <= 1'b0;
            ex_bundle_q <= '0;
        end else if (pipeline_advance) begin
            ex_bundle_valid_q <= id_valid && !stop_admission;
            ex_bundle_q <= id_bundle;
        end
    end

    core_metrics u_metrics (
        .clk_i(clk_i), .rst_ni(rst_ni), .advance_i(pipeline_advance), .halted_i(halted_q),
        .fetch_active_i(!stop_requested_q && !halted_q), .fetch_transfer_i(instruction_read_enable_o),
        .id_valid_i(id_valid), .id_admit_i(id_valid && pipeline_advance && !stop_admission),
        .id_pc_i(id_pc), .instruction_error_i(instruction_error_i), .stop_admission_i(stop_admission),
        .ex_valid_i(ex_bundle_valid_q), .ex_bundle_i(ex_bundle_q),
        .wb_operations_i(wb_operations), .mul_operation_i(mul_operation),
        .branch_valid_i(branch_operation.valid), .branch_taken_i(branch_taken),
        .memory_active_i(memory_operation_active), .req_valid_i(dmem_req_valid_o),
        .req_ready_i(dmem_req_ready_i), .rsp_valid_i(dmem_rsp_valid_i), .rsp_ready_i(dmem_rsp_ready_o),
        .dmem_done_i(dmem_done), .dmem_error_i(dmem_error_o), .dmem_write_i(dmem_req_write_o),
        .dmem_origin_i(dmem_rsp_origin_i), .alignment_error_i(invalid_address_o),
        .effective_address_i(effective_address), .events_o(perf_events_o)
    );

    /**
     * @brief La operacion sigue activa en EX aunque req_valid baje al aceptar.
     * @details Los enables preparados identifican el acceso alineado retenido.
     * Una desalineacion no solicita memoria y deja avanzar con su diagnostico.
     * Responder con error tambien termina la espera. Reset inhibe el avance.
     */
    assign dmem_req_write_o = |dmem_req_wstrb_o;
    assign memory_operation_active = lsu_read_prepared || dmem_req_write_o;
    assign pipeline_advance = rst_ni && !halted_q && (!memory_operation_active || dmem_done);

    /**
     * @brief Reconoce el marcador solo cuando EX puede completar ese avance.
     * @details stop_fire cierra admision en el propio flanco, antes de registrar
     * la marca persistente. No inhibe ejecucion ni WB del trabajo del programa.
     * Reset habilita nuevamente admision; un salto ordinario no activa la marca.
     */
    assign branch_operation = ex_operation[UNIT_BRUH];
    assign stop_fire = !stop_requested_q && pipeline_advance &&
                       branch_operation.valid && branch_taken &&
                       (branch_target == branch_operation.pc);
    assign stop_admission = stop_requested_q || stop_fire;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            stop_requested_q <= 1'b0;
        end else if (stop_fire) begin
            stop_requested_q <= 1'b1;
        end
    end

    /**
     * @brief Cierra en el propio flanco que consume el ultimo trabajo pendiente.
     * @details Incluye el marcador cuando no deja trabajo futuro y el WB actual
     * cuando se escribe. El entorno puede muestrear stop_done_o para perf_stop.
     * halted_q inhibe avances posteriores; reset cancela ambos estados de parada.
     */
    assign stop_done_o = stop_admission && pipeline_advance && !work_after_advance;
    assign halted_o = halted_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            halted_q <= 1'b0;
        end else if (stop_done_o) begin
            halted_q <= 1'b1;
        end
    end

    fetch_stage #(
        .INITIAL_PC(INITIAL_PC)
    ) u_fetch (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .advance_i(pipeline_advance),
        .stop_i(stop_admission),
        .branch_taken_i(branch_taken),
        .branch_target_i(branch_target),
        .instruction_bundle_i(instruction_bundle_i),
        .instruction_address_o(instruction_address_o),
        .instruction_read_enable_o(instruction_read_enable_o),
        .bundle_o(id_bundle),
        .bundle_pc_o(id_pc),
        .bundle_valid_o(id_valid)
    );

    idd_stage u_idd (
        .bundle_i(id_bundle),
        .alu0_slot_o(dispatch_slot[UNIT_ALU0]),
        .alu0_nop_flag_o(dispatch_nop[UNIT_ALU0]),
        .alu0_imm_o(dispatch_imm[UNIT_ALU0]),
        .alu0_op_a_addr_o(read_addr[2*UNIT_ALU0]),
        .alu0_op_b_addr_o(read_addr[2*UNIT_ALU0+1]),
        .alu1_slot_o(dispatch_slot[UNIT_ALU1]),
        .alu1_nop_flag_o(dispatch_nop[UNIT_ALU1]),
        .alu1_imm_o(dispatch_imm[UNIT_ALU1]),
        .alu1_op_a_addr_o(read_addr[2*UNIT_ALU1]),
        .alu1_op_b_addr_o(read_addr[2*UNIT_ALU1+1]),
        .lsu_slot_o(dispatch_slot[UNIT_LSU]),
        .lsu_nop_flag_o(dispatch_nop[UNIT_LSU]),
        .lsu_imm_o(dispatch_imm[UNIT_LSU]),
        .lsu_op_a_addr_o(read_addr[2*UNIT_LSU]),
        .lsu_op_b_addr_o(read_addr[2*UNIT_LSU+1]),
        .bru_slot_o(dispatch_slot[UNIT_BRUH]),
        .bru_nop_flag_o(dispatch_nop[UNIT_BRUH]),
        .bru_imm_o(dispatch_imm[UNIT_BRUH]),
        .bru_op_a_addr_o(read_addr[2*UNIT_BRUH]),
        .bru_op_b_addr_o(read_addr[2*UNIT_BRUH+1]),
        .crypto_slot_o(dispatch_slot[UNIT_CRYPTO]),
        .crypto_nop_flag_o(dispatch_nop[UNIT_CRYPTO]),
        .crypto_imm_o(dispatch_imm[UNIT_CRYPTO]),
        .crypto_op_a_addr_o(read_addr[2*UNIT_CRYPTO]),
        .crypto_op_b_addr_o(read_addr[2*UNIT_CRYPTO+1])
    );

    register_file u_register_file (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .read_addr_i(read_addr),
        .read_data_o(read_data),
        .write_enable_i(write_enable),
        .write_addr_i(write_addr),
        .write_data_i(write_data)
    );

    /**
     * @brief Frontera ID/EX comun a las cinco unidades.
     * @details Captura operandos previos al WB concurrente. El RF usa NBA:
     * un consumidor necesita emitir despues del flanco que escribe su fuente.
     * El permiso comun retiene instruccion, operandos y PC durante la espera.
     * El marcador cancela ID en su propio avance; despues solo entran burbujas.
     */
    for (genvar unit_index = 0; unit_index < NUM_UNITS; unit_index++) begin : g_issue
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                ex_operation[unit_index] <= '0;
            end else if (pipeline_advance) begin
                if (!stop_admission && id_valid && !dispatch_nop[unit_index]) begin
                    ex_operation[unit_index] <= {
                        1'b1, dispatch_slot[unit_index], dispatch_imm[unit_index],
                        read_data[2*unit_index], read_data[2*unit_index+1], id_pc
                    };
                end else begin
                    ex_operation[unit_index] <= '0;
                end
            end
        end
    end

    execution_stage u_execution (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .advance_i(pipeline_advance),
        /** WB drena y captura en el mismo flanco; no hay cola de salida aparte. */
        .completion_ready_i(rst_ni),
        .dmem_req_ready_i(dmem_req_ready_i),
        .dmem_rsp_valid_i(dmem_rsp_valid_i),
        .dmem_rsp_error_i(dmem_rsp_error_i),
        .dmem_req_valid_o(dmem_req_valid_o),
        .dmem_rsp_ready_o(dmem_rsp_ready_o),
        .dmem_done_o(dmem_done),
        .dmem_error_o(dmem_error_o),
        .work_after_advance_o(work_after_advance),
        .wb_operations_o(wb_operations), .mul_operation_o(mul_operation),
        .memory_effective_address_o(effective_address),
        .alu0_i(ex_operation[UNIT_ALU0]),
        .alu1_i(ex_operation[UNIT_ALU1]),
        .lsu_i(ex_operation[UNIT_LSU]),
        .bruh_i(ex_operation[UNIT_BRUH]),
        .crypto_i(ex_operation[UNIT_CRYPTO]),
        .memory_read_data_i(dmem_rsp_rdata_i),
        .alu0_wb_o(alu0_wb),
        .alu1_wb_o(alu1_wb),
        .load_wb_o(load_wb),
        .crypto_left_wb_o(crypto_left_wb),
        .crypto_right_wb_o(crypto_right_wb),
        .memory_address_o(dmem_req_addr_o),
        .memory_read_enable_o(lsu_read_prepared),
        .memory_write_enable_o(dmem_req_wstrb_o),
        .memory_write_data_o(dmem_req_wdata_o),
        .branch_taken_o(branch_taken),
        .branch_target_o(branch_target),
        .invalid_address_o(invalid_address_o),
        .invalid_address_pc_o(invalid_address_pc_o),
        .authenticated_o(authenticated_o),
        .auth_failed_o(auth_failed_o),
        .access_error_o(access_error_o),
        .crypto_event_pc_o(crypto_event_pc_o)
    );

    writeback_stage u_writeback (
        .rst_ni(rst_ni),
        .advance_i(pipeline_advance),
        .alu0_i(alu0_wb),
        .alu1_i(alu1_wb),
        .load_i(load_wb),
        .crypto_left_i(crypto_left_wb),
        .crypto_right_i(crypto_right_wb),
        .write_enable_o(write_enable),
        .write_addr_o(write_addr),
        .write_data_o(write_data)
    );
endmodule
