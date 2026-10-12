// Registro EX/WB de CRYPTO: conservará los dos resultados, destinos, enables
// y eventos de error preparados por crypto_unit para writeback_stage.
// Solo interfaz; reset síncrono activo bajo, captura en flanco positivo.
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
endmodule
