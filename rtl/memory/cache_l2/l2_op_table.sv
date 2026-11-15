/**
 * @file l2_op_table.sv
 * @brief Tabla de operaciones en vuelo de L2.
 *
 * @details
 *   Guarda estado, metadatos, datos y antigüedad de cada operación, y expone
 *   la consulta de conflicto por base. Una posición y su id quedan ocupados
 *   hasta el handshake de finalización (fill, wb_done o respuesta de memoria
 *   observada).
 *
 *   Estados: IDLE, PIPE (en pipeline), FILL (hit L2 esperando L1), MEMREQ
 *   (miss solicitando memoria), MEMWAIT (esperando rsp), EBOFF (install con
 *   víctima sucia esperando EB), WRITE (install escribiendo arreglo), DONE
 *   (install esperando wb_done).
 *
 *   Transiciones:
 *     IDLE    -> PIPE      al alloc.
 *     PIPE    -> FILL      demanda con hit, al terminar pipeline.
 *     PIPE    -> MEMREQ    demanda con miss, al terminar pipeline.
 *     PIPE    -> EBOFF     install con víctima sucia, al terminar pipeline.
 *     PIPE    -> WRITE     install con víctima limpia o inexistente.
 *     FILL    -> IDLE      al handshake de fill.
 *     MEMREQ  -> MEMWAIT   al emitir la solicitud de memoria.
 *     MEMWAIT -> IDLE      al observar la respuesta (owner).
 *     EBOFF   -> WRITE     al aceptar el EB.
 *     WRITE   -> DONE      al completar la escritura.
 *     DONE    -> IDLE      al handshake de wb_done.
 *
 *   Los ev_*_i son one-hot e indican que el handshake del canal ocurrió este
 *   ciclo. ev_rsp_i corresponde solo al owner de la lectura.
 *
 *   Antigüedad: older_o[j*N+i]=1 si j es más antigua que i. Se construye al
 *   alloc (toda activa es más antigua que la nueva) y se conserva durante las
 *   esperas. El desempate "más antigua que pueda; empate -> drenado" lo
 *   aplica el consumidor, no la tabla.
 *
 *   conflict_a_o y conflict_b_o son independientes: si qa_base_i == qb_base_i,
 *   ambas reflejan el mismo conflicto.
 *
 * @param N     Número de posiciones, equivale a L2_MAX_INFLIGHT.
 * @param AW    Ancho de dirección.
 * @param LW    Ancho de línea en bits.
 * @param WAY_W Ancho de índice de vía.
 * @param OPW   Ancho de índice de operación, mínimo 1.
 *
 * @input  alloc_valid_i   1 si el top acepta una operación este ciclo.
 * @input  alloc_kind_i    0 demanda, 1 instalación.
 * @input  alloc_base_i    Base de la operación.
 * @input  alloc_way_i     Vía de la operación.
 * @input  alloc_hit_i     1 si la operación acierta en L2 (solo demanda).
 * @input  alloc_vvalid_i  1 si la víctima de la vía es válida (solo install).
 * @input  alloc_vdirty_i  1 si la víctima es sucia (solo install).
 * @input  alloc_vbase_i   Base de la víctima (solo install).
 * @input  alloc_data_i    Línea a instalar (solo install).
 * @input  alloc_dirty_i   Dirty a instalar (solo install).
 * @input  pipe_end_valid_i 1 si una operación terminó el pipeline.
 * @input  pipe_end_idx_i   Índice de la operación que terminó el pipeline.
 * @input  ev_fill_i       Handshake de fill por operación.
 * @input  ev_mem_i        Handshake de mem_rd_req por operación.
 * @input  ev_rsp_i        Respuesta de memoria observada, solo owner.
 * @input  ev_eb_i         Handshake de eb_push por operación.
 * @input  ev_wr_i         Handshake de escritura de arreglo por operación.
 * @input  ev_done_i       Handshake de wb_done por operación.
 * @input  qa_base_i       Base a consultar para conflicto A (demanda).
 * @input  qb_base_i       Base a consultar para conflicto B (install).
 *
 * @output free_any_o      1 si hay al menos una posición libre.
 * @output alloc_idx_o      Índice de la posición libre elegida.
 * @output req_fill_o       Solicitud de fill por operación.
 * @output req_mem_o        Solicitud de lectura a memoria por operación.
 * @output req_eb_o         Solicitud de push al EB por operación.
 * @output req_wr_o         Solicitud de escritura de arreglo por operación.
 * @output req_done_o       Solicitud de wb_done por operación.
 * @output busy_o           1 si la posición está ocupada.
 * @output older_o          Matriz N×N de antigüedad.
 * @output base_o           Base por operación.
 * @output vbase_o          Base de la víctima por operación.
 * @output way_o            Vía por operación.
 * @output data_o           Línea a instalar por operación.
 * @output dirty_o          Dirty por operación.
 * @output hit_o            Hit por operación.
 * @output kind_o           0 demanda, 1 instalación, por operación.
 * @output vvalid_o         Validez de la víctima por operación.
 * @output vdirty_o         Dirty de la víctima por operación.
 * @output conflict_a_o     1 si qa_base_i coincide con alguna base activa.
 * @output conflict_b_o     1 si qb_base_i coincide con alguna base activa.
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

    logic [N*4-1:0]     st_q;
    logic [N-1:0]       kind_q, hit_q, vvalid_q, vdirty_q, dirty_q;
    logic [N*AW-1:0]    base_q, vbase_q;
    logic [N*WAY_W-1:0] way_q;
    logic [N*LW-1:0]    data_q;
    logic [N*N-1:0]     older_q;

    // Salidas combinacionales: slot libre, solicitudes por estado, conflicto
    // por base contra operaciones activas.
    always_comb begin
        free_any_o   = 1'b0;
        alloc_idx_o  = '0;
        conflict_a_o = 1'b0;
        conflict_b_o = 1'b0;
        // Descendente + sobrescritura: si hay varias libres, gana la menor.
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
                    ST_EBOFF:     if (ev_eb_i[i])   st_q[i*4 +: 4] <= ST_WRITE;
                    ST_WRITE:     if (ev_wr_i[i])   st_q[i*4 +: 4] <= ST_DONE;
                    ST_DONE:      if (ev_done_i[i]) st_q[i*4 +: 4] <= ST_IDLE;
                    default: ;
                endcase
            end

            if (alloc_valid_i) begin
                st_q[alloc_idx_o*4 +: 4]          <= ST_PIPE;
                kind_q[alloc_idx_o]               <= alloc_kind_i;
                hit_q[alloc_idx_o]                <= alloc_hit_i;
                vvalid_q[alloc_idx_o]             <= alloc_vvalid_i;
                vdirty_q[alloc_idx_o]             <= alloc_vdirty_i;
                dirty_q[alloc_idx_o]              <= alloc_dirty_i;
                base_q[alloc_idx_o*AW +: AW]      <= alloc_base_i;
                vbase_q[alloc_idx_o*AW +: AW]     <= alloc_vbase_i;
                way_q[alloc_idx_o*WAY_W +: WAY_W] <= alloc_way_i;
                data_q[alloc_idx_o*LW +: LW]      <= alloc_data_i;
                
                // Toda posición activa es más antigua que la nueva (alloc_idx_o); la nueva
                // no es más antigua que nadie.
                for (int j = 0; j < N; j++) begin
                    older_q[j*N + alloc_idx_o] <= (st_q[j*4 +: 4] != ST_IDLE);
                    older_q[alloc_idx_o*N + j] <= 1'b0;
                end
            end
        end
    end
endmodule
