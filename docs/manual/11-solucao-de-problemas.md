# 11. Solução de problemas

Sintomas comuns e como resolver. Se nada aqui ajudar, veja
[Privacidade e licença](12-privacidade-e-licenca.md) para o canal de contato.

## Instalação e carga dos pacotes

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| **View → Aefos AI (Chat)/(Terminal)** não aparece | IDE não reiniciada após instalar; pacote não registrado | Reinicie a RAD Studio; confira em **Components → Install Packages** |
| Um pacote do plugin falha ao carregar (`requires`) | Os BPLs de runtime não estão no caminho de busca | Confirme que os BPLs estão acessíveis (PATH / Library path) e reinicie a IDE |
| Conflito de pipe ao carregar Chat + Terminal | Os dois hosts precisam de nomes de pipe distintos | Reinicie a IDE |

## Chat

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| Chat mostra **texto simples**, sem Markdown | WebView2 Runtime ausente | Instale o WebView2: <https://aka.ms/webview2> e reinicie a IDE |
| Enviar mensagem **"não faz nada"** | Nenhum CLI de IA configurado/instalado | Configure o provedor em **Options → Aefos** e instale/logue o CLI ([Provedores](08-provedores-de-ia.md)) |
| O agente não usa as ferramentas do projeto (MCP) | MCP não conectado para aquele CLI | Rode **Test MCP** em **Options → Aefos**; confira o provedor selecionado |
| O painel docado pisca/preto por um instante ao enviar | Comportamento de composição da janela docada | Em geral se recupera sozinho; se persistir, use o painel **flutuante** |

## Provedores de IA

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| Codex conecta o MCP mas não responde | Falta `codex login` | Rode `codex login` para habilitar o modelo |
| "aefos listed but not connected" (Test MCP) | Diferença de wording entre CLIs | Para CLIs que não sejam o Claude, "aefos" presente já significa configurado |
| Copilot não acha o MCP no modo agente | `-p` não auto-carrega o `.mcp.json` do workspace | O Aefos já injeta a config global; confirme o provedor e rode **Test MCP** |

## Terminal

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| Glifos do prompt viram "quadradinhos" (tofu) | Fonte sem glifos Nerd/powerline | Selecione uma fonte compatível (ex.: uma *Nerd Font*) nas opções do Terminal |
| **Ctrl+P** e **Ctrl+R** parecem conflitar | São coisas diferentes | **Ctrl+P** = paleta do Aefos; **Ctrl+R** = busca reversa nativa do shell |
| Terminal indisponível | Recurso da edição **Pro** | Veja [Licenciamento](10-licenciamento.md) |

## Licença

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| Recurso Pro bloqueado | Sem licença Pro ativa (ou trial expirado) | Em **View → Aefos AI (Chat)**, abra o item de licença (ex.: *License: active*) e ative a chave |
| Ativação falha | Sem rede no momento da ativação | A validação precisa de rede; depois funciona offline na janela de tolerância |

➡️ Próximo: [Privacidade e licença](12-privacidade-e-licenca.md)
