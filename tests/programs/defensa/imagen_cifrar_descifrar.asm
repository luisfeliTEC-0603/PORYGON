autenticar_password_inicial:
    mov r5, r0
    ori r5, #57328
    shli r5, #16
    ori r5, #63338
    lopw r5, 0
    mov r5, r0
    ori r5, #43430
    shli r5, #16
    ori r5, #28696
    lopw r5, 1
    mov r5, r0
    ori r5, #55880
    shli r5, #16
    ori r5, #56071
    lopw r5, 2
    mov r5, r0
    ori r5, #5219
    shli r5, #16
    ori r5, #6075
    lopw r5, 3
    auth
cargar_llave_cero:
    mov r5, r0
    ori r5, #4369
    write r5, 0, 0
    mov r5, r0
    ori r5, #8738
    write r5, 1, 0
    mov r5, r0
    ori r5, #13107
    write r5, 2, 0
    mov r5, r0
    ori r5, #17476
    write r5, 3, 0
preparar_original_cifrada_descifrada:
    mov r3, r0
    sumi r3, #1
    shli r3, #16
    mov r4, r3
    sumi r4, #4096
    mov r7, r4
    sumi r7, #4096
    mov r6, r0
    sumi r6, #98
cifrar_y_descifrar_bloque:
    mov r5, r0
    ori r5, #57328
    shli r5, #16
    ori r5, #63338
    lopw r5, 0
    mov r5, r0
    ori r5, #43430
    shli r5, #16
    ori r5, #28696
    lopw r5, 1
    mov r5, r0
    ori r5, #55880
    shli r5, #16
    ori r5, #56071
    lopw r5, 2
    mov r5, r0
    ori r5, #5219
    shli r5, #16
    ori r5, #6075
    lopw r5, 3
    auth
    lowi r1, 0(r3)
    lowi r2, 4(r3)
    feistel r1, r2, 0, 0
    feistel r1, r2, 1, 0
    feistel r1, r2, 2, 0
    feistel r1, r2, 3, 0
    stwi r1, 0(r4)
    stwi r2, 4(r4)
    mov r5, r0
    ori r5, #57328
    shli r5, #16
    ori r5, #63338
    lopw r5, 0
    mov r5, r0
    ori r5, #43430
    shli r5, #16
    ori r5, #28696
    lopw r5, 1
    mov r5, r0
    ori r5, #55880
    shli r5, #16
    ori r5, #56071
    lopw r5, 2
    mov r5, r0
    ori r5, #5219
    shli r5, #16
    ori r5, #6075
    lopw r5, 3
    auth
    lowi r1, 0(r4)
    lowi r2, 4(r4)
    feistel r2, r1, 3, 0
    feistel r2, r1, 2, 0
    feistel r2, r1, 1, 0
    feistel r2, r1, 0, 0
    stwi r1, 0(r7)
    stwi r2, 4(r7)
    sumi r3, #8
    sumi r4, #8
    sumi r7, #8
    diffi r6, #1
    jnz r6, cifrar_y_descifrar_bloque
    rvk
fin:
    j fin
