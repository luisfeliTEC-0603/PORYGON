// Testbench autochecking de cache_l2 (P2-07 / P2-08).
// Ejecutar con -GN=4 y -GN=1 (L2_MAX_INFLIGHT).
`timescale 1ns/1ps
module tb_cache_l2 #(parameter int N = 4);
  import pkg_memory::*;
  localparam int IDW = id_width(N);
  localparam int MEM_LAT = 10;

  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;

  // ---------------- DUT ----------------
  logic l2_get_valid_i = 0, l2_get_ready_o; address_t l2_get_base_i = 0;
  logic [IDW-1:0] l2_get_accept_id_o;
  logic l2_fill_valid_o, l2_fill_ready_i = 0, l2_fill_dirty_o, l2_fill_error_o;
  logic [IDW-1:0] l2_fill_id_o; address_t l2_fill_base_o; line_t l2_fill_data_o;
  logic wb_install_valid_i = 0, wb_install_ready_o, wb_install_dirty_i = 0;
  address_t wb_install_base_i = 0; line_t wb_install_data_i = 0;
  logic [IDW-1:0] wb_install_accept_id_o, wb_done_id_o;
  logic wb_done_valid_o, wb_done_ready_i = 0;
  logic eb_push_valid_o, eb_push_ready_i, eb_push_dirty_o;
  address_t eb_push_base_o; line_t eb_push_data_o;
  logic eb_probe_valid_o, eb_probe_hit_i; address_t eb_probe_base_o;
  logic mem_rd_req_valid_o, mem_rd_req_ready_i; logic [IDW-1:0] mem_rd_req_id_o;
  address_t mem_rd_req_base_o;
  logic mem_rd_rsp_valid_i, mem_rd_rsp_ready_i; logic [IDW-1:0] mem_rd_rsp_id_i;
  address_t mem_rd_rsp_base_i; logic mem_rd_rsp_error_i = 0;
  pkg_metrics::l2_events_t perf;

  cache_l2 #(.L2_MAX_INFLIGHT(N)) dut (
    .clk_i(clk), .rst_ni,
    .l2_get_valid_i, .l2_get_ready_o, .l2_get_base_i, .l2_get_accept_id_o,
    .l2_fill_valid_o, .l2_fill_ready_i, .l2_fill_id_o, .l2_fill_base_o,
    .l2_fill_data_o, .l2_fill_dirty_o, .l2_fill_error_o,
    .wb_install_valid_i, .wb_install_ready_o, .wb_install_base_i,
    .wb_install_data_i, .wb_install_dirty_i, .wb_install_accept_id_o,
    .wb_done_valid_o, .wb_done_ready_i, .wb_done_id_o,
    .eb_push_valid_o, .eb_push_ready_i, .eb_push_base_o, .eb_push_data_o, .eb_push_dirty_o,
    .eb_probe_valid_o, .eb_probe_base_o, .eb_probe_hit_i,
    .mem_rd_req_valid_o, .mem_rd_req_ready_i, .mem_rd_req_id_o, .mem_rd_req_base_o,
    .mem_rd_rsp_valid_i, .mem_rd_rsp_ready_i, .mem_rd_rsp_id_i,
    .mem_rd_rsp_base_i, .mem_rd_rsp_error_i, .perf_events_o(perf));

  // ---------------- modelo de EB (vectores empaquetados: compatible con Icarus) ----------------
  logic eb_ready_en = 1;
  logic [15:0]       eb_v = 16'h0;
  logic [16*32-1:0]  eb_b = '0;
  logic [31:0]       eb_cur;
  integer            eb_i, eb_j;
  logic              eb_hit_r;
  always @* begin
    eb_hit_r = 1'b0;
    for (eb_i = 0; eb_i < 16; eb_i = eb_i + 1)
      if (eb_v[eb_i] && eb_b[eb_i*32 +: 32] == eb_probe_base_o) eb_hit_r = 1'b1;
  end
  assign eb_probe_hit_i = eb_probe_valid_o && eb_hit_r;
  assign eb_push_ready_i = eb_ready_en && !(&eb_v);
  reg eb_done_ins;
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) eb_v <= 16'h0;
    else if (eb_push_valid_o && eb_push_ready_i) begin
      eb_done_ins = 1'b0;
      for (eb_j = 0; eb_j < 16; eb_j = eb_j + 1)
        if (!eb_v[eb_j] && !eb_done_ins) begin
          eb_v[eb_j] <= 1'b1; eb_b[eb_j*32 +: 32] <= eb_push_base_o;
          eb_done_ins = 1'b1;
        end
    end
  end
  task automatic eb_release(input address_t b);
    integer k;
    for (k = 0; k < 16; k = k + 1) if (eb_v[k] && eb_b[k*32 +: 32] == b) eb_v[k] = 1'b0;
  endtask

  // ---------------- modelo de memoria: varios bursts en vuelo, orden de respuesta configurable ----------------
  // rsp_gate=0 retiene respuestas; rsp_newest=1 responde primero a la peticion mas reciente (fuera de orden).
  localparam int MP = 8;
  logic mem_en = 1, rsp_ready_en = 0, rsp_gate = 1, rsp_newest = 0;
  reg [MP-1:0] mp_v = 0, mp_sent = 0;
  integer mp_cnt [0:MP-1];
  integer mp_seq [0:MP-1];
  reg [IDW-1:0] mp_id [0:MP-1];
  reg [31:0]    mp_base [0:MP-1];
  integer seq_ctr = 0, rsp_idx = 0, pi, pbest;
  reg mp_found;
  assign mem_rd_req_ready_i = mem_en && !(&mp_v);
  assign mem_rd_rsp_ready_i = rsp_ready_en;
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      mp_v <= 0; mp_sent <= 0; mem_rd_rsp_valid_i <= 0; mem_rd_rsp_id_i <= 0; mem_rd_rsp_base_i <= 0;
      seq_ctr = 0; rsp_idx = 0;
    end else begin
      for (pi = 0; pi < MP; pi = pi + 1)
        if (mp_v[pi] && mp_cnt[pi] > 0) mp_cnt[pi] <= mp_cnt[pi] - 1;
      if (mem_rd_req_valid_o && mem_rd_req_ready_i) begin
        mp_found = 0;
        for (pi = 0; pi < MP; pi = pi + 1)
          if (!mp_v[pi] && !mp_found) begin
            mp_found = 1; mp_v[pi] <= 1; mp_sent[pi] <= 0; mp_cnt[pi] <= MEM_LAT;
            mp_id[pi] <= mem_rd_req_id_o; mp_base[pi] <= mem_rd_req_base_o;
            mp_seq[pi] <= seq_ctr; seq_ctr = seq_ctr + 1;
          end
      end
      if (mem_rd_rsp_valid_i && mem_rd_rsp_ready_i) begin
        mem_rd_rsp_valid_i <= 0; mp_v[rsp_idx] <= 0; mp_sent[rsp_idx] <= 0;
      end else if (!mem_rd_rsp_valid_i && rsp_gate) begin
        pbest = -1;
        for (pi = 0; pi < MP; pi = pi + 1)
          if (mp_v[pi] && !mp_sent[pi] && mp_cnt[pi] == 0) begin
            if (pbest < 0) pbest = pi;
            else if (rsp_newest ? (mp_seq[pi] > mp_seq[pbest]) : (mp_seq[pi] < mp_seq[pbest])) pbest = pi;
          end
        if (pbest >= 0) begin
          mem_rd_rsp_valid_i <= 1; mp_sent[pbest] <= 1; rsp_idx = pbest;
          mem_rd_rsp_id_i <= mp_id[pbest]; mem_rd_rsp_base_i <= mp_base[pbest];
        end
      end
    end
  end

  // ---------------- monitores ----------------
  int cyc = 0, errors = 0;
  int get_cnt = 0, inst_cnt = 0, fill_cnt = 0, done_cnt = 0, push_cnt = 0, memreq_cnt = 0, rsp_cnt = 0;
  int get_cyc, fill_cyc, inst_cyc, memreq_cyc;
  int pc_getacc = 0, pc_getdone = 0, pc_promo = 0, pc_clean = 0, pc_dirtyev = 0;
  address_t last_clean_base, last_dirtyev_base, last_promo_base; logic last_promo_dirty;
  address_t fill_base_log [$];
  logic [IDW-1:0] done_id_log [$];
  logic [IDW-1:0] rsp_id_log [$];
  address_t rsp_base_log [$];
  logic [IDW-1:0] last_get_id, last_inst_id, last_fill_id, last_done_id;
  address_t last_fill_base, last_push_base; line_t last_fill_data, last_push_data;
  logic last_fill_dirty, last_push_dirty;
  address_t memreq_log [$];
  logic [IDW-1:0] memreq_id_log [$];
  bit stale_check = 0; // tras reset: ninguna entrega
  int deliveries_after_reset = 0;

  // estabilidad (valid && !ready => se conserva)
  bit p_fill, p_done, p_push, p_mem; bit p_fill_dirty, p_push_dirty; address_t p_fill_b, p_push_b, p_mem_b; line_t p_fill_d, p_push_d;
  logic [IDW-1:0] p_done_id, p_fill_id, p_mem_id;
  always @(posedge clk) begin
    if (rst_ni) begin
      if (p_fill && !(l2_fill_valid_o && l2_fill_base_o == p_fill_b && l2_fill_data_o == p_fill_d && l2_fill_id_o == p_fill_id && l2_fill_dirty_o == p_fill_dirty)) begin errors++; $display("[%0t] ERR fill inestable", $time); end
      if (p_done && !(wb_done_valid_o && wb_done_id_o == p_done_id)) begin errors++; $display("[%0t] ERR wb_done inestable", $time); end
      if (p_push && !(eb_push_valid_o && eb_push_base_o == p_push_b && eb_push_data_o == p_push_d && eb_push_dirty_o == p_push_dirty)) begin errors++; $display("[%0t] ERR eb_push inestable", $time); end
      if (p_mem  && !(mem_rd_req_valid_o && mem_rd_req_base_o == p_mem_b && mem_rd_req_id_o == p_mem_id)) begin errors++; $display("[%0t] ERR mem_rd_req inestable", $time); end
    end
    p_fill <= rst_ni && l2_fill_valid_o && !l2_fill_ready_i; p_fill_b <= l2_fill_base_o; p_fill_d <= l2_fill_data_o; p_fill_id <= l2_fill_id_o; p_fill_dirty <= l2_fill_dirty_o;
    p_done <= rst_ni && wb_done_valid_o && !wb_done_ready_i; p_done_id <= wb_done_id_o;
    p_push <= rst_ni && eb_push_valid_o && !eb_push_ready_i; p_push_b <= eb_push_base_o; p_push_d <= eb_push_data_o; p_push_dirty <= eb_push_dirty_o;
    p_mem  <= rst_ni && mem_rd_req_valid_o && !mem_rd_req_ready_i; p_mem_b <= mem_rd_req_base_o; p_mem_id <= mem_rd_req_id_o;

    if (rst_ni) begin
      if (l2_get_valid_i && l2_get_ready_o) begin get_cnt++; get_cyc = cyc; last_get_id = l2_get_accept_id_o; end
      if (wb_install_valid_i && wb_install_ready_o) begin inst_cnt++; inst_cyc = cyc; last_inst_id = wb_install_accept_id_o; end
      if (l2_fill_valid_o && l2_fill_ready_i) begin
        fill_cnt++; fill_cyc = cyc; fill_base_log.push_back(l2_fill_base_o); last_fill_id = l2_fill_id_o; last_fill_base = l2_fill_base_o;
        last_fill_data = l2_fill_data_o; last_fill_dirty = l2_fill_dirty_o;
        if (stale_check) deliveries_after_reset++;
      end
      if (wb_done_valid_o && wb_done_ready_i) begin done_cnt++; last_done_id = wb_done_id_o; done_id_log.push_back(wb_done_id_o); if (stale_check) deliveries_after_reset++; end
      if (eb_push_valid_o && eb_push_ready_i) begin push_cnt++; last_push_base = eb_push_base_o; last_push_data = eb_push_data_o; last_push_dirty = eb_push_dirty_o; end
      if (mem_rd_req_valid_o && mem_rd_req_ready_i) begin memreq_cnt++; memreq_cyc = cyc; memreq_log.push_back(mem_rd_req_base_o); memreq_id_log.push_back(mem_rd_req_id_o); end
      if (mem_rd_rsp_valid_i && mem_rd_rsp_ready_i) begin rsp_cnt++; rsp_id_log.push_back(mem_rd_rsp_id_i); rsp_base_log.push_back(mem_rd_rsp_base_i); end
      if (perf.get_accept.valid) pc_getacc++;
      if (perf.get_done.valid)   pc_getdone++;
      if (perf.promotion.valid)  begin pc_promo++; last_promo_base = perf.promotion.base; last_promo_dirty = perf.promotion.dirty; end
      if (perf.clean_discard.valid)  begin pc_clean++;   last_clean_base = perf.clean_discard.base; end
      if (perf.dirty_eviction.valid) begin pc_dirtyev++; last_dirtyev_base = perf.dirty_eviction.base; end
      if (l2_fill_valid_o && l2_fill_error_o) begin errors++; $display("ERR fill con error"); end
    end
    cyc++;
  end

  // ---------------- utilidades ----------------
  task automatic chk(input bit c, input string msg);
    if (!c) begin errors++; $display("[%0t] ERR: %s", $time, msg); end
  endtask
  function automatic line_t mkdata(input int seed);
    line_t d; for (int k = 0; k < 8; k++) d[32*k +: 32] = 32'(seed * 32'h9E3779B1) ^ 32'(k * 32'h01010101);
    return d;
  endfunction
  function automatic address_t mkbase(input int set, input int tag);
    if (set < 0 || set > 127 || tag < 0 || tag > 15) $display("TB BUG: mkbase fuera de rango set=%0d tag=%0d", set, tag);
    return address_t'(32'h0001_0000 | (tag << 12) | (set << 5));
  endfunction
  // con N=1..4 y rango 0x10000..0x1FFFF: set = bits[11:5]; "tag" 0..15 en [15:12]

  task automatic tick(input int n = 1); repeat (n) @(posedge clk); #1; endtask

  task automatic do_install(input address_t b, input line_t d, input bit dirty);
    int c0 = inst_cnt;
    wb_install_base_i = b; wb_install_data_i = d; wb_install_dirty_i = dirty; wb_install_valid_i = 1;
    for (int t = 0; t < 400 && inst_cnt == c0; t++) tick();
    chk(inst_cnt != c0, "install no aceptado (timeout)");
    wb_install_valid_i = 0;
  endtask
  task automatic do_get(input address_t b);
    int c0 = get_cnt;
    l2_get_base_i = b; l2_get_valid_i = 1;
    for (int t = 0; t < 400 && get_cnt == c0; t++) tick();
    chk(get_cnt != c0, "get no aceptado (timeout)");
    l2_get_valid_i = 0;
  endtask
  // Espera a que un contador cambie (macro: Icarus no soporta argumentos ref)
  `define WAIT_CNT(CNT, OLD, TMO, WHAT) \
    begin \
      for (int t_ = 0; t_ < (TMO) && (CNT) == (OLD); t_++) tick(); \
      chk((CNT) != (OLD), {"timeout esperando ", WHAT}); \
    end

  // ---------------- pruebas ----------------
  int c0, c1, f0, d0, p0, m0, id_a, id_b, r0, i0, g0, K, pm0, pc0, pd0, pg0;
  address_t Xb, B2, M3;
  logic [IDW-1:0] id_A, id_B, id_B2;
  address_t A, X, Y, L [8];
  initial begin
    #1; tick(3); rst_ni = 1; tick(3);
    wb_done_ready_i = 1; l2_fill_ready_i = 1; rsp_ready_en = 1;

    // T1: install + hit (latencia 8) + exclusividad
    $display("T1 install/hit/exclusividad");
    A = mkbase(5, 0);
    f0 = fill_cnt; d0 = done_cnt;
    do_install(A, mkdata(1), 1);
    `WAIT_CNT(done_cnt, d0, 60, "wb_done")
    chk(last_done_id == last_inst_id, "wb_done id != accept id");
    pm0 = pc_promo; f0 = fill_cnt; do_get(A);
    `WAIT_CNT(fill_cnt, f0, 60, "fill")
    chk(fill_cyc - get_cyc == 8, $sformatf("latencia hit L2 = %0d (esperado 8)", fill_cyc - get_cyc));
    chk(last_fill_base == A, "fill base");
    chk(last_fill_data == mkdata(1), "fill data");
    chk(last_fill_dirty == 1, "fill dirty");
    chk(last_fill_id == last_get_id, "fill id");
    chk(pc_promo == pm0 + 1, "promotion debe pulsar una vez por fill");
    chk(last_promo_base == A && last_promo_dirty == 1, "promotion base/dirty");
    tick(4);
    m0 = memreq_cnt; f0 = fill_cnt; do_get(A);   // ya no esta en L2 (exclusiva)
    `WAIT_CNT(memreq_cnt, m0, 60, "mem_rd_req (miss tras promocion)")
    chk(memreq_log[$] == A, "mem_rd_req base");
    chk(memreq_id_log[$] == last_get_id, "mem_rd_req id");
    tick(MEM_LAT + 10);
    chk(fill_cnt == f0, "miss no debe entregar por l2_fill (retorno directo)");
    chk(rsp_cnt >= 1, "rsp de memoria no consumido");

    // T2: vias invalidas primero, luego PLRU (victima = via 0 tras 4 instalaciones)
    $display("T2 PLRU / victima sucia");
    for (int i = 0; i < 5; i++) L[i] = mkbase(9, i);
    for (int i = 0; i < 4; i++) begin
      d0 = done_cnt; p0 = push_cnt;
      do_install(L[i], mkdata(10+i), 1);
      `WAIT_CNT(done_cnt, d0, 60, "wb_done")
      chk(push_cnt == p0, "no debe desalojar mientras haya via invalida");
    end
    d0 = done_cnt; p0 = push_cnt; pd0 = pc_dirtyev; pc0 = pc_clean;
    do_install(L[4], mkdata(14), 0);
    `WAIT_CNT(push_cnt, p0, 60, "eb_push")
    chk(last_push_base == L[0], "victima PLRU deberia ser L0");
    chk(last_push_data == mkdata(10), "eb_push data");
    chk(last_push_dirty == 1, "eb_push dirty");
    tick(2);
    chk(pc_dirtyev == pd0 + 1 && last_dirtyev_base == L[0], "dirty_eviction debe pulsar una vez con la base de L0");
    chk(pc_clean == pc0, "clean_discard no debe pulsar con victima sucia");
    `WAIT_CNT(done_cnt, d0, 60, "wb_done")

    // T3: retencion bajo presion de EB
    $display("T3 retencion con EB lleno");
    L[5] = mkbase(9, 5);
    eb_ready_en = 0; d0 = done_cnt; p0 = push_cnt;
    do_install(L[5], mkdata(15), 1);
    tick(25);
    chk(push_cnt == p0, "EB no debia aceptar");
    chk(eb_push_valid_o && eb_push_base_o == L[2], "victima retenida deberia ser L2");
    chk(done_cnt == d0, "wb_done antes de instalar");
    eb_ready_en = 1;
    `WAIT_CNT(push_cnt, p0, 30, "eb_push tras liberar")
    chk(last_push_base == L[2], "base victima L2");
    `WAIT_CNT(done_cnt, d0, 60, "wb_done")

    // T4: hit de una linea instalada limpia conserva dirty=0
    $display("T4 dirty limpio");
    f0 = fill_cnt; do_get(L[4]);
    `WAIT_CNT(fill_cnt, f0, 60, "fill L4")
    chk(last_fill_data == mkdata(14) && last_fill_dirty == 0, "L4 datos/dirty");

    // T5: una lectura bloqueada por EB no frena a una independiente
    if (N >= 2) begin
      $display("T5 HOL por conflicto con EB");
      // EB retiene L0 y L2 (nunca se liberan hasta que lo decidamos)
      chk(|eb_v, "EB deberia retener victimas");
      X = mkbase(40, 3);
      m0 = memreq_cnt;
      do_get(L[0]);   // mas antigua, coincide con EB
      do_get(X);      // mas joven, independiente
      tick(40);
      chk(memreq_cnt > m0, "lectura independiente no avanzo (HOL)");
      chk(memreq_log[m0] == X, "primera lectura emitida deberia ser X");
      chk(!(memreq_log.size() > m0+1 && memreq_log[m0+1] == L[0]), "L0 no debe leerse mientras EB la retenga");
      eb_release(L[0]);
      for (int t = 0; t < 80 && memreq_cnt < m0+2; t++) tick();
      chk(memreq_cnt >= m0+2 && memreq_log[m0+1] == L[0], "L0 debe leerse tras liberar EB");
      tick(MEM_LAT + 10);
    end

    // T6: limite de operaciones en vuelo
    $display("T6 limite en vuelo");
    rsp_ready_en = 0; mem_en = 0;
    for (int i = 0; i < N; i++) begin
      do_get(mkbase(60+i, 7));
    end
    // quinta (N+1): no se acepta
    c0 = get_cnt;
    l2_get_base_i = mkbase(80, 7); l2_get_valid_i = 1;
    tick(20);
    chk(get_cnt == c0, "se acepto una operacion por encima de L2_MAX_INFLIGHT");
    chk(!l2_get_ready_o, "ready debe ser 0 con limite alcanzado");
    mem_en = 1; rsp_ready_en = 1;
    for (int t = 0; t < 400 && get_cnt == c0; t++) tick();
    chk(get_cnt != c0, "tras liberar posiciones debe aceptarse");
    l2_get_valid_i = 0;
    tick(2*(MEM_LAT+12)); 

    // T7: reset cancela lineas, reservas y entregas pendientes
    $display("T7 reset");
    rsp_ready_en = 1;
    A = mkbase(20, 1); d0 = done_cnt;
    do_install(A, mkdata(77), 1);
    `WAIT_CNT(done_cnt, d0, 60, "wb_done")
    l2_fill_ready_i = 0;
    do_get(A);
    tick(14);            // fill pendiente (valid && !ready)
    chk(l2_fill_valid_o, "fill deberia estar pendiente");
    rst_ni = 0; tick(2); rst_ni = 1; stale_check = 1; l2_fill_ready_i = 1; wb_done_ready_i = 1;
    tick(30);
    chk(deliveries_after_reset == 0, "se entregaron resultados de operaciones previas al reset");
    chk(perf.inflight == 0, "tras reset no deben quedar operaciones en vuelo");
    m0 = memreq_cnt; do_get(A);
    `WAIT_CNT(memreq_cnt, m0, 60, "mem_rd_req tras reset (linea cancelada)")
    chk(memreq_log[$] == A, "tras reset la linea debe ser miss");

    // ================= Pruebas ampliadas =================
    stale_check = 0; rsp_ready_en = 1; rsp_gate = 1; rsp_newest = 0; mem_en = 1;
    l2_fill_ready_i = 1; wb_done_ready_i = 1; eb_ready_en = 1;
    tick(MEM_LAT + 20);

    // T8: latencia de miss (8 ciclos hasta mem_rd_req) y liberacion de id en el handshake de rsp
    $display("T8 latencia miss + retencion/liberacion de id");
    Xb = mkbase(100, 1); m0 = memreq_cnt; do_get(Xb);
    `WAIT_CNT(memreq_cnt, m0, 60, "mem_rd_req")
    chk(memreq_cyc - get_cyc == 8, $sformatf("latencia miss L2 = %0d (esperado 8)", memreq_cyc - get_cyc));
    tick(MEM_LAT + 10);
    rsp_ready_en = 0; r0 = rsp_cnt;
    for (int i = 0; i < N; i++) do_get(mkbase(101 + i, 2));
    tick(MEM_LAT + 25);
    l2_get_base_i = mkbase(110, 2);          // base libre de conflicto, valid=0
    chk(!l2_get_ready_o, "id/posicion deben seguir ocupados con rsp pendiente");
    tick(10);
    chk(!l2_get_ready_o, "id/posicion deben seguir ocupados mientras no se consuma rsp");
    rsp_ready_en = 1;
    `WAIT_CNT(rsp_cnt, r0, 20, "rsp consumido")
    chk(l2_get_ready_o, "el id debe liberarse en el mismo flanco del handshake de rsp");
    tick(N * (MEM_LAT + 10) + 20);
    chk(perf.inflight == 0, "T8: no deben quedar operaciones en vuelo");

    // T9: retorno de memoria fuera de orden
    if (N >= 2) begin
      $display("T9 respuestas de memoria fuera de orden");
      K = (N >= 3) ? 3 : N;
      m0 = memreq_cnt; r0 = rsp_cnt; rsp_gate = 0; rsp_newest = 1;
      for (int i = 0; i < K; i++) do_get(mkbase(120 + i, 1));
      for (int t = 0; t < 100 && memreq_cnt < m0 + K; t++) tick();
      chk(memreq_cnt == m0 + K, "no se emitieron las K lecturas simultaneas");
      tick(MEM_LAT + 5);
      chk(rsp_cnt == r0, "no debe haber rsp con la compuerta cerrada");
      rsp_gate = 1;
      for (int t = 0; t < 200 && rsp_cnt < r0 + K; t++) tick();
      chk(rsp_cnt == r0 + K, "no se consumieron las K respuestas");
      for (int j = 0; j < K; j++)
        chk(rsp_id_log[r0 + j] == memreq_id_log[m0 + K - 1 - j] && rsp_base_log[r0 + j] == memreq_log[m0 + K - 1 - j],
            $sformatf("rsp %0d no esta en orden inverso", j));
      tick(6);
      chk(perf.inflight == 0, "T9: tras respuestas fuera de orden deben liberarse todos los ids");
      rsp_newest = 0;
      // todas las posiciones vuelven a estar disponibles
      for (int i = 0; i < N; i++) do_get(mkbase(112 + i, 1));
      tick(N * (MEM_LAT + 10) + 20);
    end else $display("T9 SKIP (requiere N>=2: dos lecturas simultaneas en vuelo)");

    // T10: via PLRU reservada -> la instalacion espera (no cambia de victima)
    if (N >= 2) begin
      $display("T10 via PLRU reservada: install espera");
      for (int i = 0; i < 5; i++) L[i] = mkbase(90, i);
      for (int i = 0; i < 4; i++) begin
        d0 = done_cnt; do_install(L[i], mkdata(100 + i), 0);
        `WAIT_CNT(done_cnt, d0, 60, "wb_done")
      end
      // victima PLRU = via 0 (L0). Se reserva con un hit cuyo fill no se acepta.
      l2_fill_ready_i = 0; f0 = fill_cnt; do_get(L[0]);
      tick(12);
      i0 = inst_cnt; p0 = push_cnt; pc0 = pc_clean; d0 = done_cnt;
      wb_install_base_i = L[4]; wb_install_data_i = mkdata(104); wb_install_dirty_i = 0; wb_install_valid_i = 1;
      tick(25);
      chk(inst_cnt == i0 && !wb_install_ready_o, "install debe esperar mientras la via PLRU esta reservada");
      chk(push_cnt == p0 && !eb_push_valid_o, "no debe desalojarse otra via mientras tanto");
      l2_fill_ready_i = 1;
      `WAIT_CNT(fill_cnt, f0, 30, "fill de L0")
      chk(last_fill_base == L[0] && last_fill_data == mkdata(100), "fill de L0 datos");
      for (int t = 0; t < 60 && inst_cnt == i0; t++) tick();
      chk(inst_cnt != i0, "install debe aceptarse al liberarse la via");
      wb_install_valid_i = 0;
      `WAIT_CNT(done_cnt, d0, 60, "wb_done de L4")
      chk(push_cnt == p0 && pc_clean == pc0, "al usar la via invalidada no hay desalojo ni clean_discard");
    end else $display("T10 SKIP (requiere N>=2: install concurrente con demanda reservada)");

    // T11: victima limpia -> sin EB, con clean_discard
    $display("T11 victima limpia");
    for (int i = 0; i < 5; i++) L[i] = mkbase(91, i);
    for (int i = 0; i < 4; i++) begin
      d0 = done_cnt; do_install(L[i], mkdata(110 + i), 0);
      `WAIT_CNT(done_cnt, d0, 60, "wb_done")
    end
    p0 = push_cnt; pc0 = pc_clean; pd0 = pc_dirtyev; d0 = done_cnt;
    do_install(L[4], mkdata(114), 0);
    `WAIT_CNT(done_cnt, d0, 60, "wb_done")
    tick(2);
    chk(push_cnt == p0, "victima limpia no debe ir a EB");
    chk(pc_clean == pc0 + 1 && last_clean_base == L[0], "clean_discard debe pulsar una vez con la base de la victima");
    chk(pc_dirtyev == pd0, "no hay dirty_eviction con victima limpia");

    // T12: install en servicio (wb_done sin consumir) bloquea una demanda a la misma base
    if (N >= 2) begin
      $display("T12 conflicto de linea: demanda espera a install");
      A = mkbase(92, 1); wb_done_ready_i = 0; d0 = done_cnt; i0 = inst_cnt;
      do_install(A, mkdata(120), 1);
      tick(15);
      g0 = get_cnt;
      l2_get_base_i = A; l2_get_valid_i = 1;
      tick(25);
      chk(get_cnt == g0, "la demanda no debe aceptarse mientras el install de esa base siga ocupando posicion");
      chk(done_cnt == d0, "wb_done no se consumio");
      f0 = fill_cnt; wb_done_ready_i = 1;
      for (int t = 0; t < 40 && get_cnt == g0; t++) tick();
      chk(get_cnt != g0, "la demanda debe aceptarse tras consumir wb_done");
      l2_get_valid_i = 0;
      `WAIT_CNT(fill_cnt, f0, 60, "fill tras install")
      chk(last_fill_data == mkdata(120) && last_fill_dirty == 1, "demanda debe recuperar la linea instalada");
    end else $display("T12 SKIP (requiere N>=2)");

    // T13: tras el primer handshake, entre dos respuestas listas gana la mas antigua
    //      aunque tenga mayor indice (el lock solo protege a la primera oferta).
    if (N >= 3) begin
      $display("T13 antiguedad en el canal fill");
      A = mkbase(93, 1); B2 = mkbase(94, 1); M3 = mkbase(95, 1);
      d0 = done_cnt; do_install(A, mkdata(130), 0);  `WAIT_CNT(done_cnt, d0, 60, "wb_done A")
      d0 = done_cnt; do_install(B2, mkdata(131), 0); `WAIT_CNT(done_cnt, d0, 60, "wb_done B")
      d0 = done_cnt; do_install(M3, mkdata(132), 0); `WAIT_CNT(done_cnt, d0, 60, "wb_done C")
      mem_en = 1; rsp_gate = 0; rsp_newest = 1; rsp_ready_en = 1; l2_fill_ready_i = 0;
      m0 = memreq_cnt;
      do_get(mkbase(98, 1)); do_get(mkbase(99, 1));          // M1 (id0) y M2 (id1): misses
      for (int t = 0; t < 100 && memreq_cnt < m0 + 2; t++) tick();
      tick(MEM_LAT + 3);
      do_get(A); id_A = last_get_id;                         // id2: primera oferta de fill (queda con lock)
      r0 = rsp_cnt; rsp_gate = 1;
      for (int t = 0; t < 50 && rsp_cnt == r0; t++) tick();  // responde M2 (la mas reciente): libera id1
      rsp_gate = 0;
      do_get(B2); id_B = last_get_id;                        // reutiliza id1 (mayor indice que C)
      tick(15);
      r0 = rsp_cnt; rsp_gate = 1;
      for (int t = 0; t < 50 && rsp_cnt == r0; t++) tick();  // responde M1: libera id0
      rsp_gate = 0;
      do_get(M3); id_B2 = last_get_id;                       // C: mas joven, id0 (menor indice)
      rsp_gate = 1; rsp_newest = 0;
      chk(id_B > id_B2, "setup: B (mas antigua) debe tener id mayor que C");
      tick(20);
      f0 = fill_cnt; l2_fill_ready_i = 1;
      for (int t = 0; t < 60 && fill_cnt < f0 + 3; t++) tick();
      chk(fill_cnt == f0 + 3, "no se entregaron los tres fills");
      chk(fill_base_log[f0] == A, "primera oferta (A) debe entregarse primero");
      chk(fill_base_log[f0 + 1] == B2 && fill_base_log[f0 + 2] == M3, "tras A debe entregarse B (mas antigua) antes que C aunque su id sea mayor");
    end else $display("T13 SKIP (requiere N>=3: tres respuestas pendientes en el canal fill)");

    // T14: empate install vs demanda -> gana el drenado (install)
    if (N >= 2) begin
      $display("T14 prioridad de drenado en empate");
      A = mkbase(96, 1); d0 = done_cnt; do_install(A, mkdata(140), 0); `WAIT_CNT(done_cnt, d0, 60, "wb_done")
      tick(3);
      i0 = inst_cnt; g0 = get_cnt;
      l2_get_base_i = A; l2_get_valid_i = 1;
      wb_install_base_i = mkbase(97, 1); wb_install_data_i = mkdata(141); wb_install_dirty_i = 0; wb_install_valid_i = 1;
      for (int t = 0; t < 60 && (inst_cnt == i0 || get_cnt == g0); t++) begin
        tick();
        if (inst_cnt != i0) wb_install_valid_i = 0;
        if (get_cnt != g0) l2_get_valid_i = 0;
      end
      chk(inst_cnt != i0 && get_cnt != g0, "ambas deben terminar aceptandose");
      chk(inst_cyc < get_cyc, "con solicitudes simultaneas debe aceptarse primero el install");
      tick(30);
    end else $display("T14 SKIP (requiere N>=2)");

    // Consistencia global de metricas
    $display("T15 consistencia de metricas");
    chk(pc_getacc == get_cnt, $sformatf("get_accept pulsos=%0d vs handshakes=%0d", pc_getacc, get_cnt));
    chk(pc_getdone == fill_cnt && pc_promo == fill_cnt, $sformatf("get_done/promotion pulsos=%0d/%0d vs fills=%0d", pc_getdone, pc_promo, fill_cnt));
    chk(pc_dirtyev == push_cnt, $sformatf("dirty_eviction pulsos=%0d vs eb_push=%0d", pc_dirtyev, push_cnt));

    tick(20);
    if (errors == 0) $display("PASS (N=%0d)", N); else $display("FAIL (N=%0d): %0d errores", N, errors);
    $finish;
  end
  initial begin #20000000; $display("WATCHDOG"); $finish; end
endmodule
