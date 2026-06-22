# Aefos AI — Política de Privacidade

[English](PRIVACY.md) · **Português (PT-BR)**

**Última atualização:** Junho de 2026

Esta Política de Privacidade explica como o Aefos AI ("Aefos", "nós") trata dados
pessoais relacionados ao software Aefos AI (o "Software"). Foi redigida em
conformidade com a Lei Geral de Proteção de Dados (Lei nº 13.709/2018 — "LGPD") e
complementa o Contrato de Licença de Usuário Final (EULA) do Aefos AI
([`LICENSE`](LICENSE)).

> **Resumo em linguagem clara (não vinculante).** O Aefos é um plugin local de IDE.
> Ele **não** executa um modelo de IA e **não** coleta seu código-fonte ou seus
> prompts — esses vão diretamente para a ferramenta de IA de linha de comando que
> *você* escolhe, sujeitos à política de privacidade dessa ferramenta. Os únicos
> dados pessoais que tratamos são os necessários para (a) ativar e validar uma
> licença paga e (b) opcionalmente manter o produto confiável por meio de
> diagnósticos técnicos limitados.

---

## 1. Controlador

O controlador dos dados pessoais aqui descritos é:

- **Razão social:** Isaque de Souza Pinheiro (Empresário Individual / ME)
- **CNPJ:** 02.565.249/0001-70
- **Endereço:** Av. Aurélio Alvarenga, 33-A, Guaraná, Aracruz – ES, Brasil, CEP 29.195-421
- **Produto:** Aefos AI
- **Encarregado (DPO) — art. 41 da LGPD:** Isaque de Souza Pinheiro — tecsisinfo.com.br@gmail.com
- **Canal oficial:** https://www.pubpascal.dev

Use o contato acima para exercer qualquer um dos direitos descritos na Seção 8.

## 2. Abrangência

Esta Política cobre os dados pessoais tratados pelo próprio Software e pelo backend
de licenciamento ao qual ele se conecta. Ela **não** cobre ferramentas, modelos,
APIs ou serviços de IA de terceiros que você decida usar com o Software — esses são
regidos pelas suas próprias políticas de privacidade (ver Seção 7 e Seção 6 do
EULA).

## 3. O que tratamos, por quê e com qual base legal

### 3.1 Dados de ativação e validação de licença

Ao ativar ou validar uma licença paga (Pro/Enterprise), o Software envia ao nosso
backend de licenciamento:

- a chave de licença que você digita;
- um **fingerprint da máquina** não reversível (identificador derivado desta cópia
  do Delphi nesta máquina/usuário — usado para impor a regra de um assento e evitar
  abuso);
- o **e-mail** associado à chave (quando você o fornece);
- metadados técnicos como seu **endereço IP** e os **horários** das requisições.

- **Finalidade:** ativar a licença, impor o limite por assento, prevenir pirataria e
  abuso e prestar suporte.
- **Base legal (LGPD):** execução de contrato / procedimentos preliminares
  (art. 7º, V) e legítimo interesse do controlador na proteção contra uso não
  autorizado (art. 7º, IX), ponderado com os seus direitos.

### 3.2 Dados de diagnóstico e telemetria (limitados)

O Software pode tratar informações técnicas e de diagnóstico limitadas (por exemplo,
eventos de erro, versão, edição e sinais de disponibilidade de recursos) para manter
a confiabilidade, melhorar a qualidade, detectar abuso, impor o licenciamento e
diagnosticar problemas.

Essas informações **não incluem intencionalmente seu código-fonte, informações
empresariais sigilosas ou conteúdo do usuário**, salvo se você autorizar
expressamente (por exemplo, anexando logs a uma solicitação de suporte).

- **Base legal (LGPD):** legítimo interesse (art. 7º, IX) e, quando aplicável, seu
  consentimento (art. 7º, I).

### 3.3 Dados armazenados apenas no seu dispositivo

Sessões de chat, histórico de comandos e o log de auditoria local são armazenados
**localmente** na sua máquina (por exemplo, em `%APPDATA%\Aefos`). Nós não coletamos
nem transmitimos esses dados locais. Você os controla e pode apagá-los a qualquer
momento.

### 3.4 O que NÃO coletamos

- Nós **não** operamos um modelo de IA e **não** recebemos seus prompts nem o código
  que o agente lê, gera ou edita. Esse conteúdo é enviado pela CLI de terceiros que
  *você* configura, diretamente ao respectivo provedor (ver Seção 7).
- Nós **não** gerenciamos nem recebemos as credenciais do seu provedor de IA.

## 4. Crianças e adolescentes

O Software é destinado a desenvolvedores de software e não é direcionado a crianças.
Não tratamos, de forma consciente, dados pessoais de crianças ou adolescentes.

## 5. Retenção

Mantemos os dados de licença e validação enquanto a licença estiver ativa e pelo
período necessário ao cumprimento de obrigações legais, fiscais, de segurança e de
auditoria, após o que são eliminados ou anonimizados. Dados de diagnóstico são
mantidos apenas pelo tempo necessário às finalidades da Seção 3.2.

## 6. Compartilhamento e operadores

Não vendemos dados pessoais. Compartilhamos apenas com:

- **Infraestrutura/operadores** que hospedam o backend de licenciamento (por
  exemplo, nosso provedor de banco de dados/Edge Function, atualmente o Supabase),
  atuando sob nossas instruções;
- **Autoridades**, quando exigido para cumprir obrigação legal ou regulatória;
- **Provedores de envio de e-mail** usados para enviar mensagens de licença/cadastro.

Essas partes tratam os dados sob nossas instruções e conforme a lei aplicável.

## 7. Ferramentas e serviços de IA de terceiros

O Software é um harness que inicia a ferramenta de IA de linha de comando que você
escolhe (como Claude Code, Codex, GitHub Copilot CLI ou Gemini). **Qualquer prompt,
código ou conteúdo tratado por essas ferramentas é enviado por elas, diretamente ao
respectivo provedor, sob os termos e a política de privacidade desse provedor.** O
Aefos não é o controlador desse tratamento. Revise a política de privacidade de cada
provedor de IA que você utilizar.

## 8. Transferência internacional

Nossos operadores podem armazenar ou tratar dados em servidores localizados fora do
Brasil. Quando isso ocorre, baseamo-nos nos mecanismos de transferência permitidos
pela LGPD (art. 33), incluindo a transferência necessária à execução de contrato e a
adoção de salvaguardas adequadas pelo operador.

## 9. Seus direitos (LGPD, art. 18)

Observadas as condições da LGPD, você pode solicitar: confirmação do tratamento;
acesso aos dados; correção de dados incompletos, inexatos ou desatualizados;
anonimização, bloqueio ou eliminação de dados desnecessários ou tratados em excesso;
portabilidade; eliminação dos dados tratados com consentimento; informação sobre
compartilhamento; e informação sobre as consequências de negar o consentimento.
Quando o tratamento se basear em consentimento, você pode revogá-lo a qualquer
momento.

Para exercer esses direitos, contate **tecsisinfo.com.br@gmail.com**. Você também tem
o direito de peticionar à Autoridade Nacional de Proteção de Dados (ANPD).

## 10. Segurança

Adotamos medidas técnicas e administrativas razoáveis para proteger os dados pessoais
contra acessos não autorizados, perda, alteração e divulgação indevida (LGPD,
art. 46), incluindo controles de acesso e segurança em nível de linha (RLS) no
backend de licenciamento. Nenhum método de transmissão ou armazenamento é totalmente
seguro, e não podemos garantir segurança absoluta.

## 11. Alterações desta Política

Podemos atualizar esta Política periodicamente. Versões atualizadas são publicadas
pelo canal oficial de distribuição, com data de "Última atualização" revisada. O uso
continuado do Software após a publicação constitui ciência da Política atualizada, na
medida permitida pela lei aplicável.

## 12. Contato

Para dúvidas, solicitações de privacidade ou para falar com o Encarregado (DPO):
**tecsisinfo.com.br@gmail.com**.
