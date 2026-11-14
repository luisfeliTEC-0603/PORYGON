/**
 * @brief L2 exclusiva: 16 KiB, cuatro vias, tree-PLRU, write-back, non-blocking.
 * @param L2_MAX_INFLIGHT Operaciones aceptadas hasta finalizacion consumida;
 * cuatro por defecto, rango 1..4. No determina bancos ni busquedas simultaneas.
 * @details Top de solo cableado y reglas de admision. Submodulos: l2_tag_array,
 * l2_data_array, l2_plru, l2_way_resv, l2_lookup, l2_way_select,
 * l2_op_table, l2_pipe, l2_out_sel, l2_fill_unit, l2_install_unit,
 * l2_evict_unit, l2_mem_unit, l2_perf.
 *
 * Exclusividad: hit L2 -> L1 invalida en L2 al aceptar L1; miss L2 -> retorno
 * directo (L2 solo observa mem_rd_rsp valid&&ready y libera el id); instalacion
 * WB conserva dirty y ofrece wb_done solo despues de escribir los arreglos.
 * Latencia: accept (ciclo T) -> fill_valid / mem_rd_req_valid en T+8.
 *
 * Demandas a una misma base: no se admite una segunda mientras exista una
 * operacion activa con esa base (conflict_a); espera y, al terminar la
 * primera, se evalua de nuevo. No hay MSHR ni waiters.
 *
 * Reset: asincrono (rst_ni) sobre todo el estado (tags, reservas, PLRU, tabla,
 * pipeline, arbitros); las salidas valid se fuerzan a 0 con rst_ni.
 *
 * Nota: la via de una victima sucia no se invalida al aceptarla EB; permanece
 * reservada (nadie puede acertarla ni elegirla) y se sobrescribe al instalar.
 */

module cache_l2 #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    input logic l2_get_valid_i,
    output logic l2_get_ready_o,
    input pkg_memory::address_t l2_get_base_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] l2_get_accept_id_o,

    output logic l2_fill_valid_o,
    input logic l2_fill_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] l2_fill_id_o,
    output pkg_memory::address_t l2_fill_base_o,
    output pkg_memory::line_t l2_fill_data_o,
    output logic l2_fill_dirty_o,
    output logic l2_fill_error_o,

    input logic wb_install_valid_i,
    output logic wb_install_ready_o,
    input pkg_memory::address_t wb_install_base_i,
    input pkg_memory::line_t wb_install_data_i,
    input logic wb_install_dirty_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] wb_install_accept_id_o,
    output logic wb_done_valid_o,
    input logic wb_done_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] wb_done_id_o,

    output logic eb_push_valid_o,
    input logic eb_push_ready_i,
    output pkg_memory::address_t eb_push_base_o,
    output pkg_memory::line_t eb_push_data_o,
    output logic eb_push_dirty_o,

    output logic eb_probe_valid_o,
    output pkg_memory::address_t eb_probe_base_o,
    input logic eb_probe_hit_i,

    output logic mem_rd_req_valid_o,
    input logic mem_rd_req_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_req_id_o,
    output pkg_memory::address_t mem_rd_req_base_o,

    input logic mem_rd_rsp_valid_i,
    input logic mem_rd_rsp_ready_i,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_rsp_id_i,
    input pkg_memory::address_t mem_rd_rsp_base_i,
    input logic mem_rd_rsp_error_i,

    output pkg_metrics::l2_events_t perf_events_o
);
    // ------------------------------------------------------------------
    // Geometria derivada
    // ------------------------------------------------------------------
    localparam int AW       = $bits(pkg_memory::address_t);
    localparam int LW       = $bits(pkg_memory::line_t);
    localparam int OFFSET_W = $clog2(pkg_memory::LINE_BYTES);
    localparam int SETS     = pkg_memory::L2_BYTES / (pkg_memory::L2_WAYS * pkg_memory::LINE_BYTES);
    localparam int SET_W    = $clog2(SETS);
    localparam int WAYS     = pkg_memory::L2_WAYS;
    localparam int WAY_W    = $clog2(WAYS);
    localparam int TAG_W    = AW - SET_W - OFFSET_W;
    localparam int PIPE_STAGES  = 7;
    localparam int TAG_LAST_STG = 3;

    localparam int N    = L2_MAX_INFLIGHT;
    localparam int ID_W = pkg_memory::id_width(N);
    localparam int OPW  = (N > 1) ? $clog2(N) : 1;

    initial begin
        if (N < 1 || N > 4) $display("ERROR cache_l2: L2_MAX_INFLIGHT fuera de 1..4");
        if (WAYS != 4) $display("ERROR cache_l2: tree-PLRU implementado para 4 vias");
    end

    // ------------------------------------------------------------------
    // Decodificacion de direcciones
    // ------------------------------------------------------------------
    logic [AW-1:0]    get_base, inst_base;
    logic [SET_W-1:0] get_set, inst_set;
    logic [TAG_W-1:0] get_tag, inst_tag;
    assign get_base  = l2_get_base_i;
    assign inst_base = wb_install_base_i;
    assign get_set   = get_base[OFFSET_W +: SET_W];
    assign get_tag   = get_base[OFFSET_W+SET_W +: TAG_W];
    assign inst_set  = inst_base[OFFSET_W +: SET_W];
    assign inst_tag  = inst_base[OFFSET_W+SET_W +: TAG_W];

    // ------------------------------------------------------------------
    // Arreglos, PLRU, reservas
    // ------------------------------------------------------------------
    logic [WAYS*TAG_W-1:0] a_tags, b_tags;
    logic [WAYS-1:0] a_valid, b_valid, a_dirty, b_dirty, a_resv, b_resv;

    // Escritura de install (desde l2_install_unit)
    logic             wr_valid;
    logic [SET_W-1:0] wr_set;
    logic [WAY_W-1:0] wr_way;
    logic [TAG_W-1:0] wr_tag;
    logic             wr_dirty;
    logic [LW-1:0]    wr_data;
    logic [OPW-1:0]   wr_idx;
    logic             wr_first;

    // Invalidacion de fill (desde l2_fill_unit)
    logic             inv_valid;
    logic [SET_W-1:0] inv_set;
    logic [WAY_W-1:0] inv_way;

    // Lecturas de datos
    logic [LW-1:0]    rd0_data, rd1_data;
    logic [SET_W-1:0] rd0_set, rd1_set;
    logic [WAY_W-1:0] rd0_way, rd1_way;

    // Salidas de la tabla
    logic [N*AW-1:0]    t_base, t_vbase;
    logic [N*WAY_W-1:0] t_way;
    logic [N*LW-1:0]    t_data;
    logic [N-1:0]       t_dirty;

    l2_tag_array #(.SETS(SETS), .WAYS(WAYS), .TAG_W(TAG_W)) u_tags (
        .clk_i, .rst_ni,
        .rd_a_set_i(get_set),  .rd_a_tag_o(a_tags), .rd_a_valid_o(a_valid), .rd_a_dirty_o(a_dirty),
        .rd_b_set_i(inst_set), .rd_b_tag_o(b_tags), .rd_b_valid_o(b_valid), .rd_b_dirty_o(b_dirty),
        .wr_valid_i(wr_valid), .wr_set_i(wr_set), .wr_way_i(wr_way),
        .wr_tag_i(wr_tag), .wr_dirty_i(wr_dirty),
        .inv_valid_i(inv_valid), .inv_set_i(inv_set), .inv_way_i(inv_way)
    );

    l2_data_array #(.SETS(SETS), .WAYS(WAYS), .LW(LW)) u_data (
        .clk_i,
        .rd0_set_i(rd0_set), .rd0_way_i(rd0_way), .rd0_data_o(rd0_data),
        .rd1_set_i(rd1_set), .rd1_way_i(rd1_way), .rd1_data_o(rd1_data),
        .wr_valid_i(wr_valid), .wr_set_i(wr_set), .wr_way_i(wr_way),
        .wr_data_i(wr_data)
    );

    // PLRU: query = set de install (para elegir victima); touch = write de install
    logic [1:0] plru_way;
    logic       plru_touch_valid;
    logic [SET_W-1:0] plru_touch_set;
    logic [WAY_W-1:0] plru_touch_way;

    l2_plru #(.SETS(SETS)) u_plru (
        .clk_i, .rst_ni,
        .query_set_i(inst_set), .victim_way_o(plru_way),
        .touch_valid_i(plru_touch_valid), .touch_set_i(plru_touch_set),
        .touch_way_i(plru_touch_way)
    );

    // Reservas: set al aceptar (hit de demanda o via de install), clears de fill/install
    logic             resv_set_valid;
    logic [SET_W-1:0] resv_set_set;
    logic [WAY_W-1:0] resv_set_way;
    logic             resv_clr0_valid;   // fill
    logic [SET_W-1:0] resv_clr0_set;
    logic [WAY_W-1:0] resv_clr0_way;
    logic             resv_clr1_valid;   // install
    logic [SET_W-1:0] resv_clr1_set;
    logic [WAY_W-1:0] resv_clr1_way;

    l2_way_resv #(.SETS(SETS), .WAYS(WAYS)) u_resv (
        .clk_i, .rst_ni,
        .rd_a_set_i(get_set),  .rd_a_resv_o(a_resv),
        .rd_b_set_i(inst_set), .rd_b_resv_o(b_resv),
        .set_valid_i(resv_set_valid), .set_set_i(resv_set_set), .set_way_i(resv_set_way),
        .clr0_valid_i(resv_clr0_valid), .clr0_set_i(resv_clr0_set), .clr0_way_i(resv_clr0_way),
        .clr1_valid_i(resv_clr1_valid), .clr1_set_i(resv_clr1_set), .clr1_way_i(resv_clr1_way)
    );

    // ------------------------------------------------------------------
    // Lookup de demanda e install, eleccion de via
    // ------------------------------------------------------------------
    logic get_hit, inst_hit;
    logic [WAY_W-1:0] get_hit_way, inst_hit_way;
    l2_lookup #(.WAYS(WAYS), .TAG_W(TAG_W)) u_look_get (
        .tags_i(a_tags), .valid_i(a_valid), .tag_i(get_tag), .hit_o(get_hit), .way_o(get_hit_way));
    l2_lookup #(.WAYS(WAYS), .TAG_W(TAG_W)) u_look_inst (
        .tags_i(b_tags), .valid_i(b_valid), .tag_i(inst_tag), .hit_o(inst_hit), .way_o(inst_hit_way));

    logic [WAY_W-1:0] sel_way;
    logic             sel_ok;
    l2_way_select #(.WAYS(WAYS), .WAY_W(WAY_W)) u_way_sel (
        .valid_i(b_valid), .resv_i(b_resv), .plru_way_i(plru_way),
        .way_o(sel_way), .ok_o(sel_ok));

    logic [WAY_W-1:0] inst_way;
    logic             inst_way_ok, inst_vvalid, inst_vdirty, inst_dirty_in;
    logic [AW-1:0]    inst_vbase;
    assign inst_way     = inst_hit ? inst_hit_way : sel_way;
    assign inst_way_ok  = inst_hit ? !b_resv[inst_hit_way] : sel_ok;
    assign inst_vvalid  = !inst_hit && b_valid[inst_way];
    assign inst_vdirty  = inst_vvalid && b_dirty[inst_way];
    assign inst_vbase   = {b_tags[inst_way*TAG_W +: TAG_W], inst_set, {OFFSET_W{1'b0}}};
    assign inst_dirty_in = wb_install_dirty_i | (inst_hit & b_dirty[inst_hit_way]);

    // ------------------------------------------------------------------
    // Tabla de operaciones, pipeline
    // ------------------------------------------------------------------
    logic             free_any, conflict_a, conflict_b;
    logic [OPW-1:0]   alloc_idx;
    logic [N-1:0]     busy, req_fill, req_mem, req_eb, req_wr, req_done;
    logic [N*N-1:0]   older;
    logic [N-1:0]     t_hit, t_kind, t_vvalid, t_vdirty;
    logic [N-1:0]     ev_fill, ev_mem, ev_rsp, ev_eb, ev_wr, ev_done;
    logic             pipe_end_valid;
    logic [OPW-1:0]   pipe_end_idx;
    logic [PIPE_STAGES-1:0]     stage_valid;
    logic [PIPE_STAGES*OPW-1:0] stage_idx;

    // Admision (una sola aceptacion por ciclo; drenado WB gana en empate):
    // - get con hit en via reservada -> espera
    // - get/install con base ya activa en la tabla -> espera (conflicto)
    // - get hit -> reserva la via; get miss -> sin reserva, lectura a memoria
    // - install -> reserva la via destino (invalida no reservada o PLRU)
    logic get_hit_blocked;
    assign get_hit_blocked = get_hit && a_resv[get_hit_way];

    logic get_pre, install_pre;
    assign get_pre      = rst_ni && free_any && !get_hit_blocked && !conflict_a;
    assign install_pre  = rst_ni && free_any && inst_way_ok && !conflict_b;
    assign wb_install_ready_o = install_pre;
    assign l2_get_ready_o = get_pre && !(wb_install_valid_i && install_pre);

    logic get_accept, install_accept;
    assign get_accept     = l2_get_valid_i && l2_get_ready_o;
    assign install_accept = wb_install_valid_i && wb_install_ready_o;

    assign l2_get_accept_id_o     = alloc_idx;
    assign wb_install_accept_id_o = alloc_idx;

    l2_op_table #(.N(N), .AW(AW), .LW(LW), .WAY_W(WAY_W)) u_table (
        .clk_i, .rst_ni,
        .alloc_valid_i(get_accept | install_accept),
        .alloc_kind_i(install_accept),
        .alloc_base_i(install_accept ? inst_base : get_base),
        .alloc_way_i(install_accept ? inst_way : get_hit_way),
        .alloc_hit_i(install_accept ? inst_hit : get_hit),
        .alloc_vvalid_i(install_accept & inst_vvalid),
        .alloc_vdirty_i(install_accept & inst_vdirty),
        .alloc_vbase_i(inst_vbase),
        .alloc_data_i(wb_install_data_i),
        .alloc_dirty_i(install_accept ? inst_dirty_in : a_dirty[get_hit_way]),
        .free_any_o(free_any), .alloc_idx_o(alloc_idx),
        .pipe_end_valid_i(pipe_end_valid), .pipe_end_idx_i(pipe_end_idx),
        .ev_fill_i(ev_fill), .ev_mem_i(ev_mem), .ev_rsp_i(ev_rsp),
        .ev_eb_i(ev_eb), .ev_wr_i(ev_wr), .ev_done_i(ev_done),
        .req_fill_o(req_fill), .req_mem_o(req_mem), .req_eb_o(req_eb),
        .req_wr_o(req_wr), .req_done_o(req_done),
        .busy_o(busy), .older_o(older),
        .base_o(t_base), .vbase_o(t_vbase), .way_o(t_way), .data_o(t_data),
        .dirty_o(t_dirty), .hit_o(t_hit), .kind_o(t_kind),
        .vvalid_o(t_vvalid), .vdirty_o(t_vdirty),
        .qa_base_i(get_base), .qb_base_i(inst_base),
        .conflict_a_o(conflict_a), .conflict_b_o(conflict_b)
    );

    l2_pipe #(.STAGES(PIPE_STAGES), .OPW(OPW)) u_pipe (
        .clk_i, .rst_ni,
        .in_valid_i(get_accept | install_accept), .in_idx_i(alloc_idx),
        .stage_valid_o(stage_valid), .stage_idx_o(stage_idx),
        .end_valid_o(pipe_end_valid), .end_idx_o(pipe_end_idx)
    );

    // Reserva al aceptar: via de hit (demanda) o via destino (instalacion)
    assign resv_set_valid = install_accept | (get_accept & get_hit);
    assign resv_set_set   = install_accept ? inst_set : get_set;
    assign resv_set_way   = install_accept ? inst_way : get_hit_way;

    // ------------------------------------------------------------------
    // l2_fill_unit (canal fill)
    // ------------------------------------------------------------------
    logic [SET_W-1:0] fill_sel_set;
    logic [WAY_W-1:0] fill_sel_way;
    logic             ev_fill_valid;

    l2_fill_unit #(.N(N), .AW(AW), .LW(LW), .WAY_W(WAY_W), .SET_W(SET_W), .OPW(OPW)) u_fill (
        .clk_i, .rst_ni,
        .req_fill_i(req_fill), .older_i(older),
        .t_base_i(t_base), .t_way_i(t_way), .t_dirty_i(t_dirty),
        .rd0_data_i(rd0_data),
        .l2_fill_valid_o, .l2_fill_ready_i,
        .l2_fill_id_o, .l2_fill_base_o, .l2_fill_data_o,
        .l2_fill_dirty_o, .l2_fill_error_o,
        .ev_fill_valid_o(ev_fill_valid), .ev_fill_onehot_o(ev_fill),
        .inv_valid_o(inv_valid), .inv_set_o(inv_set), .inv_way_o(inv_way),
        .resv_clr_valid_o(resv_clr0_valid), .resv_clr_set_o(resv_clr0_set),
        .resv_clr_way_o(resv_clr0_way),
        .sel_set_o(fill_sel_set), .sel_way_o(fill_sel_way)
    );

    // ------------------------------------------------------------------
    // l2_install_unit (canal de escritura)
    // ------------------------------------------------------------------
    l2_install_unit #(.N(N), .AW(AW), .LW(LW), .WAY_W(WAY_W),
                      .SET_W(SET_W), .TAG_W(TAG_W), .OPW(OPW)) u_install (
        .clk_i, .rst_ni,
        .req_wr_i(req_wr), .older_i(older),
        .t_base_i(t_base), .t_way_i(t_way), .t_data_i(t_data), .t_dirty_i(t_dirty),
        .wr_valid_o(wr_valid), .wr_set_o(wr_set), .wr_way_o(wr_way),
        .wr_tag_o(wr_tag), .wr_dirty_o(wr_dirty), .wr_data_o(wr_data),
        .wr_idx_o(wr_idx),
        .plru_touch_valid_o(plru_touch_valid),
        .plru_touch_set_o(plru_touch_set), .plru_touch_way_o(plru_touch_way),
        .resv_clr_valid_o(resv_clr1_valid), .resv_clr_set_o(resv_clr1_set),
        .resv_clr_way_o(resv_clr1_way),
        .ev_wr_valid_o(wr_first), .ev_wr_onehot_o(ev_wr)
    );

    // ------------------------------------------------------------------
    // l2_evict_unit (canal eb_push)
    // ------------------------------------------------------------------
    logic [SET_W-1:0] evict_sel_set;
    logic [WAY_W-1:0] evict_sel_way;

    l2_evict_unit #(.N(N), .AW(AW), .LW(LW), .WAY_W(WAY_W),
                    .SET_W(SET_W), .OPW(OPW)) u_evict (
        .clk_i, .rst_ni,
        .req_eb_i(req_eb), .older_i(older),
        .t_vbase_i(t_vbase), .t_way_i(t_way),
        .rd1_data_i(rd1_data),
        .eb_push_valid_o, .eb_push_ready_i,
        .eb_push_base_o, .eb_push_data_o, .eb_push_dirty_o,
        .ev_eb_valid_o(), .ev_eb_onehot_o(ev_eb),
        .sel_set_o(evict_sel_set), .sel_way_o(evict_sel_way)
    );

    // ------------------------------------------------------------------
    // l2_mem_unit (canal mem_rd_req + observacion de rsp)
    // ------------------------------------------------------------------
    l2_mem_unit #(.N(N), .AW(AW), .OPW(OPW)) u_mem (
        .clk_i, .rst_ni,
        .req_mem_i(req_mem), .older_i(older), .t_base_i(t_base),
        .eb_probe_hit_i(eb_probe_hit_i),
        .eb_probe_valid_o, .eb_probe_base_o,
        .mem_rd_req_valid_o, .mem_rd_req_ready_i,
        .mem_rd_req_id_o, .mem_rd_req_base_o,
        .mem_rd_rsp_valid_i, .mem_rd_rsp_ready_i,
        .mem_rd_rsp_id_i, .mem_rd_rsp_base_i,
        .ev_mem_valid_o(), .ev_mem_onehot_o(ev_mem),
        .ev_rsp_onehot_o(ev_rsp)
    );

    // ------------------------------------------------------------------
    // Seleccion de lecturas de datos: rd0 = fill, rd1 = evict
    // ------------------------------------------------------------------
    assign rd0_set = fill_sel_set;
    assign rd0_way = fill_sel_way;
    assign rd1_set = evict_sel_set;
    assign rd1_way = evict_sel_way;

    // ------------------------------------------------------------------
    // Canal wb_done (desde ST_DONE de la tabla)
    // ------------------------------------------------------------------
    logic done_sel_valid;
    logic [OPW-1:0] done_idx;
    logic [N-1:0] done_onehot;
    l2_out_sel #(.N(N)) u_sel_done (
        .clk_i, .rst_ni, .req_i(req_done), .older_i(older),
        .ext_valid_i(wb_done_valid_o), .ext_ready_i(wb_done_ready_i),
        .sel_valid_o(done_sel_valid), .sel_idx_o(done_idx),
        .sel_onehot_o(done_onehot));
    assign wb_done_valid_o = rst_ni && done_sel_valid;
    assign wb_done_id_o    = done_idx;
    logic done_hs;
    assign done_hs = wb_done_valid_o && wb_done_ready_i;
    assign ev_done = done_hs ? done_onehot : '0;

    // ------------------------------------------------------------------
    // Metricas
    // ------------------------------------------------------------------
    logic [OPW-1:0] look_idx;
    logic look_valid;
    assign look_valid = stage_valid[TAG_LAST_STG];
    assign look_idx   = stage_idx[TAG_LAST_STG*OPW +: OPW];

    logic [7:0] occupancy;
    always_comb begin
        occupancy = '0;
        for (int i = 0; i < N; i++) occupancy = occupancy + busy[i];
    end

    l2_perf #(.AW(AW), .ID_W(ID_W)) u_perf (
        .get_accept_i(get_accept), .get_base_i(get_base), .get_id_i(alloc_idx),
        .fill_hs_i(l2_fill_valid_o && l2_fill_ready_i),
        .fill_base_i(l2_fill_base_o), .fill_dirty_i(l2_fill_dirty_o), .fill_id_i(l2_fill_id_o),
        .lookup_valid_i(look_valid), .lookup_id_i(look_idx),
        .lookup_hit_i(t_hit[look_idx]), .lookup_is_write_i(t_kind[look_idx]),
        .clean_discard_i(wr_first && t_vvalid[wr_idx] && !t_vdirty[wr_idx]),
        .clean_base_i(t_vbase[wr_idx*AW +: AW]),
        .evict_i(eb_push_valid_o && eb_push_ready_i),
        .evict_base_i(eb_push_base_o),
        .inst_accept_i(install_accept), .inst_accept_id_i(alloc_idx),
        .inst_done_i(done_hs), .inst_done_id_i(done_idx),
        .occupancy_i(occupancy), .capacity_i(N[7:0]),
        .get_wait_i(l2_get_valid_i && !l2_get_ready_o),
        .inst_wait_i(wb_install_valid_i && !wb_install_ready_o),
        .mem_wait_i(mem_rd_req_valid_o && !mem_rd_req_ready_i),
        .eb_wait_i(eb_push_valid_o && !eb_push_ready_i),
        .perf_events_o(perf_events_o),
        .lookup_is_write_o(), .install_accept_o(), .install_accept_id_o(),
        .install_done_o(), .install_done_id_o(), .inst_wait_o(),
        .mem_wait_o(), .eb_wait_o()
    );
endmodule
