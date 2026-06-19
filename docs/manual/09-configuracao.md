# 9. Configuração

A maior parte da configuração fica em **Tools → Options → Aefos**. Esta página resume
as opções e os arquivos envolvidos.

## Tools → Options → Aefos

| Opção | O que faz |
|-------|-----------|
| **Provedor / executor** | Escolhe o CLI de IA (Claude / Codex / Copilot / Gemini) |
| **Modelo** | Escolhe o modelo do provedor (lembrado por provedor) |
| **Sessão do Terminal** | Nome da sessão de MCP usada pelo Terminal (padrão: `plugin`) |
| **Test MCP** | Verifica se o CLI selecionado enxerga o servidor `aefos` |

### Test MCP

A ação **Test MCP** é **ciente do executor**: para o Claude, ela espera a palavra
"connected"; para os demais, considera "configurado" quando o servidor `aefos`
aparece na listagem do CLI. Use-a sempre que trocar de provedor ou suspeitar que o MCP
não está conectado.

## Configuração de MCP (avançado)

O Aefos se auto-provisiona; em geral você **não precisa** editar nada à mão. Para
referência:

| Arquivo | Para quê |
|---------|----------|
| `%APPDATA%\Aefos\aefos-mcp.json` | **Configuração global de MCP** — o servidor `aefos` embutido + os seus servidores extras. Todos os CLIs apontam para este arquivo |
| `%APPDATA%\Aefos\mcp-bridge.ps1` | **Bridge** (ponte stdio ↔ named pipe) para CLIs que conectam pelo pipe |
| `.mcp.json` (na raiz do projeto) | Config de MCP **por-projeto**, gerada pela instalação para o Terminal |

> **Importante:** o `.mcp.json` é **por-máquina** — **não faça commit** dele no seu
> repositório.

### Servidores MCP extras

Se você usa outros servidores MCP, pode adicioná-los pelo modal **"MCP Servers"** —
eles são mesclados na configuração global e passam a valer para todos os CLIs.

## WebView2 (Markdown rico no Chat)

Para o Chat exibir Markdown formatado (com destaque de sintaxe), instale o **WebView2
Runtime**: <https://aka.ms/webview2>. Sem ele, o Chat usa um modo de texto simples.

## PyTools (ferramentas Python)

As **PyTools** deixam você estender o agente com ferramentas escritas em Python:

1. Crie uma pasta para sua ferramenta dentro de `%APPDATA%\Aefos\pytools`.
2. Coloque um `tool.json` (descrição) e um `main.py` (a lógica).
3. A ferramenta passa a aparecer como uma **ferramenta MCP viva** para o agente.

> As PyTools precisam de um interpretador **Python** instalado para **rodar** (o Aefos
> não inclui Python). Veja [Requisitos](02-requisitos.md).

➡️ Próximo: [Licenciamento e edições](10-licenciamento.md)
