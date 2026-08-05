# Aefos AI — Third-Party Components and GPLv3 Compatibility

Aefos AI is licensed under the **GNU General Public License version 3** (see
[`LICENSE`](LICENSE)) with the additional permissions in
[`ADDITIONAL-PERMISSIONS.md`](ADDITIONAL-PERMISSIONS.md).

This file is the **inventory and compatibility assessment** of everything Aefos
vendors, embeds, links or ships. The **full verbatim licence texts** remain in
[`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt), which is the file the
distributed product carries; that file is unchanged and is not superseded by
this one.

**Reviewed:** August 2026, against the tracked tree.
**Verdict:** **No GPLv3-incompatible component found.** One item (the bundled
font) is compatible but rests on a reading worth a lawyer's confirmation — see
§3.

---

## 1. Vendored source — compiled into the product

| # | Component | Version / pin | Licence | Where | GPLv3 |
|---|-----------|---------------|---------|-------|-------|
| 1 | **libvterm** | commit `934bc2fbf21800ac3458a499df8820ca5fb45fd3` | **MIT** | `source/terminal/ThirdParty/libvterm/` (`LICENSE` present) | ✅ Compatible — permissive, one-way into GPL |
| 2 | **SQLite** (amalgamation) | 3.46.1 | **Public domain** | `source/data/ThirdParty/sqlite/` (no `LICENSE` file; provenance in `UPSTREAM.txt`, sha256-pinned) | ✅ Compatible — no restrictions to conflict with |

**Note on SQLite:** it has no licence *file* in the vendored directory. This is
not a "missing licence" risk — SQLite is explicitly dedicated to the public
domain by its authors (<https://www.sqlite.org/copyright.html>), and the
directory records the exact upstream ZIP and its sha256. Public-domain code can
be incorporated into a GPL work without any conflict.

## 2. Vendored JavaScript / CSS — embedded as string constants in the Chat WebView

| # | Component | Version | Licence | Where | GPLv3 |
|---|-----------|---------|---------|-------|-------|
| 3 | **marked** | 14.1.4 | **MIT** | embedded in `source/chat/UI/Aefos.OTA.Chat.UI.OutputPanel.Assets.pas`; licence verbatim in `THIRD-PARTY-NOTICES.txt` | ✅ Compatible |
| 4 | **Markdown** (John Gruber, syntax description shipped inside marked's `LICENSE`) | — | **BSD 3-Clause** | licence verbatim in `THIRD-PARTY-NOTICES.txt` | ✅ Compatible — **3**-clause, no advertising clause |
| 5 | **highlight.js** | 11.11.1 | **BSD 3-Clause** | embedded in `source/chat/UI/Aefos.OTA.Chat.UI.OutputPanel.Assets.pas`; licence verbatim in `THIRD-PARTY-NOTICES.txt` | ✅ Compatible — **3**-clause, no advertising clause |

Both BSD notices were read in full and confirmed to be the **3-clause** form.
Neither contains the GPL-incompatible **4-clause "advertising"** term ("All
advertising materials mentioning features or use of this software must
display…"). That was the specific hazard to check, and it is absent.

## 3. Bundled binary assets

| # | Component | Licence | Where | GPLv3 |
|---|-----------|---------|-------|-------|
| 6 | **CaskaydiaCove Nerd Font Mono** (Nerd Fonts patch of Microsoft **Cascadia Code**) | **SIL Open Font License 1.1** | `packages/Delphi/CaskaydiaCoveNerdFontMono-Regular.ttf`, compiled into `Aefos.OTA.TerminalFont.RES` | ⚠️ Compatible, with a caveat — see below |

The OFL 1.1 is a free copyleft licence for *fonts*. It says the Font Software
"must be distributed entirely under this license, and must not be distributed
under any other license" — but it **expressly permits** bundling and embedding:
*"Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy contains
the above copyright notice and this license."* Aefos satisfies that condition by
shipping the full OFL text in `THIRD-PARTY-NOTICES.txt`.

**The caveat, stated honestly:** the font is not merely shipped alongside the
binary — it is compiled into a Windows resource (`.RES`) and linked into the
Terminal BPL. That is still "bundled/embedded" in the plain sense the OFL
permits, and the font remains font *data*, not linked code, so the usual
analysis is that this is aggregation and no GPL conflict arises. This is how
GNU/Linux distributions have shipped OFL fonts with GPL software for years.
**It is not a blocker.** But it is the one line in this inventory that rests on
an interpretation rather than on an explicit grant, so if the relicense is
reviewed by counsel, this is the item to point at. The zero-risk alternative is
to stop embedding the font and fall back to a system font, which is a code
change, not a licensing one.

*Reserved Font Names:* "Cascadia Code" and "Cascadia Mono" are reserved under
the OFL. Aefos ships the font unmodified under the Nerd Fonts name, so the
reserved-name restriction is not triggered.

## 4. Not redistributed — linked or invoked at runtime

These are **not** shipped by Aefos. They live on the user's machine under the
user's own licence. They are the reason
[`ADDITIONAL-PERMISSIONS.md`](ADDITIONAL-PERMISSIONS.md) §2 exists.

| Component | Licence | Relationship | GPLv3 |
|-----------|---------|--------------|-------|
| **Embarcadero RAD Studio** runtime + design-time (`rtl`, `vcl`, `vclie`, `designide`, `ToolsAPI`, `FireDAC`, …) | Proprietary (Embarcadero EULA) | **Linked.** A design-time `.bpl` cannot exist without `designide`. | ✅ Resolved by the **linking exception** — `ADDITIONAL-PERMISSIONS.md` §2 |
| **Microsoft Edge WebView2 Runtime** | Proprietary (Microsoft) | Hosted/called. The **runtime** is detected on the user machine, never redistributed; the small **`WebView2Loader.dll`** ships in the installer under Microsoft SDK terms | ✅ Resolved by the same exception; also arguably a GPLv3 §1 **System Library** |
| **Lazarus / Free Pascal (LCL, RTL)** — Lazarus edition | **modified LGPL** / LGPL with static-linking exception | Linked | ✅ Compatible — designed to be linkable from any licence |
| **User-supplied AI CLIs** (Claude Code, Codex, Copilot CLI, Gemini) | Each vendor's own | Spawned as a **separate process** over stdin/stdout | ✅ Separate programs at arm's length — no combined work, no GPL reach |

## 5. Shipped by the installer as separate programs

The Windows installer may stage independent CLI executables next to Aefos. They
are **aggregation on a distribution medium** (GPLv3 §5, final paragraph), not a
combined work — each stays under its own licence and none of them place any
obligation on Aefos, nor Aefos on them.

| Component | Licence | GPLv3 |
|-----------|---------|-------|
| **Codex CLI** (`openai/codex`) | **Apache-2.0** | ✅ Compatible with GPLv3 (one-way, Apache-2.0 → GPLv3) |
| **Gemini CLI** (`google-gemini/gemini-cli`) | **Apache-2.0** | ✅ Compatible with GPLv3 |
| **Claude Code** | Proprietary | Not bundled — detect-only, by design |
| **GitHub Copilot CLI** | Proprietary | Not bundled — its licence forbids repackaging |

Attribution for whatever is actually staged is generated at build time into
`redist/cli/THIRD-PARTY-LICENSES.txt` by `installer/fetch-clis.ps1`.

---

## 6. What was checked for, and not found

The following licence families are **incompatible with GPLv3**. Every vendored
component above was checked against this list. **None matched:**

- ❌ **4-clause BSD** (the "advertising clause" — the original BSD) — not present;
  both BSD notices in the tree are the 3-clause form.
- ❌ **CDDL** — not present.
- ❌ **EPL** (1.0 or 2.0) — not present.
- ❌ **SSPL** — not present.
- ❌ **"Non-commercial use only" / "no derivatives" / research-only** — not present.
- ❌ **Code with no licence file and no traceable provenance** — not present. The
  only vendored directory without a `LICENSE` file is SQLite, whose public-domain
  status and exact upstream artefact are documented and hash-pinned in
  `source/data/ThirdParty/sqlite/UPSTREAM.txt`.

---

## 7. Limits of this assessment

This inventory was produced by reading the licence files present in the tree and
the provenance metadata beside each vendored component. It is **not a legal
opinion**, and it was not written by a lawyer. It covers the components **that
are in the tracked tree**; a build machine may pull further dependencies at
build time (see `installer/fetch-clis.ps1`) that are outside its scope. Before
the relicense is announced publicly, it is worth having counsel confirm §3 and
skim §4.

To report an omission or correction, contact tecsisinfo.com.br@gmail.com.
