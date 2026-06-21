#!/usr/bin/env python3
# Builds a self-contained, offline static HTML site from the manual Markdown files.
# Usage: python build-html.py [pt|en]
#   pt (default) -> reads *.md here, writes _html/
#   en           -> reads en/*.md,  writes _html-en/
import sys, re, pathlib, html as _html, shutil
import markdown

LANG = (sys.argv[1] if len(sys.argv) > 1 else "pt").lower()
HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE if LANG == "pt" else HERE / "en"
OUT = HERE / ("_html" if LANG == "pt" else "_html-en")
OUT.mkdir(exist_ok=True)
# PT source sits in docs/manual/ but output goes to docs/manual/_html/ (one level
# deeper) -> external "../" links need +1 up. EN source already sits in docs/manual/en/
# and output in docs/manual/_html-en/ (same depth) -> no adjustment.
EXTRA_UP = 1 if LANG == "pt" else 0

# Ordered table of contents: (markdown filename, sidebar label)
TOC_PT = [
    ("README.md", "Início (Índice)"),
    ("01-visao-geral.md", "1. Visão geral"),
    ("02-requisitos.md", "2. Requisitos"),
    ("03-instalacao.md", "3. Instalação"),
    ("04-primeiros-passos.md", "4. Primeiros passos"),
    ("05-usando-o-chat.md", "5. Usando o Chat"),
    ("06-o-que-o-agente-faz.md", "6. O que o agente faz"),
    ("07-usando-o-terminal.md", "7. Usando o Terminal"),
    ("08-provedores-de-ia.md", "8. Provedores de IA"),
    ("09-configuracao.md", "9. Configuração"),
    ("10-licenciamento.md", "10. Licenciamento"),
    ("11-solucao-de-problemas.md", "11. Solução de problemas"),
    ("12-privacidade-e-licenca.md", "12. Privacidade e licença"),
]
TOC_EN = [
    ("README.md", "Home (Index)"),
    ("01-overview.md", "1. Overview"),
    ("02-requirements.md", "2. Requirements"),
    ("03-installation.md", "3. Installation"),
    ("04-getting-started.md", "4. Getting started"),
    ("05-using-the-chat.md", "5. Using the Chat"),
    ("06-what-the-agent-does.md", "6. What the agent does"),
    ("07-using-the-terminal.md", "7. Using the Terminal"),
    ("08-ai-providers.md", "8. AI providers"),
    ("09-configuration.md", "9. Configuration"),
    ("10-licensing.md", "10. Licensing"),
    ("11-troubleshooting.md", "11. Troubleshooting"),
    ("12-privacy-and-license.md", "12. Privacy & license"),
]
TOC = TOC_PT if LANG == "pt" else TOC_EN
NAMES = {fn for fn, _ in TOC}

LINK_RE = re.compile(r"\]\(([^)]+)\)")

def rewrite_target(t: str) -> str:
    if t.startswith(("http://", "https://", "#", "mailto:")):
        return t
    if t.startswith("../"):          # escapes the manual dir
        return "../" * EXTRA_UP + t
    if "/" not in t and t.endswith(".md"):  # intra-manual link
        return t[:-3] + ".html"
    return t

def rewrite_links(md: str) -> str:
    return LINK_RE.sub(lambda m: "](" + rewrite_target(m.group(1)) + ")", md)

STYLE = """
:root{--bg:#0d1117;--panel:#161b22;--fg:#c9d1d9;--muted:#8b949e;--acc:#58a6ff;--bd:#30363d;--code:#1e1e1e}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}
.wrap{display:flex;min-height:100vh}
nav{width:280px;flex:0 0 280px;background:var(--panel);border-right:1px solid var(--bd);padding:20px 0;position:sticky;top:0;height:100vh;overflow:auto}
nav .brand{font-weight:700;font-size:18px;color:#fff;padding:0 20px 14px;border-bottom:1px solid var(--bd);margin-bottom:8px}
nav a{display:block;color:var(--fg);text-decoration:none;padding:7px 20px;font-size:14px;border-left:3px solid transparent}
nav a:hover{background:#1f2630;color:#fff}
nav a.active{border-left-color:var(--acc);color:#fff;background:#1f2630;font-weight:600}
main{flex:1;min-width:0;max-width:900px;margin:0 auto;padding:36px 48px 80px}
main h1{font-size:30px;border-bottom:1px solid var(--bd);padding-bottom:.3em;margin-top:0}
main h2{font-size:22px;border-bottom:1px solid var(--bd);padding-bottom:.3em;margin-top:1.6em}
main h3{font-size:18px}
a{color:var(--acc)}
code{background:#1f2630;padding:.15em .4em;border-radius:5px;font:14px/1.5 Consolas,Menlo,monospace}
pre{background:var(--code);border:1px solid var(--bd);border-radius:8px;padding:14px 16px;overflow:auto}
pre code{background:none;padding:0}
table{border-collapse:collapse;width:100%;margin:1em 0;display:block;overflow:auto}
th,td{border:1px solid var(--bd);padding:8px 12px;text-align:left}
th{background:#1f2630}
tr:nth-child(even){background:#11161d}
blockquote{border-left:4px solid var(--acc);margin:1em 0;padding:.2em 1em;background:#11161d;color:var(--muted)}
hr{border:0;border-top:1px solid var(--bd);margin:2em 0}
img{max-width:100%}
.langbar{padding:0 20px 10px;font-size:12px;color:var(--muted)}
"""

def sidebar(active: str) -> str:
    links = []
    for fn, label in TOC:
        cls = ' class="active"' if fn == active else ""
        href = fn[:-3] + ".html"
        links.append(f'<a href="{href}"{cls}>{_html.escape(label)}</a>')
    otherlabel = "🌐 English" if LANG == "pt" else "🌐 Português"
    otherhref = ("../_html-en/README.html" if LANG == "pt" else "../_html/README.html")
    return (f'<nav><div class="brand">Aefos AI — {"Manual" if LANG=="pt" else "User Manual"}</div>'
            f'<div class="langbar"><a href="{otherhref}">{otherlabel}</a></div>'
            + "".join(links) + "</nav>")

md = markdown.Markdown(extensions=["tables", "fenced_code", "toc", "sane_lists", "attr_list"])

built = 0
for fn, label in TOC:
    src = SRC / fn
    if not src.exists():
        print(f"  SKIP (missing): {fn}")
        continue
    md.reset()
    body = md.convert(rewrite_links(src.read_text(encoding="utf-8")))
    page = (f'<!doctype html><html lang="{LANG}"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{_html.escape(label)} — Aefos AI</title><style>{STYLE}</style></head>'
            f'<body><div class="wrap">{sidebar(fn)}<main>{body}</main></div></body></html>')
    (OUT / (fn[:-3] + ".html")).write_text(page, encoding="utf-8")
    built += 1

# Ship the manual images alongside the HTML so screenshots resolve offline. The canonical
# assets live in docs/manual/assets/ (referenced as assets/ from PT pages, ../assets/ from EN).
ASSETS = HERE / "assets"
if ASSETS.is_dir():
    shutil.copytree(ASSETS, OUT / "assets", dirs_exist_ok=True)

print(f"[{LANG}] built {built} pages -> {OUT}")
