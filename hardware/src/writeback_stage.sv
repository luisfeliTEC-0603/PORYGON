/**
 * @brief Conecta los cinco resultados a los puertos fisicos del RF.
 *
 * @details Cableado combinacional: ALU0, SuperALU, load, Feistel L y Feistel R.
 * Las fronteras temporales pertenecen a execution_stage y a las unidades.
 * No agrega registros despues de crypto_wb ni resuelve colisiones de destino.
 * @input rst_ni Deshabilita todos los canales durante reset.
 * @input alu0_i, alu1_i, load_i, crypto_left_i, crypto_right_i Resultados WB.
 * @output write_enable_o, write_addr_o, write_data_o Puertos del RF.
 * @note El scheduler garantiza destinos compatibles; r0 se descarta por canal.
 */
module writeback_stage (
    input logic rst_ni,
    input pkg_vliw::wb_channel_t alu0_i,
    input pkg_vliw::wb_channel_t alu1_i,
    input pkg_vliw::wb_channel_t load_i,
    input pkg_vliw::wb_channel_t crypto_left_i,
    input pkg_vliw::wb_channel_t crypto_right_i,
    output logic write_enable_o [0:pkg_vliw::RF_WRITE_PORTS-1],
    output pkg_vliw::reg_index_t write_addr_o [0:pkg_vliw::RF_WRITE_PORTS-1],
    output pkg_vliw::word_t write_data_o [0:pkg_vliw::RF_WRITE_PORTS-1]
);
    import pkg_vliw::*;

    assign write_enable_o[WB_ALU0] = rst_ni && alu0_i.valid && (alu0_i.destination != '0);
    assign write_enable_o[WB_ALU1] = rst_ni && alu1_i.valid && (alu1_i.destination != '0);
    assign write_enable_o[WB_LSU] = rst_ni && load_i.valid && (load_i.destination != '0);
    assign write_enable_o[WB_CRYPTO_L] = rst_ni && crypto_left_i.valid && (crypto_left_i.destination != '0);
    assign write_enable_o[WB_CRYPTO_R] = rst_ni && crypto_right_i.valid && (crypto_right_i.destination != '0);
    assign write_addr_o[WB_ALU0] = alu0_i.destination;
    assign write_addr_o[WB_ALU1] = alu1_i.destination;
    assign write_addr_o[WB_LSU] = load_i.destination;
    assign write_addr_o[WB_CRYPTO_L] = crypto_left_i.destination;
    assign write_addr_o[WB_CRYPTO_R] = crypto_right_i.destination;
    assign write_data_o[WB_ALU0] = alu0_i.data;
    assign write_data_o[WB_ALU1] = alu1_i.data;
    assign write_data_o[WB_LSU] = load_i.data;
    assign write_data_o[WB_CRYPTO_L] = crypto_left_i.data;
    assign write_data_o[WB_CRYPTO_R] = crypto_right_i.data;
endmodule
