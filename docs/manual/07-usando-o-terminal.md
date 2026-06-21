# 7. Usando o Terminal

O **Terminal** do Aefos é um terminal de verdade docado dentro da IDE (emulação
VTerm), com o mesmo alcance OTA do Chat. Dá para rodar seu CLI de IA, comandos de
shell, git — tudo sem trocar de janela.

![Terminal do Aefos docado na IDE, com emulação VTerm](assets/terminal.png)

> O Terminal faz parte da edição **Pro**. Veja [Licenciamento e edições](10-licenciamento.md).

## Abrindo o Terminal

Vá em **View → Aefos AI (Terminal)**. O terminal aparece como um painel docável da
IDE.

## Paleta de comandos (Ctrl+P)

Pressione **Ctrl+P** para abrir a **paleta de comandos** do Aefos — a sua central de
produtividade no terminal:

- Histórico por tipo
- Perfis
- Ações
- Snippets

> **Ctrl+P** é a paleta **do Aefos**. **Ctrl+R** é a busca reversa **nativa do
> shell** (não é do Aefos) — as duas convivem.

## Perfis de shell

O Terminal suporta **perfis** (por exemplo PowerShell, cmd, etc.), com temas e
fontes configuráveis. Escolha o shell que você prefere para o seu fluxo.

## Histórico e snippets

- **Histórico** de comandos, navegável.
- **Snippets** reutilizáveis (com variáveis).
- **Reverse-search** do shell para reencontrar comandos.

## Fontes e glifos (Nerd Font)

O Terminal vem preparado para fontes com glifos (powerline/Nerd Font). Se você vir
"quadradinhos" (tofu) no lugar de ícones do prompt, é questão de **fonte** — ajuste a
fonte do terminal nas opções para uma família compatível (ex.: uma *Nerd Font*).

## Relação com o Chat

Tanto o Chat quanto o Terminal usam o mesmo motor MCP por baixo. Um agente lançado
**pelo terminal** também consegue agir no projeto, com as mesmas garantias de
consentimento e auditoria.

Inclusive a **revisão de alterações no editor** (o diff antes/depois com aceitar /
rejeitar / anotar na calha) é a mesma para os dois — quando o agente do terminal edita
código, você revê exatamente como no Chat. Veja
[Revisão de alterações](05-usando-o-chat.md#revisão-de-alterações-veja-o-antes-e-o-depois).

➡️ Próximo: [Provedores de IA](08-provedores-de-ia.md)
