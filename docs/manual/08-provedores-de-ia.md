# 8. Provedores de IA

O Aefos é **"traga o seu CLI"**: ele não inclui nenhum modelo nem gerencia
credenciais. Você instala e faz login no CLI de IA da sua preferência, e o Aefos o
conecta ao seu projeto. São suportados quatro provedores.

## Visão geral

| Provedor | CLI | O que você precisa |
|----------|-----|--------------------|
| **Claude Code** | Anthropic | Instalar o CLI e logar na sua conta Anthropic |
| **Codex** | OpenAI | Instalar o CLI e rodar `codex login` para usar o modelo |
| **GitHub Copilot CLI** | GitHub | Instalar o CLI e logar no GitHub Copilot |
| **Gemini** | Google | Instalar/ter o CLI do Gemini disponível e logar |

> O **Claude Code** é o provedor de referência (alvo do MVP). Os demais são totalmente
> suportados.

## Como escolher o provedor

Em **Tools → Options → Aefos**, selecione o **provedor/executor** e o **modelo**. O
modelo é lembrado **por provedor** (sem vazar de um para o outro).

## Conectando o MCP a cada CLI

O Aefos aponta **todos** os CLIs para uma **única** configuração de MCP global
(`%APPDATA%\Aefos\aefos-mcp.json`). Cada CLI é integrado de um jeito:

- **Claude Code** — recebe a config global de forma estrita (ignora qualquer
  `.mcp.json` do projeto).
- **Codex** — a configuração do servidor `aefos` é injetada por invocação (não mexe em
  arquivos de config). Lembre que o Codex precisa de `codex login` para **rodar o
  modelo** (o MCP conecta de qualquer forma).
- **GitHub Copilot CLI** — a config global é injetada e as ferramentas são liberadas
  para o modo não-interativo.
- **Gemini** — o servidor `aefos` é mesclado nas configurações do Gemini
  (`~/.gemini/settings.json`) e habilitado por nome.

> Você não precisa fazer esse wiring na mão — o Aefos cuida disso. Para **verificar**
> se está tudo certo, use **Test MCP** em **Options → Aefos** (veja
> [Configuração](09-configuracao.md)).

## E se o CLI não estiver instalado?

- O **instalador** detecta o `claude` na sua máquina e, se faltar, aponta a fonte
  oficial.
- No uso, se você escolher um provedor cujo CLI não está instalado/logado, o despacho
  não terá para onde ir — instale/logue o CLI e tente de novo.

➡️ Próximo: [Configuração](09-configuracao.md)
