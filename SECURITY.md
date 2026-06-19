# Security Policy — Aefos AI

We take the security of Aefos AI seriously. This document describes how to report a
vulnerability and how we handle it (coordinated vulnerability disclosure). It is part
of our Cyber Resilience Act (CRA) readiness, alongside the Software Bill of Materials
([`sbom/`](sbom/)) and an actively maintained release stream.

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.17.x (current beta) | ✅ Security fixes |
| < 0.17 | ❌ Please update |

During the beta, security fixes target the latest released version.

## Reporting a vulnerability — do this privately

**Please do NOT open a public issue, pull request, or discussion for a security
vulnerability.** Public disclosure before a fix puts users at risk.

Report privately through either channel:

1. **GitHub Private Vulnerability Reporting** — use the repository's
   *Security → Report a vulnerability* form (preferred).
2. **Email** — **tecsisinfo.com.br@gmail.com** with the subject line
   `SECURITY: Aefos AI`.

### What to include

- A description of the issue and its impact.
- Steps to reproduce, or a **minimal** proof of concept.
- Affected version(s), OS, and RAD Studio version.
- Any relevant logs — **with secrets, credentials, and personal data redacted**.

> Do not include proprietary source code, customer data, or secrets in your report.
> A minimal reproduction is enough.

## Our process and timelines

| Stage | Target |
|-------|--------|
| Acknowledge your report | within **3 business days** |
| Initial assessment / severity | within **10 business days** |
| Fix or mitigation plan | communicated after assessment, prioritized by severity |
| Coordinated public disclosure | after a fix is available, by mutual agreement |

We follow **coordinated disclosure**: we ask that you give us reasonable time to fix
the issue before any public disclosure, and we will keep you informed. With your
permission, we are happy to **credit** you once the fix ships.

## Scope

**In scope:** the Aefos AI plugin suite (Chat, Terminal, in-process MCP server, and
the BPLs we ship) and its bundled third-party components (see [`sbom/`](sbom/)).

**Out of scope (report to the respective vendor):**

- Third-party AI CLIs you configure (Claude Code, Codex, GitHub Copilot CLI, Gemini)
  and their models/services.
- RAD Studio / Embarcadero runtimes (RTL, VCL, FireDAC, the IDE).
- The Microsoft Edge WebView2 Runtime.
- Your own project code or data.

## Safe harbor

We will not pursue or support legal action against researchers who:

- act in good faith and avoid privacy violations, data destruction, and service
  disruption;
- only interact with systems/accounts they own or have permission to test; and
- give us a reasonable opportunity to remediate before public disclosure.

## Software Bill of Materials (SBOM)

A machine-readable SBOM (CycloneDX 1.5) for each release is published under
[`sbom/`](sbom/) so you can audit the components and supply-chain risk before
adopting Aefos AI.

## Contact

Security contact: **tecsisinfo.com.br@gmail.com** · Official channel:
<https://www.pubpascal.dev>
