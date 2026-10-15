#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOAD="$SCRIPT_DIR/load_file.py"
EXTRACT="$SCRIPT_DIR/extract_data.py"
CRYPTO_DUMP="$SCRIPT_DIR/../../hardware/tb/programs/crypto_data.mem"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/porygon-loader.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

fail()
{
    echo "test_loader: $*" >&2
    exit 1
}

# Round-trip de 13 bytes con NUL y valores de bit alto, más padding a 16 bytes.
printf '\000\001\177\200\377ABC\020\000xyz' >"$TEST_TMP/original.bin"
python3 "$LOAD" --input "$TEST_TMP/original.bin" --output "$TEST_TMP/roundtrip.mem" \
    --address 0x11000 --block 8 >/dev/null
grep -q '^@00001000$' "$TEST_TMP/roundtrip.mem" || fail "la directiva @ no es relativa"
python3 "$EXTRACT" --memory "$TEST_TMP/roundtrip.mem" --output "$TEST_TMP/recovered.bin" \
    --address 0x11000 --size 13 >/dev/null
cmp "$TEST_TMP/original.bin" "$TEST_TMP/recovered.bin" || fail "el round-trip no es idéntico"

# B07: una celda x/z solicitada debe fallar con 1 antes de crear la salida.
printf '@00001000\n11 xx 33\n' >"$TEST_TMP/unknown.mem"
set +e
python3 "$EXTRACT" --memory "$TEST_TMP/unknown.mem" --output "$TEST_TMP/unknown.out" \
    --address 0x11000 --size 3 >"$TEST_TMP/unknown.stdout" 2>"$TEST_TMP/unknown.stderr"
status=$?
set -e
[ "$status" -eq 1 ] || fail "B07 devolvió $status en vez de 1"
[ ! -e "$TEST_TMP/unknown.out" ] || fail "B07 generó una salida engañosa"
grep -q 'x/z' "$TEST_TMP/unknown.stderr" || fail "B07 no produjo un error descriptivo"

# Dump real: verifica los ocho bytes iniciales conocidos del banco crypto.
python3 "$EXTRACT" --memory "$CRYPTO_DUMP" --output "$TEST_TMP/crypto.out" \
    --address 0x10000 --size 8 >/dev/null
printf '\147\105\043\001\357\315\253\211' >"$TEST_TMP/crypto.expected"
cmp "$TEST_TMP/crypto.expected" "$TEST_TMP/crypto.out" || fail "el dump crypto real no coincide"

echo "test_loader: all tests passed"
