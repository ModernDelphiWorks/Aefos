<div align="center">

# Aefos AI

**Sua CLI de IA favorita — rodando *dentro* do RAD Studio.**

***AEFOS** — **A**gent **E**xecution **F**low **O**rchestration **S**ystem.*

**Chat** + **Terminal** de IA na IDE do RAD Studio Delphi 13, movidos pela CLI de IA
que você já usa (Claude Code, Codex, GitHub Copilot CLI, Gemini).

[![Versão](https://img.shields.io/badge/vers%C3%A3o-0.17.0--beta-orange)](CHANGELOG.md)
[![Plataforma](https://img.shields.io/badge/plataforma-Windows-0078D6)](#requisitos)
[![Licença](https://img.shields.io/badge/licen%C3%A7a-EULA%20%E2%80%94%20Community%20gr%C3%A1tis-blue)](LICENSE)
[![CRA-ready](https://img.shields.io/badge/CRA--ready-SBOM%20%2B%20Pol%C3%ADtica%20de%20Seguran%C3%A7a-success)](sbom/)

[⬇️ Download](../../releases) · [📖 Manual do Usuário](<PAGES_URL>) · [🐛 Reportar bug](../../issues/new/choose) · [🔒 Segurança](SECURITY.md)

[English](README.md) · **Português (PT-BR)**

</div>

> **Esta é a casa pública do Aefos AI** — downloads, manual do usuário e abertura de
> issues. O código-fonte do produto é privado; este repositório hospeda o que os
> usuários precisam.

## O que é

O Aefos AI traz as ferramentas de IA de linha de comando que você já usa para
**dentro** do RAD Studio Delphi 13, com conhecimento profundo do seu projeto. O agente
não só conversa — ele **age** no projeto aberto: edita código, compila e roda (com
depurador), opera o Form Designer e mais.

> **Traga sua CLI.** O Aefos **não inclui modelo de IA nem gerencia credenciais** — é
> um harness fino, ciente de Delphi, sobre a CLI que você já roda.

## Recursos

- 💬 **Chat na IDE** com **modo Agent** que age no projeto (ler/editar código,
  build/run, git, Form Designer ao vivo).
- 🖥️ **Terminal docado** (VTerm de verdade) com paleta de comandos, perfis e histórico.
- 🔀 **Multi-provedor** — Claude Code, Codex, GitHub Copilot CLI, Gemini.
- ✅ **Diff inline** de cada alteração da IA, com aceitar/rejeitar (Tab/Esc) — nada é
  aplicado sem o seu aval.
- 🎨 Fluxo **Design ↔ Code** — adicione um componente e veja a IDE virar Design; adicione
  código e veja virar Code.

## Documentação

📖 **[Manual do Usuário](<PAGES_URL>)** (PT-BR / EN) — instalação, primeiros passos,
Chat, Terminal, provedores, configuração, licenciamento e solução de problemas.

## Download e instalação

1. Pegue o instalador mais recente em **[Releases](../../releases)**
   (`Aefos-Setup-<versão>.exe`).
2. Feche a RAD Studio, rode o instalador (por-usuário, sem admin).
3. Reinicie a RAD Studio — aparecem os menus **View → Aefos AI (Chat)** e
   **View → Aefos AI (Terminal)**.

Passos completos no [manual](<PAGES_URL>).

## Requisitos

| Item | Requisito |
|------|-----------|
| IDE | RAD Studio **Delphi 13** (BDS 37.0) |
| SO | **Windows** |
| CLI de IA | Pelo menos uma: Claude Code / Codex / GitHub Copilot CLI / Gemini (traga a sua) |
| Markdown rico (opcional) | [Runtime do WebView2](https://aka.ms/webview2) |

## Edições

| Edição | Preço | Para quem |
|--------|-------|-----------|
| **Community** | **Grátis** | Pessoal, educacional **e empresarial interno** — sem cobrança por assento, sem penalidade |
| **Pro** | Assinatura | Terminal, auto-setup de MCP, assistentes, histórico, contexto avançado |
| **Enterprise** | Contrato | Uso corporativo amplo, suporte, governança |

## Reportar bugs e pedidos

- 🐛 **[Abrir uma issue](../../issues/new/choose)** — leia antes os
  [Termos de Submissão](TERMS-ISSUES.md) (curto e importante).
- 🔒 **Vulnerabilidade de segurança?** **Não** abra issue pública — siga o
  [SECURITY.md](SECURITY.md).
- ❓ Dúvidas / ajuda: veja o [SUPPORT.md](SUPPORT.md).

## Transparência de supply-chain (CRA-ready)

- 📦 **SBOM** — inventário legível por máquina (CycloneDX 1.5) em [`sbom/`](sbom/).
- 🔒 **Política de divulgação de vulnerabilidades** — [SECURITY.md](SECURITY.md).
- 📝 **Manutenção ativa** — veja o [CHANGELOG](CHANGELOG.md).
- 📜 **Licenças de terceiros** — [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).

## Privacidade e licença

- 📄 [EULA](LICENSE) — proprietária; edição Community grátis (incl. uso empresarial interno).
- 🔐 [Política de Privacidade](PRIVACY.pt-BR.md) ([EN](PRIVACY.md)) — alinhada à LGPD.

---

<div align="center">
Distribuído via <a href="https://www.pubpascal.dev">PubPascal</a> · © 2026 Aefos AI (TecSis Info)
</div>
