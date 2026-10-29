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
cambiar_password_a_1_2_3_4:
    mov r5, r0
    sumi r5, #1
    lopw r5, 0
    mov r5, r0
    sumi r5, #2
    lopw r5, 1
    mov r5, r0
    sumi r5, #3
    lopw r5, 2
    mov r5, r0
    sumi r5, #4
    lopw r5, 3
    pwd
intentar_password_vieja:
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
preparar_original_e_intento:
    mov r3, r0
    sumi r3, #1
    shli r3, #16
    mov r4, r3
    sumi r4, #4096
    mov r6, r0
    sumi r6, #98
intentar_cifrar_sin_autorizacion:
    lowi r1, 0(r3)
    lowi r2, 4(r3)
    feistel r1, r2, 0, 0
    feistel r1, r2, 1, 0
    feistel r1, r2, 2, 0
    feistel r1, r2, 3, 0
    stwi r1, 0(r4)
    stwi r2, 4(r4)
    sumi r3, #8
    sumi r4, #8
    diffi r6, #1
    jnz r6, intentar_cifrar_sin_autorizacion
fin:
    j fin
