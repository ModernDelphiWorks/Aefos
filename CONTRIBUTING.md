# Contributing

Thanks for your interest in **Aefos AI**! 💙

The product **source code is private**, so this public repository is **not** for code
contributions to the product itself. What you *can* contribute here:

- **Bug reports** and **feature requests** — via [Issues](../../issues/new/choose).
- **Documentation fixes** — typos and improvements to the user manual
  (`docs/manual/`) are welcome via pull request.
- **Questions & ideas** — via [Discussions](../../discussions).

## Before you post

By opening an issue, comment, discussion, or pull request, you accept the
[Submission Terms](TERMS-ISSUES.md). In short:

- This repo is **public and permanent** — do not post secrets, personal data, or
  proprietary code. Use a **minimal, sanitized** example when code is needed.
- **Security vulnerabilities** go through the private process in
  [SECURITY.md](SECURITY.md) — never a public issue.

## Documentation PRs

1. Edit the Markdown under `docs/manual/` (`*.md` for PT-BR, `en/*.md` for English).
2. Keep both languages in sync when you change shared facts.
3. You can preview locally:
   ```
   pip install markdown
   python docs/manual/build-html.py pt
   python docs/manual/build-html.py en
   ```
   Open `docs/manual/_html/README.html` (PT) or `docs/manual/_html-en/README.html` (EN).

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). Be kind.
