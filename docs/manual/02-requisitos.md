# 2. Requisitos

Antes de instalar, confira a lista abaixo. Os itens **obrigatórios** são o mínimo
para o Aefos funcionar; os **opcionais** habilitam recursos extras.

## Obrigatórios

| Item | Requisito | Observação |
|------|-----------|------------|
| **IDE** | RAD Studio **Delphi 13** (BDS 37.0) | Versão mínima e única suportada |
| **Sistema** | **Windows** | O plugin é Windows-only |
| **CLI de IA** | Pelo menos um: Claude Code, Codex, GitHub Copilot CLI ou Gemini | "Traga o seu" — nenhum CLI vem incluído. Veja [Provedores de IA](08-provedores-de-ia.md) |

> Sem um CLI de IA instalado e logado, o Chat abre normalmente, mas o envio de
> mensagens "não faz nada" — não há para onde despachar o prompt.

## Recomendados

| Item | Para quê | Onde obter |
|------|----------|------------|
| **WebView2 Runtime** | Renderização rica (Markdown + destaque de sintaxe) no Chat | <https://aka.ms/webview2> |

Sem o WebView2, o Chat continua funcionando, mas cai para um modo de **texto simples**
(sem Markdown formatado).

## Opcionais

| Item | Para quê | Onde obter |
|------|----------|------------|
| **Python** (`py` / `python`) | Rodar as **PyTools** (ferramentas MCP em Python que você solta numa pasta) | <https://python.org> ou `winget install Python.Python.3.12` |
| **PowerShell 7+** (`pwsh`) | Scripts auxiliares (build/instalador) | Já incluso no Windows 11 (versão antiga); 7+ opcional |

## O que **não** precisa instalar

- **SQLite** — já vai embutido (estático) no plugin; não há `sqlite3.dll` para
  instalar.
- **Runtimes do Delphi** (RTL/VCL/FireDAC) — já fazem parte da sua RAD Studio.

➡️ Próximo: [Instalação](03-instalacao.md)
