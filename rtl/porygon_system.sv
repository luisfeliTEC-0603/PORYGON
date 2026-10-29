/**
 * @brief Sistema de simulacion con nucleo, memoria de instrucciones y datos.
 *
 * @details Conserva vliw_processor como nucleo reusable con interfaces de
 * memoria explicitas. Este wrapper conecta la lectura combinacional de texto
 * y el puerto sincronico de datos requeridos por fetch y LOST.
 * Los errores de rango de memoria se exponen como diagnosticos de solicitud;
 * no se acumulan ni alteran el PC. La RAM invalida la respuesta de un load
 * fuera de rango y el nucleo suprime su escritura al RF.
 */
module porygon_system #(
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] INITIAL_PC = pkg_vliw::RESET_PC,
    parameter INSTRUCTION_INIT_FILE = "",
    parameter integer INSTRUCTION_INIT_BUNDLES = 0,
    parameter DATA_INIT_FILE = "",
    parameter integer DATA_INIT_BYTES = 0
) (
    input logic clk_i,
    input logic rst_ni,
    output logic authenticated_o,
    output logic auth_failed_o,
    output logic access_error_o,
    output pkg_vliw::address_t crypto_event_pc_o,
    output logic invalid_address_o,
    output pkg_vliw::address_t invalid_address_pc_o,
    output logic instruction_access_error_o,
    output pkg_vliw::address_t instruction_access_error_pc_o,
    output logic data_access_error_o,
    output pkg_vliw::address_t data_access_error_pc_o
);
    import pkg_vliw::*;

    bundle_t instruction_bundle;
    address_t instruction_address;
    logic instruction_read_enable;
    word_t data_read_data;
    logic data_read_valid;
    address_t data_address;
    logic data_read_enable;
    logic [3:0] data_write_enable;
    word_t data_write_data;

    assign instruction_access_error_pc_o = instruction_address;
    assign data_access_error_pc_o = invalid_address_pc_o;

    instruction_memory #(
        .MEMORY_BYTES(MEMORY_BYTES),
        .BASE_ADDRESS(TEXT_BASE_ADDRESS),
        .INIT_FILE(INSTRUCTION_INIT_FILE),
        .INIT_BUNDLES(INSTRUCTION_INIT_BUNDLES)
    ) u_instruction_memory (
        .address_i(instruction_address),
        .read_enable_i(instruction_read_enable),
        .bundle_o(instruction_bundle),
        .out_of_range_o(instruction_access_error_o)
    );

    memory_sp_ram #(
        .MEMORY_BYTES(MEMORY_BYTES),
        .BASE_ADDRESS(DATA_BASE_ADDRESS),
        .INIT_FILE(DATA_INIT_FILE),
        .INIT_BYTES(DATA_INIT_BYTES)
    ) u_data_memory (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .address_i(data_address),
        .read_enable_i(data_read_enable),
        .write_enable_i(data_write_enable),
        .write_data_i(data_write_data),
        .read_data_o(data_read_data),
        .read_valid_o(data_read_valid),
        .out_of_range_o(data_access_error_o)
    );

    vliw_processor #(
        .INITIAL_PC(INITIAL_PC)
    ) u_processor (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .instruction_bundle_i(instruction_bundle),
        .data_read_data_i(data_read_data),
        .data_read_valid_i(data_read_valid),
        .instruction_address_o(instruction_address),
        .instruction_read_enable_o(instruction_read_enable),
        .data_address_o(data_address),
        .data_read_enable_o(data_read_enable),
        .data_write_enable_o(data_write_enable),
        .data_write_data_o(data_write_data),
        .authenticated_o(authenticated_o),
        .auth_failed_o(auth_failed_o),
        .access_error_o(access_error_o),
        .crypto_event_pc_o(crypto_event_pc_o),
        .invalid_address_o(invalid_address_o),
        .invalid_address_pc_o(invalid_address_pc_o)
    );
endmodule
