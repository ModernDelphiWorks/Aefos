<div align="center">

# Aefos AI

**Sua CLI de IA favorita — rodando *dentro* do RAD Studio.**

***AEFOS** — **A**gent **E**xecution **F**low **O**rchestration **S**ystem.*

**Chat** + **Terminal** de IA na IDE do RAD Studio Delphi 13, movidos pela CLI de IA
que você já usa (Claude Code, Codex, GitHub Copilot CLI, Gemini).

[![Versão](https://img.shields.io/badge/vers%C3%A3o-0.17.0--beta-orange)](CHANGELOG.md)
[![Plataforma](https://img.shields.io/badge/plataforma-Windows-0078D6)](#requisitos)
[![Licença](https://img.shields.io/badge/licen%C3%A7a-GPL%20v3-blue)](LICENSE)
[![CRA-ready](https://img.shields.io/badge/CRA--ready-SBOM%20%2B%20Pol%C3%ADtica%20de%20Seguran%C3%A7a-success)](https://www.pubpascal.dev/packages/aefos)

[⬇️ Download](../../releases) · [📖 Manual do Usuário](https://moderndelphiworks.github.io/Aefos/) · [🐛 Reportar bug](../../issues/new/choose) · [🔒 Segurança](SECURITY.md)

[English](README.md) · **Português (PT-BR)**

</div>

> **Esta é a casa pública do Aefos AI** — o código-fonte, downloads, manual
> do usuário e abertura de issues. O Aefos AI é **software livre sob a GNU GPL
> v3** (desde 5 de agosto de 2026).

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

## Telas

| 💬 Chat (modo Agent) | 🖥️ Terminal |
|:---:|:---:|
| ![Aefos Chat](assets/chat.png) | ![Aefos Terminal](assets/terminal.png) |

## Documentação

📖 **[Manual do Usuário](https://moderndelphiworks.github.io/Aefos/)** (PT-BR / EN) — instalação, primeiros passos,
Chat, Terminal, provedores, configuração, licenciamento e solução de problemas.

## Download e instalação

1. Pegue o instalador mais recente em **[Releases](../../releases)**
   (`Aefos-Setup-<versão>.exe`).
2. Feche a RAD Studio, rode o instalador (por-usuário, sem admin).
3. Reinicie a RAD Studio — aparecem os menus **View → Aefos AI (Chat)** e
   **View → Aefos AI (Terminal)**.

Passos completos no [manual](https://moderndelphiworks.github.io/Aefos/).

## Requisitos

| Item | Requisito |
|------|-----------|
| IDE | RAD Studio **Delphi 13** (BDS 37.0) |
| SO | **Windows** |
| CLI de IA | Pelo menos uma: Claude Code / Codex / GitHub Copilot CLI / Gemini (traga a sua) |
| Markdown rico (opcional) | [Runtime do WebView2](https://aka.ms/webview2) |

## Licença e ativação

**O software é software livre sob a [GNU GPL v3](LICENSE)**, com duas permissões
adicionais concedidas pela seção 7 da GPLv3 (veja
[`ADDITIONAL-PERMISSIONS.md`](ADDITIONAL-PERMISSIONS.md)): o código que o Aefos escreve
para você é **seu**, sob qualquer licença que você escolher, e a linkagem com as
bibliotecas do RAD Studio — sem as quais um pacote design-time não pode existir —
é expressamente permitida. A licença que governava o software antes de 5 de agosto
de 2026 fica registrada em [`EULA-historical.md`](EULA-historical.md).

Uma **chave de licença** compra o serviço hospedado em volta do software, não o
software em si.

**A edição Community é grátis — nenhuma chave necessária.** Instale e use o Chat
(incluindo o **modo Agent**) na hora. A Community é grátis para uso **pessoal,
educacional e empresarial interno** — sem taxa por assento, sem limite de usuários,
sem pegadinha.

**Pro / Enterprise** liberam o Terminal, configuração automática de MCP, assistentes,
histórico de sessões e contexto avançado. Para ativar uma chave:

1. Abra **View → Aefos AI (Chat)** e clique no **item de licença** no topo — ele mostra
   seu status atual (ex.: *License: Trial* ou *License: active*).
2. Cole sua **chave de licença**.
3. Pronto — isso vincula **esta cópia do Delphi** ao seu assento. O status passa a
   *active*.

**Como a licença funciona:**
- **Uma chave = um Delphi ativo** por máquina/usuário (assento único, node-locked).
- **Funciona offline:** após a primeira validação online, continua funcionando
  **sem internet** dentro de uma janela de tolerância.
- **Sem chave?** Um **período de avaliação** embutido deixa você testar os recursos Pro.

## Atualizar, reinstalar e mudar de máquina

Esta é a parte que mais gera dúvida — leia antes de desinstalar.

| Situação | O que fazer | O que acontece com sua licença |
|-----------|-------------|--------------------------------|
| **Atualizar para uma versão nova** (mesma máquina) | Feche o RAD Studio e rode o novo `Aefos-Setup-*.exe` **por cima** do antigo | ✅ **Preservada** — você **não** redigita a chave nem desativa |
| **Reinstalar** (mesma máquina) | Igual acima — é só rodar o instalador de novo | ✅ **Preservada** (a ativação está ligada a esta máquina) |
| **Mudar de máquina** | **Desative primeiro** na antiga: **View → Aefos AI (Chat) → item de licença → Deactivate**. Depois instale na nova e ative a chave lá. | 🔄 O assento é **liberado e reutilizado** na nova máquina (transferência por você mesmo) |
| **Desinstalar de vez** | Use **Configurações → Aplicativos** do Windows (ou o desinstalador). Se pretende usar a chave em outro lugar, **desative antes** (acima) | ⚠️ Desinstalar sozinho **não** libera o assento — **desative** para liberá-lo |

> ⚠️ **Ponto-chave:** desinstalar e reinstalar na **mesma** máquina mantém sua
> licença. Só **mudar de máquina** exige **Deactivate** antes, para o assento único
> ficar livre para ativar em outro lugar. (A Community não precisa de nada disso.)

Passo a passo completo no [Manual do Usuário](https://moderndelphiworks.github.io/Aefos/).

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

- 📄 [GNU GPL v3](LICENSE) — software livre, com duas permissões adicionais
  da §7 ([ADDITIONAL-PERMISSIONS.md](ADDITIONAL-PERMISSIONS.md)): o código que o
  Aefos gera é **seu**, sob qualquer licença, e a linkagem com as bibliotecas do
  RAD Studio é expressamente permitida. A licença anterior fica como registro
  em [EULA-historical.md](EULA-historical.md).
- 🔐 [Política de Privacidade](PRIVACY.pt-BR.md) ([EN](PRIVACY.md)) — alinhada à LGPD.

---

<div align="center">
Distribuído via <a href="https://www.pubpascal.dev">PubPascal</a> · © 2026 Aefos AI (TecSis Info)
</div>
