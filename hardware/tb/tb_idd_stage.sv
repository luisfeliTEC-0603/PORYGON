`timescale 1ns/1ps

// Testbench autoverificable para idd_stage (combinacional).
// Modelo de referencia: parseo secuencial del bundle (independiente del RTL).
module idd_stage_tb;
    import pkg_vliw::*;

    logic [63:0] bundle;

    logic [15:0] s_o [5]; logic nop_o [5]; logic [15:0] imm_o [5];
    logic [2:0]  a_o [5]; logic [2:0] b_o [5];

    idd_stage dut (
        .bundle_i(bundle),
        .alu0_slot_o(s_o[0]), .alu0_nop_flag_o(nop_o[0]), .alu0_imm_o(imm_o[0]), .alu0_op_a_addr_o(a_o[0]), .alu0_op_b_addr_o(b_o[0]),
        .alu1_slot_o(s_o[1]), .alu1_nop_flag_o(nop_o[1]), .alu1_imm_o(imm_o[1]), .alu1_op_a_addr_o(a_o[1]), .alu1_op_b_addr_o(b_o[1]),
        .lsu_slot_o (s_o[2]), .lsu_nop_flag_o (nop_o[2]), .lsu_imm_o (imm_o[2]), .lsu_op_a_addr_o (a_o[2]), .lsu_op_b_addr_o (b_o[2]),
        .bru_slot_o (s_o[3]), .bru_nop_flag_o (nop_o[3]), .bru_imm_o (imm_o[3]), .bru_op_a_addr_o (a_o[3]), .bru_op_b_addr_o (b_o[3]),
        .crypto_slot_o(s_o[4]), .crypto_nop_flag_o(nop_o[4]), .crypto_imm_o(imm_o[4]), .crypto_op_a_addr_o(a_o[4]), .crypto_op_b_addr_o(b_o[4])
    );

    string pname [5] = '{"ALU0","ALU1","LSU","BRU","CRYPTO"};

    // ---------------- Modelo de referencia ----------------
    logic [15:0] e_slot [5]; logic e_nop [5]; logic [15:0] e_imm [5];
    logic [2:0]  e_a [5];    logic [2:0] e_b [5];

    task automatic model(input logic [63:0] b);
        logic got [5];
        int i, p, step;
        logic [15:0] s;
        for (int k = 0; k < 5; k++) begin got[k] = 0; e_slot[k] = 16'h0; e_imm[k] = 16'h0; end
        i = 0;
        while (i < 4) begin
            s = b[i*16 +: 16];
            step = 1;
            if (s != 16'h0000) begin
                case (s[1:0])
                    2'b00: p = s[3] ? 1 : 0;
                    2'b01: p = 2;
                    2'b10: p = 3;
                    default: p = 4;
                endcase
                if (!got[p]) begin   // prioridad: menor índice
                    got[p] = 1; e_slot[p] = s;
                    if (s[2] && i < 3) e_imm[p] = b[(i+1)*16 +: 16];
                end
                if (s[2] && i < 3) step = 2;   // el siguiente slot es dato
            end
            i += step;
        end
        for (int k = 0; k < 5; k++) begin
            e_nop[k] = (e_slot[k] == 16'h0);
            e_a[k]   = e_slot[k][15:13];
            e_b[k]   = e_slot[k][12:10];
        end
    endtask

    // ---------------- Checker ----------------
    int errors = 0, checks = 0;
    string tag;

    task automatic check(input logic [63:0] b, input string t, input bit verbose = 1);
        bit bad = 0;
        bundle = b; #1;
        model(b);
        checks++;
        for (int k = 0; k < 5; k++) begin
            if (s_o[k] !== e_slot[k] || nop_o[k] !== e_nop[k] || imm_o[k] !== e_imm[k] ||
                a_o[k] !== e_a[k] || b_o[k] !== e_b[k]) begin
                if (verbose && errors < 25)
                    $display("[FAIL] %s bundle=%016h %-6s got slot=%04h nop=%b imm=%04h a=%0d b=%0d | exp slot=%04h nop=%b imm=%04h a=%0d b=%0d",
                        t, b, pname[k], s_o[k], nop_o[k], imm_o[k], a_o[k], b_o[k],
                        e_slot[k], e_nop[k], e_imm[k], e_a[k], e_b[k]);
                bad = 1;
            end
        end
        if (bad) errors++;
    endtask

    // ---------------- Constructores de instrucciones ----------------
    function automatic logic [15:0] mk_math(input [2:0] rs1, rs2, input [5:0] f, input pipe, imm);
        return {rs1, rs2, f, pipe, imm, 2'b00};
    endfunction
    function automatic logic [15:0] mk_lost(input [2:0] rd, rs, input [3:0] f, input [2:0] off, input imm);
        return {rd, rs, f, off, imm, 2'b01};
    endfunction
    function automatic logic [15:0] mk_jump(input [2:0] rd, input [7:0] off, input [1:0] f, input imm);
        return {rd, off, f, imm, 2'b10};   // formato [4:3]=funct -> usamos {f,1'b?}
    endfunction
    function automatic logic [15:0] mk_cry(input [2:0] rs1, rs2, input [2:0] f, input [1:0] r, input [1:0] k);
        return {rs1, rs2, f, r, k, 1'b0, 2'b11};
    endfunction
    function automatic logic [63:0] mkb(input [15:0] s0, s1, s2, s3);
        return {s3, s2, s1, s0};
    endfunction

    // ---------------- Estímulos ----------------
    logic [15:0] A0, A1, L, J, C, A0i, A1i, Li, Ji, D;
    int seed = 1;

    task automatic gen_wellformed(output logic [63:0] b);
        bit used [5];
        int i, p;
        logic [15:0] sl [4];
        for (int k = 0; k < 5; k++) used[k] = 0;
        for (int k = 0; k < 4; k++) sl[k] = 16'h0;
        i = 0;
        while (i < 4) begin
            p = $urandom_range(5, 0);       // 5 = NOP
            if (p == 5 || used[p]) begin sl[i] = 16'h0; i++; end
            else begin
                used[p] = 1;
                case (p)
                    0: sl[i] = mk_math($urandom, $urandom, $urandom, 1'b0, 1'b0);
                    1: sl[i] = mk_math($urandom, $urandom, $urandom, 1'b1, 1'b0);
                    2: sl[i] = mk_lost($urandom, $urandom, $urandom, $urandom, 1'b0);
                    3: sl[i] = {$urandom_range(7,0), 8'($urandom), 2'($urandom), 1'b0, 2'b10} ;
                    4: sl[i] = mk_cry($urandom, $urandom, $urandom, $urandom, $urandom);
                endcase
                if (sl[i] == 16'h0) sl[i][15] = 1'b1; // evitar colisión con NOP
                if (p != 4 && i < 3 && $urandom_range(1,0)) begin
                    sl[i][2] = 1'b1; sl[i+1] = $urandom; i += 2;
                end else i++;
            end
        end
        b = {sl[3], sl[2], sl[1], sl[0]};
    endtask

    initial begin
        logic [63:0] b;
        $display("=== idd_stage testbench ===");

        // ---- T1: todo NOP ----
        check(64'h0, "T1 all-NOP");

        // ---- T2: una instrucción de cada tipo, sin inmediatos, en cualquier posición ----
        A0 = mk_math(3'd1,3'd2,6'h05,1'b0,1'b0);
        A1 = mk_math(3'd3,3'd4,6'h0A,1'b1,1'b0);
        L  = mk_lost(3'd5,3'd6,4'h3,3'd2,1'b0);
        J  = {3'd7, 8'h5A, 2'b01, 1'b0, 2'b10};
        C  = mk_cry(3'd2,3'd5,3'd4,2'd1,2'd3);
        check(mkb(A0,A1,L,J),  "T2a ALU0 ALU1 LSU BRU");
        check(mkb(C,J,L,A1),   "T2b CRY BRU LSU ALU1");
        check(mkb(J,C,A0,L),   "T2c BRU CRY ALU0 LSU");
        check(mkb(A1,L,J,C),   "T2d ALU1 LSU BRU CRY");
        check(mkb(16'h0,A0,16'h0,A1), "T2e NOP ALU0 NOP ALU1");

        // ---- T3: inmediatos ----
        D = 16'hBEEF;
        A0i = mk_math(3'd1,3'd2,6'h05,1'b0,1'b1);
        A1i = mk_math(3'd3,3'd4,6'h0A,1'b1,1'b1);
        Li  = mk_lost(3'd5,3'd6,4'h3,3'd2,1'b1);
        Ji  = {3'd7, 8'h5A, 2'b01, 1'b1, 2'b10};
        check(mkb(A0i,D,L,J),      "T3a ALU0+imm, LSU, BRU");
        check(mkb(A1i,D,A0,L),     "T3b ALU1+imm, ALU0, LSU");
        check(mkb(A0,Li,D,J),      "T3c ALU0, LSU+imm, BRU");
        check(mkb(A0,A1,Ji,D),     "T3d ALU0, ALU1, BRU+imm");
        check(mkb(A0i,D,Li,16'hCAFE), "T3e dos imm");
        check(mkb(A0,A1,L,Ji),     "T3f imm en slot 3 (sin dato)");
        check(mkb(A0i,16'hFFFF,A1,L), "T3g dato con bits opcode=11 / imm=1");
        check(mkb(A0i,16'h0007,L,J),  "T3h dato parece CRYPTO con imm");
        check(mkb(A0i,16'h0000,A1,L), "T3i dato = 0x0000");

        // ---- T4: corte de cadena (dato con bit[2]=1 no consume el siguiente) ----
        check(mkb(A0i,16'h1234|16'h4,L,J), "T4a chain-cut slot1");
        check(mkb(A0,A1i,16'hFFFC,J),      "T4b chain-cut slot3");

        // ---- T5: NOP no debe tapar instrucciones reales (sombra en ALU0) ----
        check(mkb(16'h0,A0,L,J),   "T5a NOP antes de ALU0");
        check(mkb(L,16'h0,A0,J),   "T5b NOP antes de ALU0 (slot2)");
        check(mkb(Li,D,A0,J),      "T5c dato->NOP antes de ALU0");
        check(mkb(Li,D,A0i,16'h1111), "T5d dato->NOP antes de ALU0+imm");
        check(mkb(Ji,D,A0,A1),     "T5e BRU+imm, luego ALU0 y ALU1");

        // ---- T6: ALU1 con NOP delante (no debe afectar) ----
        check(mkb(16'h0,A1,16'h0,16'h0), "T6 NOP ALU1");

        // ---- T7: duplicados -> prioridad menor índice ----
        check(mkb(A0,mk_math(3'd7,3'd7,6'h3F,1'b0,1'b0),L,J), "T7a ALU0 duplicado");
        check(mkb(L,mk_lost(3'd1,3'd1,4'h1,3'd1,1'b0),J,C),   "T7b LSU duplicado");

        // ---- T8: aleatorios bien formados ----
        errors = errors; // marcador
        begin
            int e0 = errors;
            for (int n = 0; n < 50000; n++) begin
                gen_wellformed(b);
                check(b, "T8 rand-wellformed", (errors - e0) < 5);
            end
            $display("T8 aleatorios bien formados: %0d fallos de 50000", errors - e0);
        end

        // ---- T9: aleatorios totalmente libres ----
        begin
            int e0 = errors;
            for (int n = 0; n < 100000; n++) begin
                b = {$urandom, $urandom};
                check(b, "T9 rand-free", (errors - e0) < 5);
            end
            $display("T9 aleatorios libres: %0d fallos de 100000", errors - e0);
        end

        // ---- T10: exhaustivo parcial: slot0/slot1 con opcode+bit2+bit3 variados ----
        begin
            int e0 = errors;
            for (int s0 = 0; s0 < 16; s0++)
              for (int s1 = 0; s1 < 16; s1++)
                for (int s2 = 0; s2 < 16; s2++)
                  for (int s3 = 0; s3 < 16; s3++)
                    check(mkb({4'hA,8'h50,s0[3:0]}, {4'h5,8'hA0,s1[3:0]}, {4'h3,8'h3C,s2[3:0]}, {4'hC,8'h81,s3[3:0]}),
                          "T10 low-nibble sweep", (errors - e0) < 5);
            $display("T10 barrido nibble bajo: %0d fallos de 65536", errors - e0);
        end

        $display("-----------------------------------------");
        $display("Chequeos: %0d   Bundles con error: %0d", checks, errors);
        if (errors == 0) $display("RESULTADO: PASS");
        else             $display("RESULTADO: FAIL");
        $finish;
    end
endmodule
