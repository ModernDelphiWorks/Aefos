# Licensing

**BPL:** `Aefos.License` · **Source:** `source/license` · **Backend:** a hosted
service (Supabase / Postgres + an Edge Function), **not part of this repository**.

`Aefos.License` is a **passive runtime package** both the Chat and Terminal
design-time BPLs `require`, so they share **one** license gate. It registers
**nothing** in the IDE (no notifiers, no keyboard bindings) — it is deliberately
outside the unload-AV surface. The hosts decide *when* to show the activation
screen (the **Aefos AI → License…** menu item / an Options button).

## Model — node-locked seat with self-transfer

- A license key has **N seats** (default **1**).
- **Activating** binds a *fingerprint* (this Delphi copy on this machine/user) to a
  seat.
- **Deactivating** frees the seat — that's how you transfer to another Delphi.
- The server's atomic `activate()` (`SELECT … FOR UPDATE`) guarantees a key can
  never exceed its seats → **"1 key = 1 active IDE"** for `seats = 1`.

## Source units

| Unit | Role |
|------|------|
| `Aefos.License.Client` | Computes the stable fingerprint, calls the Edge Function to activate / deactivate / validate (heartbeat), caches the last good result at `%APPDATA%\Aefos\license.dat`. Pure RTL + WinAPI + `System.Net` — no ToolsAPI, no VCL (unit-testable). |
| `Aefos.License.Gate` | The single gate the hosts call (`LicenseIsUsable`, `LicenseStatusText`) + the entry to the activation screen. Offline-safe — never blocks on the network. |
| `Aefos.License.Token` | RS256 signed-token verification (**phase 2**). |
| `Aefos.License.UI` | The activation screen. |

## Offline behaviour

The client caches the last good result so the IDE keeps working **offline within a
grace window**, and runs a built-in **trial** when no key is present yet.
`LicenseIsUsable` is `True` when there's an active key, a cached result within grace,
or an active trial — and it **never blocks on the network**.

## Tiers & capabilities (the gate)

Enforcement is **soft during beta** (works + upsell); `GATE_HARD_MODE` flips to hard
at GA. The philosophy: **gate the convenience / auto-create, never the manual core** —
a free user can still do everything by hand (hand-write `.mcp.json`, type commands
manually); Pro buys the in-IDE auto-create dialogs + execution power.

| Tier | Capabilities |
|------|--------------|
| **Community (free)** | `chat` (panel + conversation), `agent` (the default chat mode), own API key. |
| **Pro** | `terminal`, `mcp` (auto-setup/provision dialog), `command-wizard` (auto-create command dialog), `advanced-context`, `history` (sessions + templates), `ai-flow` (silent reload). |

> The product/pricing split (Aefos Chat vs. Aefos Studio) is a separate strategy
> discussion; the gate is already tier-aware (a `tier` column exists server-side).

## Backend

The seat server is a **hosted service** and is not part of this repository. What
matters to this code is the contract above: the client calls the `license` Edge
Function to activate / deactivate / validate, and the seat logic is enforced
server-side — the client is never trusted with it.

Because the gate is GPL-licensed like the rest, a fork is free to remove it. That
is inherent to the licence, not an oversight.

## Status

- **Phase 1 (done)** — online activate/validate + local cache + trial; the flow is
  wired into Chat + Terminal via the shared gate.
- **Phase 2 (open)** — the server returns an **RS256-signed token**;
  `Aefos.License.Token` verifies it offline via Windows CNG (embedded RSA public
  key) for tamper resistance. Phase 1 trusts the cached result (good enough to wire
  the flow).
