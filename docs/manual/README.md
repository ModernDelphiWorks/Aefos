# Manual do Usuário — Aefos AI

Bem-vindo ao **Aefos AI** — a sua CLI de IA favorita (Claude Code, Codex, GitHub
Copilot CLI, Gemini) rodando **dentro** do RAD Studio Delphi 13, com conhecimento
profundo do seu projeto.

Este manual é para o **usuário final** (dev Delphi): como instalar, configurar e usar
o Chat e o Terminal no dia a dia. Para detalhes de arquitetura/implementação, veja a
[repositório do projeto](https://github.com/ModernDelphiWorks/Aefos).

> **Versão coberta:** 0.17.0-beta · **Plataforma:** Windows · **IDE:** RAD Studio
> Delphi 13 (BDS 37.0).

---

## Índice

| # | Seção | O que você aprende |
|---|-------|--------------------|
| 1 | [Visão geral](01-visao-geral.md) | O que é o Aefos AI, pra quem é e como ele funciona |
| 2 | [Requisitos](02-requisitos.md) | O que você precisa ter antes de instalar |
| 3 | [Instalação](03-instalacao.md) | Instalar o plugin e verificar que está tudo certo |
| 4 | [Primeiros passos](04-primeiros-passos.md) | Abrir os menus do Aefos (View → Aefos AI), o Chat, escolher um provedor e a primeira conversa |
| 5 | [Usando o Chat](05-usando-o-chat.md) | Modo Agent vs Chat, skills `/agent`, contexto, diff inline (aceitar/rejeitar) |
| 6 | [O que o agente faz no seu projeto](06-o-que-o-agente-faz.md) | Ferramentas MCP, designer vivo, build/run, git e o fluxo Design↔Code |
| 7 | [Usando o Terminal](07-usando-o-terminal.md) | Terminal docado, paleta (Ctrl+P), perfis, histórico |
| 8 | [Provedores de IA](08-provedores-de-ia.md) | Instalar e logar em cada CLI (Claude/Codex/Copilot/Gemini) |
| 9 | [Configuração](09-configuracao.md) | Tools → Options, MCP, WebView2, PyTools |
| 10 | [Licenciamento e edições](10-licenciamento.md) | Community (grátis), Pro, Enterprise e como ativar |
| 11 | [Solução de problemas](11-solucao-de-problemas.md) | FAQ e troubleshooting |
| 12 | [Privacidade e licença](12-privacidade-e-licenca.md) | Links rápidos para EULA, Privacidade e avisos de terceiros |

---

## Por onde começar

- **Primeira vez?** Siga na ordem: [Requisitos](02-requisitos.md) →
  [Instalação](03-instalacao.md) → [Primeiros passos](04-primeiros-passos.md).
- **Já instalado?** Vá direto para [Usando o Chat](05-usando-o-chat.md).
- **Algo não funciona?** [Solução de problemas](11-solucao-de-problemas.md).

> **Aefos é "traga seu CLI".** O Aefos não inclui nenhum modelo de IA nem gerencia
> credenciais — ele é um *harness* que conecta o CLI que você já usa ao seu projeto
> Delphi. Você precisa ter pelo menos um CLI de IA instalado (veja
> [Provedores de IA](08-provedores-de-ia.md)).
