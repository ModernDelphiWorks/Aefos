# 3. Instalação

A forma recomendada para o usuário final é o **instalador** (`Aefos-Setup-<versão>.exe`).
Ele copia os pacotes (BPLs), registra o Chat e o Terminal na IDE e prepara a
configuração de MCP — sem você precisar mexer em pastas manualmente.

> Se você for compilar a partir do código-fonte (desenvolvedor do plugin), veja a
> o repositório do projeto. Esta página cobre o
> caminho do **usuário final**.

## Passo a passo

1. **Feche a RAD Studio.** O instalador registra pacotes na IDE; ela não pode estar
   aberta.
2. **Execute** `Aefos-Setup-<versão>.exe`. É **por-usuário** (não precisa de
   administrador).
   - Durante a instalação, o Aefos **detecta** se você já tem o CLI de IA, o Python e
     o WebView2. Se faltar algo, ele te orienta para a fonte oficial — **nunca**
     instala binários de terceiros por você.
3. **Reinicie a RAD Studio.** Os pacotes `Aefos AI - Chat` e `Aefos AI - Terminal`
   já vêm registrados.
4. **Confirme:** no menu **View** da IDE aparecem os submenus **Aefos AI (Chat)** e
   **Aefos AI (Terminal)**.

## Verificação pós-instalação

Depois de reabrir a IDE, confira:

- [ ] No menu **View** aparecem **Aefos AI (Chat)** e **Aefos AI (Terminal)**.
- [ ] Em **Tools → Options** existe o nó **Aefos** (com as páginas de configuração).
- [ ] **View → Aefos AI (Chat) → Open Chat** abre o painel de chat.
- [ ] (Se você instalou) **View → Aefos AI (Terminal)** abre o terminal.

## Habilitando o Markdown rico (WebView2)

Se o Chat estiver mostrando **texto simples** em vez de Markdown formatado, instale o
**WebView2 Runtime**: <https://aka.ms/webview2>. Depois reinicie a IDE.

## Onde as coisas ficam

| Item | Caminho |
|------|---------|
| Configuração global de MCP | `%APPDATA%\Aefos\aefos-mcp.json` |
| Bridge de MCP (Terminal) | `%APPDATA%\Aefos\mcp-bridge.ps1` |
| PyTools (ferramentas Python) | `%APPDATA%\Aefos\pytools` |

## Desinstalação

A desinstalação remove os BPLs, o bridge, o `.mcp.json` gerado, os registros de
pacote na IDE e a entrada de PATH. As suas PyTools próprias (que você soltou na pasta)
são preservadas.

➡️ Próximo: [Primeiros passos](04-primeiros-passos.md)
