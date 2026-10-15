#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Uso: ./extract.sh <programa|dump.mem> <dirección> <tamaño> [salida]

El primer argumento puede ser:
  - El nombre de una simulación creada por make sim, por ejemplo prueba.
  - La ruta explícita a un archivo de volcado .mem.

La salida se guarda junto al dump. Si se omite, se usa resultado.bin.

Ejemplos:
  ./extract.sh prueba 0x10000 32
  ./extract.sh prueba 0x10040 8 recuperado.bin
  ./extract.sh sim_output/prueba/memory.dump.mem 0x10000 32 salida.bin
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
[[ $# -ge 3 && $# -le 4 ]] || { usage >&2; exit 2; }

dump_selector=$1
address=$2
size=$3
output_name=${4:-resultado.bin}

[[ $address =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] ||
    fail "dirección inválida '$address'"
[[ $size =~ ^[1-9][0-9]*$ ]] || fail "el tamaño debe ser un entero positivo"
[[ -n "$output_name" ]] || fail "el nombre de salida está vacío"

if [[ -f "$dump_selector" ]]; then
    dump_file=$(absolute_file "$dump_selector")
elif [[ $dump_selector != */* ]]; then
    program_name=${dump_selector%.mem}
    dump_file="$root_dir/sim_output/$program_name/memory.dump.mem"
    [[ -f "$dump_file" ]] || fail \
        "no existe la simulación '$program_name' en sim_output/"
else
    fail "no existe el dump '$dump_selector'"
fi

dump_dir=$(dirname "$dump_file")
if [[ $output_name == /* ]]; then
    output_file=$output_name
else
    output_file="$dump_dir/$output_name"
fi
output_parent=$(dirname "$output_file")
[[ -d "$output_parent" ]] || fail "no existe el directorio de salida '$output_parent'"
output_file=$(cd "$output_parent" && pwd -P)/$(basename "$output_file")
[[ $output_file != "$dump_file" ]] || fail "la salida no puede sobrescribir el dump"

extractor="$root_dir/tools/data_loader/extract_data.py"
[[ -f "$extractor" ]] || fail "no existe el extractor '$extractor'"

"${PYTHON:-python3}" "$extractor" \
    --memory "$dump_file" \
    --address "$address" \
    --size "$size" \
    --output "$output_file"

printf '[porygon] dump  : %s\n' "$dump_file"
printf '[porygon] salida: %s (%s bytes desde %s)\n' "$output_file" "$size" "$address"
