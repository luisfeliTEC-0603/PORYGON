# Empaquetado y lectura de imágenes de memoria en formato $readmemh / $writememh

import re

WIDTHS = (8, 16, 32, 64)

_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_LINE_COMMENT = re.compile(r"//[^\n]*")
_UNKNOWN_BITS = str.maketrans("xXzZ", "0000")


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
    # Reconstruye {índice: palabra}; cada directiva @ reposiciona el índice de escritura
    digits = hex_digits(width)
    text = _LINE_COMMENT.sub(" ", _BLOCK_COMMENT.sub(" ", text))
    cells = {}
    index = 0
    for token in text.split():
        if token.startswith("@"):
            index = int(token[1:], 16)
            continue
        if len(token) > digits:
            raise ValueError(f"el token '{token}' excede {digits} digitos: el ancho de palabra no coincide")
        # $writememh marca con x o z las posiciones que nunca se escribieron
        cells[index] = int(token.translate(_UNKNOWN_BITS), 16)
        index += 1
    return cells


def extract(cells, start_index, count):
    # Las posiciones ausentes del volcado se devuelven como cero
    return [cells.get(start_index + i, 0) for i in range(count)]
