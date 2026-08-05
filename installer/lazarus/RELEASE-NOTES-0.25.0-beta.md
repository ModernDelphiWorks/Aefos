**Aefos AI — Lazarus edition, beta.** Free software under the GNU GPL v3 — see `LICENSE` and `ADDITIONAL-PERMISSIONS.md`.

> ### The source is open, and nothing is gated any more
> Aefos became free software on **5 August 2026**. The licence gate was not
> disabled — it was **removed**: the package, its units, the activation dialog,
> the menu items and every call site on both the Lazarus and RAD Studio sides.
> There is no key, no activation, no trial and no editions. The Lazarus edition
> never asks for anything and never contacts a backend of ours.

## Install

1. **Close Lazarus.** The installer rebuilds `lazarus.exe`, so it cannot be running.
2. Run `Aefos-Lazarus-Setup-0.25.0-beta.exe` (needs admin — it writes into the Lazarus folder).
3. The rebuild takes a couple of minutes. Your original `lazarus.exe` is backed up
   beside it first.
4. Reopen Lazarus. Aefos appears in the menu bar.

**Requirements:** Lazarus with FPC 3.2.2 · Windows · the
[WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
for the chat panel. The uninstaller restores the stock `lazarus.exe`.

## What's new since 0.24.7-beta

### 32-bit **and** 64-bit

This build carries the runtime DLLs for both, so a **64-bit Lazarus** is accepted
by the wizard instead of being refused: `libvterm.dll`, `sqlite3.dll` and
`WebView2Loader.dll` ship in an `x86_64` payload beside the i386 one. The
installer picks the set that matches the IDE it found.

### No licence, anywhere

The `License...` menu item, the live `License: <state>` caption and the gate
behind them are gone from the Lazarus register. Every feature is present in the
build you download.

### The source is on GitHub

The whole tree is published — including this edition, its packages and its
installer. If Aefos breaks on your setup you can now read exactly why, and send a
fix. See `CONTRIBUTING.md`; the issue or pull request description may be in
Portuguese.

## Verify your download

```
sha256  98553307f63c9d725d5a21c027e93b851731740bb88bf9acecff9b8475778f67
```

```powershell
Get-FileHash .\Aefos-Lazarus-Setup-0.25.0-beta.exe -Algorithm SHA256
```

## Feedback

This is a beta — please report anything that breaks, especially install problems on a
Lazarus setup different from the usual `C:\lazarus`, and anything specific to a
**64-bit** IDE, which this is the first build to accept.
