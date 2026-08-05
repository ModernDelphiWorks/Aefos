# Contributing

Thanks for your interest in **Aefos AI**! 💙

The source is here, under the GNU GPL v3. **Code contributions are welcome** — this
repository is the product, not a storefront for it.

## What you can contribute

- **Code** — fixes, features, and ports, via pull request.
- **Bug reports** and **feature requests** — via [Issues](../../issues/new/choose).
- **Documentation** — the user manual under `docs/manual/`, and the technical docs
  under `docs/`.
- **Questions & ideas** — via [Discussions](../../discussions).

## Before you post

By opening an issue, comment, discussion, or pull request, you accept the
[Submission Terms](TERMS-ISSUES.md). In short:

- This repo is **public and permanent** — do not post secrets, personal data, or
  proprietary code. Use a **minimal, sanitized** example when code is needed.
- **Security vulnerabilities** go through the private process in
  [SECURITY.md](SECURITY.md) — never a public issue.

## Language

Write **code, comments and commit messages in English** — the codebase is English
throughout, and mixing languages inside a source file makes it harder to read for
everyone who comes after you.

**Your issue or pull request description can be in Portuguese.** The maintainer is
Brazilian; if explaining the problem is easier in Portuguese, do that rather than
explaining it worse in English.

## Code contributions

1. Fork, branch from `main`, and keep the branch focused on one thing.
2. **Match the surrounding code.** The ones that bite newcomers: no inline variable
   declarations (`var X := ...`), local variables prefixed `L`, and `.pas` files
   carrying non-ASCII literals must stay **UTF-8 with BOM**.
3. **Build before you open the PR.** `scripts/build-packages.ps1` builds the Delphi
   packages; `scripts/build-lazarus.ps1` builds the Lazarus/FPC tree, and nothing
   else compiles that tree — if you touched `source/lazarus/`, run it.
4. Say in the PR **what you changed and how you know it works**. The reasoning is
   worth more than a description of the diff, which we can read ourselves.

New to the codebase? [`docs/architecture.md`](docs/architecture.md) is the map, and
[`docs/build-install.md`](docs/build-install.md) gets you to a working build.

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

## Licensing of your contribution

Aefos is GPL v3. By contributing code you agree it is licensed under the same terms,
and you confirm you have the right to contribute it — that it is yours to give, and
not your employer's.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). Be kind.
