/**
 * @brief Observacion exclusiva de testbench; no drena ni modifica el RTL.
 * @details Recupera los bytes arquitectonicos al cerrar el programa, incluida
 * la informacion dirty aun residente en caches/buffers. Requiere una instancia
 * dut.u_data_memory; conserva el formato .mem de bytes relativo a DATA_BASE.
 */
logic [7:0] architectural_memory [0:pkg_memory::MEMORY_BYTES-1];

task automatic snapshot_line(input pkg_memory::address_t base,
                             input pkg_memory::line_t data);
    for (integer byte_index = 0; byte_index < pkg_memory::LINE_BYTES; byte_index++) begin
        if (base + byte_index >= pkg_memory::DATA_BASE_ADDRESS &&
            base + byte_index < pkg_memory::DATA_BASE_ADDRESS + pkg_memory::MEMORY_BYTES)
            architectural_memory[base - pkg_memory::DATA_BASE_ADDRESS + byte_index] =
                data[8*byte_index +: 8];
    end
endtask

/** @brief Solo la rama elaborada referencia los arreglos fisicos existentes. */
generate if (REFERENCE_WITHOUT_CACHE) begin : gen_snapshot
    task automatic capture;
        for (integer index = 0; index < pkg_memory::MEMORY_BYTES; index++)
            architectural_memory[index] = dut.u_data_memory.u_main_memory.u_storage.memory[index];
    endtask
end else begin : gen_snapshot
    task automatic capture;

        localparam integer OFFSET_W = $clog2(pkg_memory::LINE_BYTES);
        localparam integer L1_SETS = pkg_memory::L1_BYTES / (pkg_memory::L1_WAYS * pkg_memory::LINE_BYTES);
        localparam integer L2_SETS = pkg_memory::L2_BYTES / (pkg_memory::L2_WAYS * pkg_memory::LINE_BYTES);
        for (integer index = 0; index < pkg_memory::MEMORY_BYTES; index++)
            architectural_memory[index] = dut.u_data_memory.u_main_memory.u_storage.memory[index];
        for (integer index = 0; index < dut.EVICTION_BUFFER_DEPTH; index++) begin
            if (dut.u_data_memory.gen_cached.u_eviction_buffer.occupied_q[index])
                snapshot_line(dut.u_data_memory.gen_cached.u_eviction_buffer.base_q[index],
                              dut.u_data_memory.gen_cached.u_eviction_buffer.data_q[index]);
        end
        for (integer index = 0; index < L2_SETS * pkg_memory::L2_WAYS; index++) begin
            if (dut.u_data_memory.gen_cached.u_l2.u_tags.valid_q[index])
                snapshot_line((32'(dut.u_data_memory.gen_cached.u_l2.u_tags.tag_q[index]) << ($clog2(L2_SETS)+OFFSET_W)) |
                              ((index/pkg_memory::L2_WAYS) << OFFSET_W),
                              dut.u_data_memory.gen_cached.u_l2.u_data.mem_q[index]);
        end
        /** WB puede conservar una instalacion ya visible en L2 hasta su done. */
        for (integer index = 0; index < dut.WRITE_BUFFER_DEPTH; index++) begin
            if (dut.u_data_memory.gen_cached.u_write_buffer.entry_valid_q[index])
                snapshot_line(dut.u_data_memory.gen_cached.u_write_buffer.entry_base_q[index],
                              dut.u_data_memory.gen_cached.u_write_buffer.entry_data_q[index]);
        end
        for (integer set_index = 0; set_index < L1_SETS; set_index++) begin
            for (integer way = 0; way < pkg_memory::L1_WAYS; way++) begin
                if (dut.u_data_memory.gen_cached.u_l1.block_valid_q[set_index][way])
                    snapshot_line((32'(dut.u_data_memory.gen_cached.u_l1.block_tag_q[set_index][way]) << ($clog2(L1_SETS)+OFFSET_W)) |
                                  (set_index << OFFSET_W),
                                  dut.u_data_memory.gen_cached.u_l1.block_data_q[set_index][way]);
            end
        end
    endtask
end endgenerate

task automatic capture_architectural_memory;
    gen_snapshot.capture();
endtask
