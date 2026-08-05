"""ExcelToResourceStrings — .xlsx -> Delphi resourcestring unit.

Binary-format tool: .xlsx is a zip of XML; the agent cannot read it, Python can
with the stdlib (zipfile + ElementTree). Key column -> identifier, value column
-> resourcestring literal. inject=new_unit.
"""
import sys
import os
import re
import json
import zipfile
import xml.etree.ElementTree as ET


def _utf8():
    try:
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def _local(tag: str) -> str:
    return tag.split("}")[-1]


def _col_index(ref: str) -> int:
    letters = "".join(ch for ch in ref if ch.isalpha())
    idx = 0
    for ch in letters:
        idx = idx * 26 + (ord(ch.upper()) - 64)
    return idx - 1 if idx else 0


def _shared_strings(z: zipfile.ZipFile):
    out = []
    if "xl/sharedStrings.xml" in z.namelist():
        root = ET.fromstring(z.read("xl/sharedStrings.xml"))
        for si in root:
            if _local(si.tag) != "si":
                continue
            out.append("".join(t.text or "" for t in si.iter()
                                if _local(t.tag) == "t"))
    return out


def _rows(z: zipfile.ZipFile, sheet_idx: int):
    sheets = sorted(n for n in z.namelist()
                    if re.match(r"xl/worksheets/sheet\d+\.xml$", n))
    if not sheets:
        return []
    name = sheets[min(max(sheet_idx - 1, 0), len(sheets) - 1)]
    shared = _shared_strings(z)
    root = ET.fromstring(z.read(name))
    rows = []
    for el in root.iter():
        if _local(el.tag) != "row":
            continue
        cells = {}
        for c in el:
            if _local(c.tag) != "c":
                continue
            ref = c.get("r", "")
            ctype = c.get("t", "")
            ci = _col_index(ref) if ref else len(cells)
            if ctype == "s":
                vtext = "".join(v.text or "" for v in c if _local(v.tag) == "v")
                try:
                    cells[ci] = shared[int(vtext)]
                except (ValueError, IndexError):
                    cells[ci] = ""
            elif ctype == "inlineStr":
                cells[ci] = "".join(x.text or "" for x in c.iter()
                                    if _local(x.tag) == "t")
            else:
                cells[ci] = "".join(v.text or "" for v in c
                                    if _local(v.tag) == "v")
        rows.append(cells)
    return rows


def _ident(s: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_]", "_", (s or "").strip())
    if not s:
        return ""
    if not (s[0].isalpha() or s[0] == "_"):
        s = "_" + s
    return s


def main() -> int:
    _utf8()
    p = json.load(sys.stdin)
    fp = p.get("xlsx_path")
    if not fp or not os.path.exists(fp):
        print(f"xlsx_path not found: {fp}", file=sys.stderr)
        return 2
    unit = p.get("unit_name") or "App.Localization"
    kc = int(p.get("key_col", 0))
    vc = int(p.get("value_col", 1))
    header = p.get("header", True)
    sheet_idx = int(p.get("sheet", 1))

    with zipfile.ZipFile(fp) as z:
        rows = _rows(z, sheet_idx)
    if header and rows:
        rows = rows[1:]

    lines, seen = [], set()
    for r in rows:
        key = _ident(r.get(kc, ""))
        if not key or key in seen:
            continue
        seen.add(key)
        val = (r.get(vc, "") or "").replace("'", "''")
        lines.append(f"  {key} = '{val}';")

    src = (f"unit {unit};\n\ninterface\n\nresourcestring\n" +
           "\n".join(lines) + "\n\nimplementation\n\nend.\n")
    json.dump({"inject": "new_unit", "unit_name": unit, "source": src,
               "entry_count": len(lines)}, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
