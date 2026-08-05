"""EmbedFileAsDelphiConst — embed a binary file as a Delphi const.

Binary-read tool: the agent cannot read raw bytes; Python can. Emits either an
`array[0..N] of Byte` (hex) or a Base64 string const. inject=at_cursor.
"""
import sys
import os
import json
import base64


def _utf8():
    try:
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def main() -> int:
    _utf8()
    p = json.load(sys.stdin)
    fp = p.get("file_path")
    if not fp or not os.path.exists(fp):
        print(f"file_path not found: {fp}", file=sys.stderr)
        return 2
    name = p.get("const_name") or "cEmbedded"
    fmt = (p.get("format") or "bytes").lower()

    with open(fp, "rb") as f:
        data = f.read()

    if fmt == "base64":
        b64 = base64.b64encode(data).decode("ascii")
        chunks = [b64[i:i + 76] for i in range(0, len(b64), 76)] or [""]
        body = " +\n    ".join(f"'{c}'" for c in chunks)
        src = f"const\n  {name}Base64 =\n    {body};"
    elif not data:
        src = f"const\n  {name}: array[0..0] of Byte = ($00); // file was empty"
    else:
        hexes = [f"${b:02X}" for b in data]
        rows = ["    " + ", ".join(hexes[i:i + 16])
                for i in range(0, len(hexes), 16)]
        src = (f"const\n  {name}: array[0..{len(data) - 1}] of Byte = (\n" +
               ",\n".join(rows) + "\n  );")

    json.dump({"inject": "at_cursor", "source": src, "byte_count": len(data)},
              sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
