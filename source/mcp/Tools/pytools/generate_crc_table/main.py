"""GenerateCrcTable — CRC lookup table -> Delphi const array.

Heavy-deterministic-compute tool: generate the 256-entry table for a polynomial
so the agent never hand-rolls 256 magic numbers. inject=at_cursor.
"""
import sys
import json


def _utf8():
    try:
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def main() -> int:
    _utf8()
    p = json.load(sys.stdin)
    poly = int(p.get("polynomial", 0xEDB88320)) & 0xFFFFFFFF
    name = p.get("const_name") or "CrcTable"

    table = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (poly ^ (c >> 1)) if (c & 1) else (c >> 1)
        table.append(c & 0xFFFFFFFF)

    hexes = [f"${v:08X}" for v in table]
    rows = ["    " + ", ".join(hexes[i:i + 8]) for i in range(0, 256, 8)]
    src = (f"const\n  {name}: array[0..255] of Cardinal = (\n" +
           ",\n".join(rows) + "\n  );")
    json.dump({"inject": "at_cursor", "source": src}, sys.stdout,
              ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
