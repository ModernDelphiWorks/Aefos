# Aefos AI — Privacy Policy

**English** · [Português (PT-BR)](PRIVACY.pt-BR.md)

**Last Updated:** June 2026

This Privacy Policy explains how Aefos AI ("Aefos", "we", "us") processes personal
data in connection with the Aefos AI software (the "Software"). It is written to be
consistent with the Brazilian General Data Protection Law (Lei nº 13.709/2018 —
"LGPD") and complements the Aefos AI End User License Agreement
([`LICENSE`](LICENSE)).

> **Plain-language summary (non-binding).** Aefos is a local IDE plugin. It does
> **not** run an AI model and does **not** collect your source code or prompts —
> those go directly to the third-party AI command-line tool *you* choose, under that
> tool's own privacy policy. The only personal data we process is what is needed to
> (a) activate and validate a paid license, and (b) optionally keep the product
> reliable through limited technical diagnostics.

---

## 1. Controller (Controlador)

The controller of the personal data described here is the Aefos AI maintainer:

- **Maintainer:** Aefos AI (TecSis Info)
- **Contact / Encarregado (DPO):** tecsisinfo.com.br@gmail.com
- **Official channel:** https://www.pubpascal.dev

You may use the contact above to exercise any of the rights described in Section 8.

## 2. Scope

This Policy covers personal data processed by the Software itself and by the
licensing backend it connects to. It does **not** cover third-party AI tools,
models, APIs, or services you choose to use with the Software — those are governed
by their own privacy policies (see Section 7 and Section 6 of the EULA).

## 3. What we process, why, and on what legal basis

### 3.1 License activation and validation data

When you activate or validate a paid (Pro/Enterprise) license, the Software sends to
our licensing backend:

- the license key you enter;
- a non-reversible **machine fingerprint** (a derived identifier for this copy of
  Delphi on this machine/user — used to enforce the one-seat rule and prevent
  abuse);
- the **email** associated with the key (when you provide it);
- technical metadata such as your **IP address** and request **timestamps**.

- **Purpose:** activate the license, enforce the per-seat limit, prevent piracy and
  abuse, and provide support.
- **Legal basis (LGPD):** performance of a contract / pre-contractual steps
  (art. 7, V) and the controller's legitimate interest in protecting against
  unauthorized use (art. 7, IX), balanced against your rights.

### 3.2 Diagnostic and telemetry data (limited)

The Software may process limited technical and diagnostic information (for example,
error events, version, edition, and feature-availability signals) to maintain
reliability, improve quality, detect abuse, enforce licensing, and diagnose issues.

This information **does not intentionally include your source code, proprietary
business information, or user content** unless you explicitly authorize it (for
example, by attaching logs to a support request).

- **Legal basis (LGPD):** legitimate interest (art. 7, IX) and, where applicable,
  your consent (art. 7, I).

### 3.3 Data stored only on your device

Chat sessions, command history, and the local audit log are stored **locally** on
your machine (e.g. under `%APPDATA%\Aefos`). We do not collect or transmit this
local data. You control it and can delete it at any time.

### 3.4 What we do NOT collect

- We do **not** operate an AI model and do **not** receive your prompts or the code
  the agent reads, generates, or edits. That content is sent by the third-party CLI
  *you* configure, directly to that provider (see Section 7).
- We do **not** manage or receive your AI provider credentials.

## 4. Children

The Software is intended for software developers and is not directed to children.
We do not knowingly process personal data of children or adolescents.

## 5. Retention

We keep license and validation data for as long as the license is active and for the
period required to comply with legal, tax, security, and audit obligations, after
which it is deleted or anonymized. Diagnostic data is kept only as long as necessary
for the purposes in Section 3.2.

## 6. Sharing and processors

We do not sell personal data. We share it only with:

- **Infrastructure/processors** that host the licensing backend (for example, our
  database/Edge-Function provider, currently Supabase), acting on our instructions;
- **Authorities**, when required to comply with a legal or regulatory obligation;
- **Email delivery** providers used to send license/registration messages.

These parties process data under our instructions and applicable law.

## 7. Third-party AI tools and services

The Software is a harness that launches the external AI command-line tool you choose
(such as Claude Code, Codex, GitHub Copilot CLI, or Gemini). **Any prompt, code, or
content processed by those tools is sent by them, directly to their provider, under
that provider's own terms and privacy policy.** Aefos is not the controller of that
processing. Please review the privacy policy of each AI provider you use.

## 8. International transfer

Our processors may store or process data on servers located outside Brazil.
Where this occurs, we rely on the transfer mechanisms permitted by the LGPD
(art. 33), including transfer necessary for the performance of a contract and the
adoption of appropriate safeguards by the processor.

## 9. Your rights (LGPD, art. 18)

Subject to the conditions of the LGPD, you may request: confirmation of processing;
access to your data; correction of incomplete, inaccurate, or outdated data;
anonymization, blocking, or deletion of unnecessary or excessively processed data;
data portability; deletion of data processed with your consent; information about
sharing; and information about the consequences of refusing consent. Where
processing is based on consent, you may withdraw it at any time.

To exercise these rights, contact **tecsisinfo.com.br@gmail.com**. You also have the
right to petition the Brazilian National Data Protection Authority (ANPD).

## 10. Security

We adopt reasonable technical and administrative measures to protect personal data
against unauthorized access, loss, alteration, and improper disclosure (LGPD,
art. 46), including access controls and row-level security on the licensing backend.
No method of transmission or storage is fully secure, and we cannot guarantee
absolute security.

## 11. Changes to this Policy

We may update this Policy from time to time. Updated versions are published through
the official distribution channel, with a revised "Last Updated" date. Continued use
of the Software after publication constitutes acknowledgment of the updated Policy,
to the extent permitted by applicable law.

## 12. Contact

For privacy questions, requests, or to reach the Encarregado (DPO):
**tecsisinfo.com.br@gmail.com**.
