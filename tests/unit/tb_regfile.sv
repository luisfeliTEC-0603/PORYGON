`timescale 1ns/1ps

// Verifica cinco escrituras simultáneas, enables, protección de r0 y reset del GPR.
module tb_regfile;
    localparam integer NUM_WRITE_PORTS = pkg_vliw::RF_WRITE_PORTS;
    localparam integer NUM_READ_PORTS  = pkg_vliw::RF_READ_PORTS;

    logic clk;
    logic rst_n;
    logic [2:0] read_addr [0:NUM_READ_PORTS-1];
    wire  [31:0] read_data [0:NUM_READ_PORTS-1];
    logic write_enable [0:NUM_WRITE_PORTS-1];
    logic [2:0] write_addr [0:NUM_WRITE_PORTS-1];
    logic [31:0] write_data [0:NUM_WRITE_PORTS-1];
    integer port;

    register_file #(
        .NUM_WRITE_PORTS(NUM_WRITE_PORTS),
        .NUM_READ_PORTS (NUM_READ_PORTS)
    ) u_register_file (
        .clk_i(clk),
        .rst_ni(rst_n),
        .read_addr_i(read_addr),
        .read_data_o(read_data),
        .write_enable_i(write_enable),
        .write_addr_i(write_addr),
        .write_data_i(write_data)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        for (port = 0; port < NUM_READ_PORTS; port = port + 1) begin
            read_addr[port] = port[2:0];
        end
        for (port = 0; port < NUM_WRITE_PORTS; port = port + 1) begin
            write_enable[port] = 1'b0;
            write_addr[port] = 3'd0;
            write_data[port] = 32'd0;
        end
        #2;
        for (port = 0; port < 8; port = port + 1) begin
            if (read_data[port] !== 32'd0) $fatal(1, "Initial reset failed: r%0d", port);
        end
        rst_n = 1'b1;

        // Los cinco resultados deben persistir tras el mismo flanco.
        for (port = 0; port < NUM_WRITE_PORTS; port = port + 1) begin
            write_enable[port] = 1'b1;
            write_addr[port] = port[2:0] + 3'd1;
            write_data[port] = 32'h11111111 * (port + 1);
        end
        @(posedge clk);
        #1;
        for (port = 0; port < NUM_WRITE_PORTS; port = port + 1) begin
            if (read_data[port+1] !== 32'h11111111 * (port + 1))
                $fatal(1, "Simultaneous write failed: port %0d", port);
        end

        @(negedge clk);
        for (port = 0; port < NUM_WRITE_PORTS; port = port + 1) begin
            write_enable[port] = 1'b0;
            write_addr[port] = 3'd6;
            write_data[port] = 32'hdeadbeef;
        end
        @(posedge clk);
        #1;
        if (read_data[6] !== 32'd0) $fatal(1, "Disabled write modified r6");
        for (port = 0; port < NUM_WRITE_PORTS; port = port + 1) begin
            if (read_data[port+1] !== 32'h11111111 * (port + 1))
                $fatal(1, "Disabled writes did not preserve r%0d", port + 1);
        end

        // Cada puerto intenta escribir r0 por separado, incluido el quinto.
        for (port = 0; port < NUM_WRITE_PORTS; port = port + 1) begin
            @(negedge clk);
            write_enable[port] = 1'b1;
            write_addr[port] = 3'd0;
            @(posedge clk);
            #1;
            if (read_data[0] !== 32'd0) $fatal(1, "r0 modified by port %0d", port);
            write_enable[port] = 1'b0;
        end

        // El reset asíncrono existente limpia el banco sin esperar otro flanco.
        @(negedge clk);
        rst_n = 1'b0;
        #1;
        for (port = 0; port < 8; port = port + 1) begin
            if (read_data[port] !== 32'd0) $fatal(1, "Final reset failed: r%0d", port);
        end

        $display("tb_regfile: PASS (8 async reads, 5 simultaneous writes, enables, r0, reset)");
        $finish;
    end
endmodule
