# `.well-known/` — PubPascal package manifest

This folder holds the **PubPascal** claim/verification manifest that links this
repository to its package page on <https://www.pubpascal.dev> and lets the portal
award the **CRA-readiness** seal.

## How it works

1. On the portal, **Publish** the Aefos package and point it at this repository.
2. The portal gives you a manifest (with a one-time `verify` nonce). Save it here as
   **`pubpascal.json`** (use [`pubpascal.example.json`](pubpascal.example.json) as the
   shape) and commit it.
3. The portal scans the repo and confirms ownership (only someone with write access
   could have committed the file with the matching nonce), then reads the SBOM
   ([`../sbom/`](../sbom/)), the [security policy](../SECURITY.md), and the recent
   release/commit activity to compute **CRA-ready 100%**.
4. The README badge then shows the live seal from `badge` in the manifest.

## Security

This is a **public** repository, so the manifest contains **no secrets** — only public
identifiers (package slug, URLs, the SBOM path, and a non-secret verification nonce).
Proof of ownership comes from **write access to the repo**, not from the file's
contents. Any token needed to *write back* to the portal (e.g. to trigger a re-scan
on release) must live as a **GitHub Actions secret**, never in this file.

> `pubpascal.example.json` is a reference template only. The portal-generated
> `pubpascal.json` is what actually claims the package.
