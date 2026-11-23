/**
 * @brief Integra unidades funcionales a partir de la frontera ID/EX.
 *
 * @details ALU0 conserva su resultado durante stalls; LOST captura el canal completo al
 * avanzar; CRYPTO conserva crypto_wb como unica frontera local, con sus tags.
 * Los PC e instrucciones se registran en paralelo a los datos de cada unidad.
 * BRUH permanece combinacional y fetch aplica su decision en issue+1.
 *
 * @input clk_i, rst_ni Reloj y reset comun; mantener reset por un posedge.
 * @input alu0_i, alu1_i, lsu_i, bruh_i, crypto_i Operaciones capturadas en ID/EX.
 * @input memory_read_data_i Palabra completa de respuesta CPU-L1.
 * @input advance_i Avance comun de resultados/tags y aceptacion CRYPTO.
 * @input completion_ready_i Capacidad de consumo, independiente del stall.
 * @input dmem_req_ready_i, dmem_rsp_valid_i, dmem_rsp_error_i Handshake CPU-L1.
 * @output dmem_* Control LSU conectado a la interfaz CPU-L1 del nucleo.
 * @output *_wb_o Canales de resultado para el RF, sin arbitraje dinamico.
 * @output memory_* Campos preparados por LSU, incluida direccion efectiva para diagnostico.
 * @output branch_* Decision de salto sin flush ni stall.
 * @output authenticated_o, auth_failed_o, access_error_o Estado/eventos CRYPTO.
 * @output crypto_event_pc_o PC alineado con los eventos registrados CRYPTO.
 * @output invalid_address_o, invalid_address_pc_o Error LSU en la solicitud EX.
 * @output work_after_advance_o Trabajo posterior al flanco, valido con advance_i=1.
 * @output wb_operations_o Operaciones EX cuya finalizacion queda para el siguiente WB.
 * @output mul_operation_o Operacion EX que finalizara tras tres avances adicionales.
 */
module execution_stage (
    input logic clk_i,
    input logic rst_ni,
    input pkg_vliw::issued_op_t alu0_i,
    input pkg_vliw::issued_op_t alu1_i,
    input pkg_vliw::issued_op_t lsu_i,
    input pkg_vliw::issued_op_t bruh_i,
    input pkg_vliw::issued_op_t crypto_i,
    input pkg_vliw::word_t memory_read_data_i,
    input logic advance_i,
    input logic completion_ready_i,
    input logic dmem_req_ready_i,
    input logic dmem_rsp_valid_i,
    input logic dmem_rsp_error_i,
    output logic dmem_req_valid_o,
    output logic dmem_rsp_ready_o,
    output logic dmem_done_o,
    output logic dmem_error_o,
    output logic work_after_advance_o,
    output pkg_metrics::event_delta_t wb_operations_o,
    output logic mul_operation_o,
    output pkg_vliw::wb_channel_t alu0_wb_o,
    output pkg_vliw::wb_channel_t alu1_wb_o,
    output pkg_vliw::wb_channel_t load_wb_o,
    output pkg_vliw::wb_channel_t crypto_left_wb_o,
    output pkg_vliw::wb_channel_t crypto_right_wb_o,
    output pkg_vliw::address_t memory_address_o,
    output pkg_vliw::address_t memory_effective_address_o,
    output logic memory_read_enable_o,
    output logic [3:0] memory_write_enable_o,
    output pkg_vliw::word_t memory_write_data_o,
    output logic branch_taken_o,
    output pkg_vliw::address_t branch_target_o,
    output logic invalid_address_o,
    output pkg_vliw::address_t invalid_address_pc_o,
    output logic authenticated_o,
    output logic auth_failed_o,
    output logic access_error_o,
    output pkg_vliw::address_t crypto_event_pc_o
);
    import pkg_vliw::*;

    /** @brief Procedencia paralela a registros internos que ya guardan destinos. */
    typedef struct packed {
        logic valid;
        address_t pc;
        slot_t instruction;
    } completion_tag_t;

    word_t alu0_data;
    reg_index_t alu0_destination;
    logic alu0_enable;
    wb_channel_t alu0_wb_q;
    wb_channel_t load_wb_q;
    word_t alu1_data;
    reg_index_t alu1_destination;
    logic alu1_enable;
    logic alu1_is_mul;
    completion_tag_t mul_tag1_q, mul_tag2_q;
    wb_channel_t alu1_wb_q;
    completion_tag_t crypto_tag_q;
    logic load_valid;
    reg_index_t load_destination;
    word_t load_data;
    lost_inst_t lsu_instruction;
    wire [0:1] crypto_enable;
    wire [0:1][$clog2(NUM_REGS)-1:0] crypto_destination;
    wire [0:1][DATA_WIDTH-1:0] crypto_data;
    logic crypto_authenticated, crypto_auth_failed, crypto_access_error;
    logic crypto_work_after_advance;

    assign lsu_instruction = lsu_i.instruction;
    assign alu1_is_mul = alu1_i.valid &&
                        ((alu1_i.instruction[9:4] == MATH_MUL) ||
                         (alu1_i.instruction[9:4] == MATH_MULH));

    alu_unit u_alu0 (
        .instruction_i(alu0_i.instruction),
        .is_nop_i(!rst_ni || !alu0_i.valid),
        .imm_data_i(alu0_i.immediate),
        .operand_a_i(alu0_i.operand_a),
        .operand_b_i(alu0_i.operand_b),
        .result_o(alu0_data),
        .dest_addr_o(alu0_destination),
        .write_enable_o(alu0_enable)
    );

    super_alu u_alu1 (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .advance_i(advance_i),
        .instruction_i(alu1_i.instruction),
        .is_nop_i(!rst_ni || !alu1_i.valid),
        .imm_data_i(alu1_i.immediate),
        .op1_i(alu1_i.operand_a),
        .op2_i(alu1_i.operand_b),
        .result_o(alu1_data),
        .dest_addr_o(alu1_destination),
        .write_enable_o(alu1_enable)
    );

    lost_unit u_lsu (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .nop_flag_i(!rst_ni || !lsu_i.valid),
        .instruction_i(lsu_instruction),
        .immediate_i(lsu_i.immediate),
        .base_address_i(lsu_i.operand_b),
        .store_data_i(lsu_i.operand_a),
        .memory_read_data_i(memory_read_data_i),
        .dmem_req_ready_i(dmem_req_ready_i),
        .dmem_rsp_valid_i(dmem_rsp_valid_i),
        .dmem_rsp_error_i(dmem_rsp_error_i),
        .completion_ready_i(completion_ready_i),
        .dmem_req_valid_o(dmem_req_valid_o),
        .dmem_rsp_ready_o(dmem_rsp_ready_o),
        .dmem_done_o(dmem_done_o),
        .dmem_error_o(dmem_error_o),
        .effective_address_o(memory_effective_address_o),
        .memory_address_o(memory_address_o),
        .memory_read_enable_o(memory_read_enable_o),
        .memory_write_enable_o(memory_write_enable_o),
        .memory_write_data_o(memory_write_data_o),
        .invalid_address_o(invalid_address_o),
        .load_valid_o(load_valid),
        .load_rd_o(load_destination),
        .load_data_o(load_data)
    );

    bruh_unit u_bruh (
        .instruction_i(bruh_i.instruction),
        .is_nop_i(!rst_ni || !bruh_i.valid),
        .imm_data_i(bruh_i.immediate),
        .operand_a_i(bruh_i.operand_a),
        .pc_i(bruh_i.pc),
        .target_pc_o(branch_target_o),
        .branch_taken_o(branch_taken_o)
    );

    crypto_unit u_crypto (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .advance_i(advance_i),
        .ex_valid_i(rst_ni && crypto_i.valid),
        .nop_flag_i(!crypto_i.valid),
        .slot_i(crypto_i.instruction),
        .op_a_addr_i(crypto_i.instruction[15:13]),
        .op_b_addr_i(crypto_i.instruction[12:10]),
        .op_a_data_i(crypto_i.operand_a),
        .op_b_data_i(crypto_i.operand_b),
        .write_enable_o(crypto_enable),
        .write_addr_o(crypto_destination),
        .write_data_o(crypto_data),
        .work_after_advance_o(crypto_work_after_advance),
        .authenticated_o(crypto_authenticated),
        .auth_failed_o(crypto_auth_failed),
        .access_error_o(crypto_access_error)
    );

    /**
     * @brief Preve trabajo que sobrevive al flanco habilitado de ejecucion/WB.
     * @details Las dos etapas MUL y las operaciones EX pueden producir trabajo
     * futuro. WB actual se consume en ese flanco y no agrega una espera extra.
     * No filtra destinos r0. Stores, saltos y errores LSU completan en EX.
     * El consumidor debe exigir advance_i: durante un stall esto no indica vacio.
     */
    assign work_after_advance_o = rst_ni &&
        (alu0_enable || alu1_is_mul || mul_tag1_q.valid || mul_tag2_q.valid ||
         (alu1_i.valid && alu1_enable) || load_valid || crypto_work_after_advance);

    /** @brief Clasifica operaciones EX para observacion, incluso con destino r0. */
    assign mul_operation_o = rst_ni && alu1_is_mul;
    always_comb begin
        wb_operations_o = '0;
        if (rst_ni) begin
            if (alu0_enable) wb_operations_o++;
            if (alu1_i.valid && !alu1_is_mul && alu1_i.instruction[9:4] != MATH_NOP)
                wb_operations_o++;
            if (load_valid) wb_operations_o++;
            if (crypto_work_after_advance) wb_operations_o++;
        end
    end

    /** @brief Conserva el PC e instruccion de CRYPTO con sus resultados/eventos WB. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            crypto_tag_q <= '0;
        end else if (advance_i) begin
            crypto_tag_q <= {crypto_i.valid, crypto_i.pc, crypto_i.instruction};
        end
    end

    /** @brief La procedencia MUL avanza con las dos etapas del multiplicador. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mul_tag1_q <= '0;
            mul_tag2_q <= '0;
        end else if (advance_i) begin
            mul_tag1_q <= {alu1_is_mul, alu1_i.pc, alu1_i.instruction};
            mul_tag2_q <= mul_tag1_q;
        end
    end

    /**
     * @brief Conserva el resultado anterior de ALU0 mientras EX espera memoria.
     * @details Dato, destino, PC, instruccion y validez se retienen juntos. Al
     * reanudar, RF consume este canal y la frontera captura la nueva operacion
     * de EX en el mismo flanco. Reset cancela el resultado pendiente.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            alu0_wb_q <= '0;
        end else if (advance_i) begin
            alu0_wb_q <= {alu0_enable, alu0_destination, alu0_data,
                          alu0_i.pc, alu0_i.instruction};
        end
    end

    /**
     * @brief Frontera WB de la salida compartida de SuperALU.
     * @details La interfaz mezcla resultados rapidos combinacionales y MUL
     * registrado: se captura el canal completo, incluido el destino que ya
     * transporta la unidad. MUL llega al RF en issue+4; rapidas en issue+2.
     * Esos tiempos suponen avance continuo: durante un stall se conservan ambas
     * etapas MUL, sus tags y este canal WB con el mismo permiso, sin desalinearse.
     * El tag selecciona solamente procedencia, no arbitra operaciones.
     * Una rapida emitida en mul_issue+2 esta prohibida por el scheduler.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            alu1_wb_q <= '0;
        end else if (advance_i) begin
            if (mul_tag2_q.valid) begin
                alu1_wb_q <= {alu1_enable, alu1_destination, alu1_data,
                              mul_tag2_q.pc, mul_tag2_q.instruction};
            end else begin
                alu1_wb_q <= {alu1_enable && alu1_i.valid, alu1_destination,
                              alu1_data, alu1_i.pc, alu1_i.instruction};
            end
        end
    end

    /**
     * @brief Frontera unica del load: valor y procedencia avanzan juntos.
     * @details La frontera conserva el canal durante advance_i=0; el consumidor
     * inhibira su escritura RF hasta reanudar. Al consumir una respuesta, el control
     * debe activar advance_i en ese flanco; LSU ya califica errores y stores.
     * Reset cancela el resultado pendiente. Los campos se usan solo con valid.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            load_wb_q <= '0;
        end else if (advance_i) begin
            load_wb_q <= {load_valid, load_destination, load_data,
                          lsu_i.pc, lsu_i.instruction};
        end
    end

    assign alu0_wb_o = rst_ni ? alu0_wb_q : '0;
    assign alu1_wb_o = rst_ni ? alu1_wb_q : '0;
    assign load_wb_o = rst_ni ? load_wb_q : '0;
    assign crypto_left_wb_o = {rst_ni && crypto_enable[0] && crypto_tag_q.valid,
                               crypto_destination[0], crypto_data[0],
                               crypto_tag_q.pc, crypto_tag_q.instruction};
    assign crypto_right_wb_o = {rst_ni && crypto_enable[1] && crypto_tag_q.valid,
                                crypto_destination[1], crypto_data[1],
                                crypto_tag_q.pc, crypto_tag_q.instruction};
    assign authenticated_o = rst_ni && crypto_authenticated;
    /** @brief Los diagnosticos retenidos se emiten solo en el flanco de avance. */
    assign auth_failed_o = rst_ni && advance_i && crypto_tag_q.valid && crypto_auth_failed;
    assign access_error_o = rst_ni && advance_i && crypto_tag_q.valid && crypto_access_error;
    assign crypto_event_pc_o = crypto_tag_q.pc;
    assign invalid_address_pc_o = lsu_i.pc;
endmodule
