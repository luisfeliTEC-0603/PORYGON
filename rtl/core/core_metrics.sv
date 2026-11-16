/**
 * @brief Observador CPU-domain: eventos sin retroalimentacion al datapath.
 * @details Los deltas se muestrean al avanzar; las esperas por reloj real.
 * Metadatos diferidos y primera presentacion se cancelan con reset.
 * No implementa contadores de rendimiento (P2-10).
 */
module core_metrics (
    input logic clk_i,
    input logic rst_ni,
    input logic advance_i,
    input logic halted_i,
    input logic fetch_active_i,
    input logic fetch_transfer_i,
    input logic id_valid_i,
    input logic id_admit_i,
    input pkg_vliw::address_t id_pc_i,
    input logic instruction_error_i,
    input logic stop_admission_i,
    input logic ex_valid_i,
    input pkg_vliw::bundle_t ex_bundle_i,
    input pkg_metrics::event_delta_t wb_operations_i,
    input logic mul_operation_i,
    input logic branch_valid_i,
    input logic branch_taken_i,
    input logic memory_active_i,
    input logic req_valid_i,
    input logic req_ready_i,
    input logic rsp_valid_i,
    input logic rsp_ready_i,
    input logic dmem_done_i,
    input logic dmem_error_i,
    input logic dmem_write_i,
    input pkg_metrics::demand_origin_t dmem_origin_i,
    input logic alignment_error_i,
    input pkg_vliw::address_t effective_address_i,
    output pkg_metrics::cpu_events_t events_o
);
    import pkg_vliw::*;
    import pkg_metrics::*;
    completion_delta_t done;
    logic wb_occupied, mul_occupied, demand_seen_q;
    logic id_error_q;
    logic [$clog2(BRANCH_NOP_BUNDLES+1)-1:0] delay_remaining_q;
    bundle_completions u_completions (
        .clk_i(clk_i), .rst_ni(rst_ni), .advance_i(advance_i), .ex_valid_i(ex_valid_i),
        .ex_bundle_i(ex_bundle_i), .wb_operations_i(wb_operations_i), .mul_operation_i(mul_operation_i),
        .done_o(done), .wb_occupied_o(wb_occupied), .mul_occupied_o(mul_occupied)
    );

    /** @brief Combinacional: cada pulso describe el flanco que sigue al intervalo. */
    always_comb begin
        events_o = '0;
        if (rst_ni && !halted_i) begin
            events_o.done_bundles = done.bundles;
            events_o.done_instructions = done.instructions;
            events_o.done_nop_slots = done.nop_slots;
            events_o.done_literal_slots = done.literal_slots;
            events_o.stage_occupied = {wb_occupied, ex_valid_i || mul_occupied, id_valid_i, fetch_active_i};
            events_o.stage_transfers = events_o.stage_occupied & {4{advance_i}};
            events_o.stage_transfers[0] = fetch_transfer_i;
            events_o.stage_transfers[1] = id_admit_i;
            events_o.stall = memory_active_i && !advance_i;
            events_o.stage_mem_stalls = events_o.stage_occupied & {4{events_o.stall}};
            if (events_o.stall) begin
                if (rsp_valid_i && !rsp_ready_i) events_o.wait_reason = WAIT_RESPONSE;
                else if (req_valid_i && !req_ready_i) events_o.wait_reason = WAIT_ACCEPT;
                else events_o.wait_reason = WAIT_MISS;
            end
            events_o.dmem_begin = req_valid_i && !demand_seen_q;
            events_o.dmem_write = dmem_write_i;
            events_o.dmem_done = dmem_done_i;
            events_o.dmem_error = dmem_error_i;
            events_o.branch_done = branch_valid_i && advance_i;
            events_o.branch_taken = events_o.branch_done && branch_taken_i;
            events_o.branch_delay = ex_valid_i && advance_i && delay_remaining_q != 0 && ex_bundle_i == '0;
            events_o.instruction_error.valid = id_admit_i && (id_error_q || instruction_error_i);
            if (events_o.instruction_error.valid) begin
                events_o.instruction_error.kind = ERROR_ADDRESS;
                if (id_pc_i[$clog2(BUNDLE_BYTES)-1:0] != '0) begin
                    events_o.instruction_error.kind = ERROR_ALIGNMENT;
                end
                events_o.instruction_error.address = id_pc_i;
            end
            events_o.alignment_error.valid = advance_i && alignment_error_i;
            if (events_o.alignment_error.valid) begin
                events_o.alignment_error.kind = ERROR_ALIGNMENT;
                events_o.alignment_error.address = effective_address_i;
            end
            if (dmem_done_i) begin
                events_o.dmem_origin = dmem_origin_i;
                if (dmem_error_i) begin
                    events_o.dmem_origin = ORIGIN_ERROR;
                end
            end
        end
    end

    /** @brief No duplica dmem_begin mientras req_valid se mantiene por backpressure. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            demand_seen_q <= 1'b0;
        end else if (dmem_done_i) begin
            demand_seen_q <= 1'b0;
        end else if (req_valid_i) begin
            demand_seen_q <= 1'b1;
        end
    end

    /**
     * @brief Conserva un error ROM que llega antes de un stall, hasta admitir ID.
     * @details Cancelar ID por terminacion tambien cancela ese diagnostico joven.
     * La cuenta de retardo identifica los dos bundles dinamicos tras cada salto.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            id_error_q <= 1'b0;
            delay_remaining_q <= '0;
        end else begin
            if (id_admit_i || stop_admission_i) id_error_q <= 1'b0;
            else if (instruction_error_i && id_valid_i) id_error_q <= 1'b1;
            if (advance_i && ex_valid_i) begin
                if (branch_valid_i) delay_remaining_q <= BRANCH_NOP_BUNDLES;
                else if (delay_remaining_q != 0) delay_remaining_q <= delay_remaining_q - 1'b1;
            end
        end
    end
endmodule
