IVERILOG ?= iverilog
VVP ?= vvp

BUILD_DIR := build
SRC_DIR := hardware/src
TB_DIR := hardware/tb

COMMON_FLAGS := -g2012 -Wall -I$(SRC_DIR)
PKG := $(SRC_DIR)/pkg_vliw.sv

.PHONY: all sim sim-alu sim-super-alu sim-regfile sim-bruh sim-feistel \
	sim-crypto-decode clean

all: sim

sim: sim-alu sim-super-alu

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

sim-bruh: $(BUILD_DIR)/bruh.vvp
	$(VVP) $<

$(BUILD_DIR)/bruh.vvp: $(PKG) $(SRC_DIR)/bruh_unit.sv $(TB_DIR)/tb_bruh.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_bruh -o $@ $^

sim-feistel: $(BUILD_DIR)/feistel_round.vvp
	$(VVP) $<

$(BUILD_DIR)/feistel_round.vvp: $(PKG) $(SRC_DIR)/crypto/feistel_round_logic.sv $(TB_DIR)/tb_crypto.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto -o $@ $^

sim-crypto-decode: $(BUILD_DIR)/crypto_decode.vvp
	$(VVP) $<

$(BUILD_DIR)/crypto_decode.vvp: $(PKG) $(SRC_DIR)/crypto/crypto_decode.sv $(TB_DIR)/tb_crypto_decode.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(COMMON_FLAGS) -s tb_crypto_decode -o $@ $^

# Espacios reservados para las siguientes unidades:
# sim-lost: compilar lost_unit.sv y tb_lost.sv.
# sim-crypto: integrar todos los módulos CRYPTO cuando estén implementados.
# sim-pkg: compilar utilidades de pkg_vliw.sv y tb_pkg.sv.
# sim-top: compilar todas las unidades, etapas, memoria, vliw_processor.sv y tb_top.sv.

clean:
	rm -rf $(BUILD_DIR)
