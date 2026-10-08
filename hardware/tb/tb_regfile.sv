module tb_regfile;

    logic clk;
    logic rst_n;
    logic [2:0] read_addr [0:7];
    logic [31:0] read_data [0:7];
    logic write_enable [0:3];
    logic [2:0] write_addr [0:3];
    logic [31:0] write_data [0:3];
    integer port;

    register_file dut (
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
        for (port = 0; port < 8; port = port + 1) begin
            read_addr[port] = 3'd0;
        end
        for (port = 0; port < 4; port = port + 1) begin
            write_enable[port] = 1'b0;
            write_addr[port] = 3'd0;
            write_data[port] = 32'd0;
        end
        #2;
        rst_n = 1'b1;

        write_enable[0] = 1'b1;
        write_addr[0] = 3'd1;
        write_data[0] = 32'h11111111;
        write_enable[1] = 1'b1;
        write_addr[1] = 3'd2;
        write_data[1] = 32'h22222222;
        write_enable[2] = 1'b1;
        write_addr[2] = 3'd3;
        write_data[2] = 32'h33333333;
        write_enable[3] = 1'b1;
        write_addr[3] = 3'd0;
        write_data[3] = 32'hffffffff;
        @(posedge clk);
        #1;

        read_addr[0] = 3'd0;
        read_addr[1] = 3'd1;
        read_addr[2] = 3'd2;
        read_addr[3] = 3'd3;
        read_addr[4] = 3'd1;
        read_addr[5] = 3'd2;
        read_addr[6] = 3'd3;
        read_addr[7] = 3'd0;
        #1;
        if (read_data[0] !== 32'h0 || read_data[7] !== 32'h0) $fatal(1, "r0 is not immutable");
        if (read_data[1] !== 32'h11111111 || read_data[4] !== 32'h11111111) $fatal(1, "r1 read failed");
        if (read_data[2] !== 32'h22222222 || read_data[5] !== 32'h22222222) $fatal(1, "r2 read failed");
        if (read_data[3] !== 32'h33333333 || read_data[6] !== 32'h33333333) $fatal(1, "r3 read failed");

        $display("tb_regfile: PASS (8 async reads, 4 sync writes, r0 protected)");
        $finish;
    end

endmodule