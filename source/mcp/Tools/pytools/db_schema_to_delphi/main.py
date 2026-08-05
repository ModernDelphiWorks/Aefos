"""DbSchemaToDelphiClasses — SQLite schema -> Delphi entity classes.

Live-resource tool: the agent cannot open a real database; Python (stdlib
sqlite3) can. JSON in on stdin, JSON out on stdout (inject=new_unit).
"""
import sys
import os
import json
import sqlite3


def _utf8():
    try:
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def delphi_type(sqltype: str) -> str:
    t = (sqltype or "").upper()
    if "INT" in t:
        return "Integer"
    if any(k in t for k in ("CHAR", "CLOB", "TEXT")):
        return "string"
    if any(k in t for k in ("REAL", "FLOA", "DOUB")):
        return "Double"
    if "BLOB" in t or t == "":
        return "TBytes"
    if any(k in t for k in ("NUMERIC", "DECIMAL", "NUMBER")):
        return "Double"
    if "DATE" in t or "TIME" in t:
        return "TDateTime"
    if "BOOL" in t:
        return "Boolean"
    return "string"


def pascal(name: str) -> str:
    parts = name.replace("-", "_").split("_")
    return "".join(p[:1].upper() + p[1:] for p in parts if p) or "_"


def main() -> int:
    _utf8()
    p = json.load(sys.stdin)
    path = p.get("sqlite_path")
    if not path or not os.path.exists(path):
        print(f"sqlite_path not found: {path}", file=sys.stderr)
        return 2
    unit = p.get("unit_name") or "Domain.Entities"
    want = p.get("tables") or []

    con = sqlite3.connect(path)
    try:
        cur = con.cursor()
        cur.execute("select name from sqlite_master where type='table' "
                    "and name not like 'sqlite_%' order by name")
        tables = [r[0] for r in cur.fetchall()]
        if want:
            tables = [t for t in tables if t in want]
        classes = []
        for t in tables:
            cols = cur.execute(f'PRAGMA table_info("{t}")').fetchall()
            priv, pub = [], []
            for c in cols:
                pn = pascal(c[1])
                dt = delphi_type(c[2])
                priv.append(f"    F{pn}: {dt};")
                pub.append(f"    property {pn}: {dt} read F{pn} write F{pn};")
            classes.append(
                f"  T{pascal(t)} = class\n  private\n" + "\n".join(priv) +
                "\n  published\n" + "\n".join(pub) + "\n  end;")
    finally:
        con.close()

    src = (f"unit {unit};\n\ninterface\n\nuses\n  System.SysUtils;\n\ntype\n" +
           "\n\n".join(classes) + "\n\nimplementation\n\nend.\n")
    json.dump({"inject": "new_unit", "unit_name": unit, "source": src,
               "table_count": len(tables)}, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
