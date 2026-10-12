/**
 * @brief Registra las salidas EX de CRYPTO para entregarlas en WB.
 *
 * @details
 * Captura dos canales independientes de escritura, cada uno con enable,
 * dirección y dato, junto con los eventos auth_failed y access_error. El
 * bloque infiere únicamente registros disparados por flanco positivo; no
 * contiene arbitraje, permisos, forwarding ni acceso al banco de registros.
 * En cada flanco, crypto_unit suministrará los valores de EX y, durante el
 * ciclo siguiente, writeback_stage consumirá las salidas registradas.
 *
 * @input  clk_i            Reloj del registro EX/WB.
 * @input  rst_ni           Reset síncrono activo bajo.
 * @input  write_enable_i   Enables de los dos canales producidos en EX.
 * @input  auth_failed_i    Evento de autenticación fallida del ciclo EX.
 * @input  access_error_i   Evento de acceso rechazado del ciclo EX.
 * @input  write_addr_i     Destinos de los dos resultados.
 * @input  write_data_i     Datos de los dos resultados.
 * @output write_enable_o   Enables conservados durante el ciclo WB.
 * @output auth_failed_o    Evento registrado para el futuro estado arquitectónico.
 * @output access_error_o   Evento registrado para el futuro estado arquitectónico.
 * @output write_addr_o     Destinos conservados durante el ciclo WB.
 * @output write_data_o     Datos conservados durante el ciclo WB.
 *
 * @note Cuando rst_ni está bajo en un flanco positivo, todos los registros
 *       se limpian. Entre flancos, las salidas conservan su valor registrado.
 */
module crypto_wb (
    input  logic clk_i,
    input  logic rst_ni,
    // Enables ya calificados por permiso de ronda y destino distinto de r0.
    input  logic write_enable_i [0:1],
    input  logic auth_failed_i,
    input  logic access_error_i,
    input  logic [$clog2(pkg_vliw::NUM_REGS)-1:0] write_addr_i [0:1],
    input  logic [pkg_vliw::DATA_WIDTH-1:0] write_data_i [0:1],

    output logic write_enable_o [0:1],
    output logic auth_failed_o,
    output logic access_error_o,
    output logic [$clog2(pkg_vliw::NUM_REGS)-1:0] write_addr_o [0:1],
    output logic [pkg_vliw::DATA_WIDTH-1:0] write_data_o [0:1]
);

    integer channel;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            auth_failed_o <= 1'b0;
            access_error_o <= 1'b0;

            for (channel = 0; channel < 2; channel = channel + 1) begin
                write_enable_o[channel] <= 1'b0;
                write_addr_o[channel] <= '0;
                write_data_o[channel] <= '0;
            end
        end else begin
            auth_failed_o <= auth_failed_i;
            access_error_o <= access_error_i;

            for (channel = 0; channel < 2; channel = channel + 1) begin
                write_enable_o[channel] <= write_enable_i[channel];
                write_addr_o[channel] <= write_addr_i[channel];
                write_data_o[channel] <= write_data_i[channel];
            end
        end
    end

endmodule
