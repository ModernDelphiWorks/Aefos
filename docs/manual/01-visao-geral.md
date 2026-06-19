# 1. Visão geral

## O que é o Aefos AI

O **Aefos AI** é uma suíte de plugins para o **RAD Studio Delphi 13** que traz as
ferramentas de IA de linha de comando que você já usa — **Claude Code, Codex, GitHub
Copilot CLI e Gemini** — para *dentro* da IDE, com conhecimento profundo do seu
projeto via Open Tools API (OTA).

> **O nome.** *AEFOS* significa **A**gent **E**xecution **F**low **O**rchestration
> **S**ystem — "Sistema de Orquestração do Fluxo de Execução do Agente", que é
> exatamente o que ele faz.

Ele tem duas superfícies principais:

- **Chat** — um painel de chat/agente de IA dentro da IDE. Você conversa, pede
  alterações e o agente **age** no seu projeto (edita código, compila, roda, mexe no
  Form Designer).
- **Terminal** — um terminal de verdade docado na IDE, com paleta de comandos,
  perfis e histórico.

## Para quem é

Para o **desenvolvedor Delphi** que quer usar IA sem sair da IDE e sem que a IA seja
"cega" ao projeto. Em vez de copiar e colar código entre o navegador e o Delphi, o
agente enxerga e altera o projeto aberto diretamente.

## Como funciona (em uma frase)

> O Aefos **inicia o CLI de IA que você escolheu** e, ao mesmo tempo, **expõe seu
> projeto Delphi para esse CLI** através de um servidor MCP interno — assim o agente
> não só conversa, ele **executa** ações no seu projeto.

O diferencial é o conhecimento de Delphi: quando o agente adiciona um componente, a
IDE vira para o **Design** (Form Designer); quando adiciona código, vira para o
**Code** (editor). Veja [O que o agente faz no seu projeto](06-o-que-o-agente-faz.md).

## O que o Aefos **não** é

- **Não é um modelo de IA.** Você traz sua própria assinatura/conta de CLI (Claude,
  OpenAI, Copilot, Gemini).
- **Não guarda suas credenciais.** O CLI usa o login que já está na sua máquina.
- **Não envia seu código para a Aefos.** Seus prompts e seu código vão direto para o
  provedor do CLI que você escolheu (veja [Privacidade](12-privacidade-e-licenca.md)).

## Edições

| Edição | Preço | Para quem |
|--------|-------|-----------|
| **Community** | Grátis | Uso pessoal, educacional **e empresarial interno** (sem penalidade) |
| **Pro** | Assinatura | Recursos de produtividade extra (Terminal, auto-setup de MCP, assistentes) |
| **Enterprise** | Contrato | Uso corporativo amplo, suporte e governança |

Detalhes em [Licenciamento e edições](10-licenciamento.md).

➡️ Próximo: [Requisitos](02-requisitos.md)
