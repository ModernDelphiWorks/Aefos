# Component — WebView2 (`TAefosWebView`)

**Runtime BPL:** `Aefos.WebView` (requires `rtl` + `vcl`) · **Design BPL:**
`dclAefosWebView` (`{$DESIGNONLY}`, requires `designide` + `Aefos.WebView`) ·
**Source:** `source/webview`.

A custom, **composition-hosted** WebView2 control — built in-house, with **no
third-party dependency** — that the Chat panel uses instead of the windowed
`Vcl.Edge.TEdgeBrowser`. It is also an installable palette component.

## Why it exists

A windowed `TEdgeBrowser` stops compositing when it loses the foreground — e.g. when
the CLI terminal steals focus while docked — leaving the chat pane **black** until it
recovers. Composition hosting (DirectComposition) composites independently of window
activation via DWM, so the docked panel **stays painted**. This was the definitive
cure for the docked blank-on-Enter / blank-on-focus-steal blink.

## Source units

| Unit | Role |
|------|------|
| `Aefos.WebView.DComp` | Hand-imported `dcomp.dll` (no `Winapi.DComp` in the RTL). |
| `Aefos.WebView.Types` | Config record, script-result type, callbacks. |
| `Aefos.WebView.CompositionHost` | Env → `ICoreWebView2CompositionController` → D3D11 → DComposition device/target/visual → `RootVisualTarget` → DWM. |
| `Aefos.WebView.Control` | `TAefosWebView` — the `TWinControl` that forwards mouse/wheel via its own WndProc and hosts the composition surface. |
| `Aefos.WebView.Reg` | `RegisterComponents('Aefos', [TAefosWebView])` — design-time only. |

## How the host stays alive across dock/undock

Dock/undock recreates the host HWND, which would (a) stop the controller rendering
and (b) orphan the DComp target bound to the dead HWND. The fix:

- Give the controller a hidden **stable anchor window** (a `CreateWindowEx` `STATIC`
  popup) as its parent — it never dies.
- On each host `CreateWnd`, `Reparent()` rebuilds the DComp target
  (`CreateTargetForHwnd`) on the new host handle.

So a dock/undock survives with **no re-navigation/replay** — `RenavigateAfterRecreate`
is a no-op for this control.

## Input

`TAefosWebView` forwards mouse + wheel through its own WndProc; keyboard works after
focus (`MoveFocus` on `WM_LBUTTONDOWN` → the hidden anchor). No manual key
forwarding is needed. `OwnsFocus`/`AnchorHandle` make the chat's focus checks
anchor-aware (Ctrl+V works when the composer is focused).

## Gotchas (solved)

- `CreateEnvironment` `E_INVALIDARG` ⇒ empty `TargetCompatibleBrowserVersion`; set the
  SDK version (`137.0.3296.44` for D13) + all option fields + `PChar('')` (not `nil`)
  for `browserExecutableFolder`. Mirror `Vcl.Edge` / `Winapi.EdgeUtils` exactly.
- `tagRECT` (`Winapi.WebView2`) ≠ `System.Types.TRect` — copy fields.
- WebView2 caches the browser env per user-data folder, so an arg change (e.g.
  `--disable-features=CalculateNativeWinOcclusion`) needs a **full IDE restart**, not
  just a BPL reload.

## ⛔ Hard rule

**Never** hook `TEdgeBrowser.WindowProc` (or leave any WndProc hook unrestored at
teardown). An unrestored hook caused an **unload AV on Build All** (rtl370, during
`DestroyWindowHandle`), silently deinstalling the package. For focus signals use
`Vcl.Edge`'s `OnEnter`/`OnExit` (nilled in `Destroy`) plus a panel self-`PostMessage`.
This is the same family as the keyboard-binding unload AV documented in the root
`CLAUDE.md`.

## Packaging

Two packages by design (do not consolidate): the runtime `Aefos.WebView` (contains
DComp/Types/CompositionHost/Control) and the design-only `dclAefosWebView` (contains
`Aefos.WebView.Reg`). Installing `dclAefosWebView` adds an **Aefos** palette tab with
`TAefosWebView`, droppable at design time (guarded by `csDesigning` + a placeholder
`Paint`).
