# PORYGON




<div align="center">

<img src="https://markdownviewer.pages.dev/api/image/0vHRcN0FG_gpvkRPJEdgWxjp" alt="porygon" width="200" height="200">

[![VLIW](https://img.shields.io/badge/Architecture-VLIW-fa646b?style=for-the-badge&logoColor=white)]()
[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-2026-5fa69f?style=for-the-badge&logoColor=white)]()
[![Cipher](https://img.shields.io/badge/Cipher-Feistel4-fa646b?style=for-the-badge&logoColor=white)]()

**Procesador VLIW con ISA propia y una unidad criptográfica Feistel4**

</div>

## Alcance y estado actual

Proyecto académico CE4301, desarrollado **100% por simulación** con Icarus
Verilog o Verilator. No requiere síntesis ni implementación en FPGA.

El repositorio contiene el skeleton inicial: los módulos SystemVerilog,
testbenches, herramientas Python y el `Makefile` son archivos vacíos pendientes
de implementación. Todavía no hay un flujo ejecutable de compilación o simulación.
Los documentos de microarquitectura, simulación e integración con CE1108 también
están pendientes de contenido.

La ISA define bundles de 64 bits, compuestos por cuatro slots de 16 bits,
con asignación flexible de unidades funcionales.

## Estructura

| Ruta | Contenido |
|------|-----------|
| `hardware/src/` | Paquete compartido, etapas del pipeline, unidades funcionales, banco de registros y modelo de memoria |
| `hardware/tb/` | Archivos reservados para testbenches unitarios y de integración |
| `tools/assembler/` | Ensamblador propio pendiente de implementación |
| `tools/data_loader/` | Herramientas de carga y extracción pendientes de implementación |
| `docs/` | Enunciado, ISA, guía y documentación técnica |
| `Makefile` | Archivo reservado para automatizar la simulación |
| `agents.md` | Directrices de trabajo y codificación para agentes |

## Referencias

- [Enunciado del proyecto](docs/EnunciadoArqui.md): requisitos oficiales.
- [ISA](docs/isa.md): formatos, instrucciones y codificación.
- [Guía de implementación](docs/GUIA.md): planificación auxiliar del desarrollo.
- [Microarquitectura](docs/microarchitecture.md): pendiente de documentar.
- [Simulación](docs/simulation.md): pendiente de documentar.
- [Integración con CE1108](docs/compiler-integration.md): pendiente de documentar.
- [Directrices para agentes](agents.md): autorización, alcance y convenciones.

En caso de conflicto, las instrucciones del usuario prevalecen sobre el enunciado,
y el enunciado sobre la ISA. La guía es material auxiliar.

## Cobertura prevista de testbenches

Todos los archivos siguientes son placeholders vacíos; esta tabla describe
la cobertura por implementar, no pruebas ya ejecutadas.

| Archivo | Cobertura prevista |
|---------|--------------------|
| `tb_pkg.sv` | Utilidades compartidas de simulación |
| `tb_alu.sv` | Operaciones aritméticas y lógicas de la ISA |
| `tb_regfile.sv` | Lecturas y escrituras simultáneas e inmutabilidad de `r0` |
| `tb_lost.sv` | Cargas, almacenamientos, alineación y extensiones de signo/ceros |
| `tb_bruh.sv` | Saltos condicionales e incondicionales, destino y `branch_taken` |
| `tb_crypto.sv` | Ronda Feistel4 y bóveda: cuatro llaves, autenticación válida/fallida, escritura, cambio de contraseña, revocación y rechazo de accesos no autorizados; aislamiento de llaves frente a registros y memoria generales |
| `tb_top.sv` | Integración del procesador, bundles mixtos y cifrado/descifrado completo contra la referencia |
