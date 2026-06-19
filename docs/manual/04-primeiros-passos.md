# 4. Primeiros passos

Em poucos minutos você terá sua primeira conversa com o agente agindo no projeto.

## 1. Abra um projeto Delphi

O Aefos trabalha sobre o **projeto aberto** na IDE. Abra (ou crie) um projeto antes
de começar — assim o agente tem o que ler e alterar.

## 2. Abra o painel de Chat

Vá em **View → Aefos AI (Chat) → Open Chat**. O painel pode ser **flutuante** ou
**docado** na IDE, como qualquer painel do Delphi.

## 3. Escolha o provedor de IA

Vá em **Tools → Options → Aefos** e selecione o **provedor/executor** que você quer
usar (Claude Code, Codex, Copilot ou Gemini) e o **modelo**, se aplicável.

- O modelo escolhido é **lembrado por provedor** — trocar de CLI não "vaza" o modelo
  de um para o outro.
- Você precisa ter aquele CLI **instalado e logado**. Veja
  [Provedores de IA](08-provedores-de-ia.md).

> **Dica:** ainda em **Options → Aefos**, use a ação **Test MCP** para confirmar que
> o CLI enxerga o servidor `aefos`. Veja [Configuração](09-configuracao.md).

## 4. Sua primeira conversa

1. No painel de Chat, digite um pedido simples, por exemplo:
   *"Liste as units do projeto e me explique a unit principal."*
2. Pressione **Enter**.
3. O agente vai usar o MCP do Aefos para ler o projeto e responder.

O **modo Agent é o padrão** — ou seja, o agente já vem pronto para *agir* no projeto,
não só conversar. Para entender a diferença entre os modos, veja
[Usando o Chat](05-usando-o-chat.md).

## 5. Veja o agente agir

Peça algo que altere o código, por exemplo:
*"Adicione um método de exemplo na unit principal."*

Quando o agente edita um arquivo, o Aefos mostra um **diff inline** (vermelho/verde)
no editor, com botões **✓ aceitar** / **✗ rejeitar** (ou **Tab** / **Esc**). Nada é
aplicado sem o seu aval. Detalhes em [Usando o Chat](05-usando-o-chat.md).

## Próximos passos

- Entenda os modos e o diff: [Usando o Chat](05-usando-o-chat.md)
- Veja tudo que o agente pode fazer: [O que o agente faz no seu projeto](06-o-que-o-agente-faz.md)
- Experimente o Terminal: [Usando o Terminal](07-usando-o-terminal.md)
