#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Uso: ./sim.sh <programa.mem> [opciones]

Opciones:
  --data <datos.mem>       Inicializa la memoria de datos.
  --max-cycles <ciclos>    Cambia el watchdog (por defecto: 100000).
  --out <directorio>       Guarda resultados en este directorio.
  --expect <clave=valor>   Verifica PC, errores o un registro r0-r7. Repetible.
  -h, --help               Muestra esta ayuda.

Ejemplos:
  ./sim.sh programa.mem
  ./sim.sh programa.mem --data datos.mem
  ./sim.sh programa.mem --max-cycles 200000 --expect r1=10 --expect errors=0
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

absolute_file() {
    local path=$1
    local directory
    [[ -f "$path" ]] || fail "no existe el archivo '$path'"
    directory=$(cd "$(dirname "$path")" && pwd -P)
    printf '%s/%s\n' "$directory" "$(basename "$path")"
}

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
[[ $1 != "-h" && $1 != "--help" ]] || { usage; exit 0; }

instruction_file=$(absolute_file "$1")
shift
data_file=""
output_dir=""
max_cycles=100000
expectations=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --data)
            [[ $# -ge 2 ]] || fail "--data requiere una ruta"
            data_file=$(absolute_file "$2")
            shift 2
            ;;
        --max-cycles)
            [[ $# -ge 2 ]] || fail "--max-cycles requiere un valor"
            [[ $2 =~ ^[1-9][0-9]*$ ]] || fail "--max-cycles requiere un entero positivo"
            max_cycles=$2
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || fail "--out requiere un directorio"
            output_dir=$2
            shift 2
            ;;
        --expect)
            [[ $# -ge 2 ]] || fail "--expect requiere clave=valor"
            [[ $2 == *=* ]] || fail "expectativa inválida '$2'; use clave=valor"
            expectations+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "opción desconocida '$1'" ;;
    esac
done

if [[ -z "$output_dir" ]]; then
    program_name=$(basename "$instruction_file")
    program_name=${program_name%.*}
    output_dir="$root_dir/sim_output/$program_name"
elif [[ $output_dir != /* ]]; then
    output_dir="$(pwd -P)/$output_dir"
fi
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd -P)

dump_file="$output_dir/memory.dump.mem"
vcd_file="$output_dir/waves.vcd"
result_file="$output_dir/results.txt"
log_file="$output_dir/simulation.log"
build_log="$output_dir/build.log"

print_artifact_paths() {
    printf '  volcado: %s\n' "$dump_file"
    printf '  ondas  : %s\n' "$vcd_file"
    printf '  resultado: %s\n' "$result_file"
    printf '  log     : %s\n' "$log_file"
}

if ! make -s -C "$root_dir" build/system.vvp >"$build_log" 2>&1; then
    printf 'La compilación del simulador falló. Últimas líneas del log:\n' >&2
    tail -20 "$build_log" >&2
    exit 1
fi

vvp_args=(
    "+INSTR=$instruction_file"
    "+MAX_CYCLES=$max_cycles"
    "+DUMP=$dump_file"
    "+VCD=$vcd_file"
    "+RESULT=$result_file"
)
if [[ -n "$data_file" ]]; then
    vvp_args+=("+DATA=$data_file")
fi

if ! "${VVP:-vvp}" "$root_dir/build/system.vvp" "${vvp_args[@]}" >"$log_file" 2>&1; then
    printf 'La simulación falló. Últimas líneas del log:\n' >&2
    tail -20 "$log_file" >&2
    exit 1
fi
[[ -s "$result_file" ]] || fail "la simulación no produjo '$result_file'"

result_value() {
    local key=$1
    awk -F= -v wanted="$key" '$1 == wanted { value=$2 } END { if (value != "") print value }' \
        "$result_file"
}

compare_values() {
    local actual=$1
    local expected=$2
    [[ $actual =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
    [[ $expected =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
    (( actual == expected ))
}

printf '\nPORYGON — resumen de simulación\n'
printf '  ciclos : %s\n' "$(result_value cycles)"
printf '  halt   : %s\n' "$(result_value halted)"
printf '  PC     : %s\n' "$(result_value pc)"
printf '  errores: %s\n' "$(result_value errors)"
printf '  GPR    :'
for register in {0..7}; do
    printf ' r%d=%s' "$register" "$(result_value "r$register")"
done
printf '\n'

failed=0
timed_out=$(result_value timeout)
base_errors=$(result_value errors)
if compare_values "$timed_out" 1; then
    printf '  estado : TIMEOUT (watchdog de %s ciclos)\n' "$max_cycles" >&2
    failed=1
elif ! compare_values "$base_errors" 0; then
    printf '  estado : ERROR ARQUITECTÓNICO\n' >&2
    failed=1
fi

if (( ${#expectations[@]} > 0 )); then
    for expectation in "${expectations[@]}"; do
        key=${expectation%%=*}
        expected=${expectation#*=}
        actual=$(result_value "$key")
        if [[ -z "$actual" ]]; then
            printf "  FAIL   : resultado desconocido '%s'\n" "$key" >&2
            failed=1
        elif compare_values "$actual" "$expected"; then
            printf '  PASS   : %s=%s\n' "$key" "$actual"
        else
            printf '  FAIL   : %s esperado=%s obtenido=%s\n' "$key" "$expected" "$actual" >&2
            failed=1
        fi
    done
fi

if (( failed != 0 )); then
    print_artifact_paths >&2
    exit 1
fi
if (( ${#expectations[@]} == 0 )); then
    printf '  estado : COMPLETADA SIN ERRORES (resultado funcional no verificado)\n'
else
    printf '  estado : PASS\n'
fi
print_artifact_paths
