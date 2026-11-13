/**
 * @file l2_op_table.sv
 * @brief Tabla de operaciones en vuelo de L2 
 *
 * @details
 *   Guarda el estado, los metadatos y los datos de cada operación, la matriz
 *   de antigüedad y la consulta de conflcto por base. Una posición y su id
 *   permanecen ocupados hasta el handshake de finalización (fill, wb_done o
 *   respuesta de memoria observada).
 *
 *   Estados (todos codificados en 4 bits):
 *     IDLE      : posición libre.
 *     PIPE      : la operación atraviesa el pipeline interno.
 *     FILL      : demanda con hit L2; espera handshake de fill hacia L1.
 *     MEMREQ    : demanda con miss; solicita lectura a memoria.
 *     MEMWAIT   : demanda esperando la respuesta de memoria (owner del MSHR).
 *     WAIT_MSHR : demanda o install enganchada a un MSHR existente (waiter).
 *     EBOFF     : install con víctima sucia; espera aceptación del eviction
 *                 buffer antes de escribir.
 *     WRITE     : install escribiendo en el arreglo de datos.
 *     DONE      : install esperando confirmación wb_done.
 *
 *   Transiciones:
 *     IDLE -> PIPE o WAIT_MSHR   al alloc, según alloc_st_i.
 *     PIPE -> FILL               demanda con hit, al terminar el pipeline.
 *     PIPE -> MEMREQ             demanda con miss, al terminar el pipeline.
 *     PIPE -> EBOFF/WRITE        install, al terminar el pipeline (según
 *                                víctima sucia o limpia).
 *     FILL -> IDLE               al handshake de fill.
 *     MEMREQ -> MEMWAIT          al emitir la solicitud de memoria.
 *     MEMWAIT -> IDLE            al observar la respuesta de memoria (owner).
 *     WAIT_MSHR -> FILL          demanda waiter al observarse la respuesta.
 *     WAIT_MSHR -> DONE          install waiter al observarse la respuesta.
 *     EBOFF -> WRITE             al aceptar el eviction buffer.
 *     WRITE -> DONE              al completar la escritura.
 *     DONE -> IDLE               al handshake de wb_done.
 *
 *   Los eventos ev_*_i son one-hot por operación e indican que el handshake
 *   del canal correspondiente ocurrió en este ciclo. El productor de
 *   ev_rsp_i debe generar el bit para TODAS las operaciones con esa base
 *   (owner y waiters) en el mismo ciclo, para que owner y waiters avancen
 *   juntos.
 *
 *   Antigüedad: older_o[j*N + i] = 1 indica que j es más antigua que i. Se
 *   construye al alloc (toda operación activa es más antigua que la nueva) y
 *   se conserva durante las esperas. El desempate "más antigua que pueda
 *   avanzar; empate -> drenado" lo resuelve el consumidor a partir de esta
 *   matriz; la tabla no lo calcula.
 *
 *   conflict_a_o / conflict_b_o son independientes: si qa_base_i == qb_base_i,
 *   ambas salidas reflejan el mismo conflicto.
 *
 * @param N     Número de posiciones (equivale a L2_MAX_INFLIGHT).
 * @param AW    Ancho de dirección.
 * @param LW    Ancho de línea en bits.
 * @param WAY_W Ancho de índice de vía.
 * @param OPW   Ancho de índice de operación (mínimo 1).
 */

module l2_op_table #(
    parameter int N     = 4,
    parameter int AW    = 16,
    parameter int LW    = 256,
    parameter int WAY_W = 2,
    parameter int OPW   = (N > 1) ? $clog2(N) : 1
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic                 clk_i,
    input  logic                 rst_ni,

    // Asignación
    input  logic                 alloc_valid_i,
    input  logic                 alloc_kind_i,    // 0 demanda, 1 instalación
    input  logic [AW-1:0]        alloc_base_i,
    input  logic [WAY_W-1:0]     alloc_way_i,
    input  logic                 alloc_hit_i,
    input  logic                 alloc_vvalid_i,  // víctima válida en la vía
    input  logic                 alloc_vdirty_i,  // víctima sucia
    input  logic [AW-1:0]        alloc_vbase_i,   // base de la víctima
    input  logic [LW-1:0]        alloc_data_i,
    input  logic                 alloc_dirty_i,
    input  logic [3:0]           alloc_st_i,      // estado inicial al allocar
    output logic                 free_any_o,
    output logic [OPW-1:0]       alloc_idx_o,

    // Fin del pipeline interno
    input  logic                 pipe_end_valid_i,
    input  logic [OPW-1:0]       pipe_end_idx_i,

    // Handshakes ocurridos (one-hot por operación)
    input  logic [N-1:0]         ev_fill_i,
    input  logic [N-1:0]         ev_mem_i,
    input  logic [N-1:0]         ev_rsp_i,
    input  logic [N-1:0]         ev_eb_i,
    input  logic [N-1:0]         ev_wr_i,
    input  logic [N-1:0]         ev_done_i,

    // Solicitudes por canal
    output logic [N-1:0]         req_fill_o,
    output logic [N-1:0]         req_mem_o,
    output logic [N-1:0]         req_eb_o,
    output logic [N-1:0]         req_wr_o,
    output logic [N-1:0]         req_done_o,
    output logic [N-1:0]         busy_o,
    output logic [N*N-1:0]       older_o,   // [j*N+i] = j más antigua que i

    // Campos por operación
    output logic [N*AW-1:0]      base_o,
    output logic [N*AW-1:0]      vbase_o,
    output logic [N*WAY_W-1:0]   way_o,
    output logic [N*LW-1:0]      data_o,
    output logic [N-1:0]         dirty_o,
    output logic [N-1:0]         hit_o,
    output logic [N-1:0]         kind_o,
    output logic [N-1:0]         vvalid_o,
    output logic [N-1:0]         vdirty_o,

    // Consulta de conflicto por base con operaciones activas
    input  logic [AW-1:0]        qa_base_i,
    input  logic [AW-1:0]        qb_base_i,
    output logic                 conflict_a_o,
    output logic                 conflict_b_o
);
    // Estados en 4 bits para cubrir 0..8 sin promociones.
    localparam logic [3:0] ST_IDLE      = 4'd0;
    localparam logic [3:0] ST_PIPE      = 4'd1;
    localparam logic [3:0] ST_FILL      = 4'd2;
    localparam logic [3:0] ST_MEMREQ    = 4'd3;
    localparam logic [3:0] ST_MEMWAIT   = 4'd4;
    localparam logic [3:0] ST_EBOFF     = 4'd5;
    localparam logic [3:0] ST_WRITE     = 4'd6;
    localparam logic [3:0] ST_DONE      = 4'd7;
    localparam logic [3:0] ST_WAIT_MSHR = 4'd8;

    logic [N*4-1:0]     st_q;
    logic [N-1:0]       kind_q, hit_q, vvalid_q, vdirty_q, dirty_q;
    logic [N*AW-1:0]    base_q, vbase_q;
    logic [N*WAY_W-1:0] way_q;
    logic [N*LW-1:0]    data_q;
    logic [N*N-1:0]     older_q;

    // Salidas combinacionales
    always_comb begin
        free_any_o   = 1'b0;
        alloc_idx_o  = '0;
        conflict_a_o = 1'b0;
        conflict_b_o = 1'b0;
        // Elección de slot libre: recorrido descendente, gana el menor índice.
        for (int i = N-1; i >= 0; i--) begin
            if (st_q[i*4 +: 4] == ST_IDLE) begin
                free_any_o  = 1'b1;
                alloc_idx_o = i;
            end
        end
        for (int i = 0; i < N; i++) begin
            busy_o[i]     = (st_q[i*4 +: 4] != ST_IDLE);
            req_fill_o[i] = (st_q[i*4 +: 4] == ST_FILL);
            req_mem_o[i]  = (st_q[i*4 +: 4] == ST_MEMREQ);
            req_eb_o[i]   = (st_q[i*4 +: 4] == ST_EBOFF);
            req_wr_o[i]   = (st_q[i*4 +: 4] == ST_WRITE);
            req_done_o[i] = (st_q[i*4 +: 4] == ST_DONE);
            if (st_q[i*4 +: 4] != ST_IDLE) begin
                if (base_q[i*AW +: AW] == qa_base_i) conflict_a_o = 1'b1;
                if (base_q[i*AW +: AW] == qb_base_i) conflict_b_o = 1'b1;
            end
        end
    end

    assign older_o  = older_q;
    assign base_o   = base_q;
    assign vbase_o  = vbase_q;
    assign way_o    = way_q;
    assign data_o   = data_q;
    assign dirty_o  = dirty_q;
    assign hit_o    = hit_q;
    assign kind_o   = kind_q;
    assign vvalid_o = vvalid_q;
    assign vdirty_o = vdirty_q;

    // Estado con reset asíncrono
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            st_q     <= '0;
            kind_q   <= '0;
            hit_q    <= '0;
            vvalid_q <= '0;
            vdirty_q <= '0;
            dirty_q  <= '0;
            base_q   <= '0;
            vbase_q  <= '0;
            way_q    <= '0;
            data_q   <= '0;
            older_q  <= '0;
        end else begin
            for (int i = 0; i < N; i++) begin
                case (st_q[i*4 +: 4])
                    ST_PIPE: begin
                        if (pipe_end_valid_i && (pipe_end_idx_i == i)) begin
                            if (!kind_q[i])
                                st_q[i*4 +: 4] <= hit_q[i] ? ST_FILL : ST_MEMREQ;
                            else
                                st_q[i*4 +: 4] <= (vvalid_q[i] && vdirty_q[i]) ?
                                                  ST_EBOFF : ST_WRITE;
                        end
                    end
                    ST_FILL:      if (ev_fill_i[i]) st_q[i*4 +: 4] <= ST_IDLE;
                    ST_MEMREQ:    if (ev_mem_i[i])  st_q[i*4 +: 4] <= ST_MEMWAIT;
                    ST_MEMWAIT:   if (ev_rsp_i[i])  st_q[i*4 +: 4] <= ST_IDLE;
                    // FIX 3: waiter distingue demanda (FILL) de install (DONE).
                    ST_WAIT_MSHR: if (ev_rsp_i[i])
                                      st_q[i*4 +: 4] <= kind_q[i] ? ST_DONE : ST_FILL;
                    ST_EBOFF:     if (ev_eb_i[i])   st_q[i*4 +: 4] <= ST_WRITE;
                    ST_WRITE:     if (ev_wr_i[i])   st_q[i*4 +: 4] <= ST_DONE;
                    ST_DONE:      if (ev_done_i[i]) st_q[i*4 +: 4] <= ST_IDLE;
                    default: ;
                endcase
            end

            if (alloc_valid_i) begin
                st_q[alloc_idx_o*4 +: 4]          <= alloc_st_i;
                kind_q[alloc_idx_o]               <= alloc_kind_i;
                hit_q[alloc_idx_o]                <= alloc_hit_i;
                vvalid_q[alloc_idx_o]             <= alloc_vvalid_i;
                vdirty_q[alloc_idx_o]             <= alloc_vdirty_i;
                dirty_q[alloc_idx_o]              <= alloc_dirty_i;
                base_q[alloc_idx_o*AW +: AW]      <= alloc_base_i;
                vbase_q[alloc_idx_o*AW +: AW]     <= alloc_vbase_i;
                way_q[alloc_idx_o*WAY_W +: WAY_W] <= alloc_way_i;
                data_q[alloc_idx_o*LW +: LW]      <= alloc_data_i;
                for (int j = 0; j < N; j++) begin
                    older_q[j*N + alloc_idx_o] <= (st_q[j*4 +: 4] != ST_IDLE);
                    older_q[alloc_idx_o*N + j] <= 1'b0;
                end
            end
        end
    end
endmodule
