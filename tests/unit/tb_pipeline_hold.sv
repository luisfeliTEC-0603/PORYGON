`timescale 1ns/1ps

/**
 * @brief Comprueba retencion IF/ID y ausencia de efectos WB durante la espera.
 * @details El entorno aplica avance y conserva los canales WB. Se cuentan
 * escrituras por puerto antes, durante y al salir del stall, sin modelo RF.
 */
module tb_pipeline_hold;
    import pkg_vliw::*;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic advance = 1'b0;
    logic branch_taken = 1'b0;
    address_t pc, id_pc;
    bundle_t rom_bundle, id_bundle;
    logic read_enable, id_valid;
    wb_channel_t result [0:RF_WRITE_PORTS-1];
    wire write_enable [0:RF_WRITE_PORTS-1];
    integer writes [0:RF_WRITE_PORTS-1];
    always #5 clk = ~clk;
    always @(posedge clk)
        if (rst_n)
            for (integer channel = 0; channel < RF_WRITE_PORTS; channel++)
                if (write_enable[channel]) writes[channel] <= writes[channel] + 1;

    instruction_memory #(
        .INIT_FILE("tests/programs/top/top_integration.mem"),
        .INIT_BUNDLES(28)
    ) rom (
        .clk_i(clk),
        .rst_ni(rst_n),
        .address_i(pc),
        .read_enable_i(read_enable),
        .bundle_o(rom_bundle)
    );
    fetch_stage fetch (
        .clk_i(clk),
        .rst_ni(rst_n),
        .advance_i(advance),
        .stop_i(1'b0),
        .branch_taken_i(branch_taken),
        .branch_target_i(32'h40),
        .instruction_bundle_i(rom_bundle),
        .instruction_address_o(pc),
        .instruction_read_enable_o(read_enable),
        .bundle_o(id_bundle),
        .bundle_pc_o(id_pc),
        .bundle_valid_o(id_valid)
    );
    writeback_stage wb (
        .rst_ni(rst_n),
        .advance_i(advance),
        .alu0_i(result[pkg_vliw::WB_ALU0]),
        .alu1_i(result[pkg_vliw::WB_ALU1]),
        .load_i(result[pkg_vliw::WB_LSU]),
        .crypto_left_i(result[pkg_vliw::WB_CRYPTO_L]),
        .crypto_right_i(result[pkg_vliw::WB_CRYPTO_R]),
        .write_enable_o(write_enable)
    );

    initial begin
        for (integer channel = 0; channel < RF_WRITE_PORTS; channel++) begin
            result[channel] = {1'b1, reg_index_t'(channel + 1), 32'h1, 32'b0, 16'b0};
            writes[channel] = 0;
        end
        @(negedge clk);
        rst_n = 1'b1;
        advance = 1'b1;
        @(posedge clk);
        #1;
        if (pc !== 32'h8 || id_pc !== '0 || !id_valid || id_bundle !== 64'h40002024)
            $fatal(1, "Primera lectura IF/ID incorrecta");
        @(negedge clk);
        advance = 1'b0;
        branch_taken = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        if (pc !== 32'h8 || id_pc !== '0 || !id_valid || id_bundle !== 64'h40002024 || read_enable)
            $fatal(1, "IF/ID o PC cambiaron durante el stall");
        for (integer channel = 0; channel < RF_WRITE_PORTS; channel++)
            if (writes[channel] !== 1) $fatal(1, "WB repetido durante stall: puerto=%0d", channel);
        @(negedge clk);
        advance = 1'b1;
        @(posedge clk);
        #1;
        if (pc !== 32'h40 || id_pc !== 32'h8 || id_bundle !== '0)
            $fatal(1, "Reanudacion o salto retenido incorrectos");
        for (integer channel = 0; channel < RF_WRITE_PORTS; channel++)
            if (writes[channel] !== 2) $fatal(1, "WB no completo al reanudar: puerto=%0d", channel);
        $display("tb_pipeline_hold: PASS");
        $finish;
    end
endmodule
