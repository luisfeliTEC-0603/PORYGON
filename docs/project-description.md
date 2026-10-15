# Especificación Proyecto Grupal I – Arquitectura VLIW Propia para Aplicaciones de Cifrado por Bloques

> **Documento de Referencia Técnica del Proyecto (Optimizado para lectura por Agentes)**  
> **Institución:** Instituto Tecnológico de Costa Rica  
> **Escuela:** Escuela de Ingeniería en Computadores  
> **Programa:** Licenciatura en Ingeniería en Computadores  
> **Curso:** CE-4301 Arquitectura de Computadores I  
> **Profesor:** Dr.-Ing. Jeferson González Gómez  
> **Grupo de trabajo:** 5 estudiantes  
> **Fecha Entrega 1 (ISA):** Viernes 25 de septiembre, 2026, 11:59 p.m. (TEC Digital)  
> **Fecha Entrega 2 (Implementación y Defensa):** Miércoles 14 de octubre, 2026  

---

## Cuadro Resumen de Requisitos de la Arquitectura (Agent Quick Reference)

| Parámetro / Módulo | Requisito Mínimo del Enunciado | Notas y Restricciones de Diseño |
| :--- | :--- | :--- |
| **Paradigma** | VLIW (*Very Long Instruction Word*) | Paralelismo estático a nivel de instrucción (ILP) resuelto por software. |
| **Ancho de Bundle / Slots** | $\ge 4$ slots por bundle | Ejecución en paralelo en el mismo ciclo de reloj. Ejemplo: 4 slots $\times$ 32 bits = 128 bits. |
| **Tipos de Unidad Funcional** | $\ge 3$ tipos diferentes entre los slots | Mínimo ALU, LSU, BRU y Unidad Criptográfica (Feistel4). |
| **Asignación de Slots** | Fija o Flexible | Debe justificarse en el diseño (fija es más simple; flexible requiere campo selector). |
| **Manejo de Riesgos (Hazards)** | **Estático (Software)** | **CERO forwarding automático, scoreboarding o stalls por datos en HW.** El compilador/ensamblador debe insertar `NOP`s o reordenar. |
| **Stalls de Hardware** | Permitidos sólo para riesgos estructurales | Por ejemplo, contención de recursos compartidos entre etapas del pipeline. |
| **Pipeline (Segmentación)** | $\ge 4$ etapas: IF, ID, EX, WB | Se evalúa en la Entrega 2. Bundles simultáneos en vuelo separados por registros de pipeline. |
| **Registros de Propósito General** | $\ge 8$ registros de 32 bits | Se permite y recomienda ampliar para facilitar el *scheduling* estático. Más PC y registro de estado. |
| **Direccionamiento / Memoria** | Direccionamiento de 32 bits, Memoria $\ge 64\text{ KB}$ | Espacio direccionable de memoria general. |
| **Algoritmo Criptográfico** | Feistel4 (Red de Feistel simétrica) | Bloques de 64 bits ($L=32\text{b}, R=32\text{b}$), llave de 128 bits (4 subllaves de 32 bits), 4 rondas. |
| **Bóveda de Llaves (*Key Vault*)** | $\ge 4$ llaves de 128 bits (16 subllaves de 32 bits) | Raíz de Confianza (*Root of Trust*). **Aislamiento total:** no accesible como memoria normal ni transferible a registros generales. |
| **Control de Acceso a Bóveda** | Instrucciones dedicadas + Registro de Estado | Instrucciones tipo `login`, `authorize`, etc. Acceso no autorizado produce excepción/error. |
| **Aceleración Feistel4** | Instrucción de ronda individual | Debe recibir ($L, R$, índice de llave/ronda) y generar nuevo $(L, R)$. Se encadenan 4 rondas por bloque. |
| **Herramientas Software Propias** | Ensamblador propio + Herramienta de carga/extracción | Ensamblador para $100\%$ de las instrucciones (`$readmemh`); `load_file.py` y `extract_data.py` (CLI). |
| **Interacción con Compiladores** | Articulación con curso CE1108 | La Entrega 1 congela el contrato del ISA (green sheet binario). Se debe validar ejecutando código de CE1108. |
| **Herramientas de Simulación** | Icarus Verilog (`iverilog`) o Verilator | Makefiles reproducibles (`make sim`) y ondas `.vcd` para GTKWave. No requiere síntesis en FPGA. |

---

## 1. Objetivo

Mediante el desarrollo de este proyecto, el estudiante aplicará los conceptos de arquitectura de computadores en el diseño e implementación en SystemVerilog de un procesador VLIW (*Very Long Instruction Word*) con una arquitectura del set de instrucciones (ISA) propia, orientada a la aceleración de un algoritmo de cifrado por bloques tipo Feistel.

El proyecto se evaluará explícitamente en dos partes:
1. **Diseño de la Arquitectura del Set de Instrucciones (ISA):** Incluyendo el formato de bundle/slots y los tipos de unidad funcional que la componen.
2. **Organización interna (pipeline) e implementación en SystemVerilog:** Evaluada a nivel de simulación utilizando [Icarus Verilog (`iverilog`)](https://steveicarus.github.io/iverilog/) o [Verilator](https://www.veripool.org/verilator/).

Adicionalmente, los estudiantes diseñarán una herramienta que permita cargar archivos de cualquier formato (texto, imágenes, binarios, etc.) en la memoria de la simulación para cifrar y descifrar datos reales.

---

## 2. Descripción General

Las arquitecturas VLIW explotan el paralelismo a nivel de instrucción (*Instruction-Level Parallelism*, ILP) de forma estática: en lugar de que el hardware detecte y reordene instrucciones independientes en tiempo de ejecución (como en un procesador superescalar), es el compilador (o el programador) quien agrupa explícitamente varias operaciones independientes en una sola palabra de instrucción larga (*bundle*), cada una destinada a una unidad funcional distinta que se ejecuta en paralelo durante el mismo ciclo.

Esta filosofía de diseño, empleada históricamente en arquitecturas como Multiflow Trace, Intel/HP Itanium (IA-64) y los procesadores TI TMS320C6x para DSP, permite hardware más simple y eficiente en área/potencia, a costa de trasladar la complejidad de la calendarización (*scheduling*) al software.

En este proyecto se dará una introducción a este paradigma mediante el diseño de un procesador VLIW propio con soporte nativo para la aceleración de un algoritmo de cifrado de bloque simplificado tipo red de Feistel, al que llamaremos **Feistel4**.

> [!IMPORTANT]
> **Propósito General Obligatorio:** Es fundamental resaltar que, si bien el procesador incluye una unidad funcional dedicada a esta aplicación criptográfica, la arquitectura y la organización deben soportar programas de propósito general (“tradicionales”): todo programa VLIW válido debe poder incluir instrucciones aritméticas, lógicas, de acceso a memoria y de control de flujo, de forma completamente independiente de la aplicación de cifrado. La unidad criptográfica es una unidad funcional más dentro del procesador, no un reemplazo de las capacidades generales de cómputo.

Este proyecto además se articula con el curso de Compiladores e Intérpretes (CE1108): cada grupo de CE4301 tendrá asignado un grupo de contraparte en CE1108, responsable de desarrollar un compilador que traduzca un lenguaje de alto nivel hacia el ensamblador de la arquitectura VLIW propia. La [Sección 6](#6-integración-con-el-curso-de-compiladores-ce1108) detalla los requisitos y el contrato de interfaz entre ambos equipos.

---

## 3. Entregas Oficiales

El proyecto se divide en dos entregas oficiales, correspondientes a las dos partes evaluadas descritas en la [Sección 1](#1-objetivo):

### Entrega 1 – Especificación del ISA
- **Fecha:** Viernes 25 de septiembre, 2026, 11:59 p.m., vía TEC Digital.
- **Alcance:** Debe incluir el documento de especificación del ISA: formato de bundle y slots, tipos de unidad funcional ([Sección 4.1](#41-arquitectura-vliw), específicamente el formato de bundle/slots y las unidades funcionales – no incluye el pipeline, ver nota más abajo), el set de instrucciones, la *instruction reference sheet* con su codificación binaria exacta, y la justificación de las decisiones de diseño.
- **Congelamiento de contrato:** Esta entrega debe considerarse **congelada**: cualquier cambio posterior al ISA debe justificarse y comunicarse formalmente al grupo de contraparte de CE1108 ([Sección 6](#6-integración-con-el-curso-de-compiladores-ce1108)), ya que es este contenido –no la organización interna del pipeline– el que constituye el contrato con dicho grupo.

### Entrega 2 – Implementación Funcional y Defensa Final
- **Fecha:** Miércoles 14 de octubre, 2026.
- **Alcance:** Corresponde a la defensa presencial del proyecto completo: implementación en SystemVerilog, validación de la aplicación criptográfica Feistel4, ensamblador propio, herramienta de carga de archivos, e integración con el compilador de la contraparte de CE1108, según el detalle de la [Sección 8](#8-evaluación-del-proyecto).

---

## 4. Especificación

### 4.1. Arquitectura VLIW

#### 4.1.1. Formato de Bundle y Slots
Cada instrucción VLIW (*bundle*) debe estar compuesta por al menos 4 slots, cada uno dedicado a una unidad funcional específica y ejecutado en paralelo durante el mismo ciclo de reloj.

Como mínimo, deberán existir al menos tres tipos diferentes de unidades funcionales entre dichos slots (por ejemplo: unidad aritmético-lógica, unidad de acceso a memoria, unidad de control de flujo y unidad criptográfica).

Cada grupo deberá definir y justificar:
1. **Ancho del bundle:** Por ejemplo, 4 slots de 32 bits cada uno, para un bundle de 128 bits, y el formato de codificación de cada slot.
2. **Asignación de slots a unidades funcionales:** Puede optarse por un esquema de slots fijos (cada slot atado permanentemente a un tipo de unidad funcional, más simple de implementar) o un esquema flexible (más de un tipo de unidad funcional puede ocupar un mismo slot mediante un campo de selección), debidamente justificado en el documento de diseño.
3. **Codificación de NOP por slot:** Para los casos en que un ciclo no requiera ejecutar una operación en una unidad funcional particular.

> [!WARNING]
> **Nota sobre calendarización estática:** Al ser una arquitectura VLIW, el hardware no debe implementar detección ni resolución dinámica de riesgos de datos entre slots de un mismo bundle o entre bundles consecutivos (i.e., **sin scoreboarding, sin forwarding automático entre bundles, ni stalls por dependencias de datos en hardware**). La responsabilidad de organizar las instrucciones en bundles válidos, respetando las dependencias de datos y de control, recae en quien genera el código (el ensamblador propio del grupo o el compilador de la contraparte de CE1108), tal como se detalla en la [Sección 6](#6-integración-con-el-curso-de-compiladores-ce1108).

#### 4.1.2. Unidades Funcionales
Como mínimo, el procesador debe incluir las siguientes unidades funcionales, cada una accesible desde su(s) slot(s) correspondiente(s):
- **Unidad Aritmético-Lógica (ALU):** Suma, resta, AND, OR, XOR, desplazamientos, comparaciones.
- **Unidad de Acceso a Memoria (LSU):** Instrucciones load y store.
- **Unidad de Control de Flujo (BRU):** Saltos condicionales e incondicionales. Dado que el hardware no reordena ni detecta riesgos de control automáticamente, cada grupo deberá definir y justificar su estrategia frente a saltos (por ejemplo, *branch delay slot(s)* explícitos que deban ser llenados por el generador de código, o vaciado de pipeline sin penalización oculta).
- **Unidad Criptográfica (Feistel4):** Instrucción(es) dedicadas para acelerar el algoritmo de cifrado descrito en la [Sección 4.2](#42-aplicación-de-cifrado-por-bloques-feistel4), con acceso exclusivo a la bóveda de llaves ([Sección 4.3](#43-almacenamiento-seguro-de-llaves-bóveda)) como fuente de subllaves.

*Nota:* Se permite (y se valorará positivamente, de forma justificada) incluir más de una unidad funcional del mismo tipo (por ejemplo, dos ALUs en dos slots distintos) siempre que se respete el mínimo de 4 slots y de 3 tipos diferentes de unidad funcional.

#### 4.1.3. Organización Segmentada (Pipeline)

> [!NOTE]
> A diferencia del formato de bundle/slots y de los tipos de unidad funcional (que forman parte del contrato ISA de la Entrega 1, por ser lo que necesita el grupo de contraparte de CE1108 para generar código), el pipeline es una decisión de microarquitectura/organización que se diseña y evalúa junto con la implementación en SystemVerilog de la Entrega 2 ([Sección 8](#8-evaluación-del-proyecto)); no es necesario congelarla ni entregarla en la Entrega 1.

La organización del procesador debe implementarse como un pipeline (segmentado): distintos bundles deben poder encontrarse simultáneamente en distintas etapas de ejecución, en lugar de que cada bundle se procese por completo (*fetch* a *writeback*) antes de iniciar el siguiente.

Como mínimo, deberán distinguirse las siguientes etapas:
1. **Fetch (IF):** Búsqueda del bundle completo (todos sus slots) desde la memoria de instrucciones.
2. **Decode/Dispatch (ID):** Decodificación de los slots del bundle y despacho hacia sus unidades funcionales correspondientes.
3. **Execute (EX):** Ejecución en paralelo de las operaciones de cada slot en su unidad funcional (ALU, LSU, BRU, unidad criptográfica).
4. **Writeback (WB):** Escritura de resultados en el banco de registros y, cuando corresponda, en la bóveda de llaves.

Cada grupo puede proponer un número mayor de etapas (por ejemplo, separando el acceso a memoria de la escritura de resultados), debidamente justificado en el documento de diseño.

> [!IMPORTANT]
> **Riesgos y Stalls en el Pipeline:** Dado que el hardware no debe resolver riesgos de datos ni de control de forma dinámica, el pipeline no requiere forwarding ni scoreboarding: la responsabilidad de evitar dichos riesgos (mediante calendarización estática e inserción de NOPs) recae en quien genera el código. El pipeline **sí puede requerir stalls por riesgos estructurales** (por ejemplo, contención de un mismo recurso entre etapas), los cuales deberán documentarse y justificarse.

---

### 4.2. Aplicación de Cifrado por Bloques: Feistel4

Las redes de Feistel [1] son una construcción clásica para el diseño de cifradores de bloque simétricos: el bloque de entrada se divide en dos mitades ($L, R$), y en cada ronda se aplica una función de ronda $F$ (parametrizada por una subllave) sobre una de las mitades, combinándola mediante XOR con la otra, seguido de un intercambio. Su principal ventaja arquitectónica es que la misma unidad de hardware puede reutilizarse tanto para cifrar como para descifrar, simplemente invirtiendo el orden en que se aplican las subllaves.

Para este proyecto se deberá utilizar una red de Feistel simplificada de 4 rondas, llamada **Feistel4**, que opera sobre:
- **Bloques:** 64 bits (dos mitades $L$ y $R$ de 32 bits cada una).
- **Llave:** 128 bits, dividida en 4 subllaves de 32 bits (una por ronda).

#### Implementación de Referencia en C (Figura 1)

```c
#include <stdint.h>

#define ROL32(x, r) (((x) << (r)) | ((x) >> (32 - (r))))

// Función de ronda F: rotación + suma modular 2^32, combinada con XOR
uint32_t feistel4_F(uint32_t x, uint32_t k) {
    uint32_t t = ROL32(x, 5) + k;
    return t ^ ROL32(x, 13);
}

// Cifrado de un bloque de 64 bits (L, R) con red Feistel de 4 rondas
void feistel4_encrypt(uint32_t *L, uint32_t *R, const uint32_t key[4]) {
    for (int i = 0; i < 4; ++i) { // 4 rondas
        uint32_t temp = *R;
        *R = *L ^ feistel4_F(*R, key[i]);
        *L = temp;
    }
}

// Descifrado: se recorren las mismas 4 subllaves en orden inverso
void feistel4_decrypt(uint32_t *L, uint32_t *R, const uint32_t key[4]) {
    for (int i = 3; i >= 0; --i) { // orden inverso de subllaves
        uint32_t temp = *L;
        *L = *R ^ feistel4_F(*L, key[i]);
        *R = temp;
    }
}
```
*Figura 1: Implementación de referencia del cifrado y descifrado Feistel4.*

---

### 4.3. Almacenamiento Seguro de Llaves (Bóveda)

El algoritmo Feistel4 requiere una llave de 128 bits que debe protegerse adecuadamente: la eficacia y fortaleza del cifrado dependen en gran medida de que dicha llave se mantenga secreta y bien administrada.

Uno de los mecanismos empleados para evitar que las llaves sean vulneradas (por ejemplo, si un atacante logra tener acceso al sistema) es no mantenerlas en archivos o memoria general, sino almacenarlas directamente en el hardware utilizando una **raíz de confianza (*Root of Trust* – RoT)**, inaccesible para un usuario común del sistema, pero accesible para las aplicaciones seguras del sistema (e.g., la unidad criptográfica Feistel4).

Para este proyecto se deberá modelar una raíz de confianza en forma de una **bóveda de llaves (memoria segura)** que cumpla con:
- Almacenar al menos **4 llaves de 128 bits cada una** (cada llave de 128 bits corresponde a las 4 subllaves de 32 bits de una instancia de Feistel4).
- Ser accesible **directa y únicamente por el CPU**, por medio de instrucciones del set específicas para escribir u operar con los datos de la misma.
- La bóveda **NO debe poder ser accedida como una memoria tradicional**.

---

### 4.4. Requisitos Específicos de la Unidad Criptográfica para la ISA

#### 4.4.1. Bóveda de Llaves
1. **Instrucciones de almacenamiento:** Se deberá contar con una o más instrucciones específicas para almacenar llaves de 128 bits. Ya que sólo se permite almacenar 4 llaves, se deberá considerar esta limitante en el diseño de la(s) instrucción(es).
2. **Origen de llaves:** Toda operación de cifrado/descifrado Feistel4 que involucre llaves deberá utilizarlas desde la bóveda: las subllaves consumidas por la(s) instrucción(es) de ronda Feistel4 ([Sección 4.4.2](#442-instrucciónes-de-ronda-feistel4)) deben provenir de una llave previamente almacenada en la bóveda, **nunca de registros de propósito general** cargados directamente por el programa.
3. **Aislamiento de lectura:** Los datos almacenados en la bóveda **NO podrán ser leídos ni escritos hacia registros del CPU o memoria general** del sistema.
4. **Uso exclusivo:** Solamente la(s) instrucción(es) de ronda Feistel4 pueden acceder a la bóveda como operando fuente.
5. **Control de acceso y autenticación:** Se deberá implementar una o varias instrucciones específicas de autenticación/autorización (p.ej., `login`, `setpassword`, `authorize`, etc.) que aseguren que solamente código autorizado pueda acceder a la bóveda de llaves y realizar operaciones criptográficas. El procesador deberá mantener un registro de estado de autenticación que controle el acceso a estas operaciones privilegiadas. Las operaciones no autorizadas deberán generar una excepción o error de acceso.

#### 4.4.2. Instrucción(es) de Ronda Feistel4
1. **Aceleración por hardware:** Deberá incluirse en el set al menos una instrucción que ejecute una ronda completa de Feistel4 (i.e., que reciba $L$, $R$, y el índice de la llave/ronda a utilizar de la bóveda, y produzca el nuevo par $(L, R)$ de esa ronda), de forma que un programa completo de cifrado/descifrado se construya encadenando 4 invocaciones de dicha instrucción con la llave correspondiente.
2. **Granularidad de instrucción:** Deberá considerarse un balance entre eficiencia y costo (área, complejidad) al diseñar la(s) instrucción(es) de la unidad criptográfica: una única instrucción que ejecute las 4 rondas completas resultaría en una unidad funcional excesivamente compleja y poco representativa del paradigma VLIW (donde el paralelismo se explota entre slots, no colapsando el algoritmo en una sola operación monolítica).
3. **Selección de llave y ronda:** La codificación exacta con la que la(s) instrucción(es) de ronda seleccionan la llave (0–3) y el número de ronda (0–3) dentro de la bóveda queda a criterio de cada grupo, debidamente justificada.
4. **Casos de prueba extendidos (Imágenes):** Aunque la aplicación de referencia es el cifrado de archivos genéricos ([Sección 5.4](#54-herramienta-de-carga-de-archivos)), se permite y se valorará positivamente extender la validación a un caso de uso sobre imágenes (por ejemplo, cifrar/descifrar los píxeles de una imagen en un formato simple como PPM/BMP sin compresión, y visualizar el resultado), siempre que se mantenga como mínimo la validación sobre archivos genéricos.

---

### 4.5. Requisitos Generales de la Arquitectura del Set de Instrucciones (ISA)

- **Estructura VLIW:** Organizada según la [Sección 4.1](#41-arquitectura-vliw) (bundle de al menos 4 slots, al menos 3 tipos de unidad funcional).
- **Banco de Registros:** Se deberá definir un **mínimo de 8 registros de propósito general de 32 bits cada uno**. Se deja libertad a cada grupo para definir un banco de registros más amplio si lo considera conveniente (por ejemplo, para dar mayor margen de maniobra a la calendarización estática de instrucciones), debidamente justificado.
- **Registros Especiales:** Se debe incluir un *Program Counter* (PC) y un registro de estado.
- **Composición de Bundles:** Todo programa VLIW válido debe poder combinar libremente, en cualquier bundle, instrucciones de los siguientes tipos:
  - Instrucciones Aritméticas y Lógicas (ALU): suma, resta, AND, OR, XOR, desplazamientos, comparaciones.
  - Instrucciones de Acceso a Memoria: load, store.
  - Instrucciones de Control de Flujo: branch condicionales, jump.
  - Instrucción(es) de la Unidad Criptográfica Feistel4 y de manejo de la bóveda de llaves ([Sección 4.4](#44-requisitos-específicos-de-la-unidad-criptográfica-para-la-isa)).
- **Espacio de Direccionamiento:** Direccionamiento de 32 bits.
- **Tamaño de Memoria:** Memoria mínima de 64 KB.

---

## 5. Implementación en SystemVerilog

### 5.1. Requisitos de Diseño

El procesador VLIW y toda la arquitectura deberán implementarse en SystemVerilog, siguiendo las mejores prácticas de diseño digital:
- **Modularidad:** El diseño debe estar dividido en módulos bien definidos (p.ej., `fetch`, `decode`/`dispatch` del bundle hacia los slots, `alu`, `lsu`, `bru`, `crypto_unit`, `key_vault`, banco de registros, memoria).
- **Parámetros:** Utilizar parámetros de SystemVerilog para definir constantes (número de slots, ancho de bundle, tamaño de memoria, número de registros, etc.) para facilitar mantenibilidad y experimentación.
- **Despacho paralelo:** La etapa de decode/dispatch debe decodificar y despachar, en el mismo ciclo, las operaciones de los distintos slots del bundle hacia sus unidades funcionales correspondientes.
- **Organización segmentada:** El procesador debe implementarse como un pipeline ([Sección 4.1.3](#413-organización-segmentada-pipeline)), con registros de segmentación (*pipeline registers*) entre etapas que permitan que distintos bundles avancen simultáneamente por el datapath.
- **Testbenches:** Se deben crear testbenches exhaustivos para validar cada unidad funcional por separado y el sistema completo.
- **Documentación interna:** El código debe incluir comentarios explicativos en las secciones críticas.

### 5.2. Simulación con Icarus Verilog o Verilator

- **Entorno de simulación:** El procesador será evaluado mediante simulación, sin necesidad de síntesis en FPGA. Cada grupo deberá elegir Icarus Verilog o Verilator como herramienta principal de simulación; se valorará positivamente (aunque no es obligatorio) que el Makefile soporte ambas.
- **Automatización (Makefile):** Se deberá proporcionar un archivo `Makefile` que compile y ejecute las simulaciones de forma reproducible (`make sim` o equivalente).
- **Visualización de ondas:** Los testbenches deberán generar archivos de salida (`.vcd` o similar) para visualización en GTKWave.
- **Casos de prueba obligatorios:**
  1. Operaciones básicas de ALU, ejecutadas en paralelo con otras unidades dentro del mismo bundle.
  2. Acceso a memoria (load/store).
  3. Saltos condicionales e incondicionales.
  4. Ejecución de la(s) instrucción(es) de ronda Feistel4.
  5. Cifrado/descifrado completo (4 rondas) verificado contra la implementación de referencia ([Figura 1](#implementación-de-referencia-en-c-figura-1)).
  6. Manejo de la bóveda de llaves: almacenamiento de las 4 llaves, control de acceso (autenticación exitosa y fallida), y verificación de que las llaves no sean legibles desde registros de propósito general ni memoria general.
  7. Un programa VLIW que combine, dentro de los mismos bundles, instrucciones “tradicionales” (ALU, memoria, control de flujo) junto con instrucciones criptográficas, demostrando que ambos tipos de aplicación coexisten en la arquitectura.

### 5.3. Ensamblador Propio

Debe existir un ensamblador propio (en el lenguaje de elección de quien lo desarrolle) que traduzca programas escritos en el lenguaje ensamblador de la arquitectura VLIW (incluyendo la organización explícita de instrucciones en bundles y slots) hacia el formato binario/hexadecimal utilizado para inicializar la memoria de instrucciones en la simulación (p.ej., mediante `$readmemh`).

Su desarrollo puede ser asumido por el grupo de contraparte de CE1108 como parte de su propia herramienta de generación de código; sin embargo, de no contar con dicha herramienta en un momento dado, el grupo de CE4301 debe ser capaz de producirlo por su cuenta. En cualquier caso, este ensamblador es un requerimiento independiente del compilador que desarrollará el grupo de contraparte de CE1108 ([Sección 6](#6-integración-con-el-curso-de-compiladores-ce1108)) y **debe permitir validar el 100% del set de instrucciones diseñado sin depender de dicho compilador**.

### 5.4. Herramienta de Carga de Archivos

#### 5.4.1. Descripción
Se deberá desarrollar una herramienta (en C, Python o similar) que permita cargar archivos de cualquier formato (texto, imágenes, binarios, etc.) hacia la memoria del simulador. Esta herramienta facilitará el testeo de las operaciones de cifrado sobre datos reales, permitiendo cargar archivos de diferentes tipos y tamaños para operar sobre ellos con las instrucciones Feistel4 implementadas en la ISA.

#### 5.4.2. Requisitos
- La herramienta deberá leer un archivo de entrada y convertirlo en un formato que pueda ser inyectado en la memoria de la simulación.
- Generar una inicialización de memoria en formato Verilog (archivo `.mem` o similar) que contenga los bytes del archivo.
- Permitir especificar la dirección de memoria inicial donde se cargará el archivo.
- Proporcionar información sobre el tamaño del archivo cargado y la zona de memoria utilizada.
- Proporcionar una utilidad para extraer datos cifrados/descifrados de la memoria de la simulación y guardarlos en un archivo de salida, permitiendo verificar el correcto funcionamiento con archivos reales (incluyendo, opcionalmente, imágenes).

#### 5.4.3. Interfaz de Línea de Comandos (CLI)

```bash
# Carga de archivos en memoria del simulador:
./load_file.py --input archivo.txt --output memory.mem --address 0x1000
./load_file.py --input imagen.bmp  --output memory.mem --address 0x2000

# Extracción de datos cifrados/descifrados desde la memoria:
./extract_data.py --memory memory_dump.txt --address 0x2000 --size 4096 --output resultado.bin
```

---

## 6. Integración con el Curso de Compiladores (CE1108)

Este proyecto se desarrolla en conjunto con el curso de Compiladores e Intérpretes (CE1108). Cada grupo de CE4301 tendrá asignado un grupo de contraparte en CE1108, responsable de diseñar e implementar un compilador (o herramienta equivalente de generación de código) capaz de traducir un lenguaje de alto nivel hacia código binario (los bundles VLIW codificados en el formato de la arquitectura propia) ejecutable directamente sobre el procesador diseñado por el grupo de CE4301.

El compilador debe llegar hasta binario:
- Generándolo directamente, o
- Generando primero ensamblador propio y traduciéndolo a binario mediante el ensamblador de CE4301 ([Sección 5.3](#53-ensamblador-propio)) como paso final de su propia cadena de herramientas.

La estrategia interna queda a criterio del grupo de CE1108. Esto incluye la calendarización estática de instrucciones dentro de los bundles (asignación de operaciones a slots, manejo de dependencias de datos y de control, e inserción de `NOP`s donde corresponda), dado que el hardware no resuelve estos riesgos de forma automática.

### 6.1. Contrato de Interfaz ISA–Compilador

Independientemente de la estrategia, herramientas o lenguaje de implementación que el grupo de CE1108 decida utilizar para su compilador, el grupo de CE4301 debe garantizar que sea posible escribir y ejecutar programas directamente en el lenguaje ensamblador de la arquitectura propia, de forma completamente independiente de dicho compilador. En particular:

1. **Autonomía del Ensamblador:** El ensamblador propio ([Sección 5.3](#53-ensamblador-propio)) debe funcionar de forma autónoma, sin depender del compilador de CE1108, y debe permitir ejercitar el 100% de las instrucciones del set diseñado mediante programas escritos a mano.
2. **Entrega de la Especificación Estable:** El grupo de CE4301 debe entregar a su contraparte de CE1108 una especificación completa y estable del ISA y del formato de bundles (*instruction reference sheet*), incluyendo la codificación binaria exacta de cada instrucción y de cada slot, así como la sintaxis de su ensamblador propio.
3. **Plataforma de Simulación:** El grupo de CE4301 debe poner a disposición de su contraparte el modelo de simulación en SystemVerilog (o una interfaz reproducible sobre este) para que el código generado por el compilador pueda ejecutarse y validarse sobre el procesador real.
4. **Control de Cambios:** Cualquier cambio al ISA o al formato de bundles que ocurra después de establecido este contrato debe comunicarse formalmente al grupo de contraparte, dado su impacto directo en el generador de código.

### 6.2. Validación Conjunta

Antes de la defensa final, cada grupo de CE4301 deberá ejecutar sobre su procesador VLIW al menos un programa generado por el compilador de su contraparte de CE1108 (por ejemplo, una rutina que invoque el cifrado/descifrado Feistel4 desde código de alto nivel), demostrando:
- Bundles correctamente formados.
- Respeto de las dependencias de datos/control planificadas por el compilador.
- Resultados correctos verificados contra la implementación de referencia.

---

## 7. Entregables

### 1. Especificación del ISA (Entrega 1 – 25 de septiembre)
Documento detallando la arquitectura VLIW, formato de bundle y slots, set de instrucciones, convenciones de registros, etc.
- Puede entregarse en formato Markdown (`isa.md`, el mismo archivo requerido en la Documentación Técnica), siempre que esté enriquecido con tablas y diagramas/imágenes que hagan la especificación clara y completa; no es necesario un documento en LaTeX o PDF.

### 2. Código SystemVerilog (Entrega 2 – 14 de octubre)
Todos los módulos del procesador implementados en SystemVerilog, incluyendo:
- **Top-level:** `top.sv`
- **Módulos principales:** `alu.sv`, `lsu.sv`, `bru.sv`, `crypto_unit.sv`, `key_vault.sv`, `dispatch.sv`, `regfile.sv`, `memory.sv`, etc.
- **Testbenches:** `tb_top.sv`, `tb_alu.sv`, `tb_crypto_unit.sv`, `tb_key_vault.sv`, etc.
- **Automatización:** `Makefile` para compilar con Icarus Verilog y/o Verilator y ejecutar simulaciones.
- **Herramientas asociadas:** Ensamblador propio y herramienta de carga de archivos.

### 3. Documentación Técnica en `docs/` (Entrega 2 – 14 de octubre)
Estructurada en archivos Markdown (`.md`):
- `docs/isa.md`: Especificación detallada del ISA, formato de bundles e *instruction reference sheet*.
- `docs/microarchitecture.md`: Diagrama de bloques y organización interna (pipeline, dispatch, slots, unidades funcionales).
- `docs/simulation.md`: Descripción del modelado de la simulación.
- `docs/compiler-integration.md`: Descripción del contrato de interfaz con el grupo de CE1108 y evidencia de la validación conjunta.

### 4. Archivo `README.md` (Entrega 2 – 14 de octubre)
Instrucciones de compilación, ejecución, estructura del repositorio, ejemplos de uso del ensamblador propio y de la herramienta de carga (demostrando carga de diferentes tipos de archivos y cifrado/descifrado), y detalles para reproducir resultados.

---

## 8. Evaluación del Proyecto

La evaluación se organiza en dos bloques, correspondientes a las dos entregas oficiales ([Sección 3](#3-entregas-oficiales)). El diseño del ISA se evalúa una única vez como parte de la Entrega 1; la Entrega 2 no vuelve a calificar ese contenido de cero, sino su consistencia con lo implementado.

### 8.1. Evaluación Entrega 1 – Especificación del ISA (20%)
Se evalúa el documento entregado el 25 de septiembre ([Sección 3](#3-entregas-oficiales)) mediante revisión y una breve consulta al grupo (a discreción del profesor):
1. **Instruction reference sheet o green sheet del ISA:** Formato de bundle/slots y codificación binaria exacta de cada instrucción (necesaria para el contrato con CE1108).
2. **Justificación de decisiones de diseño:** Unidades funcionales y su asignación a slots, modos de direccionamiento, tipos de datos, estrategia frente a saltos, y diseño de las instrucciones criptográficas y de la bóveda de llaves ([Sección 4.4](#44-requisitos-específicos-de-la-unidad-criptográfica-para-la-isa)).

### 8.2. Evaluación Entrega 2 – Implementación Funcional y Defensa Final (80%)

Defensa presencial de ~25 minutos mostrando el sistema en funcionamiento: compilación sin errores, simulación exitosa, ejecución de todas las instrucciones (ALU, memoria, BRU, Feistel4, bóveda), validación con archivos reales, consistencia con Entrega 1 e integración con CE1108.

#### 8.2.1. Presentación Proyecto Funcional (50%)
1. **Microarquitectura / Implementación (20%):**
   - a) Diagrama de bloques de la microarquitectura (dispatch, slots, unidades funcionales, bóveda de llaves, banco de registros, memoria).
   - b) Organización segmentada (pipeline) correctamente implementada, con bundles en distintas etapas simultáneamente ([Sección 4.1.3](#413-organización-segmentada-pipeline)).
   - c) Ejecución correcta y en paralelo de las unidades funcionales dentro de un mismo bundle.
   - d) Estructura modular del código SystemVerilog.
2. **Validación de la Aplicación Criptográfica (20%):**
   - a) Cifrado Feistel4 de datos cargados en memoria (archivo genérico y, opcionalmente, imagen).
   - b) Descifrado y verificación de integridad contra la implementación de referencia.
   - c) Manejo correcto de la bóveda de llaves: almacenamiento de las 4 llaves, control de acceso (autenticación/autorización) y cumplimiento de las restricciones de aislamiento ([Sección 4.4.1](#441-bóveda-de-llaves)).
   - d) Ejecución de programas VLIW que combinan instrucciones tradicionales y criptográficas en los mismos bundles.
3. **Integración con Compiladores – CE1108 (10%):**
   - a) Ensamblador propio funcional, capaz de ejercitar el 100% del set de instrucciones diseñado de forma independiente.
   - b) Especificación de la ISA entregada formalmente al grupo de CE1108 (contrato de interfaz).
   - c) Ejecución correcta sobre el procesador VLIW de al menos un programa generado por el compilador de CE1108.

#### 8.2.2. Repositorio y Documentación de Diseño (30%)
1. **Gestión de Repositorio (15%):**
   - a) **Uso adecuado de Git con flujo profesional (8%):** Historial descriptivo de commits, branches de desarrollo (*dev branches*), pull requests / merge requests.
   - b) **README completo y claro (4%):** Propósito, compilación/ejecución, dependencias, estructura, ejemplos con archivos de prueba.
   - c) **Gestión de issues y milestones (3%):** Tracking de tareas, bugs y avances organizados en hitos.
2. **Documentación de Diseño (15%):**
   - a) **Organización / Microarquitectura (5%):** Descripción detallada del hardware, diagramas de bloques, interconexiones, flujo de datos/instrucciones (`docs/microarchitecture.md`).
   - b) **Modelado del Software / Simulación (5%):** Modelo de simulación, banco de registros, memoria, ensamblador propio y cargador de archivos (`docs/simulation.md`).
   - c) **Integración con Compiladores – CE1108 (5%):** Contrato de interfaz y evidencia de validación conjunta (`docs/compiler-integration.md`).

---

## 9. Notas Importantes

1. El procesador debe compilar y simular sin errores con Icarus Verilog o Verilator.
2. La simulación debe ejecutarse exitosamente, demostrando todas las funcionalidades (tanto tradicionales como criptográficas y de bóveda).
3. Todo el código debe incluir comentarios descriptivos en secciones críticas.
4. Se recomienda usar un `Makefile` para facilitar la compilación y ejecución de testbenches.
5. La coordinación con el grupo de contraparte de CE1108 debe iniciarse tan pronto como el ISA alcance una versión estable, para no comprometer los tiempos de desarrollo del compilador.

---

## Referencias

[1] Horst Feistel. *Cryptography and computer privacy*. Scientific American, 228(5):15–23, 1973.
