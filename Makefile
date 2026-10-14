IVERILOG ?= iverilog
VVP ?= vvp
.DEFAULT_GOAL := all

BUILD_DIR := build
WAVE_DIR := $(BUILD_DIR)/waves
SRC_DIR := hardware/src
TB_DIR := hardware/tb

COMMON_FLAGS := -g2012 -Wall -I$(SRC_DIR)
PKG := $(SRC_DIR)/pkg_vliw.sv

# Nucleo reusable con puertos externos de memoria.
RTL_SOURCES := $(PKG) \
	$(wildcard $(SRC_DIR)/idd/*.sv) \
	$(wildcard $(SRC_DIR)/crypto/*.sv) \
	$(SRC_DIR)/register_file.sv \
	$(SRC_DIR)/alu_unit.sv $(SRC_DIR)/super_alu_unit.sv \
	$(SRC_DIR)/lost_unit.sv $(SRC_DIR)/bruh_unit.sv \
	$(SRC_DIR)/fetch_stage.sv $(SRC_DIR)/execution_stage.sv \
	$(SRC_DIR)/writeback_stage.sv $(SRC_DIR)/vliw_processor.sv

# Sistema conectado: memorias reales de simulacion y wrapper del nucleo.
SYSTEM_RTL_SOURCES := $(RTL_SOURCES) \
	$(SRC_DIR)/instruction_memory.sv $(SRC_DIR)/memory_sp_ram.sv \
	$(SRC_DIR)/porygon_system.sv

.PHONY: elaborate elaborate-core
elaborate: $(BUILD_DIR)/porygon_system.vvp

elaborate-core: $(BUILD_DIR)/vliw_processor.vvp

$(BUILD_DIR)/porygon_system.vvp: $(SYSTEM_RTL_SOURCES)
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s porygon_system -o $@ $^

$(BUILD_DIR)/vliw_processor.vvp: $(RTL_SOURCES)
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s vliw_processor -o $@ $^

.PHONY: all sim sim-alu sim-super-alu sim-regfile sim-bruh sim-feistel \
	sim-crypto-decode sim-key-vault sim-crypto-wb sim-crypto-unit sim-crypto \
	sim-top sim-system clean

all: sim

ifeq ($(strip $(PROG)),)
sim: sim-alu sim-super-alu sim-top
else
sim:
	@./sim.sh "$(PROG)" "$(if $(strip $(CYCLES)),$(CYCLES),200)" $(if $(strip $(DATA)),--data "$(DATA)")
endif

sim-top: $(BUILD_DIR)/top.vvp | $(WAVE_DIR)
	$(VVP) $<

sim-system: $(BUILD_DIR)/system.vvp | $(WAVE_DIR)
	$(VVP) $< $(ARGS)

$(BUILD_DIR)/system.vvp: $(SYSTEM_RTL_SOURCES) $(TB_DIR)/tb_system.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_system -o $@ $(SYSTEM_RTL_SOURCES) $(TB_DIR)/tb_system.sv


$(BUILD_DIR)/top.vvp: $(SYSTEM_RTL_SOURCES) $(TB_DIR)/tb_top.sv \
	$(TB_DIR)/programs/top_integration.mem $(TB_DIR)/programs/top_data.mem
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_top -o $@ $(SYSTEM_RTL_SOURCES) $(TB_DIR)/tb_top.sv

sim-alu: $(BUILD_DIR)/alu.vvp
	$(VVP) $<

$(BUILD_DIR)/alu.vvp: $(PKG) $(SRC_DIR)/alu_unit.sv $(TB_DIR)/tb_alu.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_alu -o $@ $^

sim-super-alu: $(BUILD_DIR)/super_alu.vvp
	$(VVP) $<

$(BUILD_DIR)/super_alu.vvp: $(PKG) $(SRC_DIR)/super_alu_unit.sv $(TB_DIR)/tb_super_alu.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_super_alu -o $@ $^

# Banco de registros: se habilita después de validar el flujo inicial de ALU.
sim-regfile: $(BUILD_DIR)/regfile.vvp
	$(VVP) $<

$(BUILD_DIR)/regfile.vvp: $(PKG) $(SRC_DIR)/register_file.sv $(TB_DIR)/tb_regfile.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_regfile -o $@ $^

sim-lost: $(BUILD_DIR)/lost.vvp
	$(VVP) $<

$(BUILD_DIR)/lost.vvp: $(PKG) $(SRC_DIR)/lost_unit.sv $(TB_DIR)/tb_lost.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_lost -o $@ $^

# Espacios reservados para las siguientes unidades:
# sim-bruh: compilar bruh_unit.sv y tb_bruh.sv.
sim-bruh: $(BUILD_DIR)/bruh.vvp
	$(VVP) $<

$(BUILD_DIR)/bruh.vvp: $(PKG) $(SRC_DIR)/bruh_unit.sv $(TB_DIR)/tb_bruh.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_bruh -o $@ $^

sim-crypto: sim-feistel sim-crypto-decode sim-key-vault sim-crypto-wb sim-crypto-unit

sim-feistel: $(BUILD_DIR)/feistel_round.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/feistel_round.vvp: $(PKG) $(SRC_DIR)/crypto/feistel_round_logic.sv $(TB_DIR)/tb_crypto.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto -o $@ $^

sim-crypto-decode: $(BUILD_DIR)/crypto_decode.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/crypto_decode.vvp: $(PKG) $(SRC_DIR)/crypto/crypto_decode.sv $(TB_DIR)/tb_crypto_decode.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto_decode -o $@ $^

sim-key-vault: $(BUILD_DIR)/key_vault.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/key_vault.vvp: $(PKG) $(SRC_DIR)/crypto/key_vault.sv $(TB_DIR)/tb_key_vault.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_key_vault -o $@ $^

sim-crypto-wb: $(BUILD_DIR)/crypto_wb.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/crypto_wb.vvp: $(PKG) $(SRC_DIR)/crypto/crypto_wb.sv $(TB_DIR)/tb_crypto_wb.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto_wb -o $@ $^

sim-crypto-unit: $(BUILD_DIR)/crypto_unit.vvp | $(WAVE_DIR)
	$(VVP) $<

$(BUILD_DIR)/crypto_unit.vvp: $(PKG) \
	$(SRC_DIR)/crypto/crypto_decode.sv \
	$(SRC_DIR)/crypto/key_vault.sv \
	$(SRC_DIR)/crypto/feistel_round_logic.sv \
	$(SRC_DIR)/crypto/crypto_wb.sv \
	$(SRC_DIR)/crypto/crypto_unit.sv \
	$(TB_DIR)/tb_crypto_unit.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto_unit -o $@ $^

$(WAVE_DIR):
	mkdir -p $@

# Espacios reservados para las siguientes unidades:
# sim-lost: compilar lost_unit.sv y tb_lost.sv.
# sim-pkg: compilar utilidades de pkg_vliw.sv y tb_pkg.sv.
# sim-top: compilar todas las unidades, etapas, memoria, vliw_processor.sv y tb_top.sv.

clean:
	rm -rf $(BUILD_DIR)
