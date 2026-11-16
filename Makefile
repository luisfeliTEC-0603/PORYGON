IVERILOG ?= iverilog
VVP ?= vvp
.DEFAULT_GOAL := all

BUILD_DIR := build
WAVE_DIR := $(BUILD_DIR)/waves
RTL_DIR := rtl
CORE_DIR := $(RTL_DIR)/core
MEMORY_DIR := $(RTL_DIR)/memory
METRICS_DIR := $(RTL_DIR)/metrics
UNIT_TB_DIR := tests/unit
SUPPORT_TB_DIR := tests/support
INTEGRATION_TB_DIR := tests/integration
PROGRAM_DIR := tests/programs

COMMON_FLAGS := -g2012 -Wall -I$(RTL_DIR) -I$(SUPPORT_TB_DIR)
PKG := $(RTL_DIR)/pkg_vliw.sv
MEMORY_PKG := $(MEMORY_DIR)/pkg_memory.sv
METRICS_PKG := $(RTL_DIR)/metrics/pkg_metrics.sv

# Nucleo reusable con puertos externos de memoria.
RTL_SOURCES := $(PKG) $(MEMORY_PKG) $(METRICS_PKG) \
	$(wildcard $(CORE_DIR)/decode/*.sv) \
	$(wildcard $(CORE_DIR)/crypto/*.sv) \
	$(CORE_DIR)/register_file.sv \
	$(CORE_DIR)/alu_unit.sv $(CORE_DIR)/super_alu_unit.sv \
	$(CORE_DIR)/lost_unit.sv $(CORE_DIR)/bruh_unit.sv \
	$(CORE_DIR)/fetch_stage.sv $(CORE_DIR)/execution_stage.sv \
	$(CORE_DIR)/writeback_stage.sv $(CORE_DIR)/vliw_processor.sv
RTL_SOURCES += $(CORE_DIR)/bundle_completions.sv
RTL_SOURCES += $(CORE_DIR)/core_metrics.sv

# Jerarquia completa; el orden de paquetes precede a todos los consumidores.
HIERARCHY_RTL_SOURCES := $(MEMORY_DIR)/memory_sp_ram.sv \
	$(MEMORY_DIR)/main_memory.sv $(MEMORY_DIR)/memory_controller.sv \
	$(MEMORY_DIR)/eviction_buffer.sv $(MEMORY_DIR)/write_buffer.sv \
	$(MEMORY_DIR)/cache_l1.sv $(wildcard $(MEMORY_DIR)/cache_l2/*.sv) \
	$(MEMORY_DIR)/line_return.sv $(RTL_DIR)/metrics/performance_counters.sv \
	$(MEMORY_DIR)/data_memory_hierarchy.sv

# Sistema conectado: ROM y jerarquia real, con observador pendiente de P2-10.
SYSTEM_RTL_SOURCES := $(RTL_SOURCES) \
	$(MEMORY_DIR)/instruction_memory.sv $(HIERARCHY_RTL_SOURCES) \
	$(RTL_DIR)/porygon_system.sv

.PHONY: elaborate elaborate-core
elaborate: $(BUILD_DIR)/porygon_system.vvp

elaborate-core: $(BUILD_DIR)/vliw_processor.vvp

$(BUILD_DIR)/porygon_system.vvp: $(SYSTEM_RTL_SOURCES)
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s porygon_system -o $@ $^

$(BUILD_DIR)/vliw_processor.vvp: $(RTL_SOURCES)
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s vliw_processor -o $@ $^

.PHONY: all sim test test-tools sim-alu sim-super-alu sim-regfile sim-lost sim-bruh sim-feistel \
	sim-crypto-decode sim-key-vault sim-crypto-wb sim-crypto-unit sim-crypto \
	sim-top sim-system sim-metrics clean

all: sim

ifeq ($(strip $(PROG)),)
sim: sim-top
else
sim:
	@./tools/sim.sh "$(PROG)" $(if $(strip $(DATA)),--data "$(DATA)") $(if $(strip $(MAX_CYCLES)),--max-cycles "$(MAX_CYCLES)")
endif

test: sim-alu sim-super-alu sim-regfile sim-lost sim-bruh sim-crypto \
	sim-metrics test-tools

.PHONY: test-p2-09 sim-lost-handshake sim-pipeline-hold sim-instruction-memory
test-p2-09: sim-instruction-memory sim-pipeline-hold sim-lost sim-lost-handshake \
	sim-load-wb sim-core-memory-wait sim-reference-storage sim-reference-timing \
	sim-bundle-completions sim-core-metrics sim-core-reference

sim-lost-handshake: $(BUILD_DIR)/lost_handshake.vvp
	$(VVP) $<
$(BUILD_DIR)/lost_handshake.vvp: $(PKG) $(CORE_DIR)/lost_unit.sv $(UNIT_TB_DIR)/tb_lost_handshake.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_lost_handshake -o $@ $^

sim-pipeline-hold: $(BUILD_DIR)/pipeline_hold.vvp
	$(VVP) $<
$(BUILD_DIR)/pipeline_hold.vvp: $(PKG) $(CORE_DIR)/fetch_stage.sv $(CORE_DIR)/writeback_stage.sv $(MEMORY_DIR)/instruction_memory.sv $(UNIT_TB_DIR)/tb_pipeline_hold.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_pipeline_hold -o $@ $^

sim-instruction-memory: $(BUILD_DIR)/instruction_memory.vvp
	$(VVP) $<
$(BUILD_DIR)/instruction_memory.vvp: $(PKG) $(MEMORY_DIR)/instruction_memory.sv $(UNIT_TB_DIR)/tb_instruction_memory.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_instruction_memory -o $@ $^

test-tools:
	sh tests/tools/test_loader.sh
	sh tests/tools/test_indicators.sh

.PHONY: sim-core-memory-wait
.PHONY: sim-reference-storage
.PHONY: sim-reference-timing
.PHONY: sim-core-reference
.PHONY: sim-load-wb
.PHONY: sim-bundle-completions
.PHONY: sim-core-metrics
sim-core-metrics: $(BUILD_DIR)/core_metrics_test.vvp
	$(VVP) $<

$(BUILD_DIR)/core_metrics_test.vvp: $(PKG) $(MEMORY_PKG) $(METRICS_PKG) $(CORE_DIR)/bundle_completions.sv $(CORE_DIR)/core_metrics.sv $(UNIT_TB_DIR)/tb_core_metrics.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_core_metrics -o $@ $^

sim-bundle-completions: $(BUILD_DIR)/bundle_completions_test.vvp
	$(VVP) $<

$(BUILD_DIR)/bundle_completions_test.vvp: $(PKG) $(MEMORY_PKG) $(METRICS_PKG) $(CORE_DIR)/bundle_completions.sv $(UNIT_TB_DIR)/tb_bundle_completions.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_bundle_completions -o $@ $^

sim-load-wb: $(BUILD_DIR)/load_wb.vvp
	$(VVP) $<

$(BUILD_DIR)/load_wb.vvp: $(RTL_SOURCES) $(UNIT_TB_DIR)/tb_load_wb.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_load_wb -o $@ $^

sim-core-reference: $(addprefix sim-core-reference-,1 9 48)
sim-core-reference-%: $(BUILD_DIR)/core_reference_%.vvp
	$(VVP) $<

$(BUILD_DIR)/core_reference_%.vvp: $(RTL_SOURCES) $(MEMORY_DIR)/instruction_memory.sv \
	$(SUPPORT_TB_DIR)/cpu_memory_reference.sv $(INTEGRATION_TB_DIR)/tb_core_reference.sv \
	$(PROGRAM_DIR)/top/top_integration.mem
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_core_reference -Ptb_core_reference.RESPONSE_CYCLES=$* -o $@ $(filter %.sv,$^)

sim-reference-timing: $(addprefix $(BUILD_DIR)/reference_timing_,1.vvp 9.vvp 48.vvp)
	$(VVP) $(BUILD_DIR)/reference_timing_1.vvp
	$(VVP) $(BUILD_DIR)/reference_timing_9.vvp
	$(VVP) $(BUILD_DIR)/reference_timing_48.vvp

$(BUILD_DIR)/reference_timing_%.vvp: $(PKG) $(MEMORY_PKG) $(METRICS_PKG) \
	$(SUPPORT_TB_DIR)/cpu_memory_reference.sv $(UNIT_TB_DIR)/tb_reference_timing.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_reference_timing -Ptb_reference_timing.RESPONSE_CYCLES=$* -o $@ $^

sim-reference-storage: $(BUILD_DIR)/reference_storage.vvp
	$(VVP) $<

$(BUILD_DIR)/reference_storage.vvp: $(PKG) $(MEMORY_PKG) $(METRICS_PKG) \
	$(SUPPORT_TB_DIR)/cpu_memory_reference.sv $(UNIT_TB_DIR)/tb_reference_storage.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_reference_storage -o $@ $^

sim-core-memory-wait: $(BUILD_DIR)/core_memory_wait.vvp
	$(VVP) $<

$(BUILD_DIR)/core_memory_wait.vvp: $(RTL_SOURCES) $(UNIT_TB_DIR)/tb_core_memory_wait.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_core_memory_wait -o $@ $^

sim-top: $(BUILD_DIR)/top.vvp | $(WAVE_DIR)
	$(VVP) $<

sim-system: $(BUILD_DIR)/system.vvp | $(WAVE_DIR)
	$(VVP) $< $(ARGS)

$(BUILD_DIR)/system.vvp: $(SYSTEM_RTL_SOURCES) $(INTEGRATION_TB_DIR)/tb_system.sv $(SUPPORT_TB_DIR)/hierarchy_snapshot.svh
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_system -o $@ $(SYSTEM_RTL_SOURCES) $(INTEGRATION_TB_DIR)/tb_system.sv


$(BUILD_DIR)/top.vvp: $(SYSTEM_RTL_SOURCES) $(INTEGRATION_TB_DIR)/tb_top.sv \
	$(SUPPORT_TB_DIR)/hierarchy_snapshot.svh \
	$(PROGRAM_DIR)/top/top_integration.mem $(PROGRAM_DIR)/top/top_data.mem
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_top -o $@ $(SYSTEM_RTL_SOURCES) $(INTEGRATION_TB_DIR)/tb_top.sv

sim-alu: $(BUILD_DIR)/alu.vvp
	$(VVP) $<

$(BUILD_DIR)/alu.vvp: $(PKG) $(CORE_DIR)/alu_unit.sv $(UNIT_TB_DIR)/tb_alu.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_alu -o $@ $^

sim-super-alu: $(BUILD_DIR)/super_alu.vvp
	$(VVP) $<

$(BUILD_DIR)/super_alu.vvp: $(PKG) $(CORE_DIR)/super_alu_unit.sv $(UNIT_TB_DIR)/tb_super_alu.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_super_alu -o $@ $^

sim-regfile: $(BUILD_DIR)/regfile.vvp
	$(VVP) $<

$(BUILD_DIR)/regfile.vvp: $(PKG) $(CORE_DIR)/register_file.sv $(UNIT_TB_DIR)/tb_regfile.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_regfile -o $@ $^

sim-lost: $(BUILD_DIR)/lost.vvp
	$(VVP) $<

$(BUILD_DIR)/lost.vvp: $(PKG) $(CORE_DIR)/lost_unit.sv $(UNIT_TB_DIR)/tb_lost.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_lost -o $@ $^

sim-bruh: $(BUILD_DIR)/bruh.vvp
	$(VVP) $<

$(BUILD_DIR)/bruh.vvp: $(PKG) $(CORE_DIR)/bruh_unit.sv $(UNIT_TB_DIR)/tb_bruh.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_bruh -o $@ $^

sim-crypto: sim-feistel sim-crypto-decode sim-key-vault sim-crypto-wb sim-crypto-unit

sim-feistel: $(BUILD_DIR)/feistel_round.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/feistel_round.vvp: $(PKG) $(CORE_DIR)/crypto/feistel_round_logic.sv $(UNIT_TB_DIR)/tb_crypto.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto -o $@ $^

sim-crypto-decode: $(BUILD_DIR)/crypto_decode.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/crypto_decode.vvp: $(PKG) $(CORE_DIR)/crypto/crypto_decode.sv $(UNIT_TB_DIR)/tb_crypto_decode.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto_decode -o $@ $^

sim-key-vault: $(BUILD_DIR)/key_vault.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/key_vault.vvp: $(PKG) $(CORE_DIR)/crypto/key_vault.sv $(UNIT_TB_DIR)/tb_key_vault.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_key_vault -o $@ $^

sim-crypto-wb: $(BUILD_DIR)/crypto_wb.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/crypto_wb.vvp: $(PKG) $(CORE_DIR)/crypto/crypto_wb.sv $(UNIT_TB_DIR)/tb_crypto_wb.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto_wb -o $@ $^

sim-crypto-unit: $(BUILD_DIR)/crypto_unit.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/crypto_unit.vvp: $(PKG) \
	$(CORE_DIR)/crypto/crypto_decode.sv \
	$(CORE_DIR)/crypto/key_vault.sv \
	$(CORE_DIR)/crypto/feistel_round_logic.sv \
	$(CORE_DIR)/crypto/crypto_wb.sv \
	$(CORE_DIR)/crypto/crypto_unit.sv \
	$(UNIT_TB_DIR)/tb_crypto_unit.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto_unit -o $@ $^

# Observador de metricas P2-10: no depende del nucleo ni de la jerarquia,
# los eventos se construyen en el testbench.
sim-metrics: $(BUILD_DIR)/metrics.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/metrics.vvp: $(PKG) \
	$(MEMORY_DIR)/pkg_memory.sv \
	$(METRICS_DIR)/pkg_metrics.sv \
	$(METRICS_DIR)/performance_counters.sv \
	$(UNIT_TB_DIR)/tb_performance_counters.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_performance_counters -o $@ $^

$(WAVE_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
