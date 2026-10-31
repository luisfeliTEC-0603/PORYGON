IVERILOG ?= iverilog
VVP ?= vvp
.DEFAULT_GOAL := all

BUILD_DIR := build
WAVE_DIR := $(BUILD_DIR)/waves
RTL_DIR := rtl
CORE_DIR := $(RTL_DIR)/core
MEMORY_DIR := $(RTL_DIR)/memory
UNIT_TB_DIR := tests/unit
INTEGRATION_TB_DIR := tests/integration
PROGRAM_DIR := tests/programs

COMMON_FLAGS := -g2012 -Wall -I$(RTL_DIR)
PKG := $(RTL_DIR)/pkg_vliw.sv

# Nucleo reusable con puertos externos de memoria.
RTL_SOURCES := $(PKG) \
	$(wildcard $(CORE_DIR)/decode/*.sv) \
	$(wildcard $(CORE_DIR)/crypto/*.sv) \
	$(CORE_DIR)/register_file.sv \
	$(CORE_DIR)/alu_unit.sv $(CORE_DIR)/super_alu_unit.sv \
	$(CORE_DIR)/lost_unit.sv $(CORE_DIR)/bruh_unit.sv \
	$(CORE_DIR)/fetch_stage.sv $(CORE_DIR)/execution_stage.sv \
	$(CORE_DIR)/writeback_stage.sv $(CORE_DIR)/vliw_processor.sv

# Sistema conectado: memorias reales de simulacion y wrapper del nucleo.
SYSTEM_RTL_SOURCES := $(RTL_SOURCES) \
	$(MEMORY_DIR)/instruction_memory.sv $(MEMORY_DIR)/memory_sp_ram.sv \
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
	sim-top sim-system clean

all: sim

ifeq ($(strip $(PROG)),)
sim: sim-top
else
sim:
	@./tools/sim.sh "$(PROG)" $(if $(strip $(DATA)),--data "$(DATA)") $(if $(strip $(MAX_CYCLES)),--max-cycles "$(MAX_CYCLES)")
endif

test: sim-alu sim-super-alu sim-regfile sim-lost sim-bruh sim-crypto test-tools

test-tools:
	sh tests/tools/test_loader.sh

sim-top: $(BUILD_DIR)/top.vvp | $(WAVE_DIR)
	$(VVP) $<

sim-system: $(BUILD_DIR)/system.vvp | $(WAVE_DIR)
	$(VVP) $< $(ARGS)

$(BUILD_DIR)/system.vvp: $(SYSTEM_RTL_SOURCES) $(INTEGRATION_TB_DIR)/tb_system.sv
	mkdir -p $(BUILD_DIR) $(WAVE_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_system -o $@ $(SYSTEM_RTL_SOURCES) $(INTEGRATION_TB_DIR)/tb_system.sv


$(BUILD_DIR)/top.vvp: $(SYSTEM_RTL_SOURCES) $(INTEGRATION_TB_DIR)/tb_top.sv \
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

$(WAVE_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
