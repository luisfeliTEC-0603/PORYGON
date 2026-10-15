# Empaquetado y lectura estricta de imágenes $readmemh / $writememh

import re

WIDTHS = (8, 16, 32, 64)

_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_LINE_COMMENT = re.compile(r"//[^\n]*")


class _UnknownCell:
    """Marca una palabra que contiene bits x/z sin inventar un valor numérico."""


UNKNOWN = _UnknownCell()


def bytes_per_word(width):
    if width not in WIDTHS:
        raise ValueError(f"ancho de palabra no soportado: {width}")
    return width // 8


def hex_digits(width):
    return width // 4


def pack(data, width, endian):
    # El byte de menor dirección ocupa los bits bajos de la palabra si el orden es little endian
    size = bytes_per_word(width)
    if len(data) % size:
        data += bytes(size - len(data) % size)
    return [int.from_bytes(data[i:i + size], endian) for i in range(0, len(data), size)]


def unpack(words, width, endian):
    size = bytes_per_word(width)
    out = bytearray()
    for word in words:
        out += int(word).to_bytes(size, endian)
    return bytes(out)


def render(words, width, start_index, per_line=16):
    # La directiva @ posiciona la carga sin tener que emitir las posiciones previas
    digits = hex_digits(width)
    lines = [f"@{start_index:08X}"]
    for i in range(0, len(words), per_line):
        lines.append(" ".join(f"{word:0{digits}X}" for word in words[i:i + per_line]))
    return "\n".join(lines) + "\n"


def parse(text, width):
    # Reconstruye {índice: palabra}; UNKNOWN conserva explícitamente cualquier x/z.
    digits = hex_digits(width)
    text = _LINE_COMMENT.sub(" ", _BLOCK_COMMENT.sub(" ", text))
    cells = {}
    index = 0
    for token in text.split():
        if token.startswith("@"):
            if not re.fullmatch(r"@[0-9a-fA-F]+", token):
                raise ValueError(f"directiva de dirección inválida: '{token}'")
            index = int(token[1:], 16)
            continue
        if not re.fullmatch(r"[0-9a-fA-FxXzZ]+", token):
            raise ValueError(f"token hexadecimal inválido: '{token}'")
        if len(token) > digits:
            raise ValueError(f"el token '{token}' excede {digits} digitos: el ancho de palabra no coincide")
        # $writememh marca con x o z las posiciones que nunca se escribieron
        cells[index] = UNKNOWN if re.search(r"[xXzZ]", token) else int(token, 16)
        index += 1
    return cells


def extract(cells, start_index, count, allow_uninitialized=False):
    """Extrae palabras sin ocultar huecos ni indeterminaciones de Verilog."""
    words = []
    for index in range(start_index, start_index + count):
        if index not in cells:
            if allow_uninitialized:
                words.append(0)
                continue
            raise ValueError(f"la posición @0x{index:08X} no fue inicializada en el volcado")
        if cells[index] is UNKNOWN:
            raise ValueError(f"la posición @0x{index:08X} contiene bits indeterminados x/z")
        words.append(cells[index])
    return words
