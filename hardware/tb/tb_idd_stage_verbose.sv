`timescale 1ns/1ps

module idd_stage_tb_verbose;
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

    string pname [5] = '{"ALU0  ","ALU1  ","LSU   ","BRU   ","CRYPTO"};

    // ---------- Modelo de referencia (valor esperado) ----------
    logic [15:0] e_slot [5]; logic e_nop [5]; logic [15:0] e_imm [5];
    logic [2:0]  e_a [5];    logic [2:0] e_b [5];

    task automatic model(input logic [63:0] b);
        logic got [5]; int i, p, step; logic [15:0] s;
        for (int k = 0; k < 5; k++) begin got[k] = 0; e_slot[k] = 0; e_imm[k] = 0; end
        i = 0;
        while (i < 4) begin
            s = b[i*16 +: 16]; step = 1;
            if (s != 16'h0000) begin
                case (s[1:0]) 2'b00: p = s[3] ? 1 : 0; 2'b01: p = 2; 2'b10: p = 3; default: p = 4; endcase
                if (!got[p]) begin
                    got[p] = 1; e_slot[p] = s;
                    if (s[2] && i < 3) e_imm[p] = b[(i+1)*16 +: 16];
                end
                if (s[2] && i < 3) step = 2;
            end
            i += step;
        end
        for (int k = 0; k < 5; k++) begin
            e_nop[k] = (e_slot[k] == 0); e_a[k] = e_slot[k][15:13]; e_b[k] = e_slot[k][12:10];
        end
    endtask

    // ---------- Ejecuta un caso e imprime la tabla ----------
    int errors = 0, cases = 0;

    task automatic run_case(input string name, input string expl, input logic [63:0] b);
        bit case_ok = 1, pipe_ok;
        bundle = b; #1; model(b); cases++;
        $display("\n================================================================================");
        $display("CASO %0d: %s", cases, name);
        $display("  Descripcion: %s", expl);
        $display("  ENTRADA bundle_i = 0x%016h", b);
        $display("     slot3=%04h  slot2=%04h  slot1=%04h  slot0=%04h", b[63:48], b[47:32], b[31:16], b[15:0]);
        $display("  ------+-----------------------------------+-----------------------------------+------");
        $display("  PIPE  |  SALIDA DUT                       |  VALOR ESPERADO                   | RES");
        $display("        |  slot  nop  imm   a  b            |  slot  nop  imm   a  b            |");
        $display("  ------+-----------------------------------+-----------------------------------+------");
        for (int k = 0; k < 5; k++) begin
            pipe_ok = (s_o[k] === e_slot[k]) && (nop_o[k] === e_nop[k]) && (imm_o[k] === e_imm[k])
                   && (a_o[k] === e_a[k]) && (b_o[k] === e_b[k]);
            if (!pipe_ok) case_ok = 0;
            $display("  %s|  %04h   %b   %04h  %0d  %0d            |  %04h   %b   %04h  %0d  %0d            | %s",
                pname[k], s_o[k], nop_o[k], imm_o[k], a_o[k], b_o[k],
                e_slot[k], e_nop[k], e_imm[k], e_a[k], e_b[k], pipe_ok ? "OK" : "<<FALLO>>");
        end
        $display("  => %s", case_ok ? "CASO PASS" : "CASO FAIL");
        if (!case_ok) errors++;
    endtask

    // ---------- Constructores ----------
    function automatic logic [15:0] mk_math(input [2:0] rs1, rs2, input [5:0] f, input pipe, imm);
        return {rs1, rs2, f, pipe, imm, 2'b00};
    endfunction
    function automatic logic [15:0] mk_lost(input [2:0] rd, rs, input [3:0] f, input [2:0] off, input imm);
        return {rd, rs, f, off, imm, 2'b01};
    endfunction
    function automatic logic [15:0] mk_jump(input [2:0] rd, input [7:0] off, input [1:0] f, input imm);
        return {rd, off, f, imm, 2'b10};
    endfunction
    function automatic logic [15:0] mk_cry(input [2:0] rs1, rs2, input [2:0] f, input [1:0] r, input [1:0] k);
        return {rs1, rs2, f, r, k, 1'b0, 2'b11};
    endfunction
    function automatic logic [63:0] mkb(input [15:0] s0, s1, s2, s3); return {s3, s2, s1, s0}; endfunction

    logic [15:0] A0, A1, L, J, C, A0i, A1i, Li, Ji, D;
    int rnd_err;
    logic [63:0] rb;

    initial begin
        A0  = mk_math(3'd1,3'd2,6'h05,1'b0,1'b0);  A0i = mk_math(3'd1,3'd2,6'h05,1'b0,1'b1);
        A1  = mk_math(3'd3,3'd4,6'h0A,1'b1,1'b0);  A1i = mk_math(3'd3,3'd4,6'h0A,1'b1,1'b1);
        L   = mk_lost(3'd5,3'd6,4'h3,3'd2,1'b0);   Li  = mk_lost(3'd5,3'd6,4'h3,3'd2,1'b1);
        J   = mk_jump(3'd7,8'h5A,2'b01,1'b0);      Ji  = mk_jump(3'd7,8'h5A,2'b01,1'b1);
        C   = mk_cry(3'd2,3'd5,3'd4,2'd1,2'd3);
        D   = 16'hBEEF;

        $display("Instrucciones de prueba:");
        $display("  A0=%04h (MATH pipe0, rs1=1 rs2=2)   A1=%04h (MATH pipe1, rs1=3 rs2=4)", A0, A1);
        $display("  L =%04h (LOST, rd=5 rs=6)           J =%04h (JUMP, rd=7)", L, J);
        $display("  C =%04h (CRYPTO, rs1=2 rs2=5)       D =%04h (dato inmediato)", C, D);
        $display("  A0i/A1i/Li/Ji = misma instruccion con imm=1 (bit 2)");

        run_case("Todo NOP", "Ningun pipe recibe instruccion; todos nop_flag=1, imm=0.", 64'h0);
        run_case("Una instruccion por pipe (A0,A1,L,J)", "Cada slot va a su pipe; CRYPTO queda en NOP.", mkb(A0,A1,L,J));
        run_case("Orden permutado (C,J,L,A1)", "El ruteo no depende de la posicion; ALU0 en NOP.", mkb(C,J,L,A1));
        run_case("Orden permutado (J,C,A0,L)", "ALU1 en NOP.", mkb(J,C,A0,L));
        run_case("NOP, A0, NOP, A1", "NOP en slot0 NO debe tapar a ALU0 (caso del bug corregido).", mkb(16'h0,A0,16'h0,A1));
        run_case("NOP delante de ALU0 (slot0 NOP)", "ALU0 debe recibir A0 del slot1.", mkb(16'h0,A0,L,J));
        run_case("A0 con imm=1 + dato", "ALU0 recibe A0i y alu0_imm=BEEF; el slot del dato no se enruta.", mkb(A0i,D,L,J));
        run_case("A1 con imm=1, luego A0 y L", "ALU1 con imm=BEEF; el dato->NOP no debe tapar a ALU0 (slot2).", mkb(A1i,D,A0,L));
        run_case("LSU con imm=1 + dato, luego BRU", "lsu_imm=BEEF; BRU en slot3.", mkb(A0,Li,D,J));
        run_case("BRU con imm=1 + dato", "bru_imm=BEEF.", mkb(A0,A1,Ji,D));
        run_case("Dos instrucciones con imm", "A0i usa slot1; Li usa slot3 (CAFE).", mkb(A0i,D,Li,16'hCAFE));
        run_case("Imm en slot3 (sin dato)", "Instruccion en slot3 con imm=1 no tiene dato: imm=0.", mkb(A0,A1,L,Ji));
        run_case("Dato 0xFFFF parece instruccion", "El dato 0xFFFF no debe ir a CRYPTO; solo se usa como imm de ALU0.", mkb(A0i,16'hFFFF,A1,L));
        run_case("Dato 0x0007 (opcode CRYPTO, imm=1)", "Dato no se decodifica como instruccion.", mkb(A0i,16'h0007,L,J));
        run_case("Dato 0x0000", "imm de ALU0 = 0000 pero nop_flag=0 (la instruccion es A0i).", mkb(A0i,16'h0000,A1,L));
        run_case("Corte de cadena slot1", "Dato con bit2=1 no consume al slot2: L sigue siendo instruccion.", mkb(A0i,16'h1234|16'h4,L,J));
        run_case("Corte de cadena slot3", "Dato FFFC en slot2 (consumido por A1i) no consume al slot3.", mkb(A0,A1i,16'hFFFC,J));
        run_case("Duplicado ALU0", "Dos MATH pipe0: gana el de menor indice (A0).", mkb(A0,mk_math(3'd7,3'd7,6'h3F,1'b0,1'b0),L,J));
        run_case("Duplicado LSU", "Dos LOST: gana el slot0.", mkb(L,mk_lost(3'd1,3'd1,4'h1,3'd1,1'b0),J,C));
        run_case("Bundle completo A0 A1 L J con CRYPTO desplazado", "Cinco pipes no caben en 4 slots: CRYPTO,A1,A0,L.", mkb(C,A1,A0,L));

        // Aleatorios: solo resumen
        rnd_err = 0;
        for (int n = 0; n < 100000; n++) begin
            rb = {$urandom, $urandom}; bundle = rb; #1; model(rb);
            for (int k = 0; k < 5; k++)
                if (s_o[k] !== e_slot[k] || nop_o[k] !== e_nop[k] || imm_o[k] !== e_imm[k] || a_o[k] !== e_a[k] || b_o[k] !== e_b[k]) begin
                    rnd_err++; break;
                end
        end

        $display("\n================================================================================");
        $display("RESUMEN: casos dirigidos=%0d  fallidos=%0d | aleatorios=100000 fallidos=%0d", cases, errors, rnd_err);
        $display("RESULTADO FINAL: %s", (errors == 0 && rnd_err == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
