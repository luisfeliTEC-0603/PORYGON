# Evidencia histórica de Feistel4

Estos archivos se conservaron sin modificar al reorganizar el kit de
verificación. Los programas y los datos de prueba están en
[tests/programs/feistel4](../../../tests/programs/feistel4/).

- `resultados.json` registra los resultados de cinco casos little-endian,
  incluidos ciclos, tamaños, hashes y comparaciones con las referencias.
- `md5sums-little-endian.txt` y `md5sums-big-endian.txt` son los listados de
  referencia entregados con el kit original.

Los listados MD5 conservan las rutas antiguas `originales/`, `llaves/` y
`cifrados/`; sus comandos no se ejecutan directamente desde esta ubicación.
Actualmente los originales y la llave están en `inputs/`, y los cifrados
little-endian en `expected/`, dentro del directorio de programas. El listado
big-endian se conserva por procedencia: los cifrados de esa variante no estaban
presentes.

El kit tampoco incluía el original JPG. Se preserva `expected/imagen.jpg.enc`;
el reporte documenta su descifrado y recifrado, sin afirmar una comparación con
un original ausente. La llave y las credenciales que aparecen en estos casos
son valores de prueba.

Esta evidencia describe ejecuciones anteriores. Las nuevas ejecuciones usan
`tools/sim.sh` y las herramientas de `tools/memory/`, y guardan sus artefactos en
`build/sim/<programa>/`. Los comandos actuales están en el README de los
programas.

Los cinco listados `.bundles` originales se pudieron regenerar de forma
idéntica con el ensamblador de PIPER-COMPILER. Son artefactos de compilación y
se generan en `build/`; aquí se conserva únicamente el reporte y los hashes
históricos.
