#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
INDICATORS="$ROOT_DIR/tools/metrics/indicators.py"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/porygon-indicators.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

fail()
{
    echo "test_indicators: $*" >&2
    exit 1
}

# Medición completa con valores escogidos para que los indicadores sean exactos.
cat >"$TEST_TMP/completa.txt" <<'EOM'
# contadores crudos de una medición de ejemplo
cpu_cycles=1000
cpu_instructions=600
cpu_bundles=250
l1_read_hits=180
l1_read_misses=20
l1_write_hits=40
l1_write_misses=10
l2_hits=20
l2_misses=10
dmem_completed=250
dmem_latency_sum=1750
wb_occupancy_sum=500
eb_occupancy_sum=250
l2_inflight_sum=1000
mem_read_words=80
mem_write_words=16
mem_read_cycles=390
mem_write_cycles=78
cpu_hz=100000000
mem_clock_div=2
mem_read_first_word_cycles=25
failed=0
overflow=0
EOM

python3 "$INDICATORS" --input "$TEST_TMP/completa.txt" --format json \
    --output "$TEST_TMP/completa.json" || fail "una medición válida no debe fallar"

valor()
{
    python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['indicadores'][sys.argv[2]])" \
        "$TEST_TMP/completa.json" "$1"
}

[ "$(valor ipc)" = "0.6" ] || fail "IPC incorrecto: $(valor ipc)"
[ "$(valor bundle_throughput)" = "0.25" ] || fail "throughput de bundles incorrecto"
[ "$(valor l1_read_hit_rate)" = "0.9" ] || fail "hit rate de lectura L1 incorrecto"
[ "$(valor l1_write_miss_rate)" = "0.2" ] || fail "miss rate de escritura L1 incorrecto"
[ "$(valor amat_observado)" = "7.0" ] || fail "AMAT observado incorrecto: $(valor amat_observado)"
[ "$(valor bytes_transferidos)" = "384" ] || fail "bytes transferidos incorrectos"
[ "$(valor ancho_banda_bytes_s)" = "38400000.0" ] || fail "ancho de banda incorrecto"
[ "$(valor utilizacion_ancho_banda)" = "0.192" ] || fail "utilización incorrecta"
[ "$(valor fraccion_tiempo_transferencia)" = "0.468" ] || fail "fracción de transferencia incorrecta"
# AMAT_referencia = 1 + 0.1 * (8 + (1/3) * (25 + 7*2)) = 3.1
[ "$(valor amat_referencia)" = "3.1" ] || fail "AMAT de referencia incorrecto: $(valor amat_referencia)"
[ "$(valor ocupacion_media_wb)" = "0.5" ] || fail "ocupación media del WB incorrecta"

# La configuracion sin cache informa N/A aunque reciba contadores no nulos.
cat "$TEST_TMP/completa.txt" >"$TEST_TMP/referencia.txt"
printf 'reference_without_cache=1\n' >>"$TEST_TMP/referencia.txt"
python3 "$INDICATORS" --input "$TEST_TMP/referencia.txt" --format json \
    --output "$TEST_TMP/referencia.json" || fail "la referencia debe ser comparable"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))['indicadores']
for key in ('l1_read_hit_rate', 'l1_read_miss_rate', 'l1_write_hit_rate',
            'l1_write_miss_rate', 'l2_hit_rate', 'l2_miss_rate',
            'ocupacion_media_wb', 'ocupacion_media_eb', 'ocupacion_media_l2', 'amat_referencia'):
    assert d[key] == 'N/A', (key, d[key])
assert d['ipc'] == 0.6 and d['amat_observado'] == 7.0
" "$TEST_TMP/referencia.json" || fail "indicadores de cache aplicados a referencia"

# Un denominador cero se informa como N/A y no aborta el cálculo del resto.
sed 's/^dmem_completed=250$/dmem_completed=0/' "$TEST_TMP/completa.txt" \
    >"$TEST_TMP/sin_demandas.txt"
python3 "$INDICATORS" --input "$TEST_TMP/sin_demandas.txt" --format json \
    --output "$TEST_TMP/sin_demandas.json" || fail "un denominador cero no debe fallar"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))['indicadores']
assert d['amat_observado'] == 'N/A', d['amat_observado']
assert d['ipc'] == 0.6, d['ipc']
" "$TEST_TMP/sin_demandas.json" || fail "el denominador cero no produjo N/A"

# Una ejecución fallida se reporta pero no es comparable, y el estado es 1.
sed 's/^failed=0$/failed=1/' "$TEST_TMP/completa.txt" >"$TEST_TMP/fallida.txt"
set +e
python3 "$INDICATORS" --input "$TEST_TMP/fallida.txt" >"$TEST_TMP/fallida.out"
status=$?
set -e
[ "$status" -eq 1 ] || fail "una ejecución fallida debe salir con estado 1"
grep -q "comparable     : NO" "$TEST_TMP/fallida.out" || fail "no se marcó como no comparable"
grep -q "ipc" "$TEST_TMP/fallida.out" || fail "se perdió la evidencia parcial"

# Lo mismo con overflow, que tampoco entra en comparaciones.
sed 's/^overflow=0$/overflow=1/' "$TEST_TMP/completa.txt" >"$TEST_TMP/desbordada.txt"
set +e
python3 "$INDICATORS" --input "$TEST_TMP/desbordada.txt" >/dev/null
status=$?
set -e
[ "$status" -eq 1 ] || fail "una medición con overflow debe salir con estado 1"

# --allow-invalid conserva el reporte pero devuelve éxito.
python3 "$INDICATORS" --input "$TEST_TMP/fallida.txt" --allow-invalid >/dev/null \
    || fail "--allow-invalid debe devolver éxito"

# Faltar un contador requerido tampoco permite comparar.
grep -v '^cpu_instructions=' "$TEST_TMP/completa.txt" >"$TEST_TMP/incompleta.txt"
set +e
python3 "$INDICATORS" --input "$TEST_TMP/incompleta.txt" >"$TEST_TMP/incompleta.out"
status=$?
set -e
[ "$status" -eq 1 ] || fail "una medición incompleta debe salir con estado 1"
grep -q "faltan contadores" "$TEST_TMP/incompleta.out" || fail "no se listaron los contadores ausentes"

# Una línea mal formada se rechaza antes de calcular nada.
printf 'cpu_cycles=10\nbasura\n' >"$TEST_TMP/mala.txt"
set +e
python3 "$INDICATORS" --input "$TEST_TMP/mala.txt" >/dev/null 2>"$TEST_TMP/mala.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail "una línea sin clave=valor debe fallar"
grep -q "sin 'clave=valor'" "$TEST_TMP/mala.err" || fail "el diagnóstico no identifica el problema"

echo "PASS: indicadores, N/A, ejecuciones no comparables y entradas inválidas"
