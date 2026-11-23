# Programas y vectores Feistel4

Estos casos provienen del kit de verificación usado con PORYGON. Cada prefijo
`kit_*` conserva su fuente `.asm`, la imagen de instrucciones `.mem` y la imagen
de datos `_datos.mem`, para poder ejecutar el hardware sin compilar de nuevo el
programa. Los resultados históricos están en
[docs/evidence/feistel4](../../../docs/evidence/feistel4/).

`inputs/` contiene los archivos originales y `llave_01.hex`, una llave fija de
prueba. `expected/` contiene los cifrados de referencia en little-endian. Los
programas también usan una credencial fija de prueba para la bóveda.

El original de `imagen.jpg.enc` no venía en el kit. Se conserva el cifrado de
referencia; `kit_imagen_jpg_datos.mem` lo carga para el caso de descifrado y
recifrado. Los originales disponibles son el binario, el GIF y los dos textos.

Desde la raíz del repositorio, ejecutar un caso con sus datos preparados:

```bash
./tools/sim.sh tests/programs/feistel4/kit_texto_corto.mem \
  --data tests/programs/feistel4/kit_texto_corto_datos.mem --expect errors=0
./tools/memory/extract.sh kit_texto_corto 0x12000 24 texto_corto.txt.enc
./tools/memory/extract.sh kit_texto_corto 0x14000 21 texto_corto.recuperado.txt
```

La simulación y los archivos extraídos quedan en `build/sim/kit_texto_corto/`.
Para preparar otra imagen de datos a partir del original del mismo caso:

```bash
mkdir -p build/feistel4
python3 tools/memory/load_file.py \
  --input tests/programs/feistel4/inputs/texto_corto.txt \
  --output build/feistel4/texto_corto_datos.mem --address 0x10000
```

Los programas usan `0x10000` como entrada, `0x12000` como primera salida y
`0x14000` como segunda salida. Los tamaños y el sentido de cada operación se
conservan en los ASM y en el reporte histórico; el caso JPEG supera el watchdog
predeterminado y requiere `--max-cycles 200000`.

Los listados `.bundles` se generan fuera de las fuentes. Definir `PIPER_DIR`
con la ruta al repositorio PIPER-COMPILER y usar su ensamblador ya compilado:

```bash
mkdir -p build/feistel4
"$PIPER_DIR/bin/porygon-schedule" tests/programs/feistel4/kit_texto_corto.asm \
  build/feistel4/kit_texto_corto.bundles build/feistel4/kit_texto_corto.mem
```
