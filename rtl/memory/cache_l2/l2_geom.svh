/**
 * @file l2_geom.svh
 * @brief Constantes derivadas de la geometría de la caché L2.
 *
 * @details
 *   Archivo de inclusión; define parámetros derivados de la
 *   geometría base declarada en `pkg_memory`, evitando anchos hardcodeados en
 *   cada submódulo. Si la geometría del paquete cambia, todo L2 se recalcula
 *   automáticamente; este archivo no fija ningún valor numérico propio.
 *
 *   Parámetros base:
 *     L2_BYTES_L   : tamaño total de la L2 en bytes.
 *     L2_WAYS_L    : vías por conjunto.
 *     LINE_BYTES_L : tamaño de línea en bytes.
 *
 *   Parámetros derivados:
 *     L2_OFFSET_W : bits de offset de byte.
 *     L2_SETS     : número de conjuntos.
 *     L2_SET_W    : bits de índice de conjunto.
 *     L2_AW       : bits de dirección.
 *     L2_LW       : bits de línea.
 *     L2_TAG_W    : bits de tag.
 *     L2_WAY_W    : bits de índice de vía.
 *
 *   Anchos dependientes de L2_MAX_INFLIGHT:
 *     L2_ID_W(N) : ancho del identificador de operación en vuelo.
 *     L2_OPW(N)  : ancho del índice en la tabla de operaciones (mínimo 1).
 *
 *   Etapas del pipeline interno y su significado:
 *     AC   (accept)   : admisión de la operación en la tabla.
 *     DS   (dispatch) : asignación de vía y reserva.
 *     TAG             : lectura y comparación de tags.
 *     DATA            : lectura del arreglo de datos.
 *     RD   (return)   : formación de la respuesta hacia el consumidor.
 *   La suma de las etapas internas más el ciclo de accept da el tiempo de
 *   hit de L2 exigido (8 ciclos).
 *
 *   L2_TAG_LAST_STG es la última etapa que aún transporta el índice de tag;
 *   `l2_pipe` la usa para alinear metadatos con la lectura de tags.
 */

`ifndef L2_GEOM_SVH
`define L2_GEOM_SVH

// Geometría base
localparam int L2_BYTES_L   = pkg_memory::L2_BYTES;
localparam int L2_WAYS_L    = pkg_memory::L2_WAYS;
localparam int LINE_BYTES_L = pkg_memory::LINE_BYTES;

// Parámetros derivados de la geometría
localparam int L2_OFFSET_W  = $clog2(LINE_BYTES_L);
localparam int L2_SETS      = L2_BYTES_L / (L2_WAYS_L * LINE_BYTES_L);
localparam int L2_SET_W     = $clog2(L2_SETS);
localparam int L2_AW        = $bits(pkg_memory::address_t);
localparam int L2_LW        = $bits(pkg_memory::line_t);
localparam int L2_TAG_W     = L2_AW - L2_SET_W - L2_OFFSET_W;
localparam int L2_WAY_W     = $clog2(L2_WAYS_L);

// Anchos dependientes de L2_MAX_INFLIGHT
`define L2_ID_W(N)  pkg_memory::id_width(N)
`define L2_OPW(N)   (((N) > 1) ? $clog2(N) : 1)

// Duraciones de etapa del pipeline interno
localparam int L2_ST_AC   = 1;  // accept
localparam int L2_ST_DS   = 1;  // dispatch
localparam int L2_ST_TAG  = 2;  // tag
localparam int L2_ST_DATA = 2;  // data
localparam int L2_ST_RD   = 1;  // return
localparam int L2_PIPE_STAGES  = L2_ST_AC + L2_ST_DS + L2_ST_TAG +
                                 L2_ST_DATA + L2_ST_RD;
localparam int L2_TAG_LAST_STG = L2_ST_AC + L2_ST_DS + L2_ST_TAG - 1;

`endif // L2_GEOM_SVH
