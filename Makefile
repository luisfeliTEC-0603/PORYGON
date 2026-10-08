IVERILOG ?= iverilog
VVP ?= vvp

BUILD_DIR := build
SRC_DIR := hardware/src
TB_DIR := hardware/tb

COMMON_FLAGS := -g2012 -Wall -I$(SRC_DIR)
PKG := $(SRC_DIR)/pkg_vliw.sv

.PHONY: all sim sim-alu sim-regfile sim-lost clean

all: sim

sim: sim-alu

sim-alu: $(BUILD_DIR)/alu.vvp
	$(VVP) $<

$(BUILD_DIR)/alu.vvp: $(PKG) $(SRC_DIR)/alu_unit.sv $(TB_DIR)/tb_alu.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_alu -o $@ $^

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
# sim-crypto: compilar key_vault.sv, crypto_unit.sv y tb_crypto.sv.
# sim-pkg: compilar utilidades de pkg_vliw.sv y tb_pkg.sv.
# sim-top: compilar todas las unidades, etapas, memoria, vliw_processor.sv y tb_top.sv.

clean:
	rm -rf $(BUILD_DIR)
