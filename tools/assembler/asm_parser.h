#ifndef PORYGON_ASSEMBLER_ASM_PARSER_H
#define PORYGON_ASSEMBLER_ASM_PARSER_H

#include "mnemonics.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Una instrucción ASM ya separada en campos, todavía sin calendarizar. */
typedef struct {
    porygon_format_t format;
    unsigned int funct;
    bool immediate;
    union {
        struct {
            uint8_t rs1;
            uint8_t rs2;
            int64_t literal;
        } math;
        struct {
            uint8_t rd;
            uint8_t rs;
            int64_t offset;
        } lost;
        struct {
            uint8_t rd;
            int64_t offset;
        } jump;
        struct {
            uint8_t rs1;
            uint8_t rs2;
            uint8_t item_index; /* Ronda, subllave o palabra, según funct. */
            uint8_t key_index;
        } crypto;
    } operands;
} porygon_instruction_t;

typedef enum {
    PORYGON_PARSE_OK,
    PORYGON_PARSE_EMPTY,
    PORYGON_PARSE_INVALID_ARGUMENT,
    PORYGON_PARSE_UNKNOWN_MNEMONIC,
    PORYGON_PARSE_EXPECTED_REGISTER,
    PORYGON_PARSE_EXPECTED_NUMBER,
    PORYGON_PARSE_EXPECTED_SEPARATOR,
    PORYGON_PARSE_OUT_OF_RANGE,
    PORYGON_PARSE_TRAILING_TEXT,
    PORYGON_PARSE_UNSUPPORTED_FORMAT
} porygon_parse_status_t;

typedef struct {
    porygon_parse_status_t status;
    size_t column; /* Columna inicial en base 1; cero para argumentos inválidos. */
} porygon_parse_result_t;

/*
 * Analiza una instrucción en una línea. Acepta espacios, registros r0..r7
 * y enteros decimales o 0x hexadecimales. Los mnemónicos aceptan mayúsculas
 * o minúsculas. No admite comentarios ni
 * etiquetas. En CRYPTO, los índices escritos en ASM son 0..3, sin conversión.
 * Devuelve PORYGON_PARSE_EMPTY para una línea en blanco. En cualquier error,
 * out queda intacto y column señala el lugar donde se detectó el problema.
 */
porygon_parse_result_t porygon_parse_instruction(const char *line,
                                                  porygon_instruction_t *out);

#endif
