/**
 * @brief Nucleo VLIW con IF/ID, ID/EX, ejecucion y cinco puertos WB.
 *
 * @details Usa diez lecturas del RF corregido: dos por unidad despachada.
 * Todas se capturan en el mismo flanco ID/EX, sin forwarding. Los puertos
 * conservan contratos de memoria explicitos; porygon_system los conecta a
 * los modelos de instrucciones y datos de simulacion.
 *
 * @input clk_i, rst_ni Reloj y reset activo bajo, sostenido por un posedge.
 * @input instruction_bundle_i Lectura combinacional del PC presentado.
 * @input data_read_data_i, data_read_valid_i Lectura sincronica de la solicitud
 * LSU anterior y validez de rango para calificar su WB.
 * @output instruction_address_o, instruction_read_enable_o Interfaz IF.
 * @output data_* Interfaz de memoria sincronica con escritura por byte.
 * @output authenticated_o Nivel de la boveda; *_error_o y auth_failed_o eventos.
 * @output crypto_event_pc_o, invalid_address_pc_o Procedencia de eventos.
 *
 * @note No contiene stalls, flush, banderas globales, traps ni arbitraje de
 * hazards. Las salidas de error son diagnosticos para simulacion.
 */
module vliw_processor #(
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] INITIAL_PC = pkg_vliw::RESET_PC
) (
    input logic clk_i,
    input logic rst_ni,
    input pkg_vliw::bundle_t instruction_bundle_i,
    input pkg_vliw::word_t data_read_data_i,
    input logic data_read_valid_i,
    output pkg_vliw::address_t instruction_address_o,
    output logic instruction_read_enable_o,
    output pkg_vliw::address_t data_address_o,
    output logic data_read_enable_o,
    output logic [3:0] data_write_enable_o,
    output pkg_vliw::word_t data_write_data_o,
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

    fetch_stage #(
        .INITIAL_PC(INITIAL_PC)
    ) u_fetch (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
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
     */
    for (genvar unit_index = 0; unit_index < NUM_UNITS; unit_index++) begin : g_issue
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                ex_operation[unit_index] <= '0;
            end else if (id_valid && !dispatch_nop[unit_index]) begin
                ex_operation[unit_index] <= {
                    1'b1, dispatch_slot[unit_index], dispatch_imm[unit_index],
                    read_data[2*unit_index], read_data[2*unit_index+1], id_pc
                };
            end else begin
                ex_operation[unit_index] <= '0;
            end
        end
    end

    execution_stage u_execution (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .alu0_i(ex_operation[UNIT_ALU0]),
        .alu1_i(ex_operation[UNIT_ALU1]),
        .lsu_i(ex_operation[UNIT_LSU]),
        .bruh_i(ex_operation[UNIT_BRUH]),
        .crypto_i(ex_operation[UNIT_CRYPTO]),
        .memory_read_data_i(data_read_data_i),
        .memory_read_valid_i(data_read_valid_i),
        .alu0_wb_o(alu0_wb),
        .alu1_wb_o(alu1_wb),
        .load_wb_o(load_wb),
        .crypto_left_wb_o(crypto_left_wb),
        .crypto_right_wb_o(crypto_right_wb),
        .memory_address_o(data_address_o),
        .memory_read_enable_o(data_read_enable_o),
        .memory_write_enable_o(data_write_enable_o),
        .memory_write_data_o(data_write_data_o),
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
