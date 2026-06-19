# 5. Usando o Chat

O painel de Chat é onde você conversa com a IA e a coloca para trabalhar no seu
projeto.

## Modo Agent vs. modo Chat

| Modo | O que faz | Quando usar |
|------|-----------|-------------|
| **Agent** (padrão) | A IA pode **agir** no projeto: ler, editar código, compilar, rodar, mexer no Form Designer, git… via ferramentas MCP | Quando você quer que a IA *faça* algo no projeto |
| **Chat** | Só conversa — sem agir no projeto | Tirar dúvidas, brainstorming, explicações |

O **modo Agent é o padrão**. Os dois modos são mantidos distintos — escolha conforme a
intenção.

## Mandando uma mensagem

Digite seu pedido e pressione **Enter**. A saída do CLI é transmitida ao vivo e
renderizada como **Markdown** (com destaque de sintaxe) quando o WebView2 está
instalado; sem ele, aparece como texto simples.

## Skills com `/agent`

Você pode invocar **skills** (fluxos pré-definidos) digitando `/agent` seguido da
skill. As skills ficam numa pasta canônica do projeto (`.aefos/skills/`) e são
replicadas automaticamente para o formato que o CLI ativo espera.

- Texto livre (sem skill) vai direto para o CLI como um prompt comum.
- Uma skill monta um prompt **ciente de Delphi** e despacha para o CLI.

## Contexto do projeto

No modo Agent, o Aefos empacota o **contexto do seu projeto Delphi** (via OTA) para
que a IA responda com conhecimento do que está aberto — em vez de respostas genéricas.

## Diff inline: aceitar ou rejeitar alterações

Sempre que o agente vai **alterar código**, o Aefos mostra a mudança como um **diff
inline** no editor, no estilo VS Code:

- Linhas removidas em **vermelho**, adicionadas em **verde**.
- Botões clicáveis **✓ (aplicar)** e **✗ (rejeitar)**.
- Atalhos: **Tab** aplica, **Esc** rejeita.

Nada é gravado sem o seu aval. Se você rejeitar, a alteração é descartada e o agente
recebe esse retorno (em vez de mutar o arquivo).

> O diff é mostrado para edições de código (ex.: editar uma unit, substituir trecho,
> reescrever o conteúdo do editor). Veja
> [O que o agente faz no seu projeto](06-o-que-o-agente-faz.md).

## Segurança: consentimento e auditoria

Ações que **modificam** o projeto passam por um pedido de **consentimento** antes de
rodar, e **toda** chamada de ferramenta fica registrada num **log de auditoria**.
Você tem rastreabilidade do que o agente fez.

➡️ Próximo: [O que o agente faz no seu projeto](06-o-que-o-agente-faz.md)
