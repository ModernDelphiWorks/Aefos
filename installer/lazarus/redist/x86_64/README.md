# 64-bit runtime payload

The Lazarus installer accepts a **64-bit Lazarus** only when all three DLLs below
are present in this folder. If any is missing, `Aefos-Lazarus.iss` computes its
payload architectures without `x86_64` and the wizard goes back to refusing a
64-bit IDE — silently, by design, so a missing cross-toolchain never breaks the
32-bit build.

| File | Licence | Where it comes from |
|---|---|---|
| `libvterm.dll` | MIT | **committed here.** Compiled from the vendored C in `source/terminal/ThirdParty/libvterm/` |
| `sqlite3.dll` | public domain | **committed here.** Compiled from the amalgamation in `source/data/ThirdParty/sqlite/` |
| `WebView2Loader.dll` | **proprietary (Microsoft)** | ⚠️ **not committed — fetch it, see below** |

The first two are committed so that building a 64-bit installer does not require an
`x86_64` mingw-w64 toolchain. To rebuild them from source instead:

```powershell
pwsh -File scripts\build-libvterm-fpc.ps1 -Arch x86_64
pwsh -File scripts\build-sqlite-fpc.ps1   -Arch x86_64
```

## `WebView2Loader.dll` — one command

It cannot be compiled: Microsoft ships it as a binary, and RAD Studio bundles only
the 32-bit one (there is no `WebView2Loader.dll` under any `bin64` of a Studio
install). It is not committed here because it is proprietary and this repository is
GPL v3. Fetch it:

```powershell
pwsh -File scripts\fetch-webview2-loader.ps1 -Arch x86_64
```

That downloads the official **Microsoft.Web.WebView2** package from nuget.org,
extracts `build/native/x64/WebView2Loader.dll` into this folder, and **verifies the
COFF machine word** against the architecture — a directory named `x86_64` is a
claim; the machine word is the fact.

`build-lazarus-installer.ps1` runs this for you when the file is absent, so on a
build box with network access there is nothing to do by hand.

### By hand, or from a copy you already have

Download <https://www.nuget.org/packages/Microsoft.Web.WebView2>, rename the
`.nupkg` to `.zip`, and copy `build/native/x64/WebView2Loader.dll` here. Or point
the build at an existing copy without placing it here:

```powershell
pwsh -File installer\lazarus\build-lazarus-installer.ps1 `
     -WebView2Loader64 C:\path\to\x64\WebView2Loader.dll
```

The environment variable `AEFOS_WEBVIEW2_LOADER_X64` works the same way.

> **Not the same thing as the runtime.** This DLL is the small loader the built
> `lazarus.exe` binds. The **WebView2 Evergreen Runtime** is the browser engine
> itself, which the installer detects on the user's machine — see
> `installer/redist/download-webview2.ps1`.

## Redistribution

Microsoft's WebView2 SDK terms allow shipping the loader with an application, which
is what the installer does. On the GPL side,
[`ADDITIONAL-PERMISSIONS.md`](../../../../ADDITIONAL-PERMISSIONS.md) §2 covers
linking with **Microsoft Edge WebView2 and the Microsoft Windows platform libraries
and runtimes that Aefos calls or hosts**, and conveying the resulting installers.
