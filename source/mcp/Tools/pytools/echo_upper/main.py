"""EchoUpper — example Aefos Python tool.

Contract: JSON in on stdin, JSON out on stdout, logs on stderr, exit 0 = ok.
Run standalone:  echo {"text":"hi"} | python main.py
"""
import sys
import json

# Windows console defaults are not UTF-8; force it so accents survive.
try:
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception as exc:
        print(f"invalid JSON on stdin: {exc}", file=sys.stderr)
        return 2

    text = payload.get("text")
    if not isinstance(text, str):
        print("missing required string field 'text'", file=sys.stderr)
        return 3

    json.dump({"result": text.upper()}, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
