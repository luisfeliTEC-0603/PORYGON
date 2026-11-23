/**
 * @brief Observa finalizaciones en EX, WB y MUL sin controlar el datapath.
 * @details MUL necesita tres avances posteriores a EX: EX2, captura WB y RF.
 * Las demas operaciones diferidas necesitan uno. Registros y eventos se pausan
 * con advance_i; reset cancela todo. Los NOP/literales se atribuyen una vez al
 * completar su bundle, incluso si termina despues que uno mas joven.
 */
module bundle_completions (
    input logic clk_i,
    input logic rst_ni,
    input logic advance_i,
    input logic ex_valid_i,
    input pkg_vliw::bundle_t ex_bundle_i,
    input pkg_metrics::event_delta_t wb_operations_i,
    input logic mul_operation_i,
    output pkg_metrics::completion_delta_t done_o,
    output logic wb_occupied_o,
    output logic mul_occupied_o
);
    import pkg_vliw::*;
    import pkg_metrics::*;
    completion_delta_t counts, immediate, wb_later, mul_later;
    completion_delta_t due1_q, due2_q, due3_q;
    logic previous_literal, literal_slot;
    slot_t slot;

    /** @brief Suma por campos para mantener independientes los cuatro deltas. */
    function automatic completion_delta_t add(input completion_delta_t a, b);
        add.bundles = a.bundles + b.bundles;
        add.instructions = a.instructions + b.instructions;
        add.nop_slots = a.nop_slots + b.nop_slots;
        add.literal_slots = a.literal_slots + b.literal_slots;
    endfunction

    /** @brief Clasifica slots usando el mismo corte de cadena de inmediatos de ID. */
    always_comb begin
        counts = '0;
        previous_literal = 1'b0;
        literal_slot = 1'b0;
        slot = '0;
        for (integer index = 0; index < NUM_SLOTS; index++) begin
            slot = ex_bundle_i[index*SLOT_WIDTH +: SLOT_WIDTH];
            literal_slot = 1'b0;
            if (index > 0) begin
                literal_slot = ex_bundle_i[(index-1)*SLOT_WIDTH+2] && !previous_literal;
            end
            if (literal_slot) begin
                counts.literal_slots++;
            end else if (slot == NOP_ENCODING) begin
                counts.nop_slots++;
            end else begin
                counts.instructions++;
            end
            previous_literal = literal_slot;
        end
        immediate = '0;
        wb_later = '0;
        mul_later = '0;
        if (ex_valid_i) begin
            counts.bundles = 1;
            if (mul_operation_i) begin
                mul_later = counts;
            end else if (wb_operations_i != 0) begin
                wb_later = counts;
            end else begin
                immediate = counts;
            end
            immediate.instructions = counts.instructions - wb_operations_i - event_delta_t'(mul_operation_i);
            wb_later.instructions = wb_operations_i;
            mul_later.instructions = event_delta_t'(mul_operation_i);
        end
    end

    assign done_o = (rst_ni && advance_i) ? add(immediate, due1_q) : '0;
    assign wb_occupied_o = rst_ni && (due1_q.instructions != 0);
    assign mul_occupied_o = rst_ni && ((due2_q.instructions != 0) || (due3_q.instructions != 0));
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            due1_q <= '0;
            due2_q <= '0;
            due3_q <= '0;
        end else if (advance_i) begin
            due1_q <= add(due2_q, wb_later);
            due2_q <= due3_q;
            due3_q <= mul_later;
        end
    end
endmodule
