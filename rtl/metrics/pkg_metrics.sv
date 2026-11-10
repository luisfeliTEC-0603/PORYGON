/**
 * @brief Eventos observables e instantanea de contadores de 64 bits.
 * @details Pulsos: un hecho por flanco. Estados: intervalo que termina en el
 * flanco. Las estructuras no tienen ready ni controlan la jerarquia.
 * Los ids de eventos se extienden con ceros a 32 bits; los puertos funcionales
 * conservan su ancho derivado. Los deltas admiten finalizaciones simultaneas.
 * @see docs/ii-proyecto/metrics.md
 */
package pkg_metrics;
    typedef logic [63:0] counter_t;
    typedef logic [7:0] event_delta_t;
    typedef logic [31:0] event_id_t;
    typedef logic [31:0] occupancy_t;

    typedef enum logic [1:0] {
        WAIT_NONE, WAIT_ACCEPT, WAIT_MISS, WAIT_RESPONSE
    } wait_reason_t;

    typedef enum logic [2:0] {
        ORIGIN_L1, ORIGIN_WB, ORIGIN_L2, ORIGIN_MEMORY,
        ORIGIN_REFERENCE, ORIGIN_ERROR
    } demand_origin_t;

    typedef enum logic [1:0] {
        ACCESS_HIT, ACCESS_MISS, ACCESS_INVALID
    } access_result_t;

    typedef enum logic [2:0] {
        ERROR_NONE, ERROR_ADDRESS, ERROR_ALIGNMENT,
        ERROR_PROTOCOL, ERROR_TIMEOUT
    } error_kind_t;

    typedef struct packed {
        logic valid;
        error_kind_t kind;
        pkg_memory::address_t address;
    } error_event_t;

    typedef struct packed {
        logic valid;
        pkg_memory::address_t base;
        logic dirty;
    } line_event_t;

    typedef struct packed {
        logic valid;
        event_id_t id;
    } id_event_t;

    typedef struct packed {
        logic valid;
        logic write;
        event_id_t id;
        pkg_memory::address_t base;
    } mem_event_t;

    typedef struct packed {
        occupancy_t occupancy;
        occupancy_t capacity;
        logic push_wait;
        logic send_wait;
        logic raw_wait;
    } buffer_state_t;

    /**
     * @brief Eventos del nucleo para el observador; campos independientes.
     * @details Mascaras de etapas: bit 0 IF, 1 ID, 2 EX, 3 WB. Los cuatro
     * deltas done_* se refieren a finalizaciones, incluso sin escritura RF.
     * dmem_begin ocurre en la primera presentacion, aun con req_ready=0.
     */
    typedef struct packed {
        event_delta_t done_bundles;
        event_delta_t done_instructions;
        event_delta_t done_nop_slots;
        event_delta_t done_literal_slots;
        logic [3:0] stage_occupied;
        logic [3:0] stage_transfers;
        logic [3:0] stage_mem_stalls;
        logic stall;
        wait_reason_t wait_reason;
        logic branch_done;
        logic branch_taken;
        logic branch_delay;
        logic dmem_begin;
        logic dmem_write;
        logic dmem_done;
        logic dmem_error;
        demand_origin_t dmem_origin;
        error_event_t instruction_error;
        error_event_t alignment_error;
    } cpu_events_t;

    typedef struct packed {
        logic access_valid;
        logic access_write;
        access_result_t access_result;
        line_event_t eviction;
        error_event_t error;
    } l1_events_t;

    typedef struct packed {
        id_event_t get_accept;
        id_event_t get_done;
        id_event_t lookup;
        logic lookup_hit;
        line_event_t promotion;
        line_event_t clean_discard;
        line_event_t dirty_eviction;
        occupancy_t inflight;
        occupancy_t capacity;
        logic get_wait;
        error_event_t error;
    } l2_events_t;

    typedef struct packed {
        line_event_t enqueued;
        line_event_t forwarded;
        id_event_t install_accept;
        id_event_t install_done;
        buffer_state_t state;
        error_event_t error;
    } wb_events_t;

    typedef struct packed {
        line_event_t enqueued;
        mem_event_t write_accept;
        mem_event_t write_done;
        logic write_error;
        buffer_state_t state;
        error_event_t error;
    } eb_events_t;

    /**
     * @brief Estados y eventos de memoria ya trasladados al dominio CPU.
     * @details accept, word y complete pueden ocurrir en el mismo flanco
     * para operaciones distintas. complete marca disponibilidad, no consumo.
     */
    typedef struct packed {
        mem_event_t accept;
        mem_event_t word;
        mem_event_t complete;
        error_kind_t complete_error;
        logic read_active;
        logic write_active;
        logic read_wait;
        logic write_wait;
        logic read_rsp_wait;
        logic write_rsp_wait;
        logic read_rsp_consumed;
        logic write_rsp_consumed;
        occupancy_t reads_pending;
        occupancy_t writes_pending;
        occupancy_t read_responses_pending;
        occupancy_t write_responses_pending;
    } mem_events_t;

    typedef struct packed {
        counter_t occupied;
        counter_t transfers;
        counter_t mem_stalls;
    } stage_counters_t;

    typedef struct packed {
        counter_t cycles;
        counter_t bundles;
        counter_t instructions;
        counter_t nop_slots;
        counter_t literal_slots;
        counter_t stall_cycles;
        counter_t wait_accept;
        counter_t wait_miss;
        counter_t wait_rsp;
        counter_t branches;
        counter_t branches_taken;
        counter_t branch_delay_cycles;
        stage_counters_t stage_if;
        stage_counters_t stage_id;
        stage_counters_t stage_ex;
        stage_counters_t stage_wb;
    } cpu_counters_t;

    typedef struct packed {
        counter_t completed;
        counter_t failed;
        counter_t reads_completed;
        counter_t writes_completed;
        counter_t latency_sum;
        counter_t read_latency_sum;
        counter_t write_latency_sum;
        counter_t miss_stalls_wb;
        counter_t miss_stalls_l2;
        counter_t miss_stalls_mem;
    } demand_counters_t;

    typedef struct packed {
        counter_t reads;
        counter_t writes;
        counter_t read_hits;
        counter_t read_misses;
        counter_t write_hits;
        counter_t write_misses;
        counter_t invalid_reads;
        counter_t invalid_writes;
        counter_t evictions_clean;
        counter_t evictions_dirty;
    } l1_counters_t;

    typedef struct packed {
        counter_t demands;
        counter_t hits;
        counter_t misses;
        counter_t promotions;
        counter_t evictions_clean;
        counter_t evictions_dirty;
        counter_t inflight_sum;
        counter_t inflight_max;
        counter_t full_cycles;
        counter_t get_wait_cycles;
    } l2_counters_t;

    typedef struct packed {
        counter_t enqueued;
        counter_t forwarded;
        counter_t sent;
        counter_t installed;
        counter_t occupancy_sum;
        counter_t occupancy_max;
        counter_t full_cycles;
        counter_t push_wait_cycles;
        counter_t install_wait_cycles;
        counter_t raw_wait_cycles;
    } wb_counters_t;

    typedef struct packed {
        counter_t enqueued;
        counter_t sent;
        counter_t written;
        counter_t occupancy_sum;
        counter_t occupancy_max;
        counter_t full_cycles;
        counter_t push_wait_cycles;
        counter_t raw_wait_cycles;
    } eb_counters_t;

    typedef struct packed {
        counter_t reads;
        counter_t writes;
        counter_t reads_complete;
        counter_t writes_complete;
        counter_t read_words;
        counter_t write_words;
        counter_t read_cycles;
        counter_t write_cycles;
        counter_t read_wait_cycles;
        counter_t write_wait_cycles;
        counter_t read_rsp_wait_cycles;
        counter_t write_rsp_wait_cycles;
        counter_t timeouts;
        counter_t errors;
    } mem_counters_t;

    typedef struct packed {
        logic [31:0] cpu_hz;
        logic [31:0] memory_bytes;
        logic [31:0] l1_bytes;
        logic [31:0] l1_ways;
        logic [31:0] l2_bytes;
        logic [31:0] l2_ways;
        logic [31:0] line_bytes;
        logic [31:0] write_buffer_depth;
        logic [31:0] eviction_buffer_depth;
        logic [31:0] l2_max_inflight;
        logic [31:0] mem_clock_div;
        logic [31:0] mem_read_first_word_cycles;
        logic [31:0] mem_write_first_word_cycles;
        logic [31:0] mem_timeout_cycles;
        logic reference_without_cache;
    } configuration_t;

    typedef struct packed {
        occupancy_t wb_entries;
        occupancy_t eb_entries;
        occupancy_t l2_inflight;
        occupancy_t mem_reads;
        occupancy_t mem_writes;
        occupancy_t mem_read_responses;
        occupancy_t mem_write_responses;
    } pending_t;

    /** @brief Vista cruda; se congela despues de incorporar el flanco de stop. */
    typedef struct packed {
        configuration_t configuration;
        cpu_counters_t cpu;
        demand_counters_t dmem;
        l1_counters_t l1;
        l2_counters_t l2;
        wb_counters_t wb;
        eb_counters_t eb;
        mem_counters_t mem;
        counter_t error_events;
        logic failed;
        logic overflow;
        pending_t pending;
    } snapshot_t;
endpackage
