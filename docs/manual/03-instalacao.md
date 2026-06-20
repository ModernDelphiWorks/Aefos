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
   - Durante a instalação, o Aefos **detecta** o CLI de IA, o Python e o WebView2.
     O **WebView2 Runtime** (componente oficial da Microsoft, exigido pelo Chat) é
     **instalado automaticamente** se estiver faltando, a partir do bootstrapper
     oficial da Microsoft. Para o **CLI de IA** e o **Python**, o Aefos apenas te
     orienta para a fonte oficial — **nunca** instala binários de terceiros por você.
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

## Markdown rico (WebView2)

O Chat renderiza via **WebView2**, que o instalador provisiona automaticamente. Se o
Chat aparecer **em branco/preto** ou mostrando **texto simples**, normalmente é o
WebView2 ausente — reexecute o instalador (ele instala o runtime) ou instale-o
manualmente: <https://aka.ms/webview2>. Depois reinicie a IDE.

## Onde as coisas ficam

| Item | Caminho |
|------|---------|
| Configuração global de MCP | `%APPDATA%\Aefos\aefos-mcp.json` |
| Bridge de MCP (Terminal) | `%APPDATA%\Aefos\mcp-bridge.ps1` |
| PyTools (ferramentas Python) | `%APPDATA%\Aefos\pytools` |

## Atualizando para uma nova versão

Na **mesma máquina**, sua licença é preservada — você **não precisa desativar nada**.

**Caminho recomendado (mesma máquina):**

1. **Feche a RAD Studio.**
2. **Execute** o novo `Aefos-Setup-<versão>.exe` — pode instalar **por cima** da
   versão atual (não precisa desinstalar).
3. **Reabra a IDE.** Sua licença (inclusive a **Free**) continua ativa, e o Chat passa
   a usar o WebView2 que o instalador provisiona.

**Reinstalação limpa — ou troca de máquina:**

1. Abra a IDE → **Aefos → License…** → **copie sua chave** e clique
   **Deactivate (free seat)**.
2. **Feche a IDE** e **desinstale** a versão atual.
3. **Instale** a versão nova.
4. Reabra a IDE → **Aefos → License…** → **cole a chave** → **Activate**.

> O **Deactivate** só é obrigatório para mover o seat para **outra máquina**. A
> licença fica em `%APPDATA%\Aefos\license.dat` e **não** é apagada na desinstalação —
> por isso, na mesma máquina, a atualização não exige desativar nem redigitar a chave.

## Desinstalação

A desinstalação remove os BPLs, o bridge, o `.mcp.json` gerado, os registros de
pacote na IDE e a entrada de PATH. As suas PyTools próprias (que você soltou na pasta)
são preservadas.

➡️ Próximo: [Primeiros passos](04-primeiros-passos.md)
