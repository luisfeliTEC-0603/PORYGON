/**
 * @file l2_mshr.sv
 * @brief MSHR de L2: tabla de misses en vuelo por base, con waiters enganchados.
 *
 * @details
 *   MSHR = Miss Status Holding Register. Mantiene hasta N entradas, una por
 *   dirección base de línea en vuelo hacia memoria. Cada entrada guarda:
 *     - valid    : entrada en uso.
 *     - base     : dirección base de línea (bits de offset en 0).
 *     - owner_id : id de la operación que originó la lectura a memoria.
 *     - waiters  : bitmap de N ids enganchados a la misma base.
 *
 *   Reglas:
 *     - probe  : combinacional; hit si la base coincide con una entrada
 *                válida. Devuelve owner_id y el bitmap de waiters.
 *     - alloc  : al aceptar un miss nuevo (base no presente). owner_id = id,
 *                waiters = 0. Precondición: existe slot libre, o `release`
 *                libera uno en el mismo ciclo (ver alloc_slot).
 *     - attach : al aceptar una demanda cuya base ya está en MSHR. Marca el
 *                bit del id en waiters. NO se emite mem_rd_req adicional.
 *     - release: al completar la lectura (mem_rd_rsp observado) o un fill
 *                hit. Libera la entrada. Los waiters se completan en la tabla
 *                de operaciones, no aquí.
 *
 *   Se asume UNA entrada por base (alloc no crea duplicados; attach no crea
 *   entradas). El lazo de release limpia todas las coincidencias como medida
 *   defensiva ante un eventual duplicado.
 *
 *   Prioridad en el mismo ciclo: release > alloc > attach. Si una entrada se
 *   libera y otra operación la reutiliza en el mismo flanco, el alloc nuevo
 *   gana sobre un attach viejo. alloc_slot excluye el slot que release está
 *   liberando en este ciclo, para no reutilizar una entrada que aún se está
 *   leyendo.
 *
 *   Reset asíncrono limpia todas las entradas.
 *
 * @param N   Número de entradas (equivale a L2_MAX_INFLIGHT).
 * @param AW  Ancho de dirección.
 * @param OPW Ancho de índice de operación en la tabla (mínimo 1).
 */

module l2_mshr #(
    parameter int N   = 4,
    parameter int AW  = 16,
    parameter int OPW = (N > 1) ? $clog2(N) : 1
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic             clk_i,
    input  logic             rst_ni,

    // Consulta A (admisión: get_base)
    input  logic [AW-1:0]    probe_a_base_i,
    output logic             probe_a_hit_o,
    output logic [OPW-1:0]   probe_a_owner_o,
    output logic [N-1:0]     probe_a_waiters_o,
    output logic [OPW-1:0]   probe_a_entry_o,

    // Consulta B (rsp: mem_rd_rsp_base_i)
    input  logic [AW-1:0]    probe_b_base_i,
    output logic             probe_b_hit_o,
    output logic [OPW-1:0]   probe_b_entry_o,

    // Asignación de miss nuevo
    input  logic             alloc_valid_i,
    input  logic [AW-1:0]    alloc_base_i,
    input  logic [OPW-1:0]   alloc_owner_i,

    // Enganche de una demanda a una entrada existente
    input  logic             attach_valid_i,
    input  logic [AW-1:0]    attach_base_i,
    input  logic [OPW-1:0]   attach_id_i,

    // Liberación al completar la lectura o un fill hit
    input  logic             release_valid_i,
    input  logic [AW-1:0]    release_base_i,

    // Waiters por entrada, como matriz N x N (bits [i*N +: N] = waiters de i)
    output logic [N*N-1:0]   waiters_o
);
    logic             valid_q [0:N-1];
    logic [AW-1:0]    base_q  [0:N-1];
    logic [OPW-1:0]   owner_q [0:N-1];
    logic [N-1:0]     wait_q  [0:N-1];

    // ---- Consulta combinacional ----
    // Recorre todas las entradas y reporta la que coincida con probe_*
    always_comb begin
        probe_a_hit_o     = 1'b0;
        probe_a_owner_o   = '0;
        probe_a_waiters_o = '0;
        probe_a_entry_o   = '0;
        probe_b_hit_o     = 1'b0;
        probe_b_entry_o   = '0;
        for (int i = 0; i < N; i++) begin
            if (valid_q[i] && base_q[i] == probe_a_base_i) begin
                probe_a_hit_o     = 1'b1;
                probe_a_owner_o   = owner_q[i];
                probe_a_waiters_o = wait_q[i];
                probe_a_entry_o   = OPW'(i);
            end
            if (valid_q[i] && base_q[i] == probe_b_base_i) begin
                probe_b_hit_o   = 1'b1;
                probe_b_entry_o = OPW'(i);
            end
        end
    end

    // ---- Salida de waiters por entrada ----
    // Matriz N x N: cada fila es el bitmap de waiters de una entrada.
    always_comb begin
        for (int i = 0; i < N; i++)
            waiters_o[i*N +: N] = wait_q[i];
    end

    // ---- Slot libre para alloc ----
    // Elige el menor índice libre, excluyendo el que release libera en este
    // ciclo (para no reutilizar una entrada que aún se está leyendo).
    integer alloc_slot;
    always_comb begin
        alloc_slot = -1;
        for (int i = N-1; i >= 0; i--) begin
            logic freed;
            freed = release_valid_i && valid_q[i] && (base_q[i] == release_base_i);
            if (!valid_q[i] && !freed) alloc_slot = i;
        end
    end

    // ---- Estado con reset asíncrono ----
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < N; i++) begin
                valid_q[i] <= 1'b0;
                base_q[i]  <= '0;
                owner_q[i] <= '0;
                wait_q[i]  <= '0;
            end
        end else begin
            // 1) release (prioridad máxima)
            if (release_valid_i) begin
                for (int i = 0; i < N; i++) begin
                    if (valid_q[i] && base_q[i] == release_base_i) begin
                        valid_q[i] <= 1'b0;
                        wait_q[i]  <= '0;
                    end
                end
            end
            // 2) alloc en el slot elegido
            if (alloc_valid_i && alloc_slot >= 0) begin
                valid_q[alloc_slot] <= 1'b1;
                base_q[alloc_slot]  <= alloc_base_i;
                owner_q[alloc_slot] <= alloc_owner_i;
                wait_q[alloc_slot]  <= '0;
            end
            // 3) attach: agrega waiter a la entrada existente de esa base
            if (attach_valid_i) begin
                for (int i = 0; i < N; i++) begin
                    if (valid_q[i] && base_q[i] == attach_base_i) begin
                        wait_q[i][attach_id_i] <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
