# 6. O que o agente faz no seu projeto

No modo Agent, a IA age no projeto aberto através do **servidor MCP** interno do
Aefos, que expõe as capacidades da IDE como **ferramentas**. Você não precisa decorar
nada disso — o agente usa as ferramentas sozinho — mas é bom saber o que ele consegue
fazer.

## O que ele consegue fazer

| Área | Exemplos do que o agente faz |
|------|------------------------------|
| **Código** | Ler, inserir, substituir e editar trechos de units |
| **Build & Run** | Compilar, rodar **com o depurador**, parar a execução, ver erros de compilação |
| **Git** | Status, log, branch atual |
| **Projeto** | Árvore do projeto, units, packages, caminhos de busca |
| **Form Designer (vivo)** | Adicionar/remover componentes no formulário aberto, definir propriedades, criar event handlers |
| **Refactor** | Renomear, scaffolding |

> Todas as alterações passam por **consentimento + diff inline + auditoria** (veja
> [Usando o Chat](05-usando-o-chat.md)).

## A "mágica" do Design ↔ Code

O grande diferencial do Delphi é ter **Design** (Form Designer) **e** **Code**
(editor). O Aefos respeita isso de forma automática:

- Quando o agente faz uma **alteração de design** (ex.: adicionar um botão), a IDE
  **vira para o Design** e você vê o componente surgir na hora.
- Quando faz uma **alteração de código** (ex.: inserir um método), a IDE **vira para
  o Code**.
- Ações de **leitura** (ler design/código, build, git, busca) **não** mexem na sua
  visualização.

O resultado é uma sequência fluida: você pede um componente e *vê* a IDE virar Design;
pede código e *vê* virar Code.

## O designer "vivo"

As leituras e alterações de formulário operam sobre o **designer ao vivo** — não sobre
o `.dfm` velho no disco. Então o que o agente lê e altera é exatamente o que você está
vendo na tela.

### Criar um event handler em um passo

O agente pode criar um manipulador de evento de forma **atômica** com o
`AddEventHandler` — ele cria o método na seção correta do formulário **e** fia o
evento no `.dfm` num único passo, exatamente como o duplo-clique do designer faria.

## Controle total de build → run → stop

Pelo Chat, o agente pode salvar tudo, limpar, compilar, **rodar com o depurador** e
**parar** a aplicação — um ciclo completo sem você sair da conversa.

➡️ Próximo: [Usando o Terminal](07-usando-o-terminal.md)
