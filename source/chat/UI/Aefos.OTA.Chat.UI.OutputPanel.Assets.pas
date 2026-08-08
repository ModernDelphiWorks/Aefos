unit Aefos.OTA.Chat.UI.OutputPanel.Assets;

{
  Embedded WebView2 panel assets (ESP-008, demand 4/5; updated ESP-004, demand 1/6).

  Per ADR-013 the HTML shell, CSS, and the marked / highlight.js JS bundles
  ship as Pascal-string constants and are concatenated into the document
  loaded via TEdgeBrowser.NavigateToString — no asset files next to the BPL,
  no .RES, no http(s) fetch.

  Per ADR-014 HTML_SHELL contains the JS bridge (window.dsAppend / window.dsClear)
  and the ~100 ms debounce timer that throttles full Markdown re-parse + syntax
  highlight on the accumulated buffer.

  Per ADR-022 MARKED_JS, HIGHLIGHT_JS and HIGHLIGHT_CSS are GENERATED from the
  pinned upstream bundles (marked 14.1.4, highlight.js 11.11.1) and must not be
  hand-edited between the BEGIN/END GENERATED markers — the SHA-256 recorded
  above each block is what ties the text to its upstream release.
  PANEL_CSS and HTML_SHELL are project-owned and not generated.
}

interface

const
  (* ── The permission prompt, in ONE place ──────────────────────────────────
     The card exists in two containers: inside the chat panel, and in a
     borderless window of its own when the request arrives with no panel open.
     The owner asked for one look and said it more than once -- "ate pode criar
     um form para cada um mas o MODELO igual poxa, padrao".

     So the three pieces are declared HERE, ahead of the shell, and the shell
     SPLICES them in. Both documents are built from the same characters at
     compile time, which is a stronger promise than two files kept in step by
     whoever remembers: there is no second copy to forget.

     UNTYPED consts on purpose. A typed constant (X: string = '...') is an
     initialised variable, not a constant expression, so it cannot appear in
     another constant's initialiser -- the splice below would not compile. *)
  PERMISSION_CSS =
    '#ds-perm-backdrop { position: fixed; inset: 0; z-index: 64; ' +
    'background: rgba(6,7,10,0.66); backdrop-filter: blur(3px); ' +
    'display: grid; place-items: center; }' + sLineBreak +
    '#ds-perm-modal { width: min(560px, 94vw); ' +
    'background: var(--ds-code-bg, #171a21); border: 1px solid var(--ds-border); ' +
    'border-radius: 16px; box-shadow: 0 24px 70px rgba(0,0,0,0.55); ' +
    'overflow: hidden; animation: ds-mem-pop .18s ease; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-head { display: flex; align-items: flex-start; ' +
    'gap: 13px; padding: 20px 22px 12px; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-badge { width: 42px; height: 42px; border-radius: 11px; ' +
    'flex: none; display: grid; place-items: center; font-size: 21px; ' +
    'background: linear-gradient(135deg, rgba(var(--ds-warn-rgb),0.22), ' +
    'rgba(var(--ds-warn-rgb),0.05)); border: 1px solid rgba(var(--ds-warn-rgb),0.4); }' + sLineBreak +
    '#ds-perm-modal .ds-perm-title { font-size: 16px; font-weight: 700; ' +
    'margin: 1px 0 3px; color: var(--ds-fg); }' + sLineBreak +
    '#ds-perm-modal .ds-perm-sub { font-size: 12.5px; color: var(--ds-secondary); ' +
    'line-height: 1.45; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-close { margin-left: auto; color: var(--ds-secondary); ' +
    'font-size: 20px; cursor: pointer; line-height: 1; background: none; border: none; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-body { padding: 4px 22px 6px; max-height: 56vh; ' +
    'overflow-y: auto; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-toolrow { display: flex; align-items: center; gap: 8px; ' +
    'margin: 8px 0 12px; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-tool { font-family: "Cascadia Code", Consolas, monospace; ' +
    'font-size: 12.5px; color: var(--ds-warn); background: rgba(var(--ds-warn-rgb),0.10); ' +
    'border: 1px solid rgba(var(--ds-warn-rgb),0.28); border-radius: 7px; padding: 3px 9px; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-what { font-size: 13.5px; line-height: 1.5; color: var(--ds-fg); }' + sLineBreak +
    '#ds-perm-modal .ds-perm-detlabel { font-size: 11px; color: var(--ds-secondary); ' +
    'font-weight: 600; letter-spacing: 0.2px; margin: 14px 0 5px; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-detail { background: var(--ds-bg); ' +
    'border: 1px solid var(--ds-border); border-radius: 10px; padding: 11px 13px; ' +
    'font-family: "Cascadia Code", Consolas, monospace; font-size: 12px; line-height: 1.5; ' +
    'color: var(--ds-fg); white-space: pre-wrap; max-height: 150px; overflow: auto; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-foot { display: flex; align-items: center; gap: 10px; ' +
    'padding: 14px 22px 20px; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-hint { font-size: 11px; color: var(--ds-secondary); }' + sLineBreak +
    '#ds-perm-modal .ds-perm-spacer { flex: 1; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-act { padding: 9px 16px; border-radius: 10px; ' +
    'font-size: 13px; font-weight: 600; cursor: pointer; border: 1px solid var(--ds-border); ' +
    'background: #1c2029; color: var(--ds-fg); }' + sLineBreak +
    (* Deny = safe default: blue focus highlight *)
    '#ds-perm-modal .ds-perm-act.ds-perm-deny { border-color: rgba(var(--ds-blue-rgb),0.5); ' +
    'box-shadow: 0 0 0 3px rgba(var(--ds-blue-rgb),0.16); }' + sLineBreak +
    '#ds-perm-modal .ds-perm-act.ds-perm-primary { border: none; color: #fff; ' +
    'background: linear-gradient(135deg, var(--ds-primary-hi), var(--ds-primary-lo)); ' +
    'box-shadow: 0 6px 18px rgba(var(--ds-primary-rgb),0.32); }' + sLineBreak;

  (* The markup. Button ORDER is load-bearing: Deny -> Allow for this session ->
     Allow once. Reversing it was enough, on its own, to make the prompt read as
     a different screen. *)
  PERMISSION_HTML =
    '<div id="ds-perm-backdrop" style="display:none">' + sLineBreak +
    '  <div id="ds-perm-modal">' + sLineBreak +
    '    <div class="ds-perm-head">' + sLineBreak +
    '      <div class="ds-perm-badge">&#128274;</div>' + sLineBreak +
    '      <div>' + sLineBreak +
    '        <div class="ds-perm-title">Permission required</div>' + sLineBreak +
    '        <div class="ds-perm-sub">The AI wants to run an action that ' +
    '<b>changes project files</b>. You decide whether it can.</div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <button class="ds-perm-close" id="ds-perm-close" type="button">&times;</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-perm-body">' + sLineBreak +
    '      <div class="ds-perm-toolrow">' +
    '<span class="ds-perm-tool" id="ds-perm-tool">tool</span>' +
    '<span class="ds-perm-hint">Aefos MCP tool</span></div>' + sLineBreak +
    '      <div class="ds-perm-what" id="ds-perm-what"></div>' + sLineBreak +
    '      <div class="ds-perm-detlabel">PREVIEW</div>' + sLineBreak +
    '      <div class="ds-perm-detail" id="ds-perm-detail"></div>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-perm-foot">' + sLineBreak +
    '      <span class="ds-perm-hint">Safe default: <b>Deny</b>.</span>' + sLineBreak +
    '      <span class="ds-perm-spacer"></span>' + sLineBreak +
    '      <button class="ds-perm-act ds-perm-deny" id="ds-perm-deny" type="button">Deny</button>' + sLineBreak +
    '      <button class="ds-perm-act" id="ds-perm-session" type="button">' +
    'Allow for this session</button>' + sLineBreak +
    '      <button class="ds-perm-act ds-perm-primary" id="ds-perm-once" type="button">' +
    'Allow once</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '  </div>' + sLineBreak +
    '</div>' + sLineBreak;

  (* The behaviour. Every exit that is not an explicit allow posts "perm:deny",
     so the Pascal side always resolves its slot instead of sitting on the
     timeout -- and BOTH hosts read the same three messages. Adding a fourth
     message here would reach the chat panel too, where anything under "perm:"
     that is not an allow counts as a denial. *)
  PERMISSION_JS =
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var bd = document.getElementById("ds-perm-backdrop");' + sLineBreak +
    '  var toolEl = document.getElementById("ds-perm-tool");' + sLineBreak +
    '  var whatEl = document.getElementById("ds-perm-what");' + sLineBreak +
    '  var detEl = document.getElementById("ds-perm-detail");' + sLineBreak +
    '  function post(msg){ try{ if(window.chrome && window.chrome.webview){ ' +
    'window.chrome.webview.postMessage(msg); } }catch(e){} }' + sLineBreak +
    '  window.dsShowPermission = function(d){' + sLineBreak +
    '    d = d || {};' + sLineBreak +
    '    if(toolEl){ toolEl.textContent = d.tool || "?"; }' + sLineBreak +
    '    if(whatEl){ whatEl.textContent = d.summary || ""; }' + sLineBreak +
    '    if(detEl){ detEl.textContent = d.detail || ""; }' + sLineBreak +
    '    if(bd){ bd.style.display = ""; }' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsHidePermission = function(){ if(bd){ bd.style.display = "none"; } };' + sLineBreak +
    '  function decide(kind){ post("perm:" + kind); window.dsHidePermission(); }' + sLineBreak +
    '  var denyEl = document.getElementById("ds-perm-deny");' + sLineBreak +
    '  var sesEl = document.getElementById("ds-perm-session");' + sLineBreak +
    '  var onceEl = document.getElementById("ds-perm-once");' + sLineBreak +
    '  if(denyEl){ denyEl.addEventListener("click", function(){ decide("deny"); }); }' + sLineBreak +
    '  if(sesEl){ sesEl.addEventListener("click", function(){ decide("session"); }); }' + sLineBreak +
    '  if(onceEl){ onceEl.addEventListener("click", function(){ decide("once"); }); }' + sLineBreak +
    '  var closeEl = document.getElementById("ds-perm-close");' + sLineBreak +
    '  if(closeEl){ closeEl.addEventListener("click", function(){ decide("deny"); }); }' + sLineBreak +
    '  if(bd){ bd.addEventListener("click", function(e){ ' +
    'if(e.target === bd){ decide("deny"); } }); }' + sLineBreak +
    '  document.addEventListener("keydown", function(e){' + sLineBreak +
    '    if(bd && bd.style.display !== "none" && e.key === "Escape"){ decide("deny"); }' + sLineBreak +
    '  });' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak;

  (* The card's own animation. Declared with the card because the standalone
     document needs it and must not drag the whole panel stylesheet in for one
     keyframe. PANEL_CSS keeps its own copy of ds-mem-pop for the memory modal. *)
  PERMISSION_KEYFRAMES =
    '@keyframes ds-mem-pop { from { transform: translateY(8px) scale(.98); ' +
    'opacity: 0; } to { transform: none; opacity: 1; } }' + sLineBreak;

  (* PANEL_CSS: project-owned, hand-editable. Chrome colors use CSS custom
     properties injected by BuildShell(ATheme). Code-block pre/code rules keep
     the generated HIGHLIGHT_CSS dark palette by design (ESP C-2/BR-5). *)
  PANEL_CSS: string =
    '* { box-sizing: border-box; }' + sLineBreak +
    'html, body { margin: 0; padding: 0; }' + sLineBreak +
    'html { height: 100%; }' + sLineBreak +
    (* body uses min-height (NOT height): with box-sizing border-box, height:100%
       fixes the height and the padding-bottom stays INSIDE it -> it does not
       become scroll space, and the last line hides behind the fixed composer even
       with the bar at the bottom. min-height lets the body grow with the content +
       padding = real scroll to the end. (html keeps height:100% so the body's %
       resolves.) *)
    'body { min-height: 100%; ' +
    'font-family: "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif; ' +
    'font-size: 13.5px; -webkit-font-smoothing: antialiased; ' +
    'background: var(--ds-bg, #1e1e1e); color: var(--ds-fg, #d4d4d4); }' + sLineBreak +
    'main { padding: 14px 18px 10px; line-height: 1.6; color: var(--ds-fg); }' + sLineBreak +
    'h1, h2, h3 { color: var(--ds-fg); font-weight: 600; ' +
    'line-height: 1.3; margin: 0.85em 0 0.35em; }' + sLineBreak +
    'h1 { font-size: 1.3em; } h2 { font-size: 1.15em; } h3 { font-size: 1.02em; }' + sLineBreak +
    'p { margin: 0.5em 0; }' + sLineBreak +
    'a { color: var(--ds-accent); text-decoration: none; }' + sLineBreak +
    'a:hover { text-decoration: underline; }' + sLineBreak +
    'pre { background: var(--ds-code-bg, #1b1b1f); ' +
    'border: 1px solid var(--ds-border); padding: 12px 14px; ' +
    'border-radius: 10px; overflow-x: auto; margin: 0.6em 0; }' + sLineBreak +
    'pre code { font-family: "Cascadia Code", Consolas, monospace; ' +
    'font-size: 12.5px; line-height: 1.5; color: #ce9178; ' +
    'background: none; padding: 0; }' + sLineBreak +
    'code { background: rgba(127,127,127,0.18); padding: 1.5px 5px; ' +
    'border-radius: 5px; font-family: "Cascadia Code", Consolas, monospace; ' +
    'font-size: 0.9em; }' + sLineBreak +
    'footer { padding: 10px 18px; border-top: 1px solid var(--ds-border); ' +
    'color: var(--ds-secondary); font-size: 12px; }' + sLineBreak +
    '.error { color: var(--ds-accent); }' + sLineBreak +
    '#ds-feed { padding: 10px 18px 0; }' + sLineBreak +
    '.ds-user { display: block; background: var(--ds-user-bg); ' +
    'color: var(--ds-user-fg); padding: 9px 13px; ' +
    'border-radius: 13px 13px 4px 13px; margin: 6px 0 10px auto; ' +
    'max-width: 86%; width: fit-content; font-style: normal; ' +
    'overflow-wrap: anywhere; word-break: break-word; white-space: pre-wrap; ' +
    'box-shadow: 0 1px 3px rgba(0,0,0,0.28); }' + sLineBreak +
    '.ds-msg { margin: 2px 0 16px; line-height: 1.6; color: var(--ds-fg); }' + sLineBreak +
    '.ds-msg:last-of-type { margin-bottom: 6px; }' + sLineBreak +
    '.ds-typing { display: flex; align-items: center; gap: 9px; ' +
    'color: var(--ds-secondary); padding: 10px 20px; font-style: normal; ' +
    'opacity: 0.92; font-size: 13px; }' + sLineBreak +
    '#ds-footer { padding: 2px 20px 10px; font-size: 12px; ' +
    'color: var(--ds-secondary); }' + sLineBreak +
    (* send-during-run queue counter, between the typing line and the footer *)
    '#ds-queued { padding: 0 20px 4px; font-size: 12px; ' +
    'color: var(--ds-warn); }' + sLineBreak +
    '.ds-typing .ds-gear { font-size: 15px; line-height: 1; flex: none; ' +
    'color: var(--ds-accent); display: inline-flex; ' +
    'animation: ds-think 1.5s ease-in-out infinite; ' +
    'transform-origin: 50% 50%; }' + sLineBreak +
    '@keyframes ds-think { 0%, 100% { transform: scale(1); opacity: 0.6; } ' +
    '50% { transform: scale(1.25); opacity: 1; } }' + sLineBreak +
    '::-webkit-scrollbar { width: 10px; height: 10px; }' + sLineBreak +
    '::-webkit-scrollbar-thumb { background: var(--ds-border); ' +
    'border-radius: 6px; border: 2px solid transparent; ' +
    'background-clip: content-box; }' + sLineBreak +
    '::-webkit-scrollbar-thumb:hover { background: var(--ds-secondary); ' +
    'background-clip: content-box; }' + sLineBreak +
    '::-webkit-scrollbar-track { background: transparent; }' + sLineBreak +
    (* ---- Header HTML fixed at the top (replaces FHeaderPanel + FSessionPanel
       VCL): Chat|Agent toggle + actions (new session / sessions / config) +
       context line. Total height ~68px, mirrored in the body's padding-top
       and in the inset-top of #ds-empty below. ---- *)
    '#ds-header { position: fixed; left: 0; right: 0; top: 0; z-index: 35; ' +
    'background: var(--ds-bg); }' + sLineBreak +
    '#ds-header .ds-hd { display: flex; align-items: center; gap: 10px; ' +
    'padding: 8px 12px; border-bottom: 1px solid var(--ds-border); }' + sLineBreak +
    '#ds-header .ds-hd-spark { color: var(--ds-accent); font-size: 16px; ' +
    'line-height: 1; }' + sLineBreak +
    '#ds-header .ds-hd-seg { display: flex; background: var(--ds-code-bg, #1b1b1f); ' +
    'border: 1px solid var(--ds-border); border-radius: 9px; padding: 2px; }' + sLineBreak +
    '#ds-header .ds-hd-seg button { border: none; background: none; ' +
    'color: var(--ds-secondary); font: inherit; font-size: 12.5px; ' +
    'font-weight: 600; padding: 4px 12px; border-radius: 7px; cursor: pointer; }' + sLineBreak +
    '#ds-header .ds-hd-seg button.ds-hd-on { color: #fff; ' +
    'background: linear-gradient(135deg, var(--ds-blue), var(--ds-blue-2)); }' + sLineBreak +
    '#ds-header .ds-hd-sp { flex: 1; }' + sLineBreak +
    '#ds-header .ds-hd-btn { width: 32px; height: 32px; border-radius: 8px; ' +
    'border: 1px solid var(--ds-border); background: var(--ds-code-bg, #1b1b1f); ' +
    'color: var(--ds-secondary); display: grid; place-items: center; ' +
    'font-size: 15px; line-height: 1; cursor: pointer; padding: 0; }' + sLineBreak +
    '#ds-header .ds-hd-btn:hover { color: var(--ds-fg); ' +
    'border-color: rgba(255,255,255,0.18); }' + sLineBreak +
    '#ds-header .ds-hd-btn.ds-hd-accent { color: var(--ds-accent); ' +
    'border-color: rgba(var(--ds-blue-rgb),0.4); background: rgba(var(--ds-blue-rgb),0.08); }' + sLineBreak +
    (* Persistent Trial badge: a clickable amber pill (urgency without per-action
       nags). Hidden via inline display:none until Pascal sets the text. *)
    '#ds-header .ds-hd-trial { border: 1px solid rgba(245,166,35,0.45); ' +
    'background: rgba(245,166,35,0.14); color: #f5a623; cursor: pointer; ' +
    'font: 600 11px/1 inherit; padding: 5px 10px; border-radius: 999px; ' +
    'white-space: nowrap; letter-spacing: 0.2px; }' + sLineBreak +
    '#ds-header .ds-hd-trial:hover { background: rgba(245,166,35,0.22); ' +
    'border-color: rgba(245,166,35,0.7); }' + sLineBreak +
    '.ds-hd-model { position: relative; }' + sLineBreak +
    '.ds-hd-effort { position: relative; }' + sLineBreak +
    '.ds-hd-mbtn { display: flex; align-items: center; gap: 5px; height: 28px; ' +
    'padding: 0 10px; border-radius: 8px; border: 1px solid var(--ds-border); ' +
    'background: var(--ds-code-bg, #1b1b1f); color: var(--ds-secondary); font: inherit; ' +
    'font-size: 12px; cursor: pointer; max-width: 240px; }' + sLineBreak +
    '.ds-hd-mbtn:hover { color: var(--ds-fg); border-color: rgba(var(--ds-blue-rgb),0.5); }' + sLineBreak +
    '#ds-hd-model-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }' + sLineBreak +
    '.ds-hd-mlist { position: absolute; top: calc(100% + 4px); left: 0; z-index: 40; ' +
    'min-width: 200px; max-height: 280px; overflow: auto; background: var(--ds-code-bg, #171a21); ' +
    'border: 1px solid var(--ds-border); border-radius: 10px; ' +
    'box-shadow: 0 12px 34px rgba(0,0,0,0.5); padding: 5px; }' + sLineBreak +
    '.ds-hd-mlist.ds-hd-mup { top: auto; bottom: calc(100% + 6px); left: auto; right: 0; }' + sLineBreak +
    '.ds-hd-mitem { padding: 7px 10px; border-radius: 7px; font-size: 12.5px; ' +
    'color: var(--ds-fg); cursor: pointer; white-space: nowrap; display: flex; ' +
    'align-items: center; gap: 8px; }' + sLineBreak +
    '.ds-hd-mitem:hover { background: rgba(var(--ds-blue-rgb),0.14); }' + sLineBreak +
    '.ds-hd-mitem.on { color: var(--ds-accent); }' + sLineBreak +
    '.ds-hd-mck { width: 12px; flex: none; color: var(--ds-accent); }' + sLineBreak +
    (* action bar below the prompt: attach / memory / MCP + model selector *)
    '#ds-composer .ds-actbar { display: flex; align-items: center; gap: 6px; padding: 7px 4px 2px; }' + sLineBreak +
    '#ds-composer .ds-act-sp { flex: 1; }' + sLineBreak +
    '#ds-ctx { display: flex; align-items: center; gap: 8px; padding: 7px 14px; ' +
    'border-bottom: 1px solid var(--ds-border); font-size: 12px; ' +
    'color: var(--ds-secondary); }' + sLineBreak +
    '#ds-ctx .ds-ctx-dot { width: 7px; height: 7px; border-radius: 50%; ' +
    'background: var(--ds-success); flex: none; }' + sLineBreak +
    '#ds-ctx .ds-ctx-title { color: var(--ds-fg); font-weight: 600; ' +
    'white-space: nowrap; overflow: hidden; text-overflow: ellipsis; ' +
    'max-width: 55%; }' + sLineBreak +
    '#ds-ctx .ds-ctx-sp { flex: 1; }' + sLineBreak +
    (* ---- Composer (input bar HTML no rodape; substitui o input VCL) ---- *)
    'body { padding-top: 68px; padding-bottom: 100px; }' + sLineBreak +
    '#ds-composer { position: fixed; left: 0; right: 0; bottom: 0; z-index: 30; ' +
    'padding: 10px 12px 12px; background: var(--ds-bg); ' +
    'border-top: 1px solid var(--ds-border); }' + sLineBreak +
    '#ds-composer .ds-inbar { display: flex; align-items: flex-end; gap: 8px; ' +
    'background: var(--ds-code-bg, #1b1b1f); border: 1px solid var(--ds-border); ' +
    'border-radius: 14px; padding: 6px 6px 6px 10px; ' +
    'transition: border-color .15s ease, box-shadow .15s ease; }' + sLineBreak +
    '#ds-composer .ds-inbar:focus-within { border-color: rgba(var(--ds-blue-rgb),0.6); ' +
    'box-shadow: 0 0 0 3px rgba(var(--ds-blue-rgb),0.12); }' + sLineBreak +
    '#ds-composer .ds-attach-btn { flex-shrink: 0; width: 30px; height: 30px; ' +
    'display: grid; place-items: center; border-radius: 8px; ' +
    'color: var(--ds-secondary); cursor: pointer; background: none; border: none; }' + sLineBreak +
    '#ds-composer .ds-attach-btn:hover { color: var(--ds-fg); ' +
    'background: rgba(127,127,127,0.12); }' + sLineBreak +
    (* ---- Attachment chips (paperclip / pasted image): square card + X overlay ---- *)
    '#ds-attachbar { display: flex; flex-wrap: wrap; gap: 10px; padding: 4px 6px 9px; }' + sLineBreak +
    '#ds-attachbar:empty { display: none; }' + sLineBreak +
    '#ds-attachbar .ds-chip { position: relative; width: 54px; height: 54px; flex: none; }' + sLineBreak +
    '#ds-attachbar .ds-chip-card { width: 100%; height: 100%; border-radius: 10px; ' +
    'border: 1px solid var(--ds-border); background: var(--ds-code-bg, #1c2029); ' +
    'overflow: hidden; display: flex; flex-direction: column; align-items: center; ' +
    'justify-content: center; gap: 2px; }' + sLineBreak +
    '#ds-attachbar .ds-chip-card img { width: 100%; height: 100%; object-fit: cover; display: block; }' + sLineBreak +
    '#ds-attachbar .ds-chip-ic { font-size: 20px; line-height: 1; }' + sLineBreak +
    '#ds-attachbar .ds-chip-nm { font-size: 8.5px; color: var(--ds-secondary); ' +
    'max-width: 48px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; padding: 0 3px; }' + sLineBreak +
    '#ds-attachbar .ds-chip-x { position: absolute; top: -7px; right: -7px; width: 19px; ' +
    'height: 19px; border-radius: 50%; border: 2px solid var(--ds-bg); ' +
    'background: rgba(20,22,28,0.92); color: #fff; font-size: 13px; line-height: 1; ' +
    'cursor: pointer; padding: 0; display: grid; place-items: center; }' + sLineBreak +
    '#ds-attachbar .ds-chip-x:hover { background: #e0664a; }' + sLineBreak +
    '#ds-composer #ds-input { flex: 1; border: none; outline: none; background: none; ' +
    'color: var(--ds-fg, #d4d4d4); resize: none; font: inherit; font-size: 13.5px; ' +
    'line-height: 1.5; max-height: 120px; padding: 6px 2px; overflow-y: auto; }' + sLineBreak +
    '#ds-composer #ds-input::placeholder { color: var(--ds-secondary); }' + sLineBreak +
    '#ds-composer .ds-send-btn { flex-shrink: 0; width: 34px; height: 34px; ' +
    'display: grid; place-items: center; border-radius: 10px; border: none; ' +
    'cursor: pointer; color: #fff; background: linear-gradient(160deg, var(--ds-primary-hi), var(--ds-primary-lo)); ' +
    'box-shadow: 0 2px 8px -2px rgba(var(--ds-primary-rgb),0.55); }' + sLineBreak +
    '#ds-composer .ds-send-btn:hover { filter: brightness(1.08); }' + sLineBreak +
    '#ds-composer .ds-send-btn svg { width: 17px; height: 17px; }' + sLineBreak +
    (* ---- Empty-state (zero-state of the feed): hero + 6 action cards ---- *)
    '#ds-empty { position: fixed; inset: 68px 0 100px 0; z-index: 5; display: flex; ' +
    'flex-direction: column; align-items: center; justify-content: safe center; ' +
    'overflow-y: auto; padding: 16px 16px 22px; text-align: center; ' +
    'background: radial-gradient(1200px 480px at 50% -8%, rgba(var(--ds-blue-rgb),0.10), transparent 60%), var(--ds-bg); ' +
    'animation: ds-rise .5s cubic-bezier(.2,.7,.2,1) both; }' + sLineBreak +
    '@keyframes ds-rise { from { opacity: 0; transform: translateY(10px); } ' +
    'to { opacity: 1; transform: none; } }' + sLineBreak +
    '#ds-empty .ds-logo { width: 210px; height: 210px; margin-bottom: 4px; ' +
    'object-fit: contain; ' +
    'filter: drop-shadow(0 6px 26px rgba(var(--ds-blue-rgb),0.40)); ' +
    'animation: ds-pulse 2.6s ease-in-out infinite; }' + sLineBreak +
    '@keyframes ds-pulse { 0%,100% { filter: drop-shadow(0 6px 26px rgba(var(--ds-blue-rgb),0.32)); ' +
    'transform: translateY(0); } 50% { filter: drop-shadow(0 6px 40px rgba(var(--ds-blue-rgb),0.55)); ' +
    'transform: translateY(-2px); } }' + sLineBreak +
    '#ds-empty .ds-title { font-size: 1.18em; font-weight: 600; line-height: 1.25; ' +
    'letter-spacing: .2px; margin: 0 0 4px; ' +
    'background: linear-gradient(180deg, var(--ds-fg), var(--ds-secondary)); ' +
    '-webkit-background-clip: text; background-clip: text; ' +
    '-webkit-text-fill-color: transparent; }' + sLineBreak +
    '#ds-empty .ds-sub { font-size: .88em; color: var(--ds-secondary); ' +
    'margin: 0 0 15px; max-width: 32ch; }' + sLineBreak +
    '#ds-empty .ds-grid { display: grid; gap: 8px; width: 100%; max-width: 460px; ' +
    'grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); }' + sLineBreak +
    '#ds-empty .ds-card { position: relative; overflow: hidden; display: flex; ' +
    'flex-direction: row; align-items: center; gap: 10px; ' +
    'padding: 10px 12px; text-align: left; ' +
    'background: linear-gradient(160deg, rgba(127,127,127,0.10), rgba(127,127,127,0.05)); ' +
    'border: 1px solid var(--ds-border); border-radius: 14px; cursor: pointer; ' +
    'color: inherit; font-family: inherit; ' +
    'transition: transform .16s ease, border-color .16s ease, box-shadow .16s ease; }' + sLineBreak +
    '#ds-empty .ds-card::after { content: ""; position: absolute; inset: 0; ' +
    'background: radial-gradient(120px 80px at 18px 14px, rgba(var(--ds-blue-rgb),0.16), transparent 70%); ' +
    'opacity: 0; transition: opacity .18s ease; }' + sLineBreak +
    '#ds-empty .ds-card:hover { transform: translateY(-3px); ' +
    'border-color: rgba(var(--ds-blue-rgb),0.55); ' +
    'box-shadow: 0 8px 22px -8px rgba(0,0,0,0.6), 0 0 0 1px rgba(var(--ds-blue-rgb),0.18) inset; }' + sLineBreak +
    '#ds-empty .ds-card:hover::after { opacity: 1; }' + sLineBreak +
    '#ds-empty .ds-card:active { transform: translateY(-1px); }' + sLineBreak +
    '#ds-empty .ds-ico { width: 28px; height: 28px; flex-shrink: 0; display: grid; ' +
    'place-items: center; border-radius: 8px; color: var(--ds-blue); ' +
    'background: rgba(var(--ds-blue-rgb),0.10); border: 1px solid rgba(var(--ds-blue-rgb),0.22); }' + sLineBreak +
    '#ds-empty .ds-ico svg { width: 17px; height: 17px; }' + sLineBreak +
    '#ds-empty .ds-card h4 { margin: 0; font-size: .9em; font-weight: 600; ' +
    'color: var(--ds-fg); }' + sLineBreak +
    '#ds-empty .ds-foot { margin-top: 14px; font-size: .78em; ' +
    'color: var(--ds-secondary); display: flex; align-items: center; gap: 7px; }' + sLineBreak +
    '#ds-empty .ds-dot { width: 8px; height: 8px; border-radius: 50%; ' +
    'background: var(--ds-success); box-shadow: 0 0 8px rgba(var(--ds-success-rgb),0.7); }' + sLineBreak +
    (* ---- Memory modal (gatilho cerebro + /memory): backdrop + card ---- *)
    '#ds-composer .ds-mem-btn { flex-shrink: 0; width: 30px; height: 30px; ' +
    'display: grid; place-items: center; border-radius: 8px; font-size: 17px; ' +
    'line-height: 1; color: var(--ds-blue); cursor: pointer; background: none; ' +
    'border: none; padding: 0; }' + sLineBreak +
    '#ds-composer .ds-mem-btn:hover { background: rgba(var(--ds-blue-rgb),0.14); }' + sLineBreak +
    '#ds-mem-backdrop { position: fixed; inset: 0; z-index: 60; ' +
    'background: rgba(6,7,10,0.62); backdrop-filter: blur(3px); ' +
    'display: grid; place-items: center; }' + sLineBreak +
    '#ds-mem-modal { width: min(540px, 92vw); ' +
    'background: var(--ds-code-bg, #171a21); border: 1px solid var(--ds-border); ' +
    'border-radius: 16px; box-shadow: 0 24px 70px rgba(0,0,0,0.55); ' +
    'overflow: hidden; animation: ds-mem-pop .18s ease; }' + sLineBreak +
    '@keyframes ds-mem-pop { from { transform: translateY(8px) scale(.98); ' +
    'opacity: 0; } to { transform: none; opacity: 1; } }' + sLineBreak +
    '#ds-mem-modal .ds-mem-head { display: flex; align-items: flex-start; ' +
    'gap: 13px; padding: 20px 22px 14px; }' + sLineBreak +
    '#ds-mem-modal .ds-mem-badge { width: 42px; height: 42px; border-radius: 11px; ' +
    'flex: none; display: grid; place-items: center; font-size: 21px; ' +
    'background: linear-gradient(135deg, rgba(var(--ds-blue-rgb),0.22), rgba(var(--ds-blue-rgb),0.05)); ' +
    'border: 1px solid rgba(var(--ds-blue-rgb),0.32); }' + sLineBreak +
    '#ds-mem-modal .ds-mem-title { font-size: 16px; font-weight: 700; ' +
    'margin: 1px 0 3px; color: var(--ds-fg); }' + sLineBreak +
    '#ds-mem-modal .ds-mem-sub { font-size: 12.5px; color: var(--ds-secondary); ' +
    'line-height: 1.45; }' + sLineBreak +
    '#ds-mem-modal .ds-mem-close { margin-left: auto; color: var(--ds-secondary); ' +
    'font-size: 20px; cursor: pointer; line-height: 1; background: none; ' +
    'border: none; }' + sLineBreak +
    '#ds-mem-modal .ds-mem-body { padding: 4px 22px 8px; }' + sLineBreak +
    '#ds-mem-text { width: 100%; height: 210px; resize: vertical; ' +
    'background: var(--ds-bg); border: 1px solid var(--ds-border); ' +
    'border-radius: 11px; color: var(--ds-fg); font-size: 13.5px; ' +
    'line-height: 1.6; padding: 13px 14px; outline: none; ' +
    'font-family: "Cascadia Code", "Consolas", monospace; }' + sLineBreak +
    '#ds-mem-text:focus { border-color: var(--ds-blue); ' +
    'box-shadow: 0 0 0 3px rgba(var(--ds-blue-rgb),0.16); }' + sLineBreak +
    '#ds-mem-text::placeholder { color: var(--ds-secondary); }' + sLineBreak +
    '#ds-mem-modal .ds-mem-foot { display: flex; align-items: center; gap: 12px; ' +
    'padding: 13px 22px 20px; }' + sLineBreak +
    '#ds-mem-meter { font-size: 12px; color: var(--ds-secondary); ' +
    'display: flex; align-items: center; gap: 7px; }' + sLineBreak +
    '#ds-mem-meter .ds-mem-warn { color: var(--ds-warn); }' + sLineBreak +
    '#ds-mem-modal .ds-mem-spacer { flex: 1; }' + sLineBreak +
    '#ds-mem-modal .ds-mem-act { padding: 9px 18px; border-radius: 10px; ' +
    'font-size: 13.5px; font-weight: 600; cursor: pointer; ' +
    'border: 1px solid var(--ds-border); ' +
    'background: var(--ds-code-bg, #1c2029); color: var(--ds-fg); }' + sLineBreak +
    '#ds-mem-modal .ds-mem-act.ds-mem-primary { border: none; color: #fff; ' +
    'background: linear-gradient(135deg, var(--ds-primary-hi), var(--ds-primary-lo)); ' +
    'box-shadow: 0 6px 18px rgba(var(--ds-primary-rgb),0.32); }' + sLineBreak +
    (* ---- MCP Servers modal (gatilho plug + /mcp): extra MCP servers ---- *)
    '#ds-mcp-backdrop { position: fixed; inset: 0; z-index: 61; ' +
    'background: rgba(6,7,10,0.62); backdrop-filter: blur(3px); ' +
    'display: grid; place-items: center; }' + sLineBreak +
    '#ds-mcp-modal { width: min(640px, 94vw); ' +
    'background: var(--ds-code-bg, #171a21); border: 1px solid var(--ds-border); ' +
    'border-radius: 16px; box-shadow: 0 24px 70px rgba(0,0,0,0.55); ' +
    'overflow: hidden; animation: ds-mem-pop .18s ease; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-head { display: flex; align-items: flex-start; ' +
    'gap: 13px; padding: 18px 22px 12px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-badge { width: 42px; height: 42px; border-radius: 11px; ' +
    'flex: none; display: grid; place-items: center; font-size: 20px; ' +
    'background: linear-gradient(135deg, rgba(var(--ds-primary-rgb),0.22), rgba(var(--ds-primary-rgb),0.05)); ' +
    'border: 1px solid rgba(var(--ds-primary-rgb),0.32); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-title { font-size: 16px; font-weight: 700; ' +
    'margin: 1px 0 3px; color: var(--ds-fg); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-sub { font-size: 12.5px; color: var(--ds-secondary); ' +
    'line-height: 1.45; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-close { margin-left: auto; color: var(--ds-secondary); ' +
    'font-size: 20px; cursor: pointer; line-height: 1; background: none; border: none; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-body { padding: 6px 22px 6px; max-height: 60vh; overflow: auto; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-seclabel { font-size: 11px; letter-spacing: 1.2px; ' +
    'font-weight: 700; color: var(--ds-secondary); margin: 10px 2px 8px; }' + sLineBreak +
    // The server LIST scrolls on its own (~3 rows tall) so N installed addons
    // never push "+ Add MCP server" / the footer off-screen; the body max-height
    // stays as the outer guard for the add/edit form.
    '#ds-mcp-modal #ds-mcp-list { max-height: 194px; overflow-y: auto; ' +
    'overscroll-behavior: contain; padding-right: 2px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-srv { display: flex; align-items: center; gap: 12px; ' +
    'background: var(--ds-bg); border: 1px solid var(--ds-border); border-radius: 11px; ' +
    'padding: 11px 13px; margin-bottom: 8px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-dot { width: 9px; height: 9px; border-radius: 50%; ' +
    'flex: none; background: #3fb950; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-nm { font-weight: 600; font-size: 13.5px; color: var(--ds-fg); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-mid { min-width: 0; flex: 1; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-cmd { font-size: 11.5px; color: var(--ds-secondary); ' +
    'font-family: "Cascadia Code","Consolas",monospace; overflow: hidden; ' +
    'text-overflow: ellipsis; white-space: nowrap; margin-top: 2px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-tag { font-size: 10px; font-weight: 700; letter-spacing: .4px; ' +
    'padding: 2px 7px; border-radius: 6px; flex: none; background: rgba(var(--ds-blue-rgb),0.12); ' +
    'color: var(--ds-blue); border: 1px solid rgba(var(--ds-blue-rgb),0.28); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-tag.ds-mcp-http { background: rgba(63,185,80,0.12); ' +
    'color: #7ee08a; border-color: rgba(63,185,80,0.28); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-tag.ds-mcp-lockt { background: rgba(var(--ds-primary-rgb),0.14); ' +
    'color: var(--ds-primary-hi); border-color: rgba(var(--ds-primary-rgb),0.3); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-act { color: var(--ds-secondary); cursor: pointer; ' +
    'padding: 3px 6px; border-radius: 6px; font-size: 14px; background: none; border: none; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-act:hover { color: var(--ds-fg); background: var(--ds-code-bg, #1c2029); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-add { display: flex; align-items: center; justify-content: center; ' +
    'gap: 8px; width: 100%; background: var(--ds-code-bg, #1c2029); border: 1px dashed var(--ds-border); ' +
    'border-radius: 11px; padding: 11px; color: var(--ds-secondary); font-size: 13px; ' +
    'font-weight: 600; cursor: pointer; margin-top: 2px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-add:hover { border-color: var(--ds-blue); color: var(--ds-blue); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-form { background: var(--ds-bg); border: 1px solid var(--ds-blue); ' +
    'border-radius: 12px; padding: 14px 15px; margin-top: 10px; ' +
    'box-shadow: 0 0 0 3px rgba(var(--ds-blue-rgb),0.10); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-ftitle { font-size: 12.5px; font-weight: 700; ' +
    'margin-bottom: 10px; color: var(--ds-fg); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-grid { display: grid; grid-template-columns: 1fr 140px; gap: 10px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-row2 { margin: 9px 0; }' + sLineBreak +
    '#ds-mcp-modal label { display: block; font-size: 11px; color: var(--ds-secondary); ' +
    'margin-bottom: 5px; font-weight: 600; letter-spacing: .2px; }' + sLineBreak +
    '#ds-mcp-modal input { width: 100%; background: var(--ds-code-bg, #1c2029); ' +
    'border: 1px solid var(--ds-border); border-radius: 9px; color: var(--ds-fg); ' +
    'font-size: 13px; padding: 9px 11px; outline: none; ' +
    'font-family: "Cascadia Code","Consolas",monospace; }' + sLineBreak +
    '#ds-mcp-modal input:focus { border-color: var(--ds-blue); ' +
    'box-shadow: 0 0 0 3px rgba(var(--ds-blue-rgb),0.16); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-seg { display: flex; background: var(--ds-code-bg, #1c2029); ' +
    'border: 1px solid var(--ds-border); border-radius: 9px; padding: 3px; height: 37px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-seg-btn { flex: 1; border: none; background: none; ' +
    'color: var(--ds-secondary); font-size: 12.5px; font-weight: 600; border-radius: 7px; cursor: pointer; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-seg-btn.on { background: var(--ds-blue); color: #fff; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-hint { font-size: 11px; color: var(--ds-secondary); ' +
    'margin-top: 7px; line-height: 1.5; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-ffoot { display: flex; gap: 8px; justify-content: flex-end; margin-top: 12px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-foot { display: flex; align-items: center; gap: 10px; ' +
    'padding: 13px 22px 20px; border-top: 1px solid var(--ds-border); margin-top: 8px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-note { font-size: 11.5px; color: var(--ds-secondary); flex: 1; line-height: 1.45; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-btn { padding: 8px 16px; border-radius: 9px; font-size: 13px; ' +
    'font-weight: 600; cursor: pointer; border: 1px solid var(--ds-border); ' +
    'background: var(--ds-code-bg, #1c2029); color: var(--ds-fg); }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-btn.sm { padding: 7px 13px; font-size: 12.5px; }' + sLineBreak +
    '#ds-mcp-modal .ds-mcp-btn.primary { border: none; color: #fff; ' +
    'background: linear-gradient(135deg, var(--ds-primary-hi), var(--ds-primary-lo)); ' +
    'box-shadow: 0 6px 18px rgba(var(--ds-primary-rgb),0.32); }' + sLineBreak +
    (* ---- Command editor (modal "New command"; ADR-250) ---- *)
    '#ds-cmd-backdrop { position: fixed; inset: 0; z-index: 62; ' +
    'background: rgba(6,7,10,0.64); backdrop-filter: blur(3px); ' +
    'display: grid; place-items: center; }' + sLineBreak +
    '#ds-cmd-modal { width: min(580px, 94vw); ' +
    'background: var(--ds-code-bg, #171a21); border: 1px solid var(--ds-border); ' +
    'border-radius: 16px; box-shadow: 0 24px 70px rgba(0,0,0,0.55); ' +
    'overflow: hidden; animation: ds-mem-pop .18s ease; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-head { display: flex; align-items: flex-start; ' +
    'gap: 13px; padding: 18px 22px 12px; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-badge { width: 42px; height: 42px; border-radius: 11px; ' +
    'flex: none; display: grid; place-items: center; font-size: 20px; ' +
    'background: linear-gradient(135deg, rgba(var(--ds-blue-rgb),0.22), rgba(var(--ds-blue-rgb),0.05)); ' +
    'border: 1px solid rgba(var(--ds-blue-rgb),0.32); }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-title { font-size: 16px; font-weight: 700; ' +
    'margin: 1px 0 3px; color: var(--ds-fg); }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-sub { font-size: 12.5px; color: var(--ds-secondary); ' +
    'line-height: 1.45; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-close { margin-left: auto; color: var(--ds-secondary); ' +
    'font-size: 20px; cursor: pointer; line-height: 1; background: none; ' +
    'border: none; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-editwrap { position: relative; margin-left: 8px; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-edit { font-size: 12px; ' +
    'color: var(--ds-blue); background: rgba(var(--ds-blue-rgb),0.08); ' +
    'border: 1px solid rgba(var(--ds-blue-rgb),0.30); border-radius: 8px; ' +
    'padding: 4px 9px; cursor: pointer; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-body { padding: 4px 22px 6px; ' +
    'max-height: 56vh; overflow-y: auto; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-row { margin: 11px 0; }' + sLineBreak +
    '#ds-cmd-modal label { display: block; font-size: 11.5px; ' +
    'color: var(--ds-secondary); margin-bottom: 5px; font-weight: 600; ' +
    'letter-spacing: 0.2px; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-namewrap { display: flex; align-items: center; ' +
    'background: var(--ds-bg); border: 1px solid var(--ds-border); ' +
    'border-radius: 10px; padding: 0 12px; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-slash { color: var(--ds-blue); font-weight: 700; ' +
    'font-size: 15px; font-family: monospace; }' + sLineBreak +
    '#ds-cmd-modal input, #ds-cmd-modal textarea { width: 100%; ' +
    'background: var(--ds-bg); border: 1px solid var(--ds-border); ' +
    'border-radius: 10px; color: var(--ds-fg); font-size: 13.5px; ' +
    'padding: 10px 12px; outline: none; font-family: inherit; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-namewrap input { border: none; background: none; ' +
    'padding: 10px 6px; font-family: monospace; font-size: 14px; }' + sLineBreak +
    '#ds-cmd-prompt { height: 110px; resize: vertical; line-height: 1.55; ' +
    'font-family: "Cascadia Code", "Consolas", monospace; font-size: 13px; }' + sLineBreak +
    '#ds-cmd-modal input:focus, #ds-cmd-modal textarea:focus, ' +
    '#ds-cmd-modal .ds-cmd-namewrap:focus-within { border-color: var(--ds-blue); ' +
    'box-shadow: 0 0 0 3px rgba(var(--ds-blue-rgb),0.16); }' + sLineBreak +
    (* the inner input of namewrap does NOT get its own glow: the box (namewrap)
       already shows focus via :focus-within; without this there are 2 frames. *)
    '#ds-cmd-modal .ds-cmd-namewrap input:focus { box-shadow: none; }' + sLineBreak +
    '#ds-cmd-modal ::placeholder { color: var(--ds-secondary); }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-hint { font-size: 11.5px; color: var(--ds-secondary); ' +
    'margin-top: 6px; line-height: 1.5; }' + sLineBreak +
    (* ---- scope segmented control (Project | Global) ---- *)
    '#ds-cmd-modal .ds-cmd-scope { display: inline-flex; gap: 4px; ' +
    'background: var(--ds-bg); border: 1px solid var(--ds-border); ' +
    'border-radius: 10px; padding: 4px; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-scopebtn { font-size: 12.5px; font-weight: 600; ' +
    'color: var(--ds-secondary); background: none; border: none; ' +
    'border-radius: 7px; padding: 7px 14px; cursor: pointer; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-scopebtn.ds-scope-on { color: #fff; ' +
    'background: linear-gradient(135deg, var(--ds-primary-hi), var(--ds-primary-lo)); }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-err { font-size: 11.5px; color: var(--ds-danger); ' +
    'margin-top: 6px; min-height: 14px; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-foot { display: flex; align-items: center; gap: 10px; ' +
    'padding: 13px 22px 20px; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-del { color: var(--ds-danger); background: none; ' +
    'border: 1px solid rgba(var(--ds-danger-rgb),0.35); border-radius: 9px; ' +
    'padding: 8px 14px; font-size: 12.5px; cursor: pointer; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-spacer { flex: 1; }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-act { padding: 9px 18px; border-radius: 10px; ' +
    'font-size: 13.5px; font-weight: 600; cursor: pointer; ' +
    'border: 1px solid var(--ds-border); ' +
    'background: var(--ds-code-bg, #1c2029); color: var(--ds-fg); }' + sLineBreak +
    '#ds-cmd-modal .ds-cmd-act.ds-cmd-primary { border: none; color: #fff; ' +
    'background: linear-gradient(135deg, var(--ds-primary-hi), var(--ds-primary-lo)); ' +
    'box-shadow: 0 6px 18px rgba(var(--ds-primary-rgb),0.32); }' + sLineBreak +
    '#ds-cmd-list { position: absolute; top: calc(100% + 4px); right: 0; ' +
    'min-width: 220px; max-height: 260px; overflow-y: auto; z-index: 5; ' +
    'background: var(--ds-code-bg, #181618); border: 1px solid var(--ds-border); ' +
    'border-radius: 10px; box-shadow: 0 12px 32px -8px rgba(0,0,0,0.7); ' +
    'text-align: left; }' + sLineBreak +
    '#ds-cmd-list .ds-cmd-li { padding: 8px 12px; cursor: pointer; ' +
    'border-bottom: 1px solid rgba(127,127,127,0.08); }' + sLineBreak +
    '#ds-cmd-list .ds-cmd-li:last-child { border-bottom: none; }' + sLineBreak +
    '#ds-cmd-list .ds-cmd-li:hover { background: rgba(var(--ds-blue-rgb),0.10); }' + sLineBreak +
    '#ds-cmd-list .ds-cmd-li b { font-weight: 600; font-size: 13px; ' +
    'color: var(--ds-fg); }' + sLineBreak +
    '#ds-cmd-list .ds-cmd-li span { display: block; font-size: 11px; ' +
    'color: var(--ds-secondary); white-space: nowrap; overflow: hidden; ' +
    'text-overflow: ellipsis; }' + sLineBreak +
    '#ds-cmd-list .ds-cmd-li-empty { padding: 9px 12px; font-size: 12px; ' +
    'color: var(--ds-secondary); }' + sLineBreak +
    (* The permission card -- spliced from the shared constant above, so the
       standalone window and this panel cannot drift apart. *)
    PERMISSION_CSS +
    (* ---- Slash-command picker (dropdown flutuante ACIMA do input) ---- *)
    '#ds-pick { position: absolute; left: 12px; right: 12px; ' +
    'bottom: calc(100% - 6px); z-index: 40; ' +
    'display: flex; flex-direction: column; max-height: 340px; ' +
    'background: var(--ds-code-bg, #171a21); border: 1px solid var(--ds-border); ' +
    'border-radius: 12px; overflow: hidden; ' +
    'box-shadow: 0 18px 44px rgba(0,0,0,0.55); animation: ds-mem-pop .16s ease; }' +
    sLineBreak +
    '#ds-pick .ds-pick-ph { flex: none; padding: 12px 16px 11px; font-size: 12px; ' +
    'color: var(--ds-secondary); font-weight: 700; letter-spacing: 0.5px; ' +
    'display: flex; align-items: center; gap: 8px; ' +
    'border-bottom: 1px solid rgba(127,127,127,0.10); }' + sLineBreak +
    '#ds-pick .ds-pick-ph svg { opacity: 0.8; }' + sLineBreak +
    '#ds-pick .ds-pick-list { flex: 1 1 auto; min-height: 0; overflow-y: auto; ' +
    'padding: 5px 0; }' + sLineBreak +
    '#ds-pick .ds-pick-foot { flex: none; padding: 8px 14px; font-size: 10.5px; ' +
    'color: var(--ds-secondary); border-top: 1px solid rgba(127,127,127,0.10); ' +
    'display: flex; gap: 14px; align-items: center; }' + sLineBreak +
    '#ds-pick .ds-pick-foot b { color: var(--ds-fg); font-weight: 600; }' + sLineBreak +
    '#ds-pick .ds-pick-item { display: flex; align-items: center; gap: 12px; ' +
    'padding: 12px 16px; cursor: pointer; }' + sLineBreak +
    '#ds-pick .ds-pick-ico { flex: none; width: 18px; height: 18px; ' +
    'color: var(--ds-accent); display: grid; place-items: center; }' + sLineBreak +
    '#ds-pick .ds-pick-ico svg { width: 16px; height: 16px; }' + sLineBreak +
    '#ds-pick .ds-pick-item.ds-pick-sel .ds-pick-ico { color: #bfe0ff; }' + sLineBreak +
    '#ds-pick .ds-pick-item:hover { background: rgba(127,127,127,0.08); }' + sLineBreak +
    '#ds-pick .ds-pick-item.ds-pick-sel { ' +
    'background: linear-gradient(90deg, rgba(var(--ds-blue-rgb),0.22), rgba(var(--ds-blue-rgb),0.10)); ' +
    'box-shadow: inset 0 0 0 1px rgba(var(--ds-blue-rgb),0.45); }' + sLineBreak +
    '#ds-pick .ds-pick-meta { flex: 1; min-width: 0; }' + sLineBreak +
    '#ds-pick .ds-pick-name { font-weight: 600; font-size: 13px; ' +
    'color: var(--ds-fg); }' + sLineBreak +
    '#ds-pick .ds-pick-item.ds-pick-sel .ds-pick-name { color: #bfe0ff; }' + sLineBreak +
    '#ds-pick .ds-pick-desc { font-size: 11px; color: var(--ds-secondary); margin-top: 2px; ' +
    'white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }' + sLineBreak +
    '#ds-pick .ds-pick-badge { flex-shrink: 0; font-size: 0.66em; font-weight: 600; ' +
    'letter-spacing: 0.4px; padding: 2px 7px; border-radius: 20px; ' +
    'text-transform: uppercase; color: var(--ds-secondary); ' +
    'background: rgba(127,127,127,0.10); border: 1px solid var(--ds-border); }' + sLineBreak +
    '#ds-pick .ds-pick-badge.ds-pick-command { color: #9cd2ff; ' +
    'background: rgba(var(--ds-blue-rgb),0.12); border-color: rgba(var(--ds-blue-rgb),0.30); }' + sLineBreak +
    (* ---- Sessions/History panel (dropdown under the clock button) ---- *)
    '#ds-ses { position: fixed; top: 46px; right: 12px; width: 300px; z-index: 55; ' +
    'background: var(--ds-code-bg, #171a21); border: 1px solid var(--ds-border); ' +
    'border-radius: 12px; box-shadow: 0 18px 44px rgba(0,0,0,0.55); ' +
    'overflow: hidden; animation: ds-mem-pop .16s ease; }' + sLineBreak +
    '#ds-ses .ds-ses-ph { padding: 11px 13px 8px; font-size: 12px; ' +
    'color: var(--ds-secondary); font-weight: 700; letter-spacing: 0.4px; ' +
    'display: flex; align-items: center; gap: 7px; }' + sLineBreak +
    '#ds-ses .ds-ses-search { margin: 0 11px 8px; display: flex; align-items: center; ' +
    'gap: 7px; background: var(--ds-bg); border: 1px solid var(--ds-border); ' +
    'border-radius: 9px; padding: 6px 9px; }' + sLineBreak +
    '#ds-ses .ds-ses-search input { flex: 1; background: none; border: none; ' +
    'outline: none; color: var(--ds-fg); font: inherit; font-size: 12.5px; }' + sLineBreak +
    '#ds-ses .ds-ses-search input::placeholder { color: var(--ds-secondary); }' + sLineBreak +
    '#ds-ses .ds-ses-list { max-height: 320px; overflow-y: auto; ' +
    'padding-bottom: 4px; }' + sLineBreak +
    '#ds-ses .ds-ses-empty { padding: 10px 13px 14px; font-size: 12px; ' +
    'color: var(--ds-secondary); }' + sLineBreak +
    '#ds-ses .ds-ses-row { display: flex; gap: 10px; padding: 8px 13px; ' +
    'cursor: pointer; align-items: flex-start; }' + sLineBreak +
    '#ds-ses .ds-ses-row:hover { background: rgba(var(--ds-blue-rgb),0.10); }' + sLineBreak +
    '#ds-ses .ds-ses-row .ds-ses-ri { color: var(--ds-accent); font-size: 13px; ' +
    'margin-top: 1px; flex: none; }' + sLineBreak +
    '#ds-ses .ds-ses-row.ds-ses-cur .ds-ses-ri { color: var(--ds-success); }' + sLineBreak +
    '#ds-ses .ds-ses-rt { flex: 1; min-width: 0; }' + sLineBreak +
    '#ds-ses .ds-ses-rt b { font-size: 13px; font-weight: 600; display: block; ' +
    'white-space: nowrap; overflow: hidden; text-overflow: ellipsis; ' +
    'color: var(--ds-fg); }' + sLineBreak +
    '#ds-ses .ds-ses-rt span { font-size: 11px; color: var(--ds-secondary); }' + sLineBreak +
    '#ds-ses .ds-ses-badge { font-size: 9.5px; background: rgba(var(--ds-success-rgb),0.16); ' +
    'color: var(--ds-success); padding: 1px 6px; border-radius: 5px; align-self: center; ' +
    'font-weight: 700; flex: none; }' + sLineBreak +
    '/* ---- Visual Scanner (project-owned; previewed in' + sLineBreak +
    '   meta/chat/tools/ChatTester/preview-visual-scanner.html) ---------------- */' + sLineBreak +
    '.vs { border: 1px solid var(--ds-border); border-radius: 12px;' + sLineBreak +
    '  background: var(--ds-code-bg); margin: 10px 0 14px; overflow: hidden; }' + sLineBreak +
    '.vs-head { display: flex; align-items: center; gap: 10px; padding: 12px 14px 11px; }' + sLineBreak +
    '.vs-dot { width: 9px; height: 9px; border-radius: 50%; flex: none;' + sLineBreak +
    '  background: var(--ds-secondary); }' + sLineBreak +
    '.vs-live .vs-dot { background: var(--ds-blue);' + sLineBreak +
    '  box-shadow: 0 0 0 0 rgba(var(--ds-blue-rgb), .55); animation: vs-pulse 1.5s infinite; }' + sLineBreak +
    '.vs-ok .vs-dot { background: var(--ds-success); }' + sLineBreak +
    '.vs-bad .vs-dot { background: var(--ds-danger); }' + sLineBreak +
    '.vs-off .vs-dot { background: var(--ds-secondary); }' + sLineBreak +
    '@keyframes vs-pulse { 70% { box-shadow: 0 0 0 7px rgba(var(--ds-blue-rgb), 0); }' + sLineBreak +
    '  100% { box-shadow: 0 0 0 0 rgba(var(--ds-blue-rgb), 0); } }' + sLineBreak +
    '.vs-title { font-weight: 650; font-size: 13px; letter-spacing: .1px; }' + sLineBreak +
    '.vs-status { color: var(--ds-secondary); font-size: 12px; margin-left: auto; }' + sLineBreak +
    '.vs-steps { list-style: none; margin: 0; padding: 2px 14px 12px; }' + sLineBreak +
    '.vs-step { display: flex; align-items: center; gap: 10px; padding: 5px 0;' + sLineBreak +
    '  font-size: 12.5px; color: var(--ds-secondary); }' + sLineBreak +
    '.vs-ico { width: 16px; height: 16px; flex: none; border-radius: 50%; display: grid;' + sLineBreak +
    '  place-items: center; font-size: 10px; line-height: 1;' + sLineBreak +
    '  border: 1.5px solid var(--ds-border); color: transparent; }' + sLineBreak +
    '.vs-step[data-s="pending"] .vs-ico { border-color: var(--ds-border); }' + sLineBreak +
    '.vs-step[data-s="active"] { color: var(--ds-fg); }' + sLineBreak +
    '.vs-step[data-s="active"] .vs-ico { border-color: var(--ds-blue);' + sLineBreak +
    '  border-right-color: transparent; animation: vs-spin .9s linear infinite; }' + sLineBreak +
    '@keyframes vs-spin { to { transform: rotate(360deg); } }' + sLineBreak +
    '.vs-step[data-s="done"] { color: var(--ds-fg); }' + sLineBreak +
    '.vs-step[data-s="done"] .vs-ico { border-color: var(--ds-success);' + sLineBreak +
    '  background: rgba(var(--ds-success-rgb), .14); color: var(--ds-success); }' + sLineBreak +
    '.vs-step[data-s="failed"] { color: var(--ds-fg); }' + sLineBreak +
    '.vs-step[data-s="failed"] .vs-ico { border-color: var(--ds-danger);' + sLineBreak +
    '  background: rgba(var(--ds-danger-rgb), .16); color: var(--ds-danger); }' + sLineBreak +
    '.vs-step[data-s="skipped"] { color: #5a5a5a; }' + sLineBreak +
    '.vs-step[data-s="skipped"] .vs-label { text-decoration: line-through;' + sLineBreak +
    '  text-decoration-color: #4a4a4a; }' + sLineBreak +
    '.vs-step[data-s="skipped"] .vs-ico { border-style: dashed; border-color: #4a4a4a; }' + sLineBreak +
    '.vs-detail { margin: 0 14px 12px; padding: 9px 11px; border-radius: 9px;' + sLineBreak +
    '  font-size: 12px; line-height: 1.45; background: rgba(var(--ds-danger-rgb), .10);' + sLineBreak +
    '  border: 1px solid rgba(var(--ds-danger-rgb), .30); color: var(--ds-fg); }' + sLineBreak +
    '/* The live preview: one small picture of what the agent is looking at,' + sLineBreak +
    '   with the scanner sweeping across it. This is the thing the feature is' + sLineBreak +
    '   NAMED after, and it was the one piece never built -- the card walked' + sLineBreak +
    '   its steps beside a static image.' + sLineBreak +
    '   Capped on purpose: full-width screenshots pushed the whole conversation' + sLineBreak +
    '   off screen -- the card is a STATUS element, not a gallery.' + sLineBreak +
    '   position:relative is LOAD-BEARING. .vs-sweep is absolutely positioned,' + sLineBreak +
    '   so it anchors to its nearest positioned ancestor; without it the sweep' + sLineBreak +
    '   anchors to the PAGE and scans the whole card. Two deleted-by-accident' + sLineBreak +
    '   declaration bodies used to sit above this rule and a browser swallowed' + sLineBreak +
    '   it whole -- Test_PanelCss now walks this stylesheet so that cannot' + sLineBreak +
    '   happen silently again. */' + sLineBreak +
    '.vs-live-shot { position: relative; margin: 0 14px 12px; border-radius: 10px;' + sLineBreak +
    '  overflow: hidden; border: 1px solid var(--ds-border); background: #0d0f13;' + sLineBreak +
    '  max-height: 180px; }' + sLineBreak +
    '.vs-live-shot img { display: block; width: 100%; height: auto;' + sLineBreak +
    '  max-height: 180px; object-fit: contain; object-position: top; opacity: .75; }' + sLineBreak +
    '.vs-sweep { position: absolute; top: 0; bottom: 0; width: 84px;' + sLineBreak +
    '  pointer-events: none; animation: vs-sweep 1.9s ease-in-out infinite;' + sLineBreak +
    '  background: linear-gradient(90deg, rgba(var(--ds-blue-rgb),0) 0%,' + sLineBreak +
    '  rgba(var(--ds-blue-rgb),.30) 45%, rgba(var(--ds-blue-rgb),.85) 50%,' + sLineBreak +
    '  rgba(var(--ds-blue-rgb),.30) 55%, rgba(var(--ds-blue-rgb),0) 100%); }' + sLineBreak +
    '@keyframes vs-sweep { 0% { left: -84px; } 100% { left: 100%; } }' + sLineBreak +
    '/* The sweep is decided in ONE place -- the renderer omits it when the' + sLineBreak +
    '   session is terminal. This rule used to hide it for vs-off too, and' + sLineBreak +
    '   vs-off does not mean finished: it means no step is spinning RIGHT NOW.' + sLineBreak +
    '   A live session between two steps landed there and lost its scan line,' + sLineBreak +
    '   which read as the whole frame having vanished. Two places deciding the' + sLineBreak +
    '   same thing is how they end up disagreeing. */' + sLineBreak;

  // BEGIN GENERATED HIGHLIGHT_CSS
  {
    Source:  https://highlightjs.org/
    Version: 11.11.1
    SHA-256: 3E2EFBD7EFA306BC2078755818E6B5B2337C89D5E5AEB612290548EFE240E789
    License: BSD-3-Clause (Ivan Sagalaev)
    DO NOT EDIT — regenerated by scripts/embed-webview-assets.ps1
  }
  HIGHLIGHT_CSS: string =
    'pre code.hljs{display:block;overflow-x:auto;padding:1em}code.hljs{padding:3px 5px}.hljs{background:#1e1e1e;color:#dcdcdc}.hljs-keyword,.hljs-literal,.hljs-name,.hljs-symbol{color:#569cd6}.hljs-link{color:#569cd6;text-decoration:underline}.hljs-built_' +
    'in,.hljs-type{color:#4ec9b0}.hljs-class,.hljs-number{color:#b8d7a3}.hljs-meta .hljs-string,.hljs-string{color:#d69d85}.hljs-regexp,.hljs-template-tag{color:#9a5334}.hljs-formula,.hljs-function,.hljs-params,.hljs-subst,.hljs-title{color:#dcdcdc}.hljs-' +
    'comment,.hljs-quote{color:#57a64a;font-style:italic}.hljs-doctag{color:#608b4e}.hljs-meta,.hljs-meta .hljs-keyword,.hljs-tag{color:#9b9b9b}.hljs-template-variable,.hljs-variable{color:#bd63c5}.hljs-attr,.hljs-attribute{color:#9cdcfe}.hljs-section{col' +
    'or:gold}.hljs-emphasis{font-style:italic}.hljs-strong{font-weight:700}.hljs-bullet,.hljs-selector-attr,.hljs-selector-class,.hljs-selector-id,.hljs-se' +
    'lector-pseudo,.hljs-selector-tag{color:#d7ba7d}.hljs-addition{background-color:#144212;display:inline-block;width:100%}.hljs-deletion{background-color:#600;display:inline-block;width:100%}';
  // END GENERATED HIGHLIGHT_CSS

  // BEGIN GENERATED MARKED_JS
  {
    Source:  https://github.com/markedjs/marked
    Version: 14.1.4
    SHA-256: 0A0FBF5EA62F007E7EDE02D6F75B4EB142EE8ACB310CD957ED566AF3304C0BCC
    License: MIT (Christopher Jeffrey)
    DO NOT EDIT — regenerated by scripts/embed-webview-assets.ps1

    Upstream license header:
    /**
     * marked v14.1.4 - a markdown parser
     * Copyright (c) 2011-2024, Christopher Jeffrey. (MIT Licensed)
     * https://github.com/markedjs/marked
     */
  }
  MARKED_JS: string =
    '/**' + sLineBreak +
    ' * marked v14.1.4 - a markdown parser' + sLineBreak +
    ' * Copyright (c) 2011-2024, Christopher Jeffrey. (MIT Licensed)' + sLineBreak +
    ' * https://github.com/markedjs/marked' + sLineBreak +
    ' */' + sLineBreak +
    '!function(e,t){"object"==typeof exports&&"undefined"!=typeof module?t(exports):"function"==typeof define&&define.amd?define(["exports"],t):t((e="undefined"!=typeof globalThis?globalThis:e||self).marked={})}(this,(function(e){"use strict";function t()' +
    '{return{async:!1,breaks:!1,extensions:null,gfm:!0,hooks:null,pedantic:!1,renderer:null,silent:!1,tokenizer:null,walkTokens:null}}function n(t){e.defaults=t}e.defaults={async:!1,breaks:!1,extensions:null,gfm:!0,hooks:null,pedantic:!1,renderer:null,sil' +
    'ent:!1,tokenizer:null,walkTokens:null};const s=/[&<>"'']/,r=new RegExp(s.source,"g"),i=/[<>"'']|&(?!(#\d{1,7}|#[Xx][a-fA-F0-9]{1,6}|\w+);)/,l=new RegExp(i.source,"g"),o={"&":"&amp;","<":"&lt;",">":"&gt;",''"'':"&quot;","''":"&#39;"},a=e=>o[e];function c(e' +
    ',t){if(t){if(s.test(e))return e.replace(r,a)}else if(i.test(e))return e.replace(l,a);return e}const h=/(^|[^\[])\^/g;function p(e,t){let n="string"==t' +
    'ypeof e?e:e.source;t=t||"";const s={replace:(e,t)=>{let r="string"==typeof t?t:t.source;return r=r.replace(h,"$1"),n=n.replace(e,r),s},getRegex:()=>new RegExp(n,t)};return s}function u(e){try{e=encodeURI(e).replace(/%25/g,"%")}catch{return null}retur' +
    'n e}const k={exec:()=>null};function g(e,t){const n=e.replace(/\|/g,((e,t,n)=>{let s=!1,r=t;for(;--r>=0&&"\\"===n[r];)s=!s;return s?"|":" |"})).split(/ \|/);let s=0;if(n[0].trim()||n.shift(),n.length>0&&!n[n.length-1].trim()&&n.pop(),t)if(n.length>t)' +
    'n.splice(t);else for(;n.length<t;)n.push("");for(;s<n.length;s++)n[s]=n[s].trim().replace(/\\\|/g,"|");return n}function f(e,t,n){const s=e.length;if(0===s)return"";let r=0;for(;r<s;){const i=e.charAt(s-r-1);if(i!==t||n){if(i===t||!n)break;r++}else r' +
    '++}return e.slice(0,s-r)}function d(e,t,n,s){const r=t.href,i=t.title?c(t.title):null,l=e[1].replace(/\\([\[\]])/g,"$1");if("!"!==e[0].charAt(0)){s.st' +
    'ate.inLink=!0;const e={type:"link",raw:n,href:r,title:i,text:l,tokens:s.inlineTokens(l)};return s.state.inLink=!1,e}return{type:"image",raw:n,href:r,title:i,text:c(l)}}class x{options;rules;lexer;constructor(t){this.options=t||e.defaults}space(e){con' +
    'st t=this.rules.block.newline.exec(e);if(t&&t[0].length>0)return{type:"space",raw:t[0]}}code(e){const t=this.rules.block.code.exec(e);if(t){const e=t[0].replace(/^(?: {1,4}| {0,3}\t)/gm,"");return{type:"code",raw:t[0],codeBlockStyle:"indented",text:t' +
    'his.options.pedantic?e:f(e,"\n")}}}fences(e){const t=this.rules.block.fences.exec(e);if(t){const e=t[0],n=function(e,t){const n=e.match(/^(\s+)(?:```)/);if(null===n)return t;const s=n[1];return t.split("\n").map((e=>{const t=e.match(/^\s+/);if(null==' +
    '=t)return e;const[n]=t;return n.length>=s.length?e.slice(s.length):e})).join("\n")}(e,t[3]||"");return{type:"code",raw:e,lang:t[2]?t[2].trim().replace' +
    '(this.rules.inline.anyPunctuation,"$1"):t[2],text:n}}}heading(e){const t=this.rules.block.heading.exec(e);if(t){let e=t[2].trim();if(/#$/.test(e)){const t=f(e,"#");this.options.pedantic?e=t.trim():t&&!/ $/.test(t)||(e=t.trim())}return{type:"heading",' +
    'raw:t[0],depth:t[1].length,text:e,tokens:this.lexer.inline(e)}}}hr(e){const t=this.rules.block.hr.exec(e);if(t)return{type:"hr",raw:f(t[0],"\n")}}blockquote(e){const t=this.rules.block.blockquote.exec(e);if(t){let e=f(t[0],"\n").split("\n"),n="",s=""' +
    ';const r=[];for(;e.length>0;){let t=!1;const i=[];let l;for(l=0;l<e.length;l++)if(/^ {0,3}>/.test(e[l]))i.push(e[l]),t=!0;else{if(t)break;i.push(e[l])}e=e.slice(l);const o=i.join("\n"),a=o.replace(/\n {0,3}((?:=+|-+) *)(?=\n|$)/g,"\n    $1").replace(' +
    '/^ {0,3}>[ \t]?/gm,"");n=n?`${n}\n${o}`:o,s=s?`${s}\n${a}`:a;const c=this.lexer.state.top;if(this.lexer.state.top=!0,this.lexer.blockTokens(a,r,!0),th' +
    'is.lexer.state.top=c,0===e.length)break;const h=r[r.length-1];if("code"===h?.type)break;if("blockquote"===h?.type){const t=h,i=t.raw+"\n"+e.join("\n"),l=this.blockquote(i);r[r.length-1]=l,n=n.substring(0,n.length-t.raw.length)+l.raw,s=s.substring(0,s' +
    '.length-t.text.length)+l.text;break}if("list"!==h?.type);else{const t=h,i=t.raw+"\n"+e.join("\n"),l=this.list(i);r[r.length-1]=l,n=n.substring(0,n.length-h.raw.length)+l.raw,s=s.substring(0,s.length-t.raw.length)+l.raw,e=i.substring(r[r.length-1].raw' +
    '.length).split("\n")}}return{type:"blockquote",raw:n,tokens:r,text:s}}}list(e){let t=this.rules.block.list.exec(e);if(t){let n=t[1].trim();const s=n.length>1,r={type:"list",raw:"",ordered:s,start:s?+n.slice(0,-1):"",loose:!1,items:[]};n=s?`\\d{1,9}\\' +
    '${n.slice(-1)}`:`\\${n}`,this.options.pedantic&&(n=s?n:"[*+-]");const i=new RegExp(`^( {0,3}${n})((?:[\t ][^\\n]*)?(?:\\n|$))`);let l=!1;for(;e;){let ' +
    'n=!1,s="",o="";if(!(t=i.exec(e)))break;if(this.rules.block.hr.test(e))break;s=t[0],e=e.substring(s.length);let a=t[2].split("\n",1)[0].replace(/^\t+/,(e=>" ".repeat(3*e.length))),c=e.split("\n",1)[0],h=!a.trim(),p=0;if(this.options.pedantic?(p=2,o=a.' +
    'trimStart()):h?p=t[1].length+1:(p=t[2].search(/[^ ]/),p=p>4?1:p,o=a.slice(p),p+=t[1].length),h&&/^[ \t]*$/.test(c)&&(s+=c+"\n",e=e.substring(c.length+1),n=!0),!n){const t=new RegExp(`^ {0,${Math.min(3,p-1)}}(?:[*+-]|\\d{1,9}[.)])((?:[ \t][^\\n]*)?(?:' +
    '\\n|$))`),n=new RegExp(`^ {0,${Math.min(3,p-1)}}((?:- *){3,}|(?:_ *){3,}|(?:\\* *){3,})(?:\\n+|$)`),r=new RegExp(`^ {0,${Math.min(3,p-1)}}(?:\`\`\`|~~~)`),i=new RegExp(`^ {0,${Math.min(3,p-1)}}#`),l=new RegExp(`^ {0,${Math.min(3,p-1)}}<(?:[a-z].*>|!-' +
    '-)`,"i");for(;e;){const u=e.split("\n",1)[0];let k;if(c=u,this.options.pedantic?(c=c.replace(/^ {1,4}(?=( {4})*[^ ])/g,"  "),k=c):k=c.replace(/\t/g," ' +
    '   "),r.test(c))break;if(i.test(c))break;if(l.test(c))break;if(t.test(c))break;if(n.test(c))break;if(k.search(/[^ ]/)>=p||!c.trim())o+="\n"+k.slice(p);else{if(h)break;if(a.replace(/\t/g,"    ").search(/[^ ]/)>=4)break;if(r.test(a))break;if(i.test(a))' +
    'break;if(n.test(a))break;o+="\n"+c}h||c.trim()||(h=!0),s+=u+"\n",e=e.substring(u.length+1),a=k.slice(p)}}r.loose||(l?r.loose=!0:/\n[ \t]*\n[ \t]*$/.test(s)&&(l=!0));let u,k=null;this.options.gfm&&(k=/^\[[ xX]\] /.exec(o),k&&(u="[ ] "!==k[0],o=o.repla' +
    'ce(/^\[[ xX]\] +/,""))),r.items.push({type:"list_item",raw:s,task:!!k,checked:u,loose:!1,text:o,tokens:[]}),r.raw+=s}r.items[r.items.length-1].raw=r.items[r.items.length-1].raw.trimEnd(),r.items[r.items.length-1].text=r.items[r.items.length-1].text.t' +
    'rimEnd(),r.raw=r.raw.trimEnd();for(let e=0;e<r.items.length;e++)if(this.lexer.state.top=!1,r.items[e].tokens=this.lexer.blockTokens(r.items[e].text,[]' +
    '),!r.loose){const t=r.items[e].tokens.filter((e=>"space"===e.type)),n=t.length>0&&t.some((e=>/\n.*\n/.test(e.raw)));r.loose=n}if(r.loose)for(let e=0;e<r.items.length;e++)r.items[e].loose=!0;return r}}html(e){const t=this.rules.block.html.exec(e);if(t' +
    '){return{type:"html",block:!0,raw:t[0],pre:"pre"===t[1]||"script"===t[1]||"style"===t[1],text:t[0]}}}def(e){const t=this.rules.block.def.exec(e);if(t){const e=t[1].toLowerCase().replace(/\s+/g," "),n=t[2]?t[2].replace(/^<(.*)>$/,"$1").replace(this.ru' +
    'les.inline.anyPunctuation,"$1"):"",s=t[3]?t[3].substring(1,t[3].length-1).replace(this.rules.inline.anyPunctuation,"$1"):t[3];return{type:"def",tag:e,raw:t[0],href:n,title:s}}}table(e){const t=this.rules.block.table.exec(e);if(!t)return;if(!/[:|]/.te' +
    'st(t[2]))return;const n=g(t[1]),s=t[2].replace(/^\||\| *$/g,"").split("|"),r=t[3]&&t[3].trim()?t[3].replace(/\n[ \t]*$/,"").split("\n"):[],i={type:"ta' +
    'ble",raw:t[0],header:[],align:[],rows:[]};if(n.length===s.length){for(const e of s)/^ *-+: *$/.test(e)?i.align.push("right"):/^ *:-+: *$/.test(e)?i.align.push("center"):/^ *:-+ *$/.test(e)?i.align.push("left"):i.align.push(null);for(let e=0;e<n.lengt' +
    'h;e++)i.header.push({text:n[e],tokens:this.lexer.inline(n[e]),header:!0,align:i.align[e]});for(const e of r)i.rows.push(g(e,i.header.length).map(((e,t)=>({text:e,tokens:this.lexer.inline(e),header:!1,align:i.align[t]}))));return i}}lheading(e){const ' +
    't=this.rules.block.lheading.exec(e);if(t)return{type:"heading",raw:t[0],depth:"="===t[2].charAt(0)?1:2,text:t[1],tokens:this.lexer.inline(t[1])}}paragraph(e){const t=this.rules.block.paragraph.exec(e);if(t){const e="\n"===t[1].charAt(t[1].length-1)?t' +
    '[1].slice(0,-1):t[1];return{type:"paragraph",raw:t[0],text:e,tokens:this.lexer.inline(e)}}}text(e){const t=this.rules.block.text.exec(e);if(t)return{t' +
    'ype:"text",raw:t[0],text:t[0],tokens:this.lexer.inline(t[0])}}escape(e){const t=this.rules.inline.escape.exec(e);if(t)return{type:"escape",raw:t[0],text:c(t[1])}}tag(e){const t=this.rules.inline.tag.exec(e);if(t)return!this.lexer.state.inLink&&/^<a /' +
    'i.test(t[0])?this.lexer.state.inLink=!0:this.lexer.state.inLink&&/^<\/a>/i.test(t[0])&&(this.lexer.state.inLink=!1),!this.lexer.state.inRawBlock&&/^<(pre|code|kbd|script)(\s|>)/i.test(t[0])?this.lexer.state.inRawBlock=!0:this.lexer.state.inRawBlock&&' +
    '/^<\/(pre|code|kbd|script)(\s|>)/i.test(t[0])&&(this.lexer.state.inRawBlock=!1),{type:"html",raw:t[0],inLink:this.lexer.state.inLink,inRawBlock:this.lexer.state.inRawBlock,block:!1,text:t[0]}}link(e){const t=this.rules.inline.link.exec(e);if(t){const' +
    ' e=t[2].trim();if(!this.options.pedantic&&/^</.test(e)){if(!/>$/.test(e))return;const t=f(e.slice(0,-1),"\\");if((e.length-t.length)%2==0)return}else{' +
    'const e=function(e,t){if(-1===e.indexOf(t[1]))return-1;let n=0;for(let s=0;s<e.length;s++)if("\\"===e[s])s++;else if(e[s]===t[0])n++;else if(e[s]===t[1]&&(n--,n<0))return s;return-1}(t[2],"()");if(e>-1){const n=(0===t[0].indexOf("!")?5:4)+t[1].length' +
    '+e;t[2]=t[2].substring(0,e),t[0]=t[0].substring(0,n).trim(),t[3]=""}}let n=t[2],s="";if(this.options.pedantic){const e=/^([^''"]*[^\s])\s+([''"])(.*)\2/.exec(n);e&&(n=e[1],s=e[3])}else s=t[3]?t[3].slice(1,-1):"";return n=n.trim(),/^</.test(n)&&(n=this.' +
    'options.pedantic&&!/>$/.test(e)?n.slice(1):n.slice(1,-1)),d(t,{href:n?n.replace(this.rules.inline.anyPunctuation,"$1"):n,title:s?s.replace(this.rules.inline.anyPunctuation,"$1"):s},t[0],this.lexer)}}reflink(e,t){let n;if((n=this.rules.inline.reflink.' +
    'exec(e))||(n=this.rules.inline.nolink.exec(e))){const e=t[(n[2]||n[1]).replace(/\s+/g," ").toLowerCase()];if(!e){const e=n[0].charAt(0);return{type:"t' +
    'ext",raw:e,text:e}}return d(n,e,n[0],this.lexer)}}emStrong(e,t,n=""){let s=this.rules.inline.emStrongLDelim.exec(e);if(!s)return;if(s[3]&&n.match(/[\p{L}\p{N}]/u))return;if(!(s[1]||s[2]||"")||!n||this.rules.inline.punctuation.exec(n)){const n=[...s[0' +
    ']].length-1;let r,i,l=n,o=0;const a="*"===s[0][0]?this.rules.inline.emStrongRDelimAst:this.rules.inline.emStrongRDelimUnd;for(a.lastIndex=0,t=t.slice(-1*e.length+n);null!=(s=a.exec(t));){if(r=s[1]||s[2]||s[3]||s[4]||s[5]||s[6],!r)continue;if(i=[...r]' +
    '.length,s[3]||s[4]){l+=i;continue}if((s[5]||s[6])&&n%3&&!((n+i)%3)){o+=i;continue}if(l-=i,l>0)continue;i=Math.min(i,i+l+o);const t=[...s[0]][0].length,a=e.slice(0,n+s.index+t+i);if(Math.min(n,i)%2){const e=a.slice(1,-1);return{type:"em",raw:a,text:e,' +
    'tokens:this.lexer.inlineTokens(e)}}const c=a.slice(2,-2);return{type:"strong",raw:a,text:c,tokens:this.lexer.inlineTokens(c)}}}}codespan(e){const t=th' +
    'is.rules.inline.code.exec(e);if(t){let e=t[2].replace(/\n/g," ");const n=/[^ ]/.test(e),s=/^ /.test(e)&&/ $/.test(e);return n&&s&&(e=e.substring(1,e.length-1)),e=c(e,!0),{type:"codespan",raw:t[0],text:e}}}br(e){const t=this.rules.inline.br.exec(e);if' +
    '(t)return{type:"br",raw:t[0]}}del(e){const t=this.rules.inline.del.exec(e);if(t)return{type:"del",raw:t[0],text:t[2],tokens:this.lexer.inlineTokens(t[2])}}autolink(e){const t=this.rules.inline.autolink.exec(e);if(t){let e,n;return"@"===t[2]?(e=c(t[1]' +
    '),n="mailto:"+e):(e=c(t[1]),n=e),{type:"link",raw:t[0],text:e,href:n,tokens:[{type:"text",raw:e,text:e}]}}}url(e){let t;if(t=this.rules.inline.url.exec(e)){let e,n;if("@"===t[2])e=c(t[0]),n="mailto:"+e;else{let s;do{s=t[0],t[0]=this.rules.inline._bac' +
    'kpedal.exec(t[0])?.[0]??""}while(s!==t[0]);e=c(t[0]),n="www."===t[1]?"http://"+t[0]:t[0]}return{type:"link",raw:t[0],text:e,href:n,tokens:[{type:"text' +
    '",raw:e,text:e}]}}}inlineText(e){const t=this.rules.inline.text.exec(e);if(t){let e;return e=this.lexer.state.inRawBlock?t[0]:c(t[0]),{type:"text",raw:t[0],text:e}}}}const b=/^ {0,3}((?:-[\t ]*){3,}|(?:_[ \t]*){3,}|(?:\*[ \t]*){3,})(?:\n+|$)/,w=/(?:[' +
    '*+-]|\d{1,9}[.)])/,m=p(/^(?!bull |blockCode|fences|blockquote|heading|html)((?:.|\n(?!\s*?\n|bull |blockCode|fences|blockquote|heading|html))+?)\n {0,3}(=+|-+) *(?:\n+|$)/).replace(/bull/g,w).replace(/blockCode/g,/(?: {4}| {0,3}\t)/).replace(/fences/' +
    'g,/ {0,3}(?:`{3,}|~{3,})/).replace(/blockquote/g,/ {0,3}>/).replace(/heading/g,/ {0,3}#{1,6}/).replace(/html/g,/ {0,3}<[^\n>]+>\n/).getRegex(),y=/^([^\n]+(?:\n(?!hr|heading|lheading|blockquote|fences|list|html|table| +\n)[^\n]+)*)/,$=/(?!\s*\])(?:\\.' +
    '|[^\[\]\\])+/,z=p(/^ {0,3}\[(label)\]: *(?:\n[ \t]*)?([^<\s][^\s]*|<.*?>)(?:(?: +(?:\n[ \t]*)?| *\n[ \t]*)(title))? *(?:\n+|$)/).replace("label",$).re' +
    'place("title",/(?:"(?:\\"?|[^"\\])*"|''[^''\n]*(?:\n[^''\n]+)*\n?''|\([^()]*\))/).getRegex(),T=p(/^( {0,3}bull)([ \t][^\n]+?)?(?:\n|$)/).replace(/bull/g,w).getRegex(),R="address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|d' +
    'etails|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|meta|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|ti' +
    'tle|tr|track|ul",_=/<!--(?:-?>|[\s\S]*?(?:-->|$))/,A=p("^ {0,3}(?:<(script|pre|style|textarea)[\\s>][\\s\\S]*?(?:</\\1>[^\\n]*\\n+|$)|comment[^\\n]*(\\n+|$)|<\\?[\\s\\S]*?(?:\\?>\\n*|$)|<![A-Z][\\s\\S]*?(?:>\\n*|$)|<!\\[CDATA\\[[\\s\\S]*?(?:\\]\\]>\\' +
    'n*|$)|</?(tag)(?: +|\\n|/?>)[\\s\\S]*?(?:(?:\\n[ \t]*)+\\n|$)|<(?!script|pre|style|textarea)([a-z][\\w-]*)(?:attribute)*? */?>(?=[ \\t]*(?:\\n|$))[\\s' +
    '\\S]*?(?:(?:\\n[ \t]*)+\\n|$)|</(?!script|pre|style|textarea)[a-z][\\w-]*\\s*>(?=[ \\t]*(?:\\n|$))[\\s\\S]*?(?:(?:\\n[ \t]*)+\\n|$))","i").replace("comment",_).replace("tag",R).replace("attribute",/ +[a-zA-Z:_][\w.:-]*(?: *= *"[^"\n]*"| *= *''[^''\n]*''' +
    '| *= *[^\s"''=<>`]+)?/).getRegex(),S=p(y).replace("hr",b).replace("heading"," {0,3}#{1,6}(?:\\s|$)").replace("|lheading","").replace("|table","").replace("blockquote"," {0,3}>").replace("fences"," {0,3}(?:`{3,}(?=[^`\\n]*\\n)|~{3,})[^\\n]*\\n").replac' +
    'e("list"," {0,3}(?:[*+-]|1[.)]) ").replace("html","</?(?:tag)(?: +|\\n|/?>)|<(?:script|pre|style|textarea|!--)").replace("tag",R).getRegex(),I={blockquote:p(/^( {0,3}> ?(paragraph|[^\n]*)(?:\n|$))+/).replace("paragraph",S).getRegex(),code:/^((?: {4}|' +
    ' {0,3}\t)[^\n]+(?:\n(?:[ \t]*(?:\n|$))*)?)+/,def:z,fences:/^ {0,3}(`{3,}(?=[^`\n]*(?:\n|$))|~{3,})([^\n]*)(?:\n|$)(?:|([\s\S]*?)(?:\n|$))(?: {0,3}\1[~' +
    '`]* *(?=\n|$)|$)/,heading:/^ {0,3}(#{1,6})(?=\s|$)(.*)(?:\n+|$)/,hr:b,html:A,lheading:m,list:T,newline:/^(?:[ \t]*(?:\n|$))+/,paragraph:S,table:k,text:/^[^\n]+/},E=p("^ *([^\\n ].*)\\n {0,3}((?:\\| *)?:?-+:? *(?:\\| *:?-+:? *)*(?:\\| *)?)(?:\\n((?:(?' +
    '! *\\n|hr|heading|blockquote|code|fences|list|html).*(?:\\n|$))*)\\n*|$)").replace("hr",b).replace("heading"," {0,3}#{1,6}(?:\\s|$)").replace("blockquote"," {0,3}>").replace("code","(?: {4}| {0,3}\t)[^\\n]").replace("fences"," {0,3}(?:`{3,}(?=[^`\\n]' +
    '*\\n)|~{3,})[^\\n]*\\n").replace("list"," {0,3}(?:[*+-]|1[.)]) ").replace("html","</?(?:tag)(?: +|\\n|/?>)|<(?:script|pre|style|textarea|!--)").replace("tag",R).getRegex(),q={...I,table:E,paragraph:p(y).replace("hr",b).replace("heading"," {0,3}#{1,6}' +
    '(?:\\s|$)").replace("|lheading","").replace("table",E).replace("blockquote"," {0,3}>").replace("fences"," {0,3}(?:`{3,}(?=[^`\\n]*\\n)|~{3,})[^\\n]*\\' +
    'n").replace("list"," {0,3}(?:[*+-]|1[.)]) ").replace("html","</?(?:tag)(?: +|\\n|/?>)|<(?:script|pre|style|textarea|!--)").replace("tag",R).getRegex()},Z={...I,html:p("^ *(?:comment *(?:\\n|\\s*$)|<(tag)[\\s\\S]+?</\\1> *(?:\\n{2,}|\\s*$)|<tag(?:\"[^' +
    '\"]*\"|''[^'']*''|\\s[^''\"/>\\s]*)*?/?> *(?:\\n{2,}|\\s*$))").replace("comment",_).replace(/tag/g,"(?!(?:a|em|strong|small|s|cite|q|dfn|abbr|data|time|code|var|samp|kbd|sub|sup|i|b|u|mark|ruby|rt|rp|bdi|bdo|span|br|wbr|ins|del|img)\\b)\\w+(?!:|[^\\w\\s@' +
    ']*@)\\b").getRegex(),def:/^ *\[([^\]]+)\]: *<?([^\s>]+)>?(?: +(["(][^\n]+[")]))? *(?:\n+|$)/,heading:/^(#{1,6})(.*)(?:\n+|$)/,fences:k,lheading:/^(.+?)\n {0,3}(=+|-+) *(?:\n+|$)/,paragraph:p(y).replace("hr",b).replace("heading"," *#{1,6} *[^\n]").rep' +
    'lace("lheading",m).replace("|table","").replace("blockquote"," {0,3}>").replace("|fences","").replace("|list","").replace("|html","").replace("|tag","' +
    '").getRegex()},P=/^\\([!"#$%&''()*+,\-./:;<=>?@\[\]\\^_`{|}~])/,L=/^( {2,}|\\)\n(?!\s*$)/,v="\\p{P}\\p{S}",Q=p(/^((?![*_])[\spunctuation])/,"u").replace(/punctuation/g,v).getRegex(),B=p(/^(?:\*+(?:((?!\*)[punct])|[^\s*]))|^_+(?:((?!_)[punct])|([^\s_])' +
    ')/,"u").replace(/punct/g,v).getRegex(),M=p("^[^_*]*?__[^_*]*?\\*[^_*]*?(?=__)|[^*]+(?=[^*])|(?!\\*)[punct](\\*+)(?=[\\s]|$)|[^punct\\s](\\*+)(?!\\*)(?=[punct\\s]|$)|(?!\\*)[punct\\s](\\*+)(?=[^punct\\s])|[\\s](\\*+)(?!\\*)(?=[punct])|(?!\\*)[punct](\' +
    '\*+)(?!\\*)(?=[punct])|[^punct\\s](\\*+)(?=[^punct\\s])","gu").replace(/punct/g,v).getRegex(),O=p("^[^_*]*?\\*\\*[^_*]*?_[^_*]*?(?=\\*\\*)|[^_]+(?=[^_])|(?!_)[punct](_+)(?=[\\s]|$)|[^punct\\s](_+)(?!_)(?=[punct\\s]|$)|(?!_)[punct\\s](_+)(?=[^punct\\s' +
    '])|[\\s](_+)(?!_)(?=[punct])|(?!_)[punct](_+)(?!_)(?=[punct])","gu").replace(/punct/g,v).getRegex(),j=p(/\\([punct])/,"gu").replace(/punct/g,v).getReg' +
    'ex(),D=p(/^<(scheme:[^\s\x00-\x1f<>]*|email)>/).replace("scheme",/[a-zA-Z][a-zA-Z0-9+.-]{1,31}/).replace("email",/[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+(@)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(?![' +
    '-_])/).getRegex(),C=p(_).replace("(?:--\x3e|$)","--\x3e").getRegex(),H=p("^comment|^</[a-zA-Z][\\w:-]*\\s*>|^<[a-zA-Z][\\w-]*(?:attribute)*?\\s*/?>|^<\\?[\\s\\S]*?\\?>|^<![a-zA-Z]+\\s[\\s\\S]*?>|^<!\\[CDATA\\[[\\s\\S]*?\\]\\]>").replace("comment",C).' +
    'replace("attribute",/\s+[a-zA-Z:_][\w.:-]*(?:\s*=\s*"[^"]*"|\s*=\s*''[^'']*''|\s*=\s*[^\s"''=<>`]+)?/).getRegex(),U=/(?:\[(?:\\.|[^\[\]\\])*\]|\\.|`[^`]*`|[^\[\]\\`])*?/,X=p(/^!?\[(label)\]\(\s*(href)(?:\s+(title))?\s*\)/).replace("label",U).replace("hre' +
    'f",/<(?:\\.|[^\n<>\\])+>|[^\s\x00-\x1f]*/).replace("title",/"(?:\\"?|[^"\\])*"|''(?:\\''?|[^''\\])*''|\((?:\\\)?|[^)\\])*\)/).getRegex(),F=p(/^!?\[(label)' +
    '\]\[(ref)\]/).replace("label",U).replace("ref",$).getRegex(),N=p(/^!?\[(ref)\](?:\[\])?/).replace("ref",$).getRegex(),G={_backpedal:k,anyPunctuation:j,autolink:D,blockSkip:/\[[^[\]]*?\]\((?:\\.|[^\\\(\)]|\((?:\\.|[^\\\(\)])*\))*\)|`[^`]*?`|<[^<>]*?>/' +
    'g,br:L,code:/^(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/,del:k,emStrongLDelim:B,emStrongRDelimAst:M,emStrongRDelimUnd:O,escape:P,link:X,nolink:N,punctuation:Q,reflink:F,reflinkSearch:p("reflink|nolink(?!\\()","g").replace("reflink",F).replace("nolink",N).ge' +
    'tRegex(),tag:H,text:/^(`+|[^`])(?:(?= {2,}\n)|[\s\S]*?(?:(?=[\\<!\[`*_]|\b_|$)|[^ ](?= {2,}\n)))/,url:k},J={...G,link:p(/^!?\[(label)\]\((.*?)\)/).replace("label",U).getRegex(),reflink:p(/^!?\[(label)\]\s*\[([^\]]*)\]/).replace("label",U).getRegex()}' +
    ',K={...G,escape:p(P).replace("])","~|])").getRegex(),url:p(/^((?:ftp|https?):\/\/|www\.)(?:[a-zA-Z0-9\-]+\.?)+[^\s<]*|^email/,"i").replace("email",/[A' +
    '-Za-z0-9._+-]+(@)[a-zA-Z0-9-_]+(?:\.[a-zA-Z0-9-_]*[a-zA-Z0-9])+(?![-_])/).getRegex(),_backpedal:/(?:[^?!.,:;*_''"~()&]+|\([^)]*\)|&(?![a-zA-Z0-9]+;$)|[?!.,:;*_''"~)]+(?!$))+/,del:/^(~~?)(?=[^\s~])((?:\\.|[^\\])*?(?:\\.|[^\s~\\]))\1(?=[^~]|$)/,text:/^([' +
    '`~]+|[^`~])(?:(?= {2,}\n)|(?=[a-zA-Z0-9.!#$%&''*+\/=?_`{\|}~-]+@)|[\s\S]*?(?:(?=[\\<!\[`*~_]|\b_|https?:\/\/|ftp:\/\/|www\.|$)|[^ ](?= {2,}\n)|[^a-zA-Z0-9.!#$%&''*+\/=?_`{\|}~-](?=[a-zA-Z0-9.!#$%&''*+\/=?_`{\|}~-]+@)))/},V={...K,br:p(L).replace("{2,}","' +
    '*").getRegex(),text:p(K.text).replace("\\b_","\\b_| {2,}\\n").replace(/\{2,\}/g,"*").getRegex()},W={normal:I,gfm:q,pedantic:Z},Y={normal:G,gfm:K,breaks:V,pedantic:J};class ee{tokens;options;state;tokenizer;inlineQueue;constructor(t){this.tokens=[],th' +
    'is.tokens.links=Object.create(null),this.options=t||e.defaults,this.options.tokenizer=this.options.tokenizer||new x,this.tokenizer=this.options.tokeni' +
    'zer,this.tokenizer.options=this.options,this.tokenizer.lexer=this,this.inlineQueue=[],this.state={inLink:!1,inRawBlock:!1,top:!0};const n={block:W.normal,inline:Y.normal};this.options.pedantic?(n.block=W.pedantic,n.inline=Y.pedantic):this.options.gfm' +
    '&&(n.block=W.gfm,this.options.breaks?n.inline=Y.breaks:n.inline=Y.gfm),this.tokenizer.rules=n}static get rules(){return{block:W,inline:Y}}static lex(e,t){return new ee(t).lex(e)}static lexInline(e,t){return new ee(t).inlineTokens(e)}lex(e){e=e.replac' +
    'e(/\r\n|\r/g,"\n"),this.blockTokens(e,this.tokens);for(let e=0;e<this.inlineQueue.length;e++){const t=this.inlineQueue[e];this.inlineTokens(t.src,t.tokens)}return this.inlineQueue=[],this.tokens}blockTokens(e,t=[],n=!1){let s,r,i;for(this.options.ped' +
    'antic&&(e=e.replace(/\t/g,"    ").replace(/^ +$/gm,""));e;)if(!(this.options.extensions&&this.options.extensions.block&&this.options.extensions.block.' +
    'some((n=>!!(s=n.call({lexer:this},e,t))&&(e=e.substring(s.raw.length),t.push(s),!0)))))if(s=this.tokenizer.space(e))e=e.substring(s.raw.length),1===s.raw.length&&t.length>0?t[t.length-1].raw+="\n":t.push(s);else if(s=this.tokenizer.code(e))e=e.substr' +
    'ing(s.raw.length),r=t[t.length-1],!r||"paragraph"!==r.type&&"text"!==r.type?t.push(s):(r.raw+="\n"+s.raw,r.text+="\n"+s.text,this.inlineQueue[this.inlineQueue.length-1].src=r.text);else if(s=this.tokenizer.fences(e))e=e.substring(s.raw.length),t.push' +
    '(s);else if(s=this.tokenizer.heading(e))e=e.substring(s.raw.length),t.push(s);else if(s=this.tokenizer.hr(e))e=e.substring(s.raw.length),t.push(s);else if(s=this.tokenizer.blockquote(e))e=e.substring(s.raw.length),t.push(s);else if(s=this.tokenizer.l' +
    'ist(e))e=e.substring(s.raw.length),t.push(s);else if(s=this.tokenizer.html(e))e=e.substring(s.raw.length),t.push(s);else if(s=this.tokenizer.def(e))e=' +
    'e.substring(s.raw.length),r=t[t.length-1],!r||"paragraph"!==r.type&&"text"!==r.type?this.tokens.links[s.tag]||(this.tokens.links[s.tag]={href:s.href,title:s.title}):(r.raw+="\n"+s.raw,r.text+="\n"+s.raw,this.inlineQueue[this.inlineQueue.length-1].src' +
    '=r.text);else if(s=this.tokenizer.table(e))e=e.substring(s.raw.length),t.push(s);else if(s=this.tokenizer.lheading(e))e=e.substring(s.raw.length),t.push(s);else{if(i=e,this.options.extensions&&this.options.extensions.startBlock){let t=1/0;const n=e.s' +
    'lice(1);let s;this.options.extensions.startBlock.forEach((e=>{s=e.call({lexer:this},n),"number"==typeof s&&s>=0&&(t=Math.min(t,s))})),t<1/0&&t>=0&&(i=e.substring(0,t+1))}if(this.state.top&&(s=this.tokenizer.paragraph(i)))r=t[t.length-1],n&&"paragraph' +
    '"===r?.type?(r.raw+="\n"+s.raw,r.text+="\n"+s.text,this.inlineQueue.pop(),this.inlineQueue[this.inlineQueue.length-1].src=r.text):t.push(s),n=i.length' +
    '!==e.length,e=e.substring(s.raw.length);else if(s=this.tokenizer.text(e))e=e.substring(s.raw.length),r=t[t.length-1],r&&"text"===r.type?(r.raw+="\n"+s.raw,r.text+="\n"+s.text,this.inlineQueue.pop(),this.inlineQueue[this.inlineQueue.length-1].src=r.te' +
    'xt):t.push(s);else if(e){const t="Infinite loop on byte: "+e.charCodeAt(0);if(this.options.silent){console.error(t);break}throw new Error(t)}}return this.state.top=!0,t}inline(e,t=[]){return this.inlineQueue.push({src:e,tokens:t}),t}inlineTokens(e,t=' +
    '[]){let n,s,r,i,l,o,a=e;if(this.tokens.links){const e=Object.keys(this.tokens.links);if(e.length>0)for(;null!=(i=this.tokenizer.rules.inline.reflinkSearch.exec(a));)e.includes(i[0].slice(i[0].lastIndexOf("[")+1,-1))&&(a=a.slice(0,i.index)+"["+"a".rep' +
    'eat(i[0].length-2)+"]"+a.slice(this.tokenizer.rules.inline.reflinkSearch.lastIndex))}for(;null!=(i=this.tokenizer.rules.inline.blockSkip.exec(a));)a=a' +
    '.slice(0,i.index)+"["+"a".repeat(i[0].length-2)+"]"+a.slice(this.tokenizer.rules.inline.blockSkip.lastIndex);for(;null!=(i=this.tokenizer.rules.inline.anyPunctuation.exec(a));)a=a.slice(0,i.index)+"++"+a.slice(this.tokenizer.rules.inline.anyPunctuati' +
    'on.lastIndex);for(;e;)if(l||(o=""),l=!1,!(this.options.extensions&&this.options.extensions.inline&&this.options.extensions.inline.some((s=>!!(n=s.call({lexer:this},e,t))&&(e=e.substring(n.raw.length),t.push(n),!0)))))if(n=this.tokenizer.escape(e))e=e' +
    '.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.tag(e))e=e.substring(n.raw.length),s=t[t.length-1],s&&"text"===n.type&&"text"===s.type?(s.raw+=n.raw,s.text+=n.text):t.push(n);else if(n=this.tokenizer.link(e))e=e.substring(n.raw.length),t.' +
    'push(n);else if(n=this.tokenizer.reflink(e,this.tokens.links))e=e.substring(n.raw.length),s=t[t.length-1],s&&"text"===n.type&&"text"===s.type?(s.raw+=' +
    'n.raw,s.text+=n.text):t.push(n);else if(n=this.tokenizer.emStrong(e,a,o))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.codespan(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.br(e))e=e.substring(n.raw.length),t.pus' +
    'h(n);else if(n=this.tokenizer.del(e))e=e.substring(n.raw.length),t.push(n);else if(n=this.tokenizer.autolink(e))e=e.substring(n.raw.length),t.push(n);else if(this.state.inLink||!(n=this.tokenizer.url(e))){if(r=e,this.options.extensions&&this.options.' +
    'extensions.startInline){let t=1/0;const n=e.slice(1);let s;this.options.extensions.startInline.forEach((e=>{s=e.call({lexer:this},n),"number"==typeof s&&s>=0&&(t=Math.min(t,s))})),t<1/0&&t>=0&&(r=e.substring(0,t+1))}if(n=this.tokenizer.inlineText(r))' +
    'e=e.substring(n.raw.length),"_"!==n.raw.slice(-1)&&(o=n.raw.slice(-1)),l=!0,s=t[t.length-1],s&&"text"===s.type?(s.raw+=n.raw,s.text+=n.text):t.push(n)' +
    ';else if(e){const t="Infinite loop on byte: "+e.charCodeAt(0);if(this.options.silent){console.error(t);break}throw new Error(t)}}else e=e.substring(n.raw.length),t.push(n);return t}}class te{options;parser;constructor(t){this.options=t||e.defaults}sp' +
    'ace(e){return""}code({text:e,lang:t,escaped:n}){const s=(t||"").match(/^\S*/)?.[0],r=e.replace(/\n$/,"")+"\n";return s?''<pre><code class="language-''+c(s)+''">''+(n?r:c(r,!0))+"</code></pre>\n":"<pre><code>"+(n?r:c(r,!0))+"</code></pre>\n"}blockquote({t' +
    'okens:e}){return`<blockquote>\n${this.parser.parse(e)}</blockquote>\n`}html({text:e}){return e}heading({tokens:e,depth:t}){return`<h${t}>${this.parser.parseInline(e)}</h${t}>\n`}hr(e){return"<hr>\n"}list(e){const t=e.ordered,n=e.start;let s="";for(le' +
    't t=0;t<e.items.length;t++){const n=e.items[t];s+=this.listitem(n)}const r=t?"ol":"ul";return"<"+r+(t&&1!==n?'' start="''+n+''"'':"")+">\n"+s+"</"+r+">\n"' +
    '}listitem(e){let t="";if(e.task){const n=this.checkbox({checked:!!e.checked});e.loose?e.tokens.length>0&&"paragraph"===e.tokens[0].type?(e.tokens[0].text=n+" "+e.tokens[0].text,e.tokens[0].tokens&&e.tokens[0].tokens.length>0&&"text"===e.tokens[0].tok' +
    'ens[0].type&&(e.tokens[0].tokens[0].text=n+" "+e.tokens[0].tokens[0].text)):e.tokens.unshift({type:"text",raw:n+" ",text:n+" "}):t+=n+" "}return t+=this.parser.parse(e.tokens,!!e.loose),`<li>${t}</li>\n`}checkbox({checked:e}){return"<input "+(e?''chec' +
    'ked="" '':"")+''disabled="" type="checkbox">''}paragraph({tokens:e}){return`<p>${this.parser.parseInline(e)}</p>\n`}table(e){let t="",n="";for(let t=0;t<e.header.length;t++)n+=this.tablecell(e.header[t]);t+=this.tablerow({text:n});let s="";for(let t=0;t' +
    '<e.rows.length;t++){const r=e.rows[t];n="";for(let e=0;e<r.length;e++)n+=this.tablecell(r[e]);s+=this.tablerow({text:n})}return s&&(s=`<tbody>${s}</tb' +
    'ody>`),"<table>\n<thead>\n"+t+"</thead>\n"+s+"</table>\n"}tablerow({text:e}){return`<tr>\n${e}</tr>\n`}tablecell(e){const t=this.parser.parseInline(e.tokens),n=e.header?"th":"td";return(e.align?`<${n} align="${e.align}">`:`<${n}>`)+t+`</${n}>\n`}stro' +
    'ng({tokens:e}){return`<strong>${this.parser.parseInline(e)}</strong>`}em({tokens:e}){return`<em>${this.parser.parseInline(e)}</em>`}codespan({text:e}){return`<code>${e}</code>`}br(e){return"<br>"}del({tokens:e}){return`<del>${this.parser.parseInline(' +
    'e)}</del>`}link({href:e,title:t,tokens:n}){const s=this.parser.parseInline(n),r=u(e);if(null===r)return s;let i=''<a href="''+(e=r)+''"'';return t&&(i+='' title="''+t+''"''),i+=">"+s+"</a>",i}image({href:e,title:t,text:n}){const s=u(e);if(null===s)return n;l' +
    'et r=`<img src="${e=s}" alt="${n}"`;return t&&(r+=` title="${t}"`),r+=">",r}text(e){return"tokens"in e&&e.tokens?this.parser.parseInline(e.tokens):e.t' +
    'ext}}class ne{strong({text:e}){return e}em({text:e}){return e}codespan({text:e}){return e}del({text:e}){return e}html({text:e}){return e}text({text:e}){return e}link({text:e}){return""+e}image({text:e}){return""+e}br(){return""}}class se{options;rend' +
    'erer;textRenderer;constructor(t){this.options=t||e.defaults,this.options.renderer=this.options.renderer||new te,this.renderer=this.options.renderer,this.renderer.options=this.options,this.renderer.parser=this,this.textRenderer=new ne}static parse(e,t' +
    '){return new se(t).parse(e)}static parseInline(e,t){return new se(t).parseInline(e)}parse(e,t=!0){let n="";for(let s=0;s<e.length;s++){const r=e[s];if(this.options.extensions&&this.options.extensions.renderers&&this.options.extensions.renderers[r.typ' +
    'e]){const e=r,t=this.options.extensions.renderers[e.type].call({parser:this},e);if(!1!==t||!["space","hr","heading","code","table","blockquote","list"' +
    ',"html","paragraph","text"].includes(e.type)){n+=t||"";continue}}const i=r;switch(i.type){case"space":n+=this.renderer.space(i);continue;case"hr":n+=this.renderer.hr(i);continue;case"heading":n+=this.renderer.heading(i);continue;case"code":n+=this.re' +
    'nderer.code(i);continue;case"table":n+=this.renderer.table(i);continue;case"blockquote":n+=this.renderer.blockquote(i);continue;case"list":n+=this.renderer.list(i);continue;case"html":n+=this.renderer.html(i);continue;case"paragraph":n+=this.renderer' +
    '.paragraph(i);continue;case"text":{let r=i,l=this.renderer.text(r);for(;s+1<e.length&&"text"===e[s+1].type;)r=e[++s],l+="\n"+this.renderer.text(r);n+=t?this.renderer.paragraph({type:"paragraph",raw:l,text:l,tokens:[{type:"text",raw:l,text:l}]}):l;con' +
    'tinue}default:{const e=''Token with "''+i.type+''" type was not found.'';if(this.options.silent)return console.error(e),"";throw new Error(e)}}}return n}p' +
    'arseInline(e,t){t=t||this.renderer;let n="";for(let s=0;s<e.length;s++){const r=e[s];if(this.options.extensions&&this.options.extensions.renderers&&this.options.extensions.renderers[r.type]){const e=this.options.extensions.renderers[r.type].call({par' +
    'ser:this},r);if(!1!==e||!["escape","html","link","image","strong","em","codespan","br","del","text"].includes(r.type)){n+=e||"";continue}}const i=r;switch(i.type){case"escape":case"text":n+=t.text(i);break;case"html":n+=t.html(i);break;case"link":n+=' +
    't.link(i);break;case"image":n+=t.image(i);break;case"strong":n+=t.strong(i);break;case"em":n+=t.em(i);break;case"codespan":n+=t.codespan(i);break;case"br":n+=t.br(i);break;case"del":n+=t.del(i);break;default:{const e=''Token with "''+i.type+''" type was' +
    ' not found.'';if(this.options.silent)return console.error(e),"";throw new Error(e)}}}return n}}class re{options;block;constructor(t){this.options=t||e.' +
    'defaults}static passThroughHooks=new Set(["preprocess","postprocess","processAllTokens"]);preprocess(e){return e}postprocess(e){return e}processAllTokens(e){return e}provideLexer(){return this.block?ee.lex:ee.lexInline}provideParser(){return this.blo' +
    'ck?se.parse:se.parseInline}}class ie{defaults={async:!1,breaks:!1,extensions:null,gfm:!0,hooks:null,pedantic:!1,renderer:null,silent:!1,tokenizer:null,walkTokens:null};options=this.setOptions;parse=this.parseMarkdown(!0);parseInline=this.parseMarkdow' +
    'n(!1);Parser=se;Renderer=te;TextRenderer=ne;Lexer=ee;Tokenizer=x;Hooks=re;constructor(...e){this.use(...e)}walkTokens(e,t){let n=[];for(const s of e)switch(n=n.concat(t.call(this,s)),s.type){case"table":{const e=s;for(const s of e.header)n=n.concat(t' +
    'his.walkTokens(s.tokens,t));for(const s of e.rows)for(const e of s)n=n.concat(this.walkTokens(e.tokens,t));break}case"list":{const e=s;n=n.concat(this' +
    '.walkTokens(e.items,t));break}default:{const e=s;this.defaults.extensions?.childTokens?.[e.type]?this.defaults.extensions.childTokens[e.type].forEach((s=>{const r=e[s].flat(1/0);n=n.concat(this.walkTokens(r,t))})):e.tokens&&(n=n.concat(this.walkToken' +
    's(e.tokens,t)))}}return n}use(...e){const t=this.defaults.extensions||{renderers:{},childTokens:{}};return e.forEach((e=>{const n={...e};if(n.async=this.defaults.async||n.async||!1,e.extensions&&(e.extensions.forEach((e=>{if(!e.name)throw new Error("' +
    'extension name required");if("renderer"in e){const n=t.renderers[e.name];t.renderers[e.name]=n?function(...t){let s=e.renderer.apply(this,t);return!1===s&&(s=n.apply(this,t)),s}:e.renderer}if("tokenizer"in e){if(!e.level||"block"!==e.level&&"inline"!' +
    '==e.level)throw new Error("extension level must be ''block'' or ''inline''");const n=t[e.level];n?n.unshift(e.tokenizer):t[e.level]=[e.tokenizer],e.start&' +
    '&("block"===e.level?t.startBlock?t.startBlock.push(e.start):t.startBlock=[e.start]:"inline"===e.level&&(t.startInline?t.startInline.push(e.start):t.startInline=[e.start]))}"childTokens"in e&&e.childTokens&&(t.childTokens[e.name]=e.childTokens)})),n.e' +
    'xtensions=t),e.renderer){const t=this.defaults.renderer||new te(this.defaults);for(const n in e.renderer){if(!(n in t))throw new Error(`renderer ''${n}'' does not exist`);if(["options","parser"].includes(n))continue;const s=n,r=e.renderer[s],i=t[s];t[s' +
    ']=(...e)=>{let n=r.apply(t,e);return!1===n&&(n=i.apply(t,e)),n||""}}n.renderer=t}if(e.tokenizer){const t=this.defaults.tokenizer||new x(this.defaults);for(const n in e.tokenizer){if(!(n in t))throw new Error(`tokenizer ''${n}'' does not exist`);if(["op' +
    'tions","rules","lexer"].includes(n))continue;const s=n,r=e.tokenizer[s],i=t[s];t[s]=(...e)=>{let n=r.apply(t,e);return!1===n&&(n=i.apply(t,e)),n}}n.to' +
    'kenizer=t}if(e.hooks){const t=this.defaults.hooks||new re;for(const n in e.hooks){if(!(n in t))throw new Error(`hook ''${n}'' does not exist`);if(["options","block"].includes(n))continue;const s=n,r=e.hooks[s],i=t[s];re.passThroughHooks.has(n)?t[s]=e=>' +
    '{if(this.defaults.async)return Promise.resolve(r.call(t,e)).then((e=>i.call(t,e)));const n=r.call(t,e);return i.call(t,n)}:t[s]=(...e)=>{let n=r.apply(t,e);return!1===n&&(n=i.apply(t,e)),n}}n.hooks=t}if(e.walkTokens){const t=this.defaults.walkTokens,' +
    's=e.walkTokens;n.walkTokens=function(e){let n=[];return n.push(s.call(this,e)),t&&(n=n.concat(t.call(this,e))),n}}this.defaults={...this.defaults,...n}})),this}setOptions(e){return this.defaults={...this.defaults,...e},this}lexer(e,t){return ee.lex(e' +
    ',t??this.defaults)}parser(e,t){return se.parse(e,t??this.defaults)}parseMarkdown(e){return(t,n)=>{const s={...n},r={...this.defaults,...s},i=this.onEr' +
    'ror(!!r.silent,!!r.async);if(!0===this.defaults.async&&!1===s.async)return i(new Error("marked(): The async option was set to true by an extension. Remove async: false from the parse options object to return a Promise."));if(null==t)return i(new Erro' +
    'r("marked(): input parameter is undefined or null"));if("string"!=typeof t)return i(new Error("marked(): input parameter is of type "+Object.prototype.toString.call(t)+", string expected"));r.hooks&&(r.hooks.options=r,r.hooks.block=e);const l=r.hooks' +
    '?r.hooks.provideLexer():e?ee.lex:ee.lexInline,o=r.hooks?r.hooks.provideParser():e?se.parse:se.parseInline;if(r.async)return Promise.resolve(r.hooks?r.hooks.preprocess(t):t).then((e=>l(e,r))).then((e=>r.hooks?r.hooks.processAllTokens(e):e)).then((e=>r' +
    '.walkTokens?Promise.all(this.walkTokens(e,r.walkTokens)).then((()=>e)):e)).then((e=>o(e,r))).then((e=>r.hooks?r.hooks.postprocess(e):e)).catch(i);try{' +
    'r.hooks&&(t=r.hooks.preprocess(t));let e=l(t,r);r.hooks&&(e=r.hooks.processAllTokens(e)),r.walkTokens&&this.walkTokens(e,r.walkTokens);let n=o(e,r);return r.hooks&&(n=r.hooks.postprocess(n)),n}catch(e){return i(e)}}}onError(e,t){return n=>{if(n.messa' +
    'ge+="\nPlease report this to https://github.com/markedjs/marked.",e){const e="<p>An error occurred:</p><pre>"+c(n.message+"",!0)+"</pre>";return t?Promise.resolve(e):e}if(t)return Promise.reject(n);throw n}}}const le=new ie;function oe(e,t){return le' +
    '.parse(e,t)}oe.options=oe.setOptions=function(e){return le.setOptions(e),oe.defaults=le.defaults,n(oe.defaults),oe},oe.getDefaults=t,oe.defaults=e.defaults,oe.use=function(...e){return le.use(...e),oe.defaults=le.defaults,n(oe.defaults),oe},oe.walkTo' +
    'kens=function(e,t){return le.walkTokens(e,t)},oe.parseInline=le.parseInline,oe.Parser=se,oe.parser=se.parse,oe.Renderer=te,oe.TextRenderer=ne,oe.Lexer' +
    '=ee,oe.lexer=ee.lex,oe.Tokenizer=x,oe.Hooks=re,oe.parse=oe;const ae=oe.options,ce=oe.setOptions,he=oe.use,pe=oe.walkTokens,ue=oe.parseInline,ke=oe,ge=se.parse,fe=ee.lex;e.Hooks=re,e.Lexer=ee,e.Marked=ie,e.Parser=se,e.Renderer=te,e.TextRenderer=ne,e.T' +
    'okenizer=x,e.getDefaults=t,e.lexer=fe,e.marked=oe,e.options=ae,e.parse=ke,e.parseInline=ue,e.parser=ge,e.setOptions=ce,e.use=he,e.walkTokens=pe}));' + sLineBreak;
  // END GENERATED MARKED_JS

  // BEGIN GENERATED HIGHLIGHT_JS
  {
    Source:  https://highlightjs.org/
    Version: 11.11.1
    SHA-256: 63672F8EF2032370B72553542D32BFB015350E6B848C10540115EE3138335756
    License: BSD-3-Clause (Ivan Sagalaev)
    DO NOT EDIT — regenerated by scripts/embed-webview-assets.ps1

    Upstream license header:
    /*!
      Highlight.js v11.11.1 (git: 08cb242e7d)
      (c) 2006-2024 Josh Goebel <hello@joshgoebel.com> and other contributors
      License: BSD-3-Clause
     */
  }
  HIGHLIGHT_JS: string =
    '/*!' + sLineBreak +
    '  Highlight.js v11.11.1 (git: 08cb242e7d)' + sLineBreak +
    '  (c) 2006-2024 Josh Goebel <hello@joshgoebel.com> and other contributors' + sLineBreak +
    '  License: BSD-3-Clause' + sLineBreak +
    ' */' + sLineBreak +
    'var hljs=function(){"use strict";function e(n){' + sLineBreak +
    'return n instanceof Map?n.clear=n.delete=n.set=()=>{' + sLineBreak +
    'throw Error("map is read-only")}:n instanceof Set&&(n.add=n.clear=n.delete=()=>{' + sLineBreak +
    'throw Error("set is read-only")' + sLineBreak +
    '}),Object.freeze(n),Object.getOwnPropertyNames(n).forEach((t=>{' + sLineBreak +
    'const a=n[t],i=typeof a;"object"!==i&&"function"!==i||Object.isFrozen(a)||e(a)' + sLineBreak +
    '})),n}class n{constructor(e){' + sLineBreak +
    'void 0===e.data&&(e.data={}),this.data=e.data,this.isMatchIgnored=!1}' + sLineBreak +
    'ignoreMatch(){this.isMatchIgnored=!0}}function t(e){' + sLineBreak +
    'return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/''/g,"&#x27;")' + sLineBreak +
    '}function a(e,...n){const t=Object.create(null);for(const n in e)t[n]=e[n]' + sLineBreak +
    ';return n.forEach((e=>{for(const n in e)t[n]=e[n]})),t}const i=e=>!!e.scope' + sLineBreak +
    ';class r{constructor(e,n){' + sLineBreak +
    'this.buffer="",this.classPrefix=n.classPrefix,e.walk(this)}addText(e){' + sLineBreak +
    'this.buffer+=t(e)}openNode(e){if(!i(e))return;const n=((e,{prefix:n})=>{' + sLineBreak +
    'if(e.startsWith("language:"))return e.replace("language:","language-")' + sLineBreak +
    ';if(e.includes(".")){const t=e.split(".")' + sLineBreak +
    ';return[`${n}${t.shift()}`,...t.map(((e,n)=>`${e}${"_".repeat(n+1)}`))].join(" ")' + sLineBreak +
    '}return`${n}${e}`})(e.scope,{prefix:this.classPrefix});this.span(n)}' + sLineBreak +
    'closeNode(e){i(e)&&(this.buffer+="</span>")}value(){return this.buffer}span(e){' + sLineBreak +
    'this.buffer+=`<span class="${e}">`}}const s=(e={})=>{const n={children:[]}' + sLineBreak +
    ';return Object.assign(n,e),n};class o{constructor(){' + sLineBreak +
    'this.rootNode=s(),this.stack=[this.rootNode]}get top(){' + sLineBreak +
    'return this.stack[this.stack.length-1]}get root(){return this.rootNode}add(e){' + sLineBreak +
    'this.top.children.push(e)}openNode(e){const n=s({scope:e})' + sLineBreak +
    ';this.add(n),this.stack.push(n)}closeNode(){' + sLineBreak +
    'if(this.stack.length>1)return this.stack.pop()}closeAllNodes(){' + sLineBreak +
    'for(;this.closeNode(););}toJSON(){return JSON.stringify(this.rootNode,null,4)}' + sLineBreak +
    'walk(e){return this.constructor._walk(e,this.rootNode)}static _walk(e,n){' + sLineBreak +
    'return"string"==typeof n?e.addText(n):n.children&&(e.openNode(n),' + sLineBreak +
    'n.children.forEach((n=>this._walk(e,n))),e.closeNode(n)),e}static _collapse(e){' + sLineBreak +
    '"string"!=typeof e&&e.children&&(e.children.every((e=>"string"==typeof e))?e.children=[e.children.join("")]:e.children.forEach((e=>{' + sLineBreak +
    'o._collapse(e)})))}}class l extends o{constructor(e){super(),this.options=e}' + sLineBreak +
    'addText(e){""!==e&&this.add(e)}startScope(e){this.openNode(e)}endScope(){' + sLineBreak +
    'this.closeNode()}__addSublanguage(e,n){const t=e.root' + sLineBreak +
    ';n&&(t.scope="language:"+n),this.add(t)}toHTML(){' + sLineBreak +
    'return new r(this,this.options).value()}finalize(){' + sLineBreak +
    'return this.closeAllNodes(),!0}}function c(e){' + sLineBreak +
    'return e?"string"==typeof e?e:e.source:null}function d(e){return b("(?=",e,")")}' + sLineBreak +
    'function g(e){return b("(?:",e,")*")}function u(e){return b("(?:",e,")?")}' + sLineBreak +
    'function b(...e){return e.map((e=>c(e))).join("")}function m(...e){const n=(e=>{' + sLineBreak +
    'const n=e[e.length-1]' + sLineBreak +
    ';return"object"==typeof n&&n.constructor===Object?(e.splice(e.length-1,1),n):{}' + sLineBreak +
    '})(e);return"("+(n.capture?"":"?:")+e.map((e=>c(e))).join("|")+")"}' + sLineBreak +
    'function p(e){return RegExp(e.toString()+"|").exec("").length-1}' + sLineBreak +
    'const _=/\[(?:[^\\\]]|\\.)*\]|\(\??|\\([1-9][0-9]*)|\\./' + sLineBreak +
    ';function h(e,{joinWith:n}){let t=0;return e.map((e=>{t+=1;const n=t' + sLineBreak +
    ';let a=c(e),i="";for(;a.length>0;){const e=_.exec(a);if(!e){i+=a;break}' + sLineBreak +
    'i+=a.substring(0,e.index),' + sLineBreak +
    'a=a.substring(e.index+e[0].length),"\\"===e[0][0]&&e[1]?i+="\\"+(Number(e[1])+n):(i+=e[0],' + sLineBreak +
    '"("===e[0]&&t++)}return i})).map((e=>`(${e})`)).join(n)}' + sLineBreak +
    'const f="[a-zA-Z]\\w*",E="[a-zA-Z_]\\w*",y="\\b\\d+(\\.\\d+)?",w="(-?)(\\b0[xX][a-fA-F0-9]+|(\\b\\d+(\\.\\d*)?|\\.\\d+)([eE][-+]?\\d+)?)",v="\\b(0b[01]+)",N={' + sLineBreak +
    'begin:"\\\\[\\s\\S]",relevance:0},k={scope:"string",begin:"''",end:"''",' + sLineBreak +
    'illegal:"\\n",contains:[N]},x={scope:"string",begin:''"'',end:''"'',illegal:"\\n",' + sLineBreak +
    'contains:[N]},O=(e,n,t={})=>{const i=a({scope:"comment",begin:e,end:n,' + sLineBreak +
    'contains:[]},t);i.contains.push({scope:"doctag",' + sLineBreak +
    'begin:"[ ]*(?=(TODO|FIXME|NOTE|BUG|OPTIMIZE|HACK|XXX):)",' + sLineBreak +
    'end:/(TODO|FIXME|NOTE|BUG|OPTIMIZE|HACK|XXX):/,excludeBegin:!0,relevance:0})' + sLineBreak +
    ';const r=m("I","a","is","so","us","to","at","if","in","it","on",/[A-Za-z]+[''](d|ve|re|ll|t|s|n)/,/[A-Za-z]+[-][a-z]+/,/[A-Za-z][a-z]{2,}/)' + sLineBreak +
    ';return i.contains.push({begin:b(/[ ]+/,"(",r,/[.]?[:]?([.][ ]|[ ])/,"){3}")}),i' + sLineBreak +
    '},M=O("//","$"),A=O("/\\*","\\*/"),S=O("#","$");var C=Object.freeze({' + sLineBreak +
    '__proto__:null,APOS_STRING_MODE:k,BACKSLASH_ESCAPE:N,BINARY_NUMBER_MODE:{' + sLineBreak +
    'scope:"number",begin:v,relevance:0},BINARY_NUMBER_RE:v,COMMENT:O,' + sLineBreak +
    'C_BLOCK_COMMENT_MODE:A,C_LINE_COMMENT_MODE:M,C_NUMBER_MODE:{scope:"number",' + sLineBreak +
    'begin:w,relevance:0},C_NUMBER_RE:w,END_SAME_AS_BEGIN:e=>Object.assign(e,{' + sLineBreak +
    '"on:begin":(e,n)=>{n.data._beginMatch=e[1]},"on:end":(e,n)=>{' + sLineBreak +
    'n.data._beginMatch!==e[1]&&n.ignoreMatch()}}),HASH_COMMENT_MODE:S,IDENT_RE:f,' + sLineBreak +
    'MATCH_NOTHING_RE:/\b\B/,METHOD_GUARD:{begin:"\\.\\s*"+E,relevance:0},' + sLineBreak +
    'NUMBER_MODE:{scope:"number",begin:y,relevance:0},NUMBER_RE:y,' + sLineBreak +
    'PHRASAL_WORDS_MODE:{' + sLineBreak +
    'begin:/\b(a|an|the|are|I''m|isn''t|don''t|doesn''t|won''t|but|just|should|pretty|simply|enough|gonna|going|wtf|so|such|will|you|your|they|like|more)\b/' + sLineBreak +
    '},QUOTE_STRING_MODE:x,REGEXP_MODE:{scope:"regexp",begin:/\/(?=[^/\n]*\/)/,' + sLineBreak +
    'end:/\/[gimuy]*/,contains:[N,{begin:/\[/,end:/\]/,relevance:0,contains:[N]}]},' + sLineBreak +
    'RE_STARTERS_RE:"!|!=|!==|%|%=|&|&&|&=|\\*|\\*=|\\+|\\+=|,|-|-=|/=|/|:|;|<<|<<=|<=|<|===|==|=|>>>=|>>=|>=|>>>|>>|>|\\?|\\[|\\{|\\(|\\^|\\^=|\\||\\|=|\\|\\||~",' + sLineBreak +
    'SHEBANG:(e={})=>{const n=/^#![ ]*\//' + sLineBreak +
    ';return e.binary&&(e.begin=b(n,/.*\b/,e.binary,/\b.*/)),a({scope:"meta",begin:n,' + sLineBreak +
    'end:/$/,relevance:0,"on:begin":(e,n)=>{0!==e.index&&n.ignoreMatch()}},e)},' + sLineBreak +
    'TITLE_MODE:{scope:"title",begin:f,relevance:0},UNDERSCORE_IDENT_RE:E,' + sLineBreak +
    'UNDERSCORE_TITLE_MODE:{scope:"title",begin:E,relevance:0}});function T(e,n){' + sLineBreak +
    '"."===e.input[e.index-1]&&n.ignoreMatch()}function R(e,n){' + sLineBreak +
    'void 0!==e.className&&(e.scope=e.className,delete e.className)}function D(e,n){' + sLineBreak +
    'n&&e.beginKeywords&&(e.begin="\\b("+e.beginKeywords.split(" ").join("|")+")(?!\\.)(?=\\b|\\s)",' + sLineBreak +
    'e.__beforeBegin=T,e.keywords=e.keywords||e.beginKeywords,delete e.beginKeywords,' + sLineBreak +
    'void 0===e.relevance&&(e.relevance=0))}function I(e,n){' + sLineBreak +
    'Array.isArray(e.illegal)&&(e.illegal=m(...e.illegal))}function L(e,n){' + sLineBreak +
    'if(e.match){' + sLineBreak +
    'if(e.begin||e.end)throw Error("begin & end are not supported with match")' + sLineBreak +
    ';e.begin=e.match,delete e.match}}function B(e,n){' + sLineBreak +
    'void 0===e.relevance&&(e.relevance=1)}const $=(e,n)=>{if(!e.beforeMatch)return' + sLineBreak +
    ';if(e.starts)throw Error("beforeMatch cannot be used with starts")' + sLineBreak +
    ';const t=Object.assign({},e);Object.keys(e).forEach((n=>{delete e[n]' + sLineBreak +
    '})),e.keywords=t.keywords,e.begin=b(t.beforeMatch,d(t.begin)),e.starts={' + sLineBreak +
    'relevance:0,contains:[Object.assign(t,{endsParent:!0})]' + sLineBreak +
    '},e.relevance=0,delete t.beforeMatch' + sLineBreak +
    '},F=["of","and","for","in","not","or","if","then","parent","list","value"]' + sLineBreak +
    ';function z(e,n,t="keyword"){const a=Object.create(null)' + sLineBreak +
    ';return"string"==typeof e?i(t,e.split(" ")):Array.isArray(e)?i(t,e):Object.keys(e).forEach((t=>{' + sLineBreak +
    'Object.assign(a,z(e[t],n,t))})),a;function i(e,t){' + sLineBreak +
    'n&&(t=t.map((e=>e.toLowerCase()))),t.forEach((n=>{const t=n.split("|")' + sLineBreak +
    ';a[t[0]]=[e,j(t[0],t[1])]}))}}function j(e,n){' + sLineBreak +
    'return n?Number(n):(e=>F.includes(e.toLowerCase()))(e)?0:1}const U={},P=e=>{' + sLineBreak +
    'console.error(e)},K=(e,...n)=>{console.log("WARN: "+e,...n)},q=(e,n)=>{' + sLineBreak +
    'U[`${e}/${n}`]||(console.log(`Deprecated as of ${e}. ${n}`),U[`${e}/${n}`]=!0)' + sLineBreak +
    '},H=Error();function G(e,n,{key:t}){let a=0;const i=e[t],r={},s={}' + sLineBreak +
    ';for(let e=1;e<=n.length;e++)s[e+a]=i[e],r[e+a]=!0,a+=p(n[e-1])' + sLineBreak +
    ';e[t]=s,e[t]._emit=r,e[t]._multi=!0}function Z(e){(e=>{' + sLineBreak +
    'e.scope&&"object"==typeof e.scope&&null!==e.scope&&(e.beginScope=e.scope,' + sLineBreak +
    'delete e.scope)})(e),"string"==typeof e.beginScope&&(e.beginScope={' + sLineBreak +
    '_wrap:e.beginScope}),"string"==typeof e.endScope&&(e.endScope={_wrap:e.endScope' + sLineBreak +
    '}),(e=>{if(Array.isArray(e.begin)){' + sLineBreak +
    'if(e.skip||e.excludeBegin||e.returnBegin)throw P("skip, excludeBegin, returnBegin not compatible with beginScope: {}"),' + sLineBreak +
    'H' + sLineBreak +
    ';if("object"!=typeof e.beginScope||null===e.beginScope)throw P("beginScope must be object"),' + sLineBreak +
    'H;G(e,e.begin,{key:"beginScope"}),e.begin=h(e.begin,{joinWith:""})}})(e),(e=>{' + sLineBreak +
    'if(Array.isArray(e.end)){' + sLineBreak +
    'if(e.skip||e.excludeEnd||e.returnEnd)throw P("skip, excludeEnd, returnEnd not compatible with endScope: {}"),' + sLineBreak +
    'H' + sLineBreak +
    ';if("object"!=typeof e.endScope||null===e.endScope)throw P("endScope must be object"),' + sLineBreak +
    'H;G(e,e.end,{key:"endScope"}),e.end=h(e.end,{joinWith:""})}})(e)}function W(e){' + sLineBreak +
    'function n(n,t){' + sLineBreak +
    'return RegExp(c(n),"m"+(e.case_insensitive?"i":"")+(e.unicodeRegex?"u":"")+(t?"g":""))' + sLineBreak +
    '}class t{constructor(){' + sLineBreak +
    'this.matchIndexes={},this.regexes=[],this.matchAt=1,this.position=0}' + sLineBreak +
    'addRule(e,n){' + sLineBreak +
    'n.position=this.position++,this.matchIndexes[this.matchAt]=n,this.regexes.push([n,e]),' + sLineBreak +
    'this.matchAt+=p(e)+1}compile(){0===this.regexes.length&&(this.exec=()=>null)' + sLineBreak +
    ';const e=this.regexes.map((e=>e[1]));this.matcherRe=n(h(e,{joinWith:"|"' + sLineBreak +
    '}),!0),this.lastIndex=0}exec(e){this.matcherRe.lastIndex=this.lastIndex' + sLineBreak +
    ';const n=this.matcherRe.exec(e);if(!n)return null' + sLineBreak +
    ';const t=n.findIndex(((e,n)=>n>0&&void 0!==e)),a=this.matchIndexes[t]' + sLineBreak +
    ';return n.splice(0,t),Object.assign(n,a)}}class i{constructor(){' + sLineBreak +
    'this.rules=[],this.multiRegexes=[],' + sLineBreak +
    'this.count=0,this.lastIndex=0,this.regexIndex=0}getMatcher(e){' + sLineBreak +
    'if(this.multiRegexes[e])return this.multiRegexes[e];const n=new t' + sLineBreak +
    ';return this.rules.slice(e).forEach((([e,t])=>n.addRule(e,t))),' + sLineBreak +
    'n.compile(),this.multiRegexes[e]=n,n}resumingScanAtSamePosition(){' + sLineBreak +
    'return 0!==this.regexIndex}considerAll(){this.regexIndex=0}addRule(e,n){' + sLineBreak +
    'this.rules.push([e,n]),"begin"===n.type&&this.count++}exec(e){' + sLineBreak +
    'const n=this.getMatcher(this.regexIndex);n.lastIndex=this.lastIndex' + sLineBreak +
    ';let t=n.exec(e)' + sLineBreak +
    ';if(this.resumingScanAtSamePosition())if(t&&t.index===this.lastIndex);else{' + sLineBreak +
    'const n=this.getMatcher(0);n.lastIndex=this.lastIndex+1,t=n.exec(e)}' + sLineBreak +
    'return t&&(this.regexIndex+=t.position+1,' + sLineBreak +
    'this.regexIndex===this.count&&this.considerAll()),t}}' + sLineBreak +
    'if(e.compilerExtensions||(e.compilerExtensions=[]),' + sLineBreak +
    'e.contains&&e.contains.includes("self"))throw Error("ERR: contains `self` is not supported at the top-level of a language.  See documentation.")' + sLineBreak +
    ';return e.classNameAliases=a(e.classNameAliases||{}),function t(r,s){const o=r' + sLineBreak +
    ';if(r.isCompiled)return o' + sLineBreak +
    ';[R,L,Z,$].forEach((e=>e(r,s))),e.compilerExtensions.forEach((e=>e(r,s))),' + sLineBreak +
    'r.__beforeBegin=null,[D,I,B].forEach((e=>e(r,s))),r.isCompiled=!0;let l=null' + sLineBreak +
    ';return"object"==typeof r.keywords&&r.keywords.$pattern&&(r.keywords=Object.assign({},r.keywords),' + sLineBreak +
    'l=r.keywords.$pattern,' + sLineBreak +
    'delete r.keywords.$pattern),l=l||/\w+/,r.keywords&&(r.keywords=z(r.keywords,e.case_insensitive)),' + sLineBreak +
    'o.keywordPatternRe=n(l,!0),' + sLineBreak +
    's&&(r.begin||(r.begin=/\B|\b/),o.beginRe=n(o.begin),r.end||r.endsWithParent||(r.end=/\B|\b/),' + sLineBreak +
    'r.end&&(o.endRe=n(o.end)),' + sLineBreak +
    'o.terminatorEnd=c(o.end)||"",r.endsWithParent&&s.terminatorEnd&&(o.terminatorEnd+=(r.end?"|":"")+s.terminatorEnd)),' + sLineBreak +
    'r.illegal&&(o.illegalRe=n(r.illegal)),' + sLineBreak +
    'r.contains||(r.contains=[]),r.contains=[].concat(...r.contains.map((e=>(e=>(e.variants&&!e.cachedVariants&&(e.cachedVariants=e.variants.map((n=>a(e,{' + sLineBreak +
    'variants:null},n)))),e.cachedVariants?e.cachedVariants:Q(e)?a(e,{' + sLineBreak +
    'starts:e.starts?a(e.starts):null' + sLineBreak +
    '}):Object.isFrozen(e)?a(e):e))("self"===e?r:e)))),r.contains.forEach((e=>{t(e,o)' + sLineBreak +
    '})),r.starts&&t(r.starts,s),o.matcher=(e=>{const n=new i' + sLineBreak +
    ';return e.contains.forEach((e=>n.addRule(e.begin,{rule:e,type:"begin"' + sLineBreak +
    '}))),e.terminatorEnd&&n.addRule(e.terminatorEnd,{type:"end"' + sLineBreak +
    '}),e.illegal&&n.addRule(e.illegal,{type:"illegal"}),n})(o),o}(e)}function Q(e){' + sLineBreak +
    'return!!e&&(e.endsWithParent||Q(e.starts))}class X extends Error{' + sLineBreak +
    'constructor(e,n){super(e),this.name="HTMLInjectionError",this.html=n}}' + sLineBreak +
    'const V=t,J=a,Y=Symbol("nomatch"),ee=t=>{' + sLineBreak +
    'const a=Object.create(null),i=Object.create(null),r=[];let s=!0' + sLineBreak +
    ';const o="Could not find the language ''{}'', did you forget to load/include a language module?",c={' + sLineBreak +
    'disableAutodetect:!0,name:"Plain text",contains:[]};let p={' + sLineBreak +
    'ignoreUnescapedHTML:!1,throwUnescapedHTML:!1,noHighlightRe:/^(no-?highlight)$/i,' + sLineBreak +
    'languageDetectRe:/\blang(?:uage)?-([\w-]+)\b/i,classPrefix:"hljs-",' + sLineBreak +
    'cssSelector:"pre code",languages:null,__emitter:l};function _(e){' + sLineBreak +
    'return p.noHighlightRe.test(e)}function h(e,n,t){let a="",i=""' + sLineBreak +
    ';"object"==typeof n?(a=e,' + sLineBreak +
    't=n.ignoreIllegals,i=n.language):(q("10.7.0","highlight(lang, code, ...args) has been deprecated."),' + sLineBreak +
    'q("10.7.0","Please use highlight(code, options) instead.\nhttps://github.com/highlightjs/highlight.js/issues/2277"),' + sLineBreak +
    'i=e,a=n),void 0===t&&(t=!0);const r={code:a,language:i};O("before:highlight",r)' + sLineBreak +
    ';const s=r.result?r.result:f(r.language,r.code,t)' + sLineBreak +
    ';return s.code=r.code,O("after:highlight",s),s}function f(e,t,i,r){' + sLineBreak +
    'const l=Object.create(null);function c(){if(!O.keywords)return void A.addText(S)' + sLineBreak +
    ';let e=0;O.keywordPatternRe.lastIndex=0;let n=O.keywordPatternRe.exec(S),t=""' + sLineBreak +
    ';for(;n;){t+=S.substring(e,n.index)' + sLineBreak +
    ';const i=v.case_insensitive?n[0].toLowerCase():n[0],r=(a=i,O.keywords[a]);if(r){' + sLineBreak +
    'const[e,a]=r' + sLineBreak +
    ';if(A.addText(t),t="",l[i]=(l[i]||0)+1,l[i]<=7&&(C+=a),e.startsWith("_"))t+=n[0];else{' + sLineBreak +
    'const t=v.classNameAliases[e]||e;g(n[0],t)}}else t+=n[0]' + sLineBreak +
    ';e=O.keywordPatternRe.lastIndex,n=O.keywordPatternRe.exec(S)}var a' + sLineBreak +
    ';t+=S.substring(e),A.addText(t)}function d(){null!=O.subLanguage?(()=>{' + sLineBreak +
    'if(""===S)return;let e=null;if("string"==typeof O.subLanguage){' + sLineBreak +
    'if(!a[O.subLanguage])return void A.addText(S)' + sLineBreak +
    ';e=f(O.subLanguage,S,!0,M[O.subLanguage]),M[O.subLanguage]=e._top' + sLineBreak +
    '}else e=E(S,O.subLanguage.length?O.subLanguage:null)' + sLineBreak +
    ';O.relevance>0&&(C+=e.relevance),A.__addSublanguage(e._emitter,e.language)' + sLineBreak +
    '})():c(),S=""}function g(e,n){' + sLineBreak +
    '""!==e&&(A.startScope(n),A.addText(e),A.endScope())}function u(e,n){let t=1' + sLineBreak +
    ';const a=n.length-1;for(;t<=a;){if(!e._emit[t]){t++;continue}' + sLineBreak +
    'const a=v.classNameAliases[e[t]]||e[t],i=n[t];a?g(i,a):(S=i,c(),S=""),t++}}' + sLineBreak +
    'function b(e,n){' + sLineBreak +
    'return e.scope&&"string"==typeof e.scope&&A.openNode(v.classNameAliases[e.scope]||e.scope),' + sLineBreak +
    'e.beginScope&&(e.beginScope._wrap?(g(S,v.classNameAliases[e.beginScope._wrap]||e.beginScope._wrap),' + sLineBreak +
    'S=""):e.beginScope._multi&&(u(e.beginScope,n),S="")),O=Object.create(e,{parent:{' + sLineBreak +
    'value:O}}),O}function m(e,t,a){let i=((e,n)=>{const t=e&&e.exec(n)' + sLineBreak +
    ';return t&&0===t.index})(e.endRe,a);if(i){if(e["on:end"]){const a=new n(e)' + sLineBreak +
    ';e["on:end"](t,a),a.isMatchIgnored&&(i=!1)}if(i){' + sLineBreak +
    'for(;e.endsParent&&e.parent;)e=e.parent;return e}}' + sLineBreak +
    'if(e.endsWithParent)return m(e.parent,t,a)}function _(e){' + sLineBreak +
    'return 0===O.matcher.regexIndex?(S+=e[0],1):(D=!0,0)}function h(e){' + sLineBreak +
    'const n=e[0],a=t.substring(e.index),i=m(O,e,a);if(!i)return Y;const r=O' + sLineBreak +
    ';O.endScope&&O.endScope._wrap?(d(),' + sLineBreak +
    'g(n,O.endScope._wrap)):O.endScope&&O.endScope._multi?(d(),' + sLineBreak +
    'u(O.endScope,e)):r.skip?S+=n:(r.returnEnd||r.excludeEnd||(S+=n),' + sLineBreak +
    'd(),r.excludeEnd&&(S=n));do{' + sLineBreak +
    'O.scope&&A.closeNode(),O.skip||O.subLanguage||(C+=O.relevance),O=O.parent' + sLineBreak +
    '}while(O!==i.parent);return i.starts&&b(i.starts,e),r.returnEnd?0:n.length}' + sLineBreak +
    'let y={};function w(a,r){const o=r&&r[0];if(S+=a,null==o)return d(),0' + sLineBreak +
    ';if("begin"===y.type&&"end"===r.type&&y.index===r.index&&""===o){' + sLineBreak +
    'if(S+=t.slice(r.index,r.index+1),!s){const n=Error(`0 width match regex (${e})`)' + sLineBreak +
    ';throw n.languageName=e,n.badRule=y.rule,n}return 1}' + sLineBreak +
    'if(y=r,"begin"===r.type)return(e=>{' + sLineBreak +
    'const t=e[0],a=e.rule,i=new n(a),r=[a.__beforeBegin,a["on:begin"]]' + sLineBreak +
    ';for(const n of r)if(n&&(n(e,i),i.isMatchIgnored))return _(t)' + sLineBreak +
    ';return a.skip?S+=t:(a.excludeBegin&&(S+=t),' + sLineBreak +
    'd(),a.returnBegin||a.excludeBegin||(S=t)),b(a,e),a.returnBegin?0:t.length})(r)' + sLineBreak +
    ';if("illegal"===r.type&&!i){' + sLineBreak +
    'const e=Error(''Illegal lexeme "''+o+''" for mode "''+(O.scope||"<unnamed>")+''"'')' + sLineBreak +
    ';throw e.mode=O,e}if("end"===r.type){const e=h(r);if(e!==Y)return e}' + sLineBreak +
    'if("illegal"===r.type&&""===o)return S+="\n",1' + sLineBreak +
    ';if(R>1e5&&R>3*r.index)throw Error("potential infinite loop, way more iterations than matches")' + sLineBreak +
    ';return S+=o,o.length}const v=N(e)' + sLineBreak +
    ';if(!v)throw P(o.replace("{}",e)),Error(''Unknown language: "''+e+''"'')' + sLineBreak +
    ';const k=W(v);let x="",O=r||k;const M={},A=new p.__emitter(p);(()=>{const e=[]' + sLineBreak +
    ';for(let n=O;n!==v;n=n.parent)n.scope&&e.unshift(n.scope)' + sLineBreak +
    ';e.forEach((e=>A.openNode(e)))})();let S="",C=0,T=0,R=0,D=!1;try{' + sLineBreak +
    'if(v.__emitTokens)v.__emitTokens(t,A);else{for(O.matcher.considerAll();;){' + sLineBreak +
    'R++,D?D=!1:O.matcher.considerAll(),O.matcher.lastIndex=T' + sLineBreak +
    ';const e=O.matcher.exec(t);if(!e)break;const n=w(t.substring(T,e.index),e)' + sLineBreak +
    ';T=e.index+n}w(t.substring(T))}return A.finalize(),x=A.toHTML(),{language:e,' + sLineBreak +
    'value:x,relevance:C,illegal:!1,_emitter:A,_top:O}}catch(n){' + sLineBreak +
    'if(n.message&&n.message.includes("Illegal"))return{language:e,value:V(t),' + sLineBreak +
    'illegal:!0,relevance:0,_illegalBy:{message:n.message,index:T,' + sLineBreak +
    'context:t.slice(T-100,T+100),mode:n.mode,resultSoFar:x},_emitter:A};if(s)return{' + sLineBreak +
    'language:e,value:V(t),illegal:!1,relevance:0,errorRaised:n,_emitter:A,_top:O}' + sLineBreak +
    ';throw n}}function E(e,n){n=n||p.languages||Object.keys(a);const t=(e=>{' + sLineBreak +
    'const n={value:V(e),illegal:!1,relevance:0,_top:c,_emitter:new p.__emitter(p)}' + sLineBreak +
    ';return n._emitter.addText(e),n})(e),i=n.filter(N).filter(x).map((n=>f(n,e,!1)))' + sLineBreak +
    ';i.unshift(t);const r=i.sort(((e,n)=>{' + sLineBreak +
    'if(e.relevance!==n.relevance)return n.relevance-e.relevance' + sLineBreak +
    ';if(e.language&&n.language){if(N(e.language).supersetOf===n.language)return 1' + sLineBreak +
    ';if(N(n.language).supersetOf===e.language)return-1}return 0})),[s,o]=r,l=s' + sLineBreak +
    ';return l.secondBest=o,l}function y(e){let n=null;const t=(e=>{' + sLineBreak +
    'let n=e.className+" ";n+=e.parentNode?e.parentNode.className:""' + sLineBreak +
    ';const t=p.languageDetectRe.exec(n);if(t){const n=N(t[1])' + sLineBreak +
    ';return n||(K(o.replace("{}",t[1])),' + sLineBreak +
    'K("Falling back to no-highlight mode for this block.",e)),n?t[1]:"no-highlight"}' + sLineBreak +
    'return n.split(/\s+/).find((e=>_(e)||N(e)))})(e);if(_(t))return' + sLineBreak +
    ';if(O("before:highlightElement",{el:e,language:t' + sLineBreak +
    '}),e.dataset.highlighted)return void console.log("Element previously highlighted. To highlight again, first unset `dataset.highlighted`.",e)' + sLineBreak +
    ';if(e.children.length>0&&(p.ignoreUnescapedHTML||(console.warn("One of your code blocks includes unescaped HTML. This is a potentially serious security risk."),' + sLineBreak +
    'console.warn("https://github.com/highlightjs/highlight.js/wiki/security"),' + sLineBreak +
    'console.warn("The element with unescaped HTML:"),' + sLineBreak +
    'console.warn(e)),p.throwUnescapedHTML))throw new X("One of your code blocks includes unescaped HTML.",e.innerHTML)' + sLineBreak +
    ';n=e;const a=n.textContent,r=t?h(a,{language:t,ignoreIllegals:!0}):E(a)' + sLineBreak +
    ';e.innerHTML=r.value,e.dataset.highlighted="yes",((e,n,t)=>{const a=n&&i[n]||t' + sLineBreak +
    ';e.classList.add("hljs"),e.classList.add("language-"+a)' + sLineBreak +
    '})(e,t,r.language),e.result={language:r.language,re:r.relevance,' + sLineBreak +
    'relevance:r.relevance},r.secondBest&&(e.secondBest={' + sLineBreak +
    'language:r.secondBest.language,relevance:r.secondBest.relevance' + sLineBreak +
    '}),O("after:highlightElement",{el:e,result:r,text:a})}let w=!1;function v(){' + sLineBreak +
    'if("loading"===document.readyState)return w||window.addEventListener("DOMContentLoaded",(()=>{' + sLineBreak +
    'v()}),!1),void(w=!0);document.querySelectorAll(p.cssSelector).forEach(y)}' + sLineBreak +
    'function N(e){return e=(e||"").toLowerCase(),a[e]||a[i[e]]}' + sLineBreak +
    'function k(e,{languageName:n}){"string"==typeof e&&(e=[e]),e.forEach((e=>{' + sLineBreak +
    'i[e.toLowerCase()]=n}))}function x(e){const n=N(e)' + sLineBreak +
    ';return n&&!n.disableAutodetect}function O(e,n){const t=e;r.forEach((e=>{' + sLineBreak +
    'e[t]&&e[t](n)}))}Object.assign(t,{highlight:h,highlightAuto:E,highlightAll:v,' + sLineBreak +
    'highlightElement:y,' + sLineBreak +
    'highlightBlock:e=>(q("10.7.0","highlightBlock will be removed entirely in v12.0"),' + sLineBreak +
    'q("10.7.0","Please use highlightElement now."),y(e)),configure:e=>{p=J(p,e)},' + sLineBreak +
    'initHighlighting:()=>{' + sLineBreak +
    'v(),q("10.6.0","initHighlighting() deprecated.  Use highlightAll() now.")},' + sLineBreak +
    'initHighlightingOnLoad:()=>{' + sLineBreak +
    'v(),q("10.6.0","initHighlightingOnLoad() deprecated.  Use highlightAll() now.")' + sLineBreak +
    '},registerLanguage:(e,n)=>{let i=null;try{i=n(t)}catch(n){' + sLineBreak +
    'if(P("Language definition for ''{}'' could not be registered.".replace("{}",e)),' + sLineBreak +
    '!s)throw n;P(n),i=c}' + sLineBreak +
    'i.name||(i.name=e),a[e]=i,i.rawDefinition=n.bind(null,t),i.aliases&&k(i.aliases,{' + sLineBreak +
    'languageName:e})},unregisterLanguage:e=>{delete a[e]' + sLineBreak +
    ';for(const n of Object.keys(i))i[n]===e&&delete i[n]},' + sLineBreak +
    'listLanguages:()=>Object.keys(a),getLanguage:N,registerAliases:k,' + sLineBreak +
    'autoDetection:x,inherit:J,addPlugin:e=>{(e=>{' + sLineBreak +
    'e["before:highlightBlock"]&&!e["before:highlightElement"]&&(e["before:highlightElement"]=n=>{' + sLineBreak +
    'e["before:highlightBlock"](Object.assign({block:n.el},n))' + sLineBreak +
    '}),e["after:highlightBlock"]&&!e["after:highlightElement"]&&(e["after:highlightElement"]=n=>{' + sLineBreak +
    'e["after:highlightBlock"](Object.assign({block:n.el},n))})})(e),r.push(e)},' + sLineBreak +
    'removePlugin:e=>{const n=r.indexOf(e);-1!==n&&r.splice(n,1)}}),t.debugMode=()=>{' + sLineBreak +
    's=!1},t.safeMode=()=>{s=!0},t.versionString="11.11.1",t.regex={concat:b,' + sLineBreak +
    'lookahead:d,either:m,optional:u,anyNumberOfTimes:g}' + sLineBreak +
    ';for(const n in C)"object"==typeof C[n]&&e(C[n]);return Object.assign(t,C),t' + sLineBreak +
    '},ne=ee({});ne.newInstance=()=>ee({});const te=e=>({IMPORTANT:{scope:"meta",' + sLineBreak +
    'begin:"!important"},BLOCK_COMMENT:e.C_BLOCK_COMMENT_MODE,HEXCOLOR:{' + sLineBreak +
    'scope:"number",begin:/#(([0-9a-fA-F]{3,4})|(([0-9a-fA-F]{2}){3,4}))\b/},' + sLineBreak +
    'FUNCTION_DISPATCH:{className:"built_in",begin:/[\w-]+(?=\()/},' + sLineBreak +
    'ATTRIBUTE_SELECTOR_MODE:{scope:"selector-attr",begin:/\[/,end:/\]/,illegal:"$",' + sLineBreak +
    'contains:[e.APOS_STRING_MODE,e.QUOTE_STRING_MODE]},CSS_NUMBER_MODE:{' + sLineBreak +
    'scope:"number",' + sLineBreak +
    'begin:e.NUMBER_RE+"(%|em|ex|ch|rem|vw|vh|vmin|vmax|cm|mm|in|pt|pc|px|deg|grad|rad|turn|s|ms|Hz|kHz|dpi|dpcm|dppx)?",' + sLineBreak +
    'relevance:0},CSS_VARIABLE:{className:"attr",begin:/--[A-Za-z_][A-Za-z0-9_-]*/}' + sLineBreak +
    '}),ae=["a","abbr","address","article","aside","audio","b","blockquote","body","button","canvas","caption","cite","code","dd","del","details","dfn","div","dl","dt","em","fieldset","figcaption","figure","footer","form","h1","h2","h3","h4","h5","h6","he' +
    'ader","hgroup","html","i","iframe","img","input","ins","kbd","label","legend","li","main","mark","menu","nav","object","ol","optgroup","option","p","picture","q","quote","samp","section","select","source","span","strong","summary","sup","table","tbod' +
    'y","td","textarea","tfoot","th","thead","time","tr","ul","var","video","defs","g","marker","mask","pattern","svg","switch","symbol","feBlend","feColorMatrix","feComponentTransfer","feComposite","feConvolveMatrix","feDiffuseLighting","feDisplacementMa' +
    'p","feFlood","feGaussianBlur","feImage","feMerge","feMorphology","feOffset","feSpecularLighting","feTile","feTurbulence","linearGradient","radialGradi' +
    'ent","stop","circle","ellipse","image","line","path","polygon","polyline","rect","text","use","textPath","tspan","foreignObject","clipPath"],ie=["any-hover","any-pointer","aspect-ratio","color","color-gamut","color-index","device-aspect-ratio","devic' +
    'e-height","device-width","display-mode","forced-colors","grid","height","hover","inverted-colors","monochrome","orientation","overflow-block","overflow-inline","pointer","prefers-color-scheme","prefers-contrast","prefers-reduced-motion","prefers-redu' +
    'ced-transparency","resolution","scan","scripting","update","width","min-width","max-width","min-height","max-height"].sort().reverse(),re=["active","any-link","blank","checked","current","default","defined","dir","disabled","drop","empty","enabled","' +
    'first","first-child","first-of-type","fullscreen","future","focus","focus-visible","focus-within","has","host","host-context","hover","indeterminate",' +
    '"in-range","invalid","is","lang","last-child","last-of-type","left","link","local-link","not","nth-child","nth-col","nth-last-child","nth-last-col","nth-last-of-type","nth-of-type","only-child","only-of-type","optional","out-of-range","past","placeho' +
    'lder-shown","read-only","read-write","required","right","root","scope","target","target-within","user-invalid","valid","visited","where"].sort().reverse(),se=["after","backdrop","before","cue","cue-region","first-letter","first-line","grammar-error",' +
    '"marker","part","placeholder","selection","slotted","spelling-error"].sort().reverse(),oe=["accent-color","align-content","align-items","align-self","alignment-baseline","all","anchor-name","animation","animation-composition","animation-delay","anima' +
    'tion-direction","animation-duration","animation-fill-mode","animation-iteration-count","animation-name","animation-play-state","animation-range","anim' +
    'ation-range-end","animation-range-start","animation-timeline","animation-timing-function","appearance","aspect-ratio","backdrop-filter","backface-visibility","background","background-attachment","background-blend-mode","background-clip","background-c' +
    'olor","background-image","background-origin","background-position","background-position-x","background-position-y","background-repeat","background-size","baseline-shift","block-size","border","border-block","border-block-color","border-block-end","bo' +
    'rder-block-end-color","border-block-end-style","border-block-end-width","border-block-start","border-block-start-color","border-block-start-style","border-block-start-width","border-block-style","border-block-width","border-bottom","border-bottom-col' +
    'or","border-bottom-left-radius","border-bottom-right-radius","border-bottom-style","border-bottom-width","border-collapse","border-color","border-end-' +
    'end-radius","border-end-start-radius","border-image","border-image-outset","border-image-repeat","border-image-slice","border-image-source","border-image-width","border-inline","border-inline-color","border-inline-end","border-inline-end-color","bord' +
    'er-inline-end-style","border-inline-end-width","border-inline-start","border-inline-start-color","border-inline-start-style","border-inline-start-width","border-inline-style","border-inline-width","border-left","border-left-color","border-left-style"' +
    ',"border-left-width","border-radius","border-right","border-right-color","border-right-style","border-right-width","border-spacing","border-start-end-radius","border-start-start-radius","border-style","border-top","border-top-color","border-top-left-' +
    'radius","border-top-right-radius","border-top-style","border-top-width","border-width","bottom","box-align","box-decoration-break","box-direction","bo' +
    'x-flex","box-flex-group","box-lines","box-ordinal-group","box-orient","box-pack","box-shadow","box-sizing","break-after","break-before","break-inside","caption-side","caret-color","clear","clip","clip-path","clip-rule","color","color-interpolation","' +
    'color-interpolation-filters","color-profile","color-rendering","color-scheme","column-count","column-fill","column-gap","column-rule","column-rule-color","column-rule-style","column-rule-width","column-span","column-width","columns","contain","contai' +
    'n-intrinsic-block-size","contain-intrinsic-height","contain-intrinsic-inline-size","contain-intrinsic-size","contain-intrinsic-width","container","container-name","container-type","content","content-visibility","counter-increment","counter-reset","co' +
    'unter-set","cue","cue-after","cue-before","cursor","cx","cy","direction","display","dominant-baseline","empty-cells","enable-background","field-sizing' +
    '","fill","fill-opacity","fill-rule","filter","flex","flex-basis","flex-direction","flex-flow","flex-grow","flex-shrink","flex-wrap","float","flood-color","flood-opacity","flow","font","font-display","font-family","font-feature-settings","font-kerning' +
    '","font-language-override","font-optical-sizing","font-palette","font-size","font-size-adjust","font-smooth","font-smoothing","font-stretch","font-style","font-synthesis","font-synthesis-position","font-synthesis-small-caps","font-synthesis-style","f' +
    'ont-synthesis-weight","font-variant","font-variant-alternates","font-variant-caps","font-variant-east-asian","font-variant-emoji","font-variant-ligatures","font-variant-numeric","font-variant-position","font-variation-settings","font-weight","forced-' +
    'color-adjust","gap","glyph-orientation-horizontal","glyph-orientation-vertical","grid","grid-area","grid-auto-columns","grid-auto-flow","grid-auto-row' +
    's","grid-column","grid-column-end","grid-column-start","grid-gap","grid-row","grid-row-end","grid-row-start","grid-template","grid-template-areas","grid-template-columns","grid-template-rows","hanging-punctuation","height","hyphenate-character","hyph' +
    'enate-limit-chars","hyphens","icon","image-orientation","image-rendering","image-resolution","ime-mode","initial-letter","initial-letter-align","inline-size","inset","inset-area","inset-block","inset-block-end","inset-block-start","inset-inline","ins' +
    'et-inline-end","inset-inline-start","isolation","justify-content","justify-items","justify-self","kerning","left","letter-spacing","lighting-color","line-break","line-height","line-height-step","list-style","list-style-image","list-style-position","l' +
    'ist-style-type","margin","margin-block","margin-block-end","margin-block-start","margin-bottom","margin-inline","margin-inline-end","margin-inline-sta' +
    'rt","margin-left","margin-right","margin-top","margin-trim","marker","marker-end","marker-mid","marker-start","marks","mask","mask-border","mask-border-mode","mask-border-outset","mask-border-repeat","mask-border-slice","mask-border-source","mask-bor' +
    'der-width","mask-clip","mask-composite","mask-image","mask-mode","mask-origin","mask-position","mask-repeat","mask-size","mask-type","masonry-auto-flow","math-depth","math-shift","math-style","max-block-size","max-height","max-inline-size","max-width' +
    '","min-block-size","min-height","min-inline-size","min-width","mix-blend-mode","nav-down","nav-index","nav-left","nav-right","nav-up","none","normal","object-fit","object-position","offset","offset-anchor","offset-distance","offset-path","offset-posi' +
    'tion","offset-rotate","opacity","order","orphans","outline","outline-color","outline-offset","outline-style","outline-width","overflow","overflow-anch' +
    'or","overflow-block","overflow-clip-margin","overflow-inline","overflow-wrap","overflow-x","overflow-y","overlay","overscroll-behavior","overscroll-behavior-block","overscroll-behavior-inline","overscroll-behavior-x","overscroll-behavior-y","padding"' +
    ',"padding-block","padding-block-end","padding-block-start","padding-bottom","padding-inline","padding-inline-end","padding-inline-start","padding-left","padding-right","padding-top","page","page-break-after","page-break-before","page-break-inside","p' +
    'aint-order","pause","pause-after","pause-before","perspective","perspective-origin","place-content","place-items","place-self","pointer-events","position","position-anchor","position-visibility","print-color-adjust","quotes","r","resize","rest","rest' +
    '-after","rest-before","right","rotate","row-gap","ruby-align","ruby-position","scale","scroll-behavior","scroll-margin","scroll-margin-block","scroll-' +
    'margin-block-end","scroll-margin-block-start","scroll-margin-bottom","scroll-margin-inline","scroll-margin-inline-end","scroll-margin-inline-start","scroll-margin-left","scroll-margin-right","scroll-margin-top","scroll-padding","scroll-padding-block"' +
    ',"scroll-padding-block-end","scroll-padding-block-start","scroll-padding-bottom","scroll-padding-inline","scroll-padding-inline-end","scroll-padding-inline-start","scroll-padding-left","scroll-padding-right","scroll-padding-top","scroll-snap-align","' +
    'scroll-snap-stop","scroll-snap-type","scroll-timeline","scroll-timeline-axis","scroll-timeline-name","scrollbar-color","scrollbar-gutter","scrollbar-width","shape-image-threshold","shape-margin","shape-outside","shape-rendering","speak","speak-as","s' +
    'rc","stop-color","stop-opacity","stroke","stroke-dasharray","stroke-dashoffset","stroke-linecap","stroke-linejoin","stroke-miterlimit","stroke-opacity' +
    '","stroke-width","tab-size","table-layout","text-align","text-align-all","text-align-last","text-anchor","text-combine-upright","text-decoration","text-decoration-color","text-decoration-line","text-decoration-skip","text-decoration-skip-ink","text-d' +
    'ecoration-style","text-decoration-thickness","text-emphasis","text-emphasis-color","text-emphasis-position","text-emphasis-style","text-indent","text-justify","text-orientation","text-overflow","text-rendering","text-shadow","text-size-adjust","text-' +
    'transform","text-underline-offset","text-underline-position","text-wrap","text-wrap-mode","text-wrap-style","timeline-scope","top","touch-action","transform","transform-box","transform-origin","transform-style","transition","transition-behavior","tra' +
    'nsition-delay","transition-duration","transition-property","transition-timing-function","translate","unicode-bidi","user-modify","user-select","vector' +
    '-effect","vertical-align","view-timeline","view-timeline-axis","view-timeline-inset","view-timeline-name","view-transition-name","visibility","voice-balance","voice-duration","voice-family","voice-pitch","voice-range","voice-rate","voice-stress","voi' +
    'ce-volume","white-space","white-space-collapse","widows","width","will-change","word-break","word-spacing","word-wrap","writing-mode","x","y","z-index","zoom"].sort().reverse(),le=re.concat(se).sort().reverse()' + sLineBreak +
    ';var ce="[0-9](_*[0-9])*",de=`\\.(${ce})`,ge="[0-9a-fA-F](_*[0-9a-fA-F])*",ue={' + sLineBreak +
    'className:"number",variants:[{' + sLineBreak +
    'begin:`(\\b(${ce})((${de})|\\.)?|(${de}))[eE][+-]?(${ce})[fFdD]?\\b`},{' + sLineBreak +
    'begin:`\\b(${ce})((${de})[fFdD]?\\b|\\.([fFdD]\\b)?)`},{' + sLineBreak +
    'begin:`(${de})[fFdD]?\\b`},{begin:`\\b(${ce})[fFdD]\\b`},{' + sLineBreak +
    'begin:`\\b0[xX]((${ge})\\.?|(${ge})?\\.(${ge}))[pP][+-]?(${ce})[fFdD]?\\b`},{' + sLineBreak +
    'begin:"\\b(0|[1-9](_*[0-9])*)[lL]?\\b"},{begin:`\\b0[xX](${ge})[lL]?\\b`},{' + sLineBreak +
    'begin:"\\b0(_*[0-7])*[lL]?\\b"},{begin:"\\b0[bB][01](_*[01])*[lL]?\\b"}],' + sLineBreak +
    'relevance:0};function be(e,n,t){return-1===t?"":e.replace(n,(a=>be(e,n,t-1)))}' + sLineBreak +
    'const me="[A-Za-z$_][0-9A-Za-z$_]*",pe=["as","in","of","if","for","while","finally","var","new","function","do","return","void","else","break","catch","instanceof","with","throw","case","default","try","switch","continue","typeof","delete","let","yie' +
    'ld","const","class","debugger","async","await","static","import","from","export","extends","using"],_e=["true","false","null","undefined","NaN","Infinity"],he=["Object","Function","Boolean","Symbol","Math","Date","Number","BigInt","String","RegExp","' +
    'Array","Float32Array","Float64Array","Int8Array","Uint8Array","Uint8ClampedArray","Int16Array","Int32Array","Uint16Array","Uint32Array","BigInt64Array","BigUint64Array","Set","Map","WeakSet","WeakMap","ArrayBuffer","SharedArrayBuffer","Atomics","Data' +
    'View","JSON","Promise","Generator","GeneratorFunction","AsyncFunction","Reflect","Proxy","Intl","WebAssembly"],fe=["Error","EvalError","InternalError"' +
    ',"RangeError","ReferenceError","SyntaxError","TypeError","URIError"],Ee=["setInterval","setTimeout","clearInterval","clearTimeout","require","exports","eval","isFinite","isNaN","parseFloat","parseInt","decodeURI","decodeURIComponent","encodeURI","enc' +
    'odeURIComponent","escape","unescape"],ye=["arguments","this","super","console","window","document","localStorage","sessionStorage","module","global"],we=[].concat(Ee,he,fe)' + sLineBreak +
    ';function ve(e){const n=e.regex,t=me,a={begin:/<[A-Za-z0-9\\._:-]+/,' + sLineBreak +
    'end:/\/[A-Za-z0-9\\._:-]+>|\/>/,isTrulyOpeningTag:(e,n)=>{' + sLineBreak +
    'const t=e[0].length+e.index,a=e.input[t]' + sLineBreak +
    ';if("<"===a||","===a)return void n.ignoreMatch();let i' + sLineBreak +
    ';">"===a&&(((e,{after:n})=>{const t="</"+e[0].slice(1)' + sLineBreak +
    ';return-1!==e.input.indexOf(t,n)})(e,{after:t})||n.ignoreMatch())' + sLineBreak +
    ';const r=e.input.substring(t)' + sLineBreak +
    ';((i=r.match(/^\s*=/))||(i=r.match(/^\s+extends\s+/))&&0===i.index)&&n.ignoreMatch()' + sLineBreak +
    '}},i={$pattern:me,keyword:pe,literal:_e,built_in:we,"variable.language":ye' + sLineBreak +
    '},r="[0-9](_?[0-9])*",s=`\\.(${r})`,o="0|[1-9](_?[0-9])*|0[0-7]*[89][0-9]*",l={' + sLineBreak +
    'className:"number",variants:[{' + sLineBreak +
    'begin:`(\\b(${o})((${s})|\\.)?|(${s}))[eE][+-]?(${r})\\b`},{' + sLineBreak +
    'begin:`\\b(${o})\\b((${s})\\b|\\.)?|(${s})\\b`},{' + sLineBreak +
    'begin:"\\b(0|[1-9](_?[0-9])*)n\\b"},{' + sLineBreak +
    'begin:"\\b0[xX][0-9a-fA-F](_?[0-9a-fA-F])*n?\\b"},{' + sLineBreak +
    'begin:"\\b0[bB][0-1](_?[0-1])*n?\\b"},{begin:"\\b0[oO][0-7](_?[0-7])*n?\\b"},{' + sLineBreak +
    'begin:"\\b0[0-7]+n?\\b"}],relevance:0},c={className:"subst",begin:"\\$\\{",' + sLineBreak +
    'end:"\\}",keywords:i,contains:[]},d={begin:".?html`",end:"",starts:{end:"`",' + sLineBreak +
    'returnEnd:!1,contains:[e.BACKSLASH_ESCAPE,c],subLanguage:"xml"}},g={' + sLineBreak +
    'begin:".?css`",end:"",starts:{end:"`",returnEnd:!1,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,c],subLanguage:"css"}},u={begin:".?gql`",end:"",' + sLineBreak +
    'starts:{end:"`",returnEnd:!1,contains:[e.BACKSLASH_ESCAPE,c],' + sLineBreak +
    'subLanguage:"graphql"}},b={className:"string",begin:"`",end:"`",' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,c]},m={className:"comment",' + sLineBreak +
    'variants:[e.COMMENT(/\/\*\*(?!\/)/,"\\*/",{relevance:0,contains:[{' + sLineBreak +
    'begin:"(?=@[A-Za-z]+)",relevance:0,contains:[{className:"doctag",' + sLineBreak +
    'begin:"@[A-Za-z]+"},{className:"type",begin:"\\{",end:"\\}",excludeEnd:!0,' + sLineBreak +
    'excludeBegin:!0,relevance:0},{className:"variable",begin:t+"(?=\\s*(-)|$)",' + sLineBreak +
    'endsParent:!0,relevance:0},{begin:/(?=[^\n])\s/,relevance:0}]}]' + sLineBreak +
    '}),e.C_BLOCK_COMMENT_MODE,e.C_LINE_COMMENT_MODE]' + sLineBreak +
    '},p=[e.APOS_STRING_MODE,e.QUOTE_STRING_MODE,d,g,u,b,{match:/\$\d+/},l]' + sLineBreak +
    ';c.contains=p.concat({begin:/\{/,end:/\}/,keywords:i,contains:["self"].concat(p)' + sLineBreak +
    '});const _=[].concat(m,c.contains),h=_.concat([{begin:/(\s*)\(/,end:/\)/,' + sLineBreak +
    'keywords:i,contains:["self"].concat(_)}]),f={className:"params",begin:/(\s*)\(/,' + sLineBreak +
    'end:/\)/,excludeBegin:!0,excludeEnd:!0,keywords:i,contains:h},E={variants:[{' + sLineBreak +
    'match:[/class/,/\s+/,t,/\s+/,/extends/,/\s+/,n.concat(t,"(",n.concat(/\./,t),")*")],' + sLineBreak +
    'scope:{1:"keyword",3:"title.class",5:"keyword",7:"title.class.inherited"}},{' + sLineBreak +
    'match:[/class/,/\s+/,t],scope:{1:"keyword",3:"title.class"}}]},y={relevance:0,' + sLineBreak +
    'match:n.either(/\bJSON/,/\b[A-Z][a-z]+([A-Z][a-z]*|\d)*/,/\b[A-Z]{2,}([A-Z][a-z]+|\d)+([A-Z][a-z]*)*/,/\b[A-Z]{2,}[a-z]+([A-Z][a-z]+|\d)*([A-Z][a-z]*)*/),' + sLineBreak +
    'className:"title.class",keywords:{_:[...he,...fe]}},w={variants:[{' + sLineBreak +
    'match:[/function/,/\s+/,t,/(?=\s*\()/]},{match:[/function/,/\s*(?=\()/]}],' + sLineBreak +
    'className:{1:"keyword",3:"title.function"},label:"func.def",contains:[f],' + sLineBreak +
    'illegal:/%/},v={' + sLineBreak +
    'match:n.concat(/\b/,(N=[...Ee,"super","import"].map((e=>e+"\\s*\\(")),' + sLineBreak +
    'n.concat("(?!",N.join("|"),")")),t,n.lookahead(/\s*\(/)),' + sLineBreak +
    'className:"title.function",relevance:0};var N;const k={' + sLineBreak +
    'begin:n.concat(/\./,n.lookahead(n.concat(t,/(?![0-9A-Za-z$_(])/))),end:t,' + sLineBreak +
    'excludeBegin:!0,keywords:"prototype",className:"property",relevance:0},x={' + sLineBreak +
    'match:[/get|set/,/\s+/,t,/(?=\()/],className:{1:"keyword",3:"title.function"},' + sLineBreak +
    'contains:[{begin:/\(\)/},f]' + sLineBreak +
    '},O="(\\([^()]*(\\([^()]*(\\([^()]*\\)[^()]*)*\\)[^()]*)*\\)|"+e.UNDERSCORE_IDENT_RE+")\\s*=>",M={' + sLineBreak +
    'match:[/const|var|let/,/\s+/,t,/\s*/,/=\s*/,/(async\s*)?/,n.lookahead(O)],' + sLineBreak +
    'keywords:"async",className:{1:"keyword",3:"title.function"},contains:[f]}' + sLineBreak +
    ';return{name:"JavaScript",aliases:["js","jsx","mjs","cjs"],keywords:i,exports:{' + sLineBreak +
    'PARAMS_CONTAINS:h,CLASS_REFERENCE:y},illegal:/#(?![$_A-z])/,' + sLineBreak +
    'contains:[e.SHEBANG({label:"shebang",binary:"node",relevance:5}),{' + sLineBreak +
    'label:"use_strict",className:"meta",relevance:10,' + sLineBreak +
    'begin:/^\s*[''"]use (strict|asm)[''"]/' + sLineBreak +
    '},e.APOS_STRING_MODE,e.QUOTE_STRING_MODE,d,g,u,b,m,{match:/\$\d+/},l,y,{' + sLineBreak +
    'scope:"attr",match:t+n.lookahead(":"),relevance:0},M,{' + sLineBreak +
    'begin:"("+e.RE_STARTERS_RE+"|\\b(case|return|throw)\\b)\\s*",' + sLineBreak +
    'keywords:"return throw case",relevance:0,contains:[m,e.REGEXP_MODE,{' + sLineBreak +
    'className:"function",begin:O,returnBegin:!0,end:"\\s*=>",contains:[{' + sLineBreak +
    'className:"params",variants:[{begin:e.UNDERSCORE_IDENT_RE,relevance:0},{' + sLineBreak +
    'className:null,begin:/\(\s*\)/,skip:!0},{begin:/(\s*)\(/,end:/\)/,' + sLineBreak +
    'excludeBegin:!0,excludeEnd:!0,keywords:i,contains:h}]}]},{begin:/,/,relevance:0' + sLineBreak +
    '},{match:/\s+/,relevance:0},{variants:[{begin:"<>",end:"</>"},{' + sLineBreak +
    'match:/<[A-Za-z0-9\\._:-]+\s*\/>/},{begin:a.begin,' + sLineBreak +
    '"on:begin":a.isTrulyOpeningTag,end:a.end}],subLanguage:"xml",contains:[{' + sLineBreak +
    'begin:a.begin,end:a.end,skip:!0,contains:["self"]}]}]},w,{' + sLineBreak +
    'beginKeywords:"while if switch catch for"},{' + sLineBreak +
    'begin:"\\b(?!function)"+e.UNDERSCORE_IDENT_RE+"\\([^()]*(\\([^()]*(\\([^()]*\\)[^()]*)*\\)[^()]*)*\\)\\s*\\{",' + sLineBreak +
    'returnBegin:!0,label:"func.def",contains:[f,e.inherit(e.TITLE_MODE,{begin:t,' + sLineBreak +
    'className:"title.function"})]},{match:/\.\.\./,relevance:0},k,{match:"\\$"+t,' + sLineBreak +
    'relevance:0},{match:[/\bconstructor(?=\s*\()/],className:{1:"title.function"},' + sLineBreak +
    'contains:[f]},v,{relevance:0,match:/\b[A-Z][A-Z_0-9]+\b/,' + sLineBreak +
    'className:"variable.constant"},E,x,{match:/\$[(.]/}]}}' + sLineBreak +
    'const Ne=e=>b(/\b/,e,/\w$/.test(e)?/\b/:/\B/),ke=["Protocol","Type"].map(Ne),xe=["init","self"].map(Ne),Oe=["Any","Self"],Me=["actor","any","associatedtype","async","await",/as\?/,/as!/,"as","borrowing","break","case","catch","class","consume","consu' +
    'ming","continue","convenience","copy","default","defer","deinit","didSet","distributed","do","dynamic","each","else","enum","extension","fallthrough",/fileprivate\(set\)/,"fileprivate","final","for","func","get","guard","if","import","indirect","infi' +
    'x",/init\?/,/init!/,"inout",/internal\(set\)/,"internal","in","is","isolated","nonisolated","lazy","let","macro","mutating","nonmutating",/open\(set\)/,"open","operator","optional","override","package","postfix","precedencegroup","prefix",/private\(s' +
    'et\)/,"private","protocol",/public\(set\)/,"public","repeat","required","rethrows","return","set","some","static","struct","subscript","super","switch' +
    '","throws","throw",/try\?/,/try!/,"try","typealias",/unowned\(safe\)/,/unowned\(unsafe\)/,"unowned","var","weak","where","while","willSet"],Ae=["false","nil","true"],Se=["assignment","associativity","higherThan","left","lowerThan","none","right"],Ce=' +
    '["#colorLiteral","#column","#dsohandle","#else","#elseif","#endif","#error","#file","#fileID","#fileLiteral","#filePath","#function","#if","#imageLiteral","#keyPath","#line","#selector","#sourceLocation","#warning"],Te=["abs","all","any","assert","as' +
    'sertionFailure","debugPrint","dump","fatalError","getVaList","isKnownUniquelyReferenced","max","min","numericCast","pointwiseMax","pointwiseMin","precondition","preconditionFailure","print","readLine","repeatElement","sequence","stride","swap","swift' +
    '_unboxFromSwiftValueWithType","transcode","type","unsafeBitCast","unsafeDowncast","withExtendedLifetime","withUnsafeMutablePointer","withUnsafePointer' +
    '","withVaList","withoutActuallyEscaping","zip"],Re=m(/[/=\-+!*%<>&|^~?]/,/[\u00A1-\u00A7]/,/[\u00A9\u00AB]/,/[\u00AC\u00AE]/,/[\u00B0\u00B1]/,/[\u00B6\u00BB\u00BF\u00D7\u00F7]/,/[\u2016-\u2017]/,/[\u2020-\u2027]/,/[\u2030-\u203E]/,/[\u2041-\u2053]/,/' +
    '[\u2055-\u205E]/,/[\u2190-\u23FF]/,/[\u2500-\u2775]/,/[\u2794-\u2BFF]/,/[\u2E00-\u2E7F]/,/[\u3001-\u3003]/,/[\u3008-\u3020]/,/[\u3030]/),De=m(Re,/[\u0300-\u036F]/,/[\u1DC0-\u1DFF]/,/[\u20D0-\u20FF]/,/[\uFE00-\uFE0F]/,/[\uFE20-\uFE2F]/),Ie=b(Re,De,"*"' +
    '),Le=m(/[a-zA-Z_]/,/[\u00A8\u00AA\u00AD\u00AF\u00B2-\u00B5\u00B7-\u00BA]/,/[\u00BC-\u00BE\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u00FF]/,/[\u0100-\u02FF\u0370-\u167F\u1681-\u180D\u180F-\u1DBF]/,/[\u1E00-\u1FFF]/,/[\u200B-\u200D\u202A-\u202E\u203F-\u2040\u2' +
    '054\u2060-\u206F]/,/[\u2070-\u20CF\u2100-\u218F\u2460-\u24FF\u2776-\u2793]/,/[\u2C00-\u2DFF\u2E80-\u2FFF]/,/[\u3004-\u3007\u3021-\u302F\u3031-\u303F\u' +
    '3040-\uD7FF]/,/[\uF900-\uFD3D\uFD40-\uFDCF\uFDF0-\uFE1F\uFE30-\uFE44]/,/[\uFE47-\uFEFE\uFF00-\uFFFD]/),Be=m(Le,/\d/,/[\u0300-\u036F\u1DC0-\u1DFF\u20D0-\u20FF\uFE20-\uFE2F]/),$e=b(Le,Be,"*"),Fe=b(/[A-Z]/,Be,"*"),ze=["attached","autoclosure",b(/convent' +
    'ion\(/,m("swift","block","c"),/\)/),"discardableResult","dynamicCallable","dynamicMemberLookup","escaping","freestanding","frozen","GKInspectable","IBAction","IBDesignable","IBInspectable","IBOutlet","IBSegueAction","inlinable","main","nonobjc","NSAp' +
    'plicationMain","NSCopying","NSManaged",b(/objc\(/,$e,/\)/),"objc","objcMembers","propertyWrapper","requires_stored_property_inits","resultBuilder","Sendable","testable","UIApplicationMain","unchecked","unknown","usableFromInline","warn_unqualified_ac' +
    'cess"],je=["iOS","iOSApplicationExtension","macOS","macOSApplicationExtension","macCatalyst","macCatalystApplicationExtension","watchOS","watchOSAppli' +
    'cationExtension","tvOS","tvOSApplicationExtension","swift"]' + sLineBreak +
    ';var Ue=Object.freeze({__proto__:null,grmr_bash:e=>{const n=e.regex,t={},a={' + sLineBreak +
    'begin:/\$\{/,end:/\}/,contains:["self",{begin:/:-/,contains:[t]}]}' + sLineBreak +
    ';Object.assign(t,{className:"variable",variants:[{' + sLineBreak +
    'begin:n.concat(/\$[\w\d#@][\w\d_]*/,"(?![\\w\\d])(?![$])")},a]});const i={' + sLineBreak +
    'className:"subst",begin:/\$\(/,end:/\)/,contains:[e.BACKSLASH_ESCAPE]' + sLineBreak +
    '},r=e.inherit(e.COMMENT(),{match:[/(^|\s)/,/#.*$/],scope:{2:"comment"}}),s={' + sLineBreak +
    'begin:/<<-?\s*(?=\w+)/,starts:{contains:[e.END_SAME_AS_BEGIN({begin:/(\w+)/,' + sLineBreak +
    'end:/(\w+)/,className:"string"})]}},o={className:"string",begin:/"/,end:/"/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,t,i]};i.contains.push(o);const l={begin:/\$?\(\(/,' + sLineBreak +
    'end:/\)\)/,contains:[{begin:/\d+#[0-9a-f]+/,className:"number"},e.NUMBER_MODE,t]' + sLineBreak +
    '},c=e.SHEBANG({binary:"(fish|bash|zsh|sh|csh|ksh|tcsh|dash|scsh)",relevance:10' + sLineBreak +
    '}),d={className:"function",begin:/\w[\w\d_]*\s*\(\s*\)\s*\{/,returnBegin:!0,' + sLineBreak +
    'contains:[e.inherit(e.TITLE_MODE,{begin:/\w[\w\d_]*/})],relevance:0};return{' + sLineBreak +
    'name:"Bash",aliases:["sh","zsh"],keywords:{$pattern:/\b[a-z][a-z0-9._-]+\b/,' + sLineBreak +
    'keyword:["if","then","else","elif","fi","time","for","while","until","in","do","done","case","esac","coproc","function","select"],' + sLineBreak +
    'literal:["true","false"],' + sLineBreak +
    'built_in:["break","cd","continue","eval","exec","exit","export","getopts","hash","pwd","readonly","return","shift","test","times","trap","umask","unset","alias","bind","builtin","caller","command","declare","echo","enable","help","let","local","logou' +
    't","mapfile","printf","read","readarray","source","sudo","type","typeset","ulimit","unalias","set","shopt","autoload","bg","bindkey","bye","cap","chdir","clone","comparguments","compcall","compctl","compdescribe","compfiles","compgroups","compquote",' +
    '"comptags","comptry","compvalues","dirs","disable","disown","echotc","echoti","emulate","fc","fg","float","functions","getcap","getln","history","integer","jobs","kill","limit","log","noglob","popd","print","pushd","pushln","rehash","sched","setcap",' +
    '"setopt","stat","suspend","ttyctl","unfunction","unhash","unlimit","unsetopt","vared","wait","whence","where","which","zcompile","zformat","zftp","zle' +
    '","zmodload","zparseopts","zprof","zpty","zregexparse","zsocket","zstyle","ztcp","chcon","chgrp","chown","chmod","cp","dd","df","dir","dircolors","ln","ls","mkdir","mkfifo","mknod","mktemp","mv","realpath","rm","rmdir","shred","sync","touch","truncat' +
    'e","vdir","b2sum","base32","base64","cat","cksum","comm","csplit","cut","expand","fmt","fold","head","join","md5sum","nl","numfmt","od","paste","ptx","pr","sha1sum","sha224sum","sha256sum","sha384sum","sha512sum","shuf","sort","split","sum","tac","ta' +
    'il","tr","tsort","unexpand","uniq","wc","arch","basename","chroot","date","dirname","du","echo","env","expr","factor","groups","hostid","id","link","logname","nice","nohup","nproc","pathchk","pinky","printenv","printf","pwd","readlink","runcon","seq"' +
    ',"sleep","stat","stdbuf","stty","tee","test","timeout","tty","uname","unlink","uptime","users","who","whoami","yes"]' + sLineBreak +
    '},contains:[c,e.SHEBANG(),d,l,r,s,{match:/(\/[a-z._-]+)+/},o,{match:/\\"/},{' + sLineBreak +
    'className:"string",begin:/''/,end:/''/},{match:/\\''/},t]}},grmr_c:e=>{' + sLineBreak +
    'const n=e.regex,t=e.COMMENT("//","$",{contains:[{begin:/\\\n/}]' + sLineBreak +
    '}),a="decltype\\(auto\\)",i="[a-zA-Z_]\\w*::",r="("+a+"|"+n.optional(i)+"[a-zA-Z_]\\w*"+n.optional("<[^<>]+>")+")",s={' + sLineBreak +
    'className:"type",variants:[{begin:"\\b[a-z\\d_]*_t\\b"},{' + sLineBreak +
    'match:/\batomic_[a-z]{3,6}\b/}]},o={className:"string",variants:[{' + sLineBreak +
    'begin:''(u8?|U|L)?"'',end:''"'',illegal:"\\n",contains:[e.BACKSLASH_ESCAPE]},{' + sLineBreak +
    'begin:"(u8?|U|L)?''(\\\\(x[0-9A-Fa-f]{2}|u[0-9A-Fa-f]{4,8}|[0-7]{3}|\\S)|.)",' + sLineBreak +
    'end:"''",illegal:"."},e.END_SAME_AS_BEGIN({' + sLineBreak +
    'begin:/(?:u8?|U|L)?R"([^()\\ ]{0,16})\(/,end:/\)([^()\\ ]{0,16})"/})]},l={' + sLineBreak +
    'className:"number",variants:[{match:/\b(0b[01'']+)/},{' + sLineBreak +
    'match:/(-?)\b([\d'']+(\.[\d'']*)?|\.[\d'']+)((ll|LL|l|L)(u|U)?|(u|U)(ll|LL|l|L)?|f|F|b|B)/' + sLineBreak +
    '},{' + sLineBreak +
    'match:/(-?)\b(0[xX][a-fA-F0-9]+(?:''[a-fA-F0-9]+)*(?:\.[a-fA-F0-9]*(?:''[a-fA-F0-9]*)*)?(?:[pP][-+]?[0-9]+)?(l|L)?(u|U)?)/' + sLineBreak +
    '},{match:/(-?)\b\d+(?:''\d+)*(?:\.\d*(?:''\d*)*)?(?:[eE][-+]?\d+)?/}],relevance:0' + sLineBreak +
    '},c={className:"meta",begin:/#\s*[a-z]+\b/,end:/$/,keywords:{' + sLineBreak +
    'keyword:"if else elif endif define undef warning error line pragma _Pragma ifdef ifndef elifdef elifndef include"' + sLineBreak +
    '},contains:[{begin:/\\\n/,relevance:0},e.inherit(o,{className:"string"}),{' + sLineBreak +
    'className:"string",begin:/<.*?>/},t,e.C_BLOCK_COMMENT_MODE]},d={' + sLineBreak +
    'className:"title",begin:n.optional(i)+e.IDENT_RE,relevance:0' + sLineBreak +
    '},g=n.optional(i)+e.IDENT_RE+"\\s*\\(",u={' + sLineBreak +
    'keyword:["asm","auto","break","case","continue","default","do","else","enum","extern","for","fortran","goto","if","inline","register","restrict","return","sizeof","typeof","typeof_unqual","struct","switch","typedef","union","volatile","while","_Align' +
    'as","_Alignof","_Atomic","_Generic","_Noreturn","_Static_assert","_Thread_local","alignas","alignof","noreturn","static_assert","thread_local","_Pragma"],' + sLineBreak +
    'type:["float","double","signed","unsigned","int","short","long","char","void","_Bool","_BitInt","_Complex","_Imaginary","_Decimal32","_Decimal64","_Decimal96","_Decimal128","_Decimal64x","_Decimal128x","_Float16","_Float32","_Float64","_Float128","_F' +
    'loat32x","_Float64x","_Float128x","const","static","constexpr","complex","bool","imaginary"],' + sLineBreak +
    'literal:"true false NULL",' + sLineBreak +
    'built_in:"std string wstring cin cout cerr clog stdin stdout stderr stringstream istringstream ostringstream auto_ptr deque list queue stack vector map set pair bitset multiset multimap unordered_set unordered_map unordered_multiset unordered_multima' +
    'p priority_queue make_pair array shared_ptr abort terminate abs acos asin atan2 atan calloc ceil cosh cos exit exp fabs floor fmod fprintf fputs free frexp fscanf future isalnum isalpha iscntrl isdigit isgraph islower isprint ispunct isspace isupper ' +
    'isxdigit tolower toupper labs ldexp log10 log malloc realloc memchr memcmp memcpy memset modf pow printf putchar puts scanf sinh sin snprintf sprintf sqrt sscanf strcat strchr strcmp strcpy strcspn strlen strncat strncmp strncpy strpbrk strrchr strsp' +
    'n strstr tanh tan vfprintf vprintf vsprintf endl initializer_list unique_ptr"' + sLineBreak +
    '},b=[c,s,t,e.C_BLOCK_COMMENT_MODE,l,o],m={variants:[{begin:/=/,end:/;/},{' + sLineBreak +
    'begin:/\(/,end:/\)/},{beginKeywords:"new throw return else",end:/;/}],' + sLineBreak +
    'keywords:u,contains:b.concat([{begin:/\(/,end:/\)/,keywords:u,' + sLineBreak +
    'contains:b.concat(["self"]),relevance:0}]),relevance:0},p={' + sLineBreak +
    'begin:"("+r+"[\\*&\\s]+)+"+g,returnBegin:!0,end:/[{;=]/,excludeEnd:!0,' + sLineBreak +
    'keywords:u,illegal:/[^\w\s\*&:<>.]/,contains:[{begin:a,keywords:u,relevance:0},{' + sLineBreak +
    'begin:g,returnBegin:!0,contains:[e.inherit(d,{className:"title.function"})],' + sLineBreak +
    'relevance:0},{relevance:0,match:/,/},{className:"params",begin:/\(/,end:/\)/,' + sLineBreak +
    'keywords:u,relevance:0,contains:[t,e.C_BLOCK_COMMENT_MODE,o,l,s,{begin:/\(/,' + sLineBreak +
    'end:/\)/,keywords:u,relevance:0,contains:["self",t,e.C_BLOCK_COMMENT_MODE,o,l,s]' + sLineBreak +
    '}]},s,t,e.C_BLOCK_COMMENT_MODE,c]};return{name:"C",aliases:["h"],keywords:u,' + sLineBreak +
    'disableAutodetect:!0,illegal:"</",contains:[].concat(m,p,b,[c,{' + sLineBreak +
    'begin:e.IDENT_RE+"::",keywords:u},{className:"class",' + sLineBreak +
    'beginKeywords:"enum class struct union",end:/[{;:<>=]/,contains:[{' + sLineBreak +
    'beginKeywords:"final class struct"},e.TITLE_MODE]}]),exports:{preprocessor:c,' + sLineBreak +
    'strings:o,keywords:u}}},grmr_cpp:e=>{const n=e.regex,t=e.COMMENT("//","$",{' + sLineBreak +
    'contains:[{begin:/\\\n/}]' + sLineBreak +
    '}),a="decltype\\(auto\\)",i="[a-zA-Z_]\\w*::",r="(?!struct)("+a+"|"+n.optional(i)+"[a-zA-Z_]\\w*"+n.optional("<[^<>]+>")+")",s={' + sLineBreak +
    'className:"type",begin:"\\b[a-z\\d_]*_t\\b"},o={className:"string",variants:[{' + sLineBreak +
    'begin:''(u8?|U|L)?"'',end:''"'',illegal:"\\n",contains:[e.BACKSLASH_ESCAPE]},{' + sLineBreak +
    'begin:"(u8?|U|L)?''(\\\\(x[0-9A-Fa-f]{2}|u[0-9A-Fa-f]{4,8}|[0-7]{3}|\\S)|.)",' + sLineBreak +
    'end:"''",illegal:"."},e.END_SAME_AS_BEGIN({' + sLineBreak +
    'begin:/(?:u8?|U|L)?R"([^()\\ ]{0,16})\(/,end:/\)([^()\\ ]{0,16})"/})]},l={' + sLineBreak +
    'className:"number",variants:[{' + sLineBreak +
    'begin:"[+-]?(?:(?:[0-9](?:''?[0-9])*\\.(?:[0-9](?:''?[0-9])*)?|\\.[0-9](?:''?[0-9])*)(?:[Ee][+-]?[0-9](?:''?[0-9])*)?|[0-9](?:''?[0-9])*[Ee][+-]?[0-9](?:''?[0-9])*|0[Xx](?:[0-9A-Fa-f](?:''?[0-9A-Fa-f])*(?:\\.(?:[0-9A-Fa-f](?:''?[0-9A-Fa-f])*)?)?|\\.[0-9A-Fa-' +
    'f](?:''?[0-9A-Fa-f])*)[Pp][+-]?[0-9](?:''?[0-9])*)(?:[Ff](?:16|32|64|128)?|(BF|bf)16|[Ll]|)"' + sLineBreak +
    '},{' + sLineBreak +
    'begin:"[+-]?\\b(?:0[Bb][01](?:''?[01])*|0[Xx][0-9A-Fa-f](?:''?[0-9A-Fa-f])*|0(?:''?[0-7])*|[1-9](?:''?[0-9])*)(?:[Uu](?:LL?|ll?)|[Uu][Zz]?|(?:LL?|ll?)[Uu]?|[Zz][Uu]|)"' + sLineBreak +
    '}],relevance:0},c={className:"meta",begin:/#\s*[a-z]+\b/,end:/$/,keywords:{' + sLineBreak +
    'keyword:"if else elif endif define undef warning error line pragma _Pragma ifdef ifndef include"' + sLineBreak +
    '},contains:[{begin:/\\\n/,relevance:0},e.inherit(o,{className:"string"}),{' + sLineBreak +
    'className:"string",begin:/<.*?>/},t,e.C_BLOCK_COMMENT_MODE]},d={' + sLineBreak +
    'className:"title",begin:n.optional(i)+e.IDENT_RE,relevance:0' + sLineBreak +
    '},g=n.optional(i)+e.IDENT_RE+"\\s*\\(",u={' + sLineBreak +
    'type:["bool","char","char16_t","char32_t","char8_t","double","float","int","long","short","void","wchar_t","unsigned","signed","const","static"],' + sLineBreak +
    'keyword:["alignas","alignof","and","and_eq","asm","atomic_cancel","atomic_commit","atomic_noexcept","auto","bitand","bitor","break","case","catch","class","co_await","co_return","co_yield","compl","concept","const_cast|10","consteval","constexpr","co' +
    'nstinit","continue","decltype","default","delete","do","dynamic_cast|10","else","enum","explicit","export","extern","false","final","for","friend","goto","if","import","inline","module","mutable","namespace","new","noexcept","not","not_eq","nullptr",' +
    '"operator","or","or_eq","override","private","protected","public","reflexpr","register","reinterpret_cast|10","requires","return","sizeof","static_assert","static_cast|10","struct","switch","synchronized","template","this","thread_local","throw","tra' +
    'nsaction_safe","transaction_safe_dynamic","true","try","typedef","typeid","typename","union","using","virtual","volatile","while","xor","xor_eq"],' + sLineBreak +
    'literal:["NULL","false","nullopt","nullptr","true"],built_in:["_Pragma"],' + sLineBreak +
    '_type_hints:["any","auto_ptr","barrier","binary_semaphore","bitset","complex","condition_variable","condition_variable_any","counting_semaphore","deque","false_type","flat_map","flat_set","future","imaginary","initializer_list","istringstream","jthre' +
    'ad","latch","lock_guard","multimap","multiset","mutex","optional","ostringstream","packaged_task","pair","promise","priority_queue","queue","recursive_mutex","recursive_timed_mutex","scoped_lock","set","shared_future","shared_lock","shared_mutex","sh' +
    'ared_timed_mutex","shared_ptr","stack","string_view","stringstream","timed_mutex","thread","true_type","tuple","unique_lock","unique_ptr","unordered_map","unordered_multimap","unordered_multiset","unordered_set","variant","vector","weak_ptr","wstring' +
    '","wstring_view"]' + sLineBreak +
    '},b={className:"function.dispatch",relevance:0,keywords:{' + sLineBreak +
    '_hint:["abort","abs","acos","apply","as_const","asin","atan","atan2","calloc","ceil","cerr","cin","clog","cos","cosh","cout","declval","endl","exchange","exit","exp","fabs","floor","fmod","forward","fprintf","fputs","free","frexp","fscanf","future","' +
    'invoke","isalnum","isalpha","iscntrl","isdigit","isgraph","islower","isprint","ispunct","isspace","isupper","isxdigit","labs","launder","ldexp","log","log10","make_pair","make_shared","make_shared_for_overwrite","make_tuple","make_unique","malloc","m' +
    'emchr","memcmp","memcpy","memset","modf","move","pow","printf","putchar","puts","realloc","scanf","sin","sinh","snprintf","sprintf","sqrt","sscanf","std","stderr","stdin","stdout","strcat","strchr","strcmp","strcpy","strcspn","strlen","strncat","strn' +
    'cmp","strncpy","strpbrk","strrchr","strspn","strstr","swap","tan","tanh","terminate","to_underlying","tolower","toupper","vfprintf","visit","vprintf",' +
    '"vsprintf"]' + sLineBreak +
    '},' + sLineBreak +
    'begin:n.concat(/\b/,/(?!decltype)/,/(?!if)/,/(?!for)/,/(?!switch)/,/(?!while)/,e.IDENT_RE,n.lookahead(/(<[^<>]+>|)\s*\(/))' + sLineBreak +
    '},m=[b,c,s,t,e.C_BLOCK_COMMENT_MODE,l,o],p={variants:[{begin:/=/,end:/;/},{' + sLineBreak +
    'begin:/\(/,end:/\)/},{beginKeywords:"new throw return else",end:/;/}],' + sLineBreak +
    'keywords:u,contains:m.concat([{begin:/\(/,end:/\)/,keywords:u,' + sLineBreak +
    'contains:m.concat(["self"]),relevance:0}]),relevance:0},_={className:"function",' + sLineBreak +
    'begin:"("+r+"[\\*&\\s]+)+"+g,returnBegin:!0,end:/[{;=]/,excludeEnd:!0,' + sLineBreak +
    'keywords:u,illegal:/[^\w\s\*&:<>.]/,contains:[{begin:a,keywords:u,relevance:0},{' + sLineBreak +
    'begin:g,returnBegin:!0,contains:[d],relevance:0},{begin:/::/,relevance:0},{' + sLineBreak +
    'begin:/:/,endsWithParent:!0,contains:[o,l]},{relevance:0,match:/,/},{' + sLineBreak +
    'className:"params",begin:/\(/,end:/\)/,keywords:u,relevance:0,' + sLineBreak +
    'contains:[t,e.C_BLOCK_COMMENT_MODE,o,l,s,{begin:/\(/,end:/\)/,keywords:u,' + sLineBreak +
    'relevance:0,contains:["self",t,e.C_BLOCK_COMMENT_MODE,o,l,s]}]' + sLineBreak +
    '},s,t,e.C_BLOCK_COMMENT_MODE,c]};return{name:"C++",' + sLineBreak +
    'aliases:["cc","c++","h++","hpp","hh","hxx","cxx"],keywords:u,illegal:"</",' + sLineBreak +
    'classNameAliases:{"function.dispatch":"built_in"},' + sLineBreak +
    'contains:[].concat(p,_,b,m,[c,{' + sLineBreak +
    'begin:"\\b(deque|list|queue|priority_queue|pair|stack|vector|map|set|bitset|multiset|multimap|unordered_map|unordered_set|unordered_multiset|unordered_multimap|array|tuple|optional|variant|function|flat_map|flat_set)\\s*<(?!<)",' + sLineBreak +
    'end:">",keywords:u,contains:["self",s]},{begin:e.IDENT_RE+"::",keywords:u},{' + sLineBreak +
    'match:[/\b(?:enum(?:\s+(?:class|struct))?|class|struct|union)/,/\s+/,/\w+/],' + sLineBreak +
    'className:{1:"keyword",3:"title.class"}}])}},grmr_csharp:e=>{const n={' + sLineBreak +
    'keyword:["abstract","as","base","break","case","catch","class","const","continue","do","else","event","explicit","extern","finally","fixed","for","foreach","goto","if","implicit","in","interface","internal","is","lock","namespace","new","operator","o' +
    'ut","override","params","private","protected","public","readonly","record","ref","return","scoped","sealed","sizeof","stackalloc","static","struct","switch","this","throw","try","typeof","unchecked","unsafe","using","virtual","void","volatile","while' +
    '"].concat(["add","alias","and","ascending","args","async","await","by","descending","dynamic","equals","file","from","get","global","group","init","into","join","let","nameof","not","notnull","on","or","orderby","partial","record","remove","required"' +
    ',"scoped","select","set","unmanaged","value|0","var","when","where","with","yield"]),' + sLineBreak +
    'built_in:["bool","byte","char","decimal","delegate","double","dynamic","enum","float","int","long","nint","nuint","object","sbyte","short","string","ulong","uint","ushort"],' + sLineBreak +
    'literal:["default","false","null","true"]},t=e.inherit(e.TITLE_MODE,{' + sLineBreak +
    'begin:"[a-zA-Z](\\.?\\w)*"}),a={className:"number",variants:[{' + sLineBreak +
    'begin:"\\b(0b[01'']+)"},{' + sLineBreak +
    'begin:"(-?)\\b([\\d'']+(\\.[\\d'']*)?|\\.[\\d'']+)(u|U|l|L|ul|UL|f|F|b|B)"},{' + sLineBreak +
    'begin:"(-?)(\\b0[xX][a-fA-F0-9'']+|(\\b[\\d'']+(\\.[\\d'']*)?|\\.[\\d'']+)([eE][-+]?[\\d'']+)?)"' + sLineBreak +
    '}],relevance:0},i={className:"string",begin:''@"'',end:''"'',contains:[{begin:''""''}]' + sLineBreak +
    '},r=e.inherit(i,{illegal:/\n/}),s={className:"subst",begin:/\{/,end:/\}/,' + sLineBreak +
    'keywords:n},o=e.inherit(s,{illegal:/\n/}),l={className:"string",begin:/\$"/,' + sLineBreak +
    'end:''"'',illegal:/\n/,contains:[{begin:/\{\{/},{begin:/\}\}/' + sLineBreak +
    '},e.BACKSLASH_ESCAPE,o]},c={className:"string",begin:/\$@"/,end:''"'',contains:[{' + sLineBreak +
    'begin:/\{\{/},{begin:/\}\}/},{begin:''""''},s]},d=e.inherit(c,{illegal:/\n/,' + sLineBreak +
    'contains:[{begin:/\{\{/},{begin:/\}\}/},{begin:''""''},o]})' + sLineBreak +
    ';s.contains=[c,l,i,e.APOS_STRING_MODE,e.QUOTE_STRING_MODE,a,e.C_BLOCK_COMMENT_MODE],' + sLineBreak +
    'o.contains=[d,l,r,e.APOS_STRING_MODE,e.QUOTE_STRING_MODE,a,e.inherit(e.C_BLOCK_COMMENT_MODE,{' + sLineBreak +
    'illegal:/\n/})];const g={variants:[{className:"string",' + sLineBreak +
    'begin:/"""("*)(?!")(.|\n)*?"""\1/,relevance:1' + sLineBreak +
    '},c,l,i,e.APOS_STRING_MODE,e.QUOTE_STRING_MODE]},u={begin:"<",end:">",' + sLineBreak +
    'contains:[{beginKeywords:"in out"},t]' + sLineBreak +
    '},b=e.IDENT_RE+"(<"+e.IDENT_RE+"(\\s*,\\s*"+e.IDENT_RE+")*>)?(\\[\\])?",m={' + sLineBreak +
    'begin:"@"+e.IDENT_RE,relevance:0};return{name:"C#",aliases:["cs","c#"],' + sLineBreak +
    'keywords:n,illegal:/::/,contains:[e.COMMENT("///","$",{returnBegin:!0,' + sLineBreak +
    'contains:[{className:"doctag",variants:[{begin:"///",relevance:0},{' + sLineBreak +
    'begin:"\x3c!--|--\x3e"},{begin:"</?",end:">"}]}]' + sLineBreak +
    '}),e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,{className:"meta",begin:"#",' + sLineBreak +
    'end:"$",keywords:{' + sLineBreak +
    'keyword:"if else elif endif define undef warning error line region endregion pragma checksum"' + sLineBreak +
    '}},g,a,{beginKeywords:"class interface",relevance:0,end:/[{;=]/,' + sLineBreak +
    'illegal:/[^\s:,]/,contains:[{beginKeywords:"where class"' + sLineBreak +
    '},t,u,e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE]},{beginKeywords:"namespace",' + sLineBreak +
    'relevance:0,end:/[{;=]/,illegal:/[^\s:]/,' + sLineBreak +
    'contains:[t,e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE]},{' + sLineBreak +
    'beginKeywords:"record",relevance:0,end:/[{;=]/,illegal:/[^\s:]/,' + sLineBreak +
    'contains:[t,u,e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE]},{className:"meta",' + sLineBreak +
    'begin:"^\\s*\\[(?=[\\w])",excludeBegin:!0,end:"\\]",excludeEnd:!0,contains:[{' + sLineBreak +
    'className:"string",begin:/"/,end:/"/}]},{' + sLineBreak +
    'beginKeywords:"new return throw await else",relevance:0},{className:"function",' + sLineBreak +
    'begin:"("+b+"\\s+)+"+e.IDENT_RE+"\\s*(<[^=]+>\\s*)?\\(",returnBegin:!0,' + sLineBreak +
    'end:/\s*[{;=]/,excludeEnd:!0,keywords:n,contains:[{' + sLineBreak +
    'beginKeywords:"public private protected static internal protected abstract async extern override unsafe virtual new sealed partial",' + sLineBreak +
    'relevance:0},{begin:e.IDENT_RE+"\\s*(<[^=]+>\\s*)?\\(",returnBegin:!0,' + sLineBreak +
    'contains:[e.TITLE_MODE,u],relevance:0},{match:/\(\)/},{className:"params",' + sLineBreak +
    'begin:/\(/,end:/\)/,excludeBegin:!0,excludeEnd:!0,keywords:n,relevance:0,' + sLineBreak +
    'contains:[g,a,e.C_BLOCK_COMMENT_MODE]' + sLineBreak +
    '},e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE]},m]}},grmr_css:e=>{' + sLineBreak +
    'const n=e.regex,t=te(e),a=[e.APOS_STRING_MODE,e.QUOTE_STRING_MODE];return{' + sLineBreak +
    'name:"CSS",case_insensitive:!0,illegal:/[=|''\$]/,keywords:{' + sLineBreak +
    'keyframePosition:"from to"},classNameAliases:{keyframePosition:"selector-tag"},' + sLineBreak +
    'contains:[t.BLOCK_COMMENT,{begin:/-(webkit|moz|ms|o)-(?=[a-z])/' + sLineBreak +
    '},t.CSS_NUMBER_MODE,{className:"selector-id",begin:/#[A-Za-z0-9_-]+/,relevance:0' + sLineBreak +
    '},{className:"selector-class",begin:"\\.[a-zA-Z-][a-zA-Z0-9_-]*",relevance:0' + sLineBreak +
    '},t.ATTRIBUTE_SELECTOR_MODE,{className:"selector-pseudo",variants:[{' + sLineBreak +
    'begin:":("+re.join("|")+")"},{begin:":(:)?("+se.join("|")+")"}]' + sLineBreak +
    '},t.CSS_VARIABLE,{className:"attribute",begin:"\\b("+oe.join("|")+")\\b"},{' + sLineBreak +
    'begin:/:/,end:/[;}{]/,' + sLineBreak +
    'contains:[t.BLOCK_COMMENT,t.HEXCOLOR,t.IMPORTANT,t.CSS_NUMBER_MODE,...a,{' + sLineBreak +
    'begin:/(url|data-uri)\(/,end:/\)/,relevance:0,keywords:{built_in:"url data-uri"' + sLineBreak +
    '},contains:[...a,{className:"string",begin:/[^)]/,endsWithParent:!0,' + sLineBreak +
    'excludeEnd:!0}]},t.FUNCTION_DISPATCH]},{begin:n.lookahead(/@/),end:"[{;]",' + sLineBreak +
    'relevance:0,illegal:/:/,contains:[{className:"keyword",begin:/@-?\w[\w]*(-\w+)*/' + sLineBreak +
    '},{begin:/\s/,endsWithParent:!0,excludeEnd:!0,relevance:0,keywords:{' + sLineBreak +
    '$pattern:/[a-z-]+/,keyword:"and or not only",attribute:ie.join(" ")},contains:[{' + sLineBreak +
    'begin:/[a-z-]+(?=:)/,className:"attribute"},...a,t.CSS_NUMBER_MODE]}]},{' + sLineBreak +
    'className:"selector-tag",begin:"\\b("+ae.join("|")+")\\b"}]}},grmr_diff:e=>{' + sLineBreak +
    'const n=e.regex;return{name:"Diff",aliases:["patch"],contains:[{' + sLineBreak +
    'className:"meta",relevance:10,' + sLineBreak +
    'match:n.either(/^@@ +-\d+,\d+ +\+\d+,\d+ +@@/,/^\*\*\* +\d+,\d+ +\*\*\*\*$/,/^--- +\d+,\d+ +----$/)' + sLineBreak +
    '},{className:"comment",variants:[{' + sLineBreak +
    'begin:n.either(/Index: /,/^index/,/={3,}/,/^-{3}/,/^\*{3} /,/^\+{3}/,/^diff --git/),' + sLineBreak +
    'end:/$/},{match:/^\*{15}$/}]},{className:"addition",begin:/^\+/,end:/$/},{' + sLineBreak +
    'className:"deletion",begin:/^-/,end:/$/},{className:"addition",begin:/^!/,' + sLineBreak +
    'end:/$/}]}},grmr_go:e=>{const n={' + sLineBreak +
    'keyword:["break","case","chan","const","continue","default","defer","else","fallthrough","for","func","go","goto","if","import","interface","map","package","range","return","select","struct","switch","type","var"],' + sLineBreak +
    'type:["bool","byte","complex64","complex128","error","float32","float64","int8","int16","int32","int64","string","uint8","uint16","uint32","uint64","int","uint","uintptr","rune"],' + sLineBreak +
    'literal:["true","false","iota","nil"],' + sLineBreak +
    'built_in:["append","cap","close","complex","copy","imag","len","make","new","panic","print","println","real","recover","delete"]' + sLineBreak +
    '};return{name:"Go",aliases:["golang"],keywords:n,illegal:"</",' + sLineBreak +
    'contains:[e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,{className:"string",' + sLineBreak +
    'variants:[e.QUOTE_STRING_MODE,e.APOS_STRING_MODE,{begin:"`",end:"`"}]},{' + sLineBreak +
    'className:"number",variants:[{' + sLineBreak +
    'match:/-?\b0[xX]\.[a-fA-F0-9](_?[a-fA-F0-9])*[pP][+-]?\d(_?\d)*i?/,relevance:0' + sLineBreak +
    '},{' + sLineBreak +
    'match:/-?\b0[xX](_?[a-fA-F0-9])+((\.([a-fA-F0-9](_?[a-fA-F0-9])*)?)?[pP][+-]?\d(_?\d)*)?i?/,' + sLineBreak +
    'relevance:0},{match:/-?\b0[oO](_?[0-7])*i?/,relevance:0},{' + sLineBreak +
    'match:/-?\.\d(_?\d)*([eE][+-]?\d(_?\d)*)?i?/,relevance:0},{' + sLineBreak +
    'match:/-?\b\d(_?\d)*(\.(\d(_?\d)*)?)?([eE][+-]?\d(_?\d)*)?i?/,relevance:0}]},{' + sLineBreak +
    'begin:/:=/},{className:"function",beginKeywords:"func",end:"\\s*(\\{|$)",' + sLineBreak +
    'excludeEnd:!0,contains:[e.TITLE_MODE,{className:"params",begin:/\(/,end:/\)/,' + sLineBreak +
    'endsParent:!0,keywords:n,illegal:/["'']/}]}]}},grmr_graphql:e=>{const n=e.regex' + sLineBreak +
    ';return{name:"GraphQL",aliases:["gql"],case_insensitive:!0,disableAutodetect:!1,' + sLineBreak +
    'keywords:{' + sLineBreak +
    'keyword:["query","mutation","subscription","type","input","schema","directive","interface","union","scalar","fragment","enum","on"],' + sLineBreak +
    'literal:["true","false","null"]},' + sLineBreak +
    'contains:[e.HASH_COMMENT_MODE,e.QUOTE_STRING_MODE,e.NUMBER_MODE,{' + sLineBreak +
    'scope:"punctuation",match:/[.]{3}/,relevance:0},{scope:"punctuation",' + sLineBreak +
    'begin:/[\!\(\)\:\=\[\]\{\|\}]{1}/,relevance:0},{scope:"variable",begin:/\$/,' + sLineBreak +
    'end:/\W/,excludeEnd:!0,relevance:0},{scope:"meta",match:/@\w+/,excludeEnd:!0},{' + sLineBreak +
    'scope:"symbol",begin:n.concat(/[_A-Za-z][_0-9A-Za-z]*/,n.lookahead(/\s*:/)),' + sLineBreak +
    'relevance:0}],illegal:[/[;<'']/,/BEGIN/]}},grmr_ini:e=>{const n=e.regex,t={' + sLineBreak +
    'className:"number",relevance:0,variants:[{begin:/([+-]+)?[\d]+_[\d_]+/},{' + sLineBreak +
    'begin:e.NUMBER_RE}]},a=e.COMMENT();a.variants=[{begin:/;/,end:/$/},{begin:/#/,' + sLineBreak +
    'end:/$/}];const i={className:"variable",variants:[{begin:/\$[\w\d"][\w\d_]*/},{' + sLineBreak +
    'begin:/\$\{(.*?)\}/}]},r={className:"literal",' + sLineBreak +
    'begin:/\bon|off|true|false|yes|no\b/},s={className:"string",' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE],variants:[{begin:"''''''",end:"''''''",relevance:10},{' + sLineBreak +
    'begin:''"""'',end:''"""'',relevance:10},{begin:''"'',end:''"''},{begin:"''",end:"''"}]' + sLineBreak +
    '},o={begin:/\[/,end:/\]/,contains:[a,r,i,s,t,"self"],relevance:0' + sLineBreak +
    '},l=n.either(/[A-Za-z0-9_-]+/,/"(\\"|[^"])*"/,/''[^'']*''/);return{' + sLineBreak +
    'name:"TOML, also INI",aliases:["toml"],case_insensitive:!0,illegal:/\S/,' + sLineBreak +
    'contains:[a,{className:"section",begin:/\[+/,end:/\]+/},{' + sLineBreak +
    'begin:n.concat(l,"(\\s*\\.\\s*",l,")*",n.lookahead(/\s*=\s*[^#\s]/)),' + sLineBreak +
    'className:"attr",starts:{end:/$/,contains:[a,o,r,i,s,t]}}]}},grmr_java:e=>{' + sLineBreak +
    'const n=e.regex,t="[\xc0-\u02b8a-zA-Z_$][\xc0-\u02b8a-zA-Z_$0-9]*",a=t+be("(?:<"+t+"~~~(?:\\s*,\\s*"+t+"~~~)*>)?",/~~~/g,2),i={' + sLineBreak +
    'keyword:["synchronized","abstract","private","var","static","if","const ","for","while","strictfp","finally","protected","import","native","final","void","enum","else","break","transient","catch","instanceof","volatile","case","assert","package","def' +
    'ault","public","try","switch","continue","throws","protected","public","private","module","requires","exports","do","sealed","yield","permits","goto","when"],' + sLineBreak +
    'literal:["false","true","null"],' + sLineBreak +
    'type:["char","boolean","long","float","int","byte","short","double"],' + sLineBreak +
    'built_in:["super","this"]},r={className:"meta",begin:"@"+t,contains:[{' + sLineBreak +
    'begin:/\(/,end:/\)/,contains:["self"]}]},s={className:"params",begin:/\(/,' + sLineBreak +
    'end:/\)/,keywords:i,relevance:0,contains:[e.C_BLOCK_COMMENT_MODE],endsParent:!0}' + sLineBreak +
    ';return{name:"Java",aliases:["jsp"],keywords:i,illegal:/<\/|#/,' + sLineBreak +
    'contains:[e.COMMENT("/\\*\\*","\\*/",{relevance:0,contains:[{begin:/\w+@/,' + sLineBreak +
    'relevance:0},{className:"doctag",begin:"@[A-Za-z]+"}]}),{' + sLineBreak +
    'begin:/import java\.[a-z]+\./,keywords:"import",relevance:2' + sLineBreak +
    '},e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,{begin:/"""/,end:/"""/,' + sLineBreak +
    'className:"string",contains:[e.BACKSLASH_ESCAPE]' + sLineBreak +
    '},e.APOS_STRING_MODE,e.QUOTE_STRING_MODE,{' + sLineBreak +
    'match:[/\b(?:class|interface|enum|extends|implements|new)/,/\s+/,t],className:{' + sLineBreak +
    '1:"keyword",3:"title.class"}},{match:/non-sealed/,scope:"keyword"},{' + sLineBreak +
    'begin:[n.concat(/(?!else)/,t),/\s+/,t,/\s+/,/=(?!=)/],className:{1:"type",' + sLineBreak +
    '3:"variable",5:"operator"}},{begin:[/record/,/\s+/,t],className:{1:"keyword",' + sLineBreak +
    '3:"title.class"},contains:[s,e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE]},{' + sLineBreak +
    'beginKeywords:"new throw return else",relevance:0},{' + sLineBreak +
    'begin:["(?:"+a+"\\s+)",e.UNDERSCORE_IDENT_RE,/\s*(?=\()/],className:{' + sLineBreak +
    '2:"title.function"},keywords:i,contains:[{className:"params",begin:/\(/,' + sLineBreak +
    'end:/\)/,keywords:i,relevance:0,' + sLineBreak +
    'contains:[r,e.APOS_STRING_MODE,e.QUOTE_STRING_MODE,ue,e.C_BLOCK_COMMENT_MODE]' + sLineBreak +
    '},e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE]},ue,r]}},grmr_javascript:ve,' + sLineBreak +
    'grmr_json:e=>{const n=["true","false","null"],t={scope:"literal",' + sLineBreak +
    'beginKeywords:n.join(" ")};return{name:"JSON",aliases:["jsonc"],keywords:{' + sLineBreak +
    'literal:n},contains:[{className:"attr",begin:/"(\\.|[^\\"\r\n])*"(?=\s*:)/,' + sLineBreak +
    'relevance:1.01},{match:/[{}[\],:]/,className:"punctuation",relevance:0' + sLineBreak +
    '},e.QUOTE_STRING_MODE,t,e.C_NUMBER_MODE,e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE],' + sLineBreak +
    'illegal:"\\S"}},grmr_kotlin:e=>{const n={' + sLineBreak +
    'keyword:"abstract as val var vararg get set class object open private protected public noinline crossinline dynamic final enum if else do while for when throw try catch finally import package is in fun override companion reified inline lateinit init ' +
    'interface annotation data sealed internal infix operator out by constructor super tailrec where const inner suspend typealias external expect actual",' + sLineBreak +
    'built_in:"Byte Short Char Int Long Boolean Float Double Void Unit Nothing",' + sLineBreak +
    'literal:"true false null"},t={className:"symbol",begin:e.UNDERSCORE_IDENT_RE+"@"' + sLineBreak +
    '},a={className:"subst",begin:/\$\{/,end:/\}/,contains:[e.C_NUMBER_MODE]},i={' + sLineBreak +
    'className:"variable",begin:"\\$"+e.UNDERSCORE_IDENT_RE},r={className:"string",' + sLineBreak +
    'variants:[{begin:''"""'',end:''"""(?=[^"])'',contains:[i,a]},{begin:"''",end:"''",' + sLineBreak +
    'illegal:/\n/,contains:[e.BACKSLASH_ESCAPE]},{begin:''"'',end:''"'',illegal:/\n/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,i,a]}]};a.contains.push(r);const s={' + sLineBreak +
    'className:"meta",' + sLineBreak +
    'begin:"@(?:file|property|field|get|set|receiver|param|setparam|delegate)\\s*:(?:\\s*"+e.UNDERSCORE_IDENT_RE+")?"' + sLineBreak +
    '},o={className:"meta",begin:"@"+e.UNDERSCORE_IDENT_RE,contains:[{begin:/\(/,' + sLineBreak +
    'end:/\)/,contains:[e.inherit(r,{className:"string"}),"self"]}]' + sLineBreak +
    '},l=ue,c=e.COMMENT("/\\*","\\*/",{contains:[e.C_BLOCK_COMMENT_MODE]}),d={' + sLineBreak +
    'variants:[{className:"type",begin:e.UNDERSCORE_IDENT_RE},{begin:/\(/,end:/\)/,' + sLineBreak +
    'contains:[]}]},g=d;return g.variants[1].contains=[d],d.variants[1].contains=[g],' + sLineBreak +
    '{name:"Kotlin",aliases:["kt","kts"],keywords:n,' + sLineBreak +
    'contains:[e.COMMENT("/\\*\\*","\\*/",{relevance:0,contains:[{className:"doctag",' + sLineBreak +
    'begin:"@[A-Za-z]+"}]}),e.C_LINE_COMMENT_MODE,c,{className:"keyword",' + sLineBreak +
    'begin:/\b(break|continue|return|this)\b/,starts:{contains:[{className:"symbol",' + sLineBreak +
    'begin:/@\w+/}]}},t,s,o,{className:"function",beginKeywords:"fun",end:"[(]|$",' + sLineBreak +
    'returnBegin:!0,excludeEnd:!0,keywords:n,relevance:5,contains:[{' + sLineBreak +
    'begin:e.UNDERSCORE_IDENT_RE+"\\s*\\(",returnBegin:!0,relevance:0,' + sLineBreak +
    'contains:[e.UNDERSCORE_TITLE_MODE]},{className:"type",begin:/</,end:/>/,' + sLineBreak +
    'keywords:"reified",relevance:0},{className:"params",begin:/\(/,end:/\)/,' + sLineBreak +
    'endsParent:!0,keywords:n,relevance:0,contains:[{begin:/:/,end:/[=,\/]/,' + sLineBreak +
    'endsWithParent:!0,contains:[d,e.C_LINE_COMMENT_MODE,c],relevance:0' + sLineBreak +
    '},e.C_LINE_COMMENT_MODE,c,s,o,r,e.C_NUMBER_MODE]},c]},{' + sLineBreak +
    'begin:[/class|interface|trait/,/\s+/,e.UNDERSCORE_IDENT_RE],beginScope:{' + sLineBreak +
    '3:"title.class"},keywords:"class interface trait",end:/[:\{(]|$/,excludeEnd:!0,' + sLineBreak +
    'illegal:"extends implements",contains:[{' + sLineBreak +
    'beginKeywords:"public protected internal private constructor"' + sLineBreak +
    '},e.UNDERSCORE_TITLE_MODE,{className:"type",begin:/</,end:/>/,excludeBegin:!0,' + sLineBreak +
    'excludeEnd:!0,relevance:0},{className:"type",begin:/[,:]\s*/,end:/[<\(,){\s]|$/,' + sLineBreak +
    'excludeBegin:!0,returnEnd:!0},s,o]},r,{className:"meta",begin:"^#!/usr/bin/env",' + sLineBreak +
    'end:"$",illegal:"\n"},l]}},grmr_less:e=>{' + sLineBreak +
    'const n=te(e),t=le,a="[\\w-]+",i="("+a+"|@\\{"+a+"\\})",r=[],s=[],o=e=>({' + sLineBreak +
    'className:"string",begin:"~?"+e+".*?"+e}),l=(e,n,t)=>({className:e,begin:n,' + sLineBreak +
    'relevance:t}),c={$pattern:/[a-z-]+/,keyword:"and or not only",' + sLineBreak +
    'attribute:ie.join(" ")},d={begin:"\\(",end:"\\)",contains:s,keywords:c,' + sLineBreak +
    'relevance:0}' + sLineBreak +
    ';s.push(e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,o("''"),o(''"''),n.CSS_NUMBER_MODE,{' + sLineBreak +
    'begin:"(url|data-uri)\\(",starts:{className:"string",end:"[\\)\\n]",' + sLineBreak +
    'excludeEnd:!0}' + sLineBreak +
    '},n.HEXCOLOR,d,l("variable","@@?"+a,10),l("variable","@\\{"+a+"\\}"),l("built_in","~?`[^`]*?`"),{' + sLineBreak +
    'className:"attribute",begin:a+"\\s*:",end:":",returnBegin:!0,excludeEnd:!0' + sLineBreak +
    '},n.IMPORTANT,{beginKeywords:"and not"},n.FUNCTION_DISPATCH);const g=s.concat({' + sLineBreak +
    'begin:/\{/,end:/\}/,contains:r}),u={beginKeywords:"when",endsWithParent:!0,' + sLineBreak +
    'contains:[{beginKeywords:"and not"}].concat(s)},b={begin:i+"\\s*:",' + sLineBreak +
    'returnBegin:!0,end:/[;}]/,relevance:0,contains:[{begin:/-(webkit|moz|ms|o)-/' + sLineBreak +
    '},n.CSS_VARIABLE,{className:"attribute",begin:"\\b("+oe.join("|")+")\\b",' + sLineBreak +
    'end:/(?=:)/,starts:{endsWithParent:!0,illegal:"[<=$]",relevance:0,contains:s}}]' + sLineBreak +
    '},m={className:"keyword",' + sLineBreak +
    'begin:"@(import|media|charset|font-face|(-[a-z]+-)?keyframes|supports|document|namespace|page|viewport|host)\\b",' + sLineBreak +
    'starts:{end:"[;{}]",keywords:c,returnEnd:!0,contains:s,relevance:0}},p={' + sLineBreak +
    'className:"variable",variants:[{begin:"@"+a+"\\s*:",relevance:15},{begin:"@"+a' + sLineBreak +
    '}],starts:{end:"[;}]",returnEnd:!0,contains:g}},_={variants:[{' + sLineBreak +
    'begin:"[\\.#:&\\[>]",end:"[;{}]"},{begin:i,end:/\{/}],returnBegin:!0,' + sLineBreak +
    'returnEnd:!0,illegal:"[<=''$\"]",relevance:0,' + sLineBreak +
    'contains:[e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,u,l("keyword","all\\b"),l("variable","@\\{"+a+"\\}"),{' + sLineBreak +
    'begin:"\\b("+ae.join("|")+")\\b",className:"selector-tag"' + sLineBreak +
    '},n.CSS_NUMBER_MODE,l("selector-tag",i,0),l("selector-id","#"+i),l("selector-class","\\."+i,0),l("selector-tag","&",0),n.ATTRIBUTE_SELECTOR_MODE,{' + sLineBreak +
    'className:"selector-pseudo",begin:":("+re.join("|")+")"},{' + sLineBreak +
    'className:"selector-pseudo",begin:":(:)?("+se.join("|")+")"},{begin:/\(/,' + sLineBreak +
    'end:/\)/,relevance:0,contains:g},{begin:"!important"},n.FUNCTION_DISPATCH]},h={' + sLineBreak +
    'begin:a+":(:)?"+`(${t.join("|")})`,returnBegin:!0,contains:[_]}' + sLineBreak +
    ';return r.push(e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,m,p,h,b,_,u,n.FUNCTION_DISPATCH),' + sLineBreak +
    '{name:"Less",case_insensitive:!0,illegal:"[=>''/<($\"]",contains:r}},' + sLineBreak +
    'grmr_lua:e=>{const n="\\[=*\\[",t="\\]=*\\]",a={begin:n,end:t,contains:["self"]' + sLineBreak +
    '},i=[e.COMMENT("--(?!"+n+")","$"),e.COMMENT("--"+n,t,{contains:[a],relevance:10' + sLineBreak +
    '})];return{name:"Lua",aliases:["pluto"],keywords:{' + sLineBreak +
    '$pattern:e.UNDERSCORE_IDENT_RE,literal:"true false nil",' + sLineBreak +
    'keyword:"and break do else elseif end for goto if in local not or repeat return then until while",' + sLineBreak +
    'built_in:"_G _ENV _VERSION __index __newindex __mode __call __metatable __tostring __len __gc __add __sub __mul __div __mod __pow __concat __unm __eq __lt __le assert collectgarbage dofile error getfenv getmetatable ipairs load loadfile loadstring mo' +
    'dule next pairs pcall print rawequal rawget rawset require select setfenv setmetatable tonumber tostring type unpack xpcall arg self coroutine resume yield status wrap create running debug getupvalue debug sethook getmetatable gethook setmetatable se' +
    'tlocal traceback setfenv getinfo setupvalue getlocal getregistry getfenv io lines write close flush open output type read stderr stdin input stdout popen tmpfile math log max acos huge ldexp pi cos tanh pow deg tan cosh sinh random randomseed frexp c' +
    'eil floor rad abs sqrt modf asin min mod fmod log10 atan2 exp sin atan os exit setlocale date getenv difftime remove time clock tmpname rename execute' +
    ' package preload loadlib loaded loaders cpath config path seeall string sub upper len gfind rep find match char dump gmatch reverse byte format gsub lower table setn insert getn foreachi maxn foreach concat sort remove"' + sLineBreak +
    '},contains:i.concat([{className:"function",beginKeywords:"function",end:"\\)",' + sLineBreak +
    'contains:[e.inherit(e.TITLE_MODE,{' + sLineBreak +
    'begin:"([_a-zA-Z]\\w*\\.)*([_a-zA-Z]\\w*:)?[_a-zA-Z]\\w*"}),{className:"params",' + sLineBreak +
    'begin:"\\(",endsWithParent:!0,contains:i}].concat(i)' + sLineBreak +
    '},e.C_NUMBER_MODE,e.APOS_STRING_MODE,e.QUOTE_STRING_MODE,{className:"string",' + sLineBreak +
    'begin:n,end:t,contains:[a],relevance:5}])}},grmr_makefile:e=>{const n={' + sLineBreak +
    'className:"variable",variants:[{begin:"\\$\\("+e.UNDERSCORE_IDENT_RE+"\\)",' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE]},{begin:/\$[@%<?\^\+\*]/}]},t={className:"string",' + sLineBreak +
    'begin:/"/,end:/"/,contains:[e.BACKSLASH_ESCAPE,n]},a={className:"variable",' + sLineBreak +
    'begin:/\$\([\w-]+\s/,end:/\)/,keywords:{' + sLineBreak +
    'built_in:"subst patsubst strip findstring filter filter-out sort word wordlist firstword lastword dir notdir suffix basename addsuffix addprefix join wildcard realpath abspath error warning shell origin flavor foreach if or and call eval file value"' + sLineBreak +
    '},contains:[n,t]},i={begin:"^"+e.UNDERSCORE_IDENT_RE+"\\s*(?=[:+?]?=)"},r={' + sLineBreak +
    'className:"section",begin:/^[^\s]+:/,end:/$/,contains:[n]};return{' + sLineBreak +
    'name:"Makefile",aliases:["mk","mak","make"],keywords:{$pattern:/[\w-]+/,' + sLineBreak +
    'keyword:"define endef undefine ifdef ifndef ifeq ifneq else endif include -include sinclude override export unexport private vpath"' + sLineBreak +
    '},contains:[e.HASH_COMMENT_MODE,n,t,a,i,{className:"meta",begin:/^\.PHONY:/,' + sLineBreak +
    'end:/$/,keywords:{$pattern:/[\.\w]+/,keyword:".PHONY"}},r]}},grmr_markdown:e=>{' + sLineBreak +
    'const n={begin:/<\/?[A-Za-z_]/,end:">",subLanguage:"xml",relevance:0},t={' + sLineBreak +
    'variants:[{begin:/\[.+?\]\[.*?\]/,relevance:0},{' + sLineBreak +
    'begin:/\[.+?\]\(((data|javascript|mailto):|(?:http|ftp)s?:\/\/).*?\)/,' + sLineBreak +
    'relevance:2},{' + sLineBreak +
    'begin:e.regex.concat(/\[.+?\]\(/,/[A-Za-z][A-Za-z0-9+.-]*/,/:\/\/.*?\)/),' + sLineBreak +
    'relevance:2},{begin:/\[.+?\]\([./?&#].*?\)/,relevance:1},{' + sLineBreak +
    'begin:/\[.*?\]\(.*?\)/,relevance:0}],returnBegin:!0,contains:[{match:/\[(?=\])/' + sLineBreak +
    '},{className:"string",relevance:0,begin:"\\[",end:"\\]",excludeBegin:!0,' + sLineBreak +
    'returnEnd:!0},{className:"link",relevance:0,begin:"\\]\\(",end:"\\)",' + sLineBreak +
    'excludeBegin:!0,excludeEnd:!0},{className:"symbol",relevance:0,begin:"\\]\\[",' + sLineBreak +
    'end:"\\]",excludeBegin:!0,excludeEnd:!0}]},a={className:"strong",contains:[],' + sLineBreak +
    'variants:[{begin:/_{2}(?!\s)/,end:/_{2}/},{begin:/\*{2}(?!\s)/,end:/\*{2}/}]' + sLineBreak +
    '},i={className:"emphasis",contains:[],variants:[{begin:/\*(?![*\s])/,end:/\*/},{' + sLineBreak +
    'begin:/_(?![_\s])/,end:/_/,relevance:0}]},r=e.inherit(a,{contains:[]' + sLineBreak +
    '}),s=e.inherit(i,{contains:[]});a.contains.push(s),i.contains.push(r)' + sLineBreak +
    ';let o=[n,t];return[a,i,r,s].forEach((e=>{e.contains=e.contains.concat(o)' + sLineBreak +
    '})),o=o.concat(a,i),{name:"Markdown",aliases:["md","mkdown","mkd"],contains:[{' + sLineBreak +
    'className:"section",variants:[{begin:"^#{1,6}",end:"$",contains:o},{' + sLineBreak +
    'begin:"(?=^.+?\\n[=-]{2,}$)",contains:[{begin:"^[=-]*$"},{begin:"^",end:"\\n",' + sLineBreak +
    'contains:o}]}]},n,{className:"bullet",begin:"^[ \t]*([*+-]|(\\d+\\.))(?=\\s+)",' + sLineBreak +
    'end:"\\s+",excludeEnd:!0},a,i,{className:"quote",begin:"^>\\s+",contains:o,' + sLineBreak +
    'end:"$"},{className:"code",variants:[{begin:"(`{3,})[^`](.|\\n)*?\\1`*[ ]*"},{' + sLineBreak +
    'begin:"(~{3,})[^~](.|\\n)*?\\1~*[ ]*"},{begin:"```",end:"```+[ ]*$"},{' + sLineBreak +
    'begin:"~~~",end:"~~~+[ ]*$"},{begin:"`.+?`"},{begin:"(?=^( {4}|\\t))",' + sLineBreak +
    'contains:[{begin:"^( {4}|\\t)",end:"(\\n)$"}],relevance:0}]},{' + sLineBreak +
    'begin:"^[-\\*]{3,}",end:"$"},t,{begin:/^\[[^\n]+\]:/,returnBegin:!0,contains:[{' + sLineBreak +
    'className:"symbol",begin:/\[/,end:/\]/,excludeBegin:!0,excludeEnd:!0},{' + sLineBreak +
    'className:"link",begin:/:\s*/,end:/$/,excludeBegin:!0}]},{scope:"literal",' + sLineBreak +
    'match:/&([a-zA-Z0-9]+|#[0-9]{1,7}|#[Xx][0-9a-fA-F]{1,6});/}]}},' + sLineBreak +
    'grmr_objectivec:e=>{const n=/[a-zA-Z@][a-zA-Z0-9_]*/,t={$pattern:n,' + sLineBreak +
    'keyword:["@interface","@class","@protocol","@implementation"]};return{' + sLineBreak +
    'name:"Objective-C",aliases:["mm","objc","obj-c","obj-c++","objective-c++"],' + sLineBreak +
    'keywords:{"variable.language":["this","super"],$pattern:n,' + sLineBreak +
    'keyword:["while","export","sizeof","typedef","const","struct","for","union","volatile","static","mutable","if","do","return","goto","enum","else","break","extern","asm","case","default","register","explicit","typename","switch","continue","inline","r' +
    'eadonly","assign","readwrite","self","@synchronized","id","typeof","nonatomic","IBOutlet","IBAction","strong","weak","copy","in","out","inout","bycopy","byref","oneway","__strong","__weak","__block","__autoreleasing","@private","@protected","@public"' +
    ',"@try","@property","@end","@throw","@catch","@finally","@autoreleasepool","@synthesize","@dynamic","@selector","@optional","@required","@encode","@package","@import","@defs","@compatibility_alias","__bridge","__bridge_transfer","__bridge_retained","' +
    '__bridge_retain","__covariant","__contravariant","__kindof","_Nonnull","_Nullable","_Null_unspecified","__FUNCTION__","__PRETTY_FUNCTION__","__attribu' +
    'te__","getter","setter","retain","unsafe_unretained","nonnull","nullable","null_unspecified","null_resettable","class","instancetype","NS_DESIGNATED_INITIALIZER","NS_UNAVAILABLE","NS_REQUIRES_SUPER","NS_RETURNS_INNER_POINTER","NS_INLINE","NS_AVAILABL' +
    'E","NS_DEPRECATED","NS_ENUM","NS_OPTIONS","NS_SWIFT_UNAVAILABLE","NS_ASSUME_NONNULL_BEGIN","NS_ASSUME_NONNULL_END","NS_REFINED_FOR_SWIFT","NS_SWIFT_NAME","NS_SWIFT_NOTHROW","NS_DURING","NS_HANDLER","NS_ENDHANDLER","NS_VALUERETURN","NS_VOIDRETURN"],' + sLineBreak +
    'literal:["false","true","FALSE","TRUE","nil","YES","NO","NULL"],' + sLineBreak +
    'built_in:["dispatch_once_t","dispatch_queue_t","dispatch_sync","dispatch_async","dispatch_once"],' + sLineBreak +
    'type:["int","float","char","unsigned","signed","short","long","double","wchar_t","unichar","void","bool","BOOL","id|0","_Bool"]' + sLineBreak +
    '},illegal:"</",contains:[{className:"built_in",' + sLineBreak +
    'begin:"\\b(AV|CA|CF|CG|CI|CL|CM|CN|CT|MK|MP|MTK|MTL|NS|SCN|SK|UI|WK|XC)\\w+"' + sLineBreak +
    '},e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,e.C_NUMBER_MODE,e.QUOTE_STRING_MODE,e.APOS_STRING_MODE,{' + sLineBreak +
    'className:"string",variants:[{begin:''@"'',end:''"'',illegal:"\\n",' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE]}]},{className:"meta",begin:/#\s*[a-z]+\b/,end:/$/,' + sLineBreak +
    'keywords:{' + sLineBreak +
    'keyword:"if else elif endif define undef warning error line pragma ifdef ifndef include"' + sLineBreak +
    '},contains:[{begin:/\\\n/,relevance:0},e.inherit(e.QUOTE_STRING_MODE,{' + sLineBreak +
    'className:"string"}),{className:"string",begin:/<.*?>/,end:/$/,illegal:"\\n"' + sLineBreak +
    '},e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE]},{className:"class",' + sLineBreak +
    'begin:"("+t.keyword.join("|")+")\\b",end:/(\{|$)/,excludeEnd:!0,keywords:t,' + sLineBreak +
    'contains:[e.UNDERSCORE_TITLE_MODE]},{begin:"\\."+e.UNDERSCORE_IDENT_RE,' + sLineBreak +
    'relevance:0}]}},grmr_perl:e=>{const n=e.regex,t=/[dualxmsipngr]{0,12}/,a={' + sLineBreak +
    '$pattern:/[\w.]+/,' + sLineBreak +
    'keyword:"abs accept alarm and atan2 bind binmode bless break caller chdir chmod chomp chop chown chr chroot class close closedir connect continue cos crypt dbmclose dbmopen defined delete die do dump each else elsif endgrent endhostent endnetent endp' +
    'rotoent endpwent endservent eof eval exec exists exit exp fcntl field fileno flock for foreach fork format formline getc getgrent getgrgid getgrnam gethostbyaddr gethostbyname gethostent getlogin getnetbyaddr getnetbyname getnetent getpeername getpgr' +
    'p getpriority getprotobyname getprotobynumber getprotoent getpwent getpwnam getpwuid getservbyname getservbyport getservent getsockname getsockopt given glob gmtime goto grep gt hex if index int ioctl join keys kill last lc lcfirst length link listen' +
    ' local localtime log lstat lt ma map method mkdir msgctl msgget msgrcv msgsnd my ne next no not oct open opendir or ord our pack package pipe pop pos ' +
    'print printf prototype push q|0 qq quotemeta qw qx rand read readdir readline readlink readpipe recv redo ref rename require reset return reverse rewinddir rindex rmdir say scalar seek seekdir select semctl semget semop send setgrent sethostent setne' +
    'tent setpgrp setpriority setprotoent setpwent setservent setsockopt shift shmctl shmget shmread shmwrite shutdown sin sleep socket socketpair sort splice split sprintf sqrt srand stat state study sub substr symlink syscall sysopen sysread sysseek sys' +
    'tem syswrite tell telldir tie tied time times tr truncate uc ucfirst umask undef unless unlink unpack unshift untie until use utime values vec wait waitpid wantarray warn when while write x|0 xor y|0"' + sLineBreak +
    '},i={className:"subst",begin:"[$@]\\{",end:"\\}",keywords:a},r={begin:/->\{/,' + sLineBreak +
    'end:/\}/},s={scope:"attr",match:/\s+:\s*\w+(\s*\(.*?\))?/},o={scope:"variable",' + sLineBreak +
    'variants:[{begin:/\$\d/},{' + sLineBreak +
    'begin:n.concat(/[$%@](?!")(\^\w\b|#\w+(::\w+)*|\{\w+\}|\w+(::\w*)*)/,"(?![A-Za-z])(?![@$%])")' + sLineBreak +
    '},{begin:/[$%@](?!")[^\s\w{=]|\$=/,relevance:0}],contains:[s]},l={' + sLineBreak +
    'className:"number",variants:[{match:/0?\.[0-9][0-9_]+\b/},{' + sLineBreak +
    'match:/\bv?(0|[1-9][0-9_]*(\.[0-9_]+)?|[1-9][0-9_]*)\b/},{' + sLineBreak +
    'match:/\b0[0-7][0-7_]*\b/},{match:/\b0x[0-9a-fA-F][0-9a-fA-F_]*\b/},{' + sLineBreak +
    'match:/\b0b[0-1][0-1_]*\b/}],relevance:0' + sLineBreak +
    '},c=[e.BACKSLASH_ESCAPE,i,o],d=[/!/,/\//,/\|/,/\?/,/''/,/"/,/#/],g=(e,a,i="\\1")=>{' + sLineBreak +
    'const r="\\1"===i?i:n.concat(i,a)' + sLineBreak +
    ';return n.concat(n.concat("(?:",e,")"),a,/(?:\\.|[^\\\/])*?/,r,/(?:\\.|[^\\\/])*?/,i,t)' + sLineBreak +
    '},u=(e,a,i)=>n.concat(n.concat("(?:",e,")"),a,/(?:\\.|[^\\\/])*?/,i,t),b=[o,e.HASH_COMMENT_MODE,e.COMMENT(/^=\w/,/=cut/,{' + sLineBreak +
    'endsWithParent:!0}),r,{className:"string",contains:c,variants:[{' + sLineBreak +
    'begin:"q[qwxr]?\\s*\\(",end:"\\)",relevance:5},{begin:"q[qwxr]?\\s*\\[",' + sLineBreak +
    'end:"\\]",relevance:5},{begin:"q[qwxr]?\\s*\\{",end:"\\}",relevance:5},{' + sLineBreak +
    'begin:"q[qwxr]?\\s*\\|",end:"\\|",relevance:5},{begin:"q[qwxr]?\\s*<",end:">",' + sLineBreak +
    'relevance:5},{begin:"qw\\s+q",end:"q",relevance:5},{begin:"''",end:"''",' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE]},{begin:''"'',end:''"''},{begin:"`",end:"`",' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE]},{begin:/\{\w+\}/,relevance:0},{' + sLineBreak +
    'begin:"-?\\w+\\s*=>",relevance:0}]},l,{' + sLineBreak +
    'begin:"(\\/\\/|"+e.RE_STARTERS_RE+"|\\b(split|return|print|reverse|grep)\\b)\\s*",' + sLineBreak +
    'keywords:"split return print reverse grep",relevance:0,' + sLineBreak +
    'contains:[e.HASH_COMMENT_MODE,{className:"regexp",variants:[{' + sLineBreak +
    'begin:g("s|tr|y",n.either(...d,{capture:!0}))},{begin:g("s|tr|y","\\(","\\)")},{' + sLineBreak +
    'begin:g("s|tr|y","\\[","\\]")},{begin:g("s|tr|y","\\{","\\}")}],relevance:2},{' + sLineBreak +
    'className:"regexp",variants:[{begin:/(m|qr)\/\//,relevance:0},{' + sLineBreak +
    'begin:u("(?:m|qr)?",/\//,/\//)},{begin:u("m|qr",n.either(...d,{capture:!0' + sLineBreak +
    '}),/\1/)},{begin:u("m|qr",/\(/,/\)/)},{begin:u("m|qr",/\[/,/\]/)},{' + sLineBreak +
    'begin:u("m|qr",/\{/,/\}/)}]}]},{className:"function",beginKeywords:"sub method",' + sLineBreak +
    'end:"(\\s*\\(.*?\\))?[;{]",excludeEnd:!0,relevance:5,contains:[e.TITLE_MODE,s]' + sLineBreak +
    '},{className:"class",beginKeywords:"class",end:"[;{]",excludeEnd:!0,relevance:5,' + sLineBreak +
    'contains:[e.TITLE_MODE,s,l]},{begin:"-\\w\\b",relevance:0},{begin:"^__DATA__$",' + sLineBreak +
    'end:"^__END__$",subLanguage:"mojolicious",contains:[{begin:"^@@.*",end:"$",' + sLineBreak +
    'className:"comment"}]}];return i.contains=b,r.contains=b,{name:"Perl",' + sLineBreak +
    'aliases:["pl","pm"],keywords:a,contains:b}},grmr_php:e=>{' + sLineBreak +
    'const n=e.regex,t=/(?![A-Za-z0-9])(?![$])/,a=n.concat(/[a-zA-Z_\x7f-\xff][a-zA-Z0-9_\x7f-\xff]*/,t),i=n.concat(/(\\?[A-Z][a-z0-9_\x7f-\xff]+|\\?[A-Z]+(?=[A-Z][a-z0-9_\x7f-\xff])){1,}/,t),r=n.concat(/[A-Z]+/,t),s={' + sLineBreak +
    'scope:"variable",match:"\\$+"+a},o={scope:"subst",variants:[{begin:/\$\w+/},{' + sLineBreak +
    'begin:/\{\$/,end:/\}/}]},l=e.inherit(e.APOS_STRING_MODE,{illegal:null' + sLineBreak +
    '}),c="[ \t\n]",d={scope:"string",variants:[e.inherit(e.QUOTE_STRING_MODE,{' + sLineBreak +
    'illegal:null,contains:e.QUOTE_STRING_MODE.contains.concat(o)}),l,{' + sLineBreak +
    'begin:/<<<[ \t]*(?:(\w+)|"(\w+)")\n/,end:/[ \t]*(\w+)\b/,' + sLineBreak +
    'contains:e.QUOTE_STRING_MODE.contains.concat(o),"on:begin":(e,n)=>{' + sLineBreak +
    'n.data._beginMatch=e[1]||e[2]},"on:end":(e,n)=>{' + sLineBreak +
    'n.data._beginMatch!==e[1]&&n.ignoreMatch()}},e.END_SAME_AS_BEGIN({' + sLineBreak +
    'begin:/<<<[ \t]*''(\w+)''\n/,end:/[ \t]*(\w+)\b/})]},g={scope:"number",variants:[{' + sLineBreak +
    'begin:"\\b0[bB][01]+(?:_[01]+)*\\b"},{begin:"\\b0[oO][0-7]+(?:_[0-7]+)*\\b"},{' + sLineBreak +
    'begin:"\\b0[xX][\\da-fA-F]+(?:_[\\da-fA-F]+)*\\b"},{' + sLineBreak +
    'begin:"(?:\\b\\d+(?:_\\d+)*(\\.(?:\\d+(?:_\\d+)*))?|\\B\\.\\d+)(?:[eE][+-]?\\d+)?"' + sLineBreak +
    '}],relevance:0' + sLineBreak +
    '},u=["false","null","true"],b=["__CLASS__","__DIR__","__FILE__","__FUNCTION__","__COMPILER_HALT_OFFSET__","__LINE__","__METHOD__","__NAMESPACE__","__TRAIT__","die","echo","exit","include","include_once","print","require","require_once","array","abstr' +
    'act","and","as","binary","bool","boolean","break","callable","case","catch","class","clone","const","continue","declare","default","do","double","else","elseif","empty","enddeclare","endfor","endforeach","endif","endswitch","endwhile","enum","eval","' +
    'extends","final","finally","float","for","foreach","from","global","goto","if","implements","instanceof","insteadof","int","integer","interface","isset","iterable","list","match|0","mixed","new","never","object","or","private","protected","public","r' +
    'eadonly","real","return","string","switch","throw","trait","try","unset","use","var","void","while","xor","yield"],m=["Error|0","AppendIterator","Argu' +
    'mentCountError","ArithmeticError","ArrayIterator","ArrayObject","AssertionError","BadFunctionCallException","BadMethodCallException","CachingIterator","CallbackFilterIterator","CompileError","Countable","DirectoryIterator","DivisionByZeroError","Doma' +
    'inException","EmptyIterator","ErrorException","Exception","FilesystemIterator","FilterIterator","GlobIterator","InfiniteIterator","InvalidArgumentException","IteratorIterator","LengthException","LimitIterator","LogicException","MultipleIterator","NoR' +
    'ewindIterator","OutOfBoundsException","OutOfRangeException","OuterIterator","OverflowException","ParentIterator","ParseError","RangeException","RecursiveArrayIterator","RecursiveCachingIterator","RecursiveCallbackFilterIterator","RecursiveDirectoryIt' +
    'erator","RecursiveFilterIterator","RecursiveIterator","RecursiveIteratorIterator","RecursiveRegexIterator","RecursiveTreeIterator","RegexIterator","Ru' +
    'ntimeException","SeekableIterator","SplDoublyLinkedList","SplFileInfo","SplFileObject","SplFixedArray","SplHeap","SplMaxHeap","SplMinHeap","SplObjectStorage","SplObserver","SplPriorityQueue","SplQueue","SplStack","SplSubject","SplTempFileObject","Typ' +
    'eError","UnderflowException","UnexpectedValueException","UnhandledMatchError","ArrayAccess","BackedEnum","Closure","Fiber","Generator","Iterator","IteratorAggregate","Serializable","Stringable","Throwable","Traversable","UnitEnum","WeakReference","We' +
    'akMap","Directory","__PHP_Incomplete_Class","parent","php_user_filter","self","static","stdClass"],p={' + sLineBreak +
    'keyword:b,literal:(e=>{const n=[];return e.forEach((e=>{' + sLineBreak +
    'n.push(e),e.toLowerCase()===e?n.push(e.toUpperCase()):n.push(e.toLowerCase())' + sLineBreak +
    '})),n})(u),built_in:m},_=e=>e.map((e=>e.replace(/\|\d+$/,""))),h={variants:[{' + sLineBreak +
    'match:[/new/,n.concat(c,"+"),n.concat("(?!",_(m).join("\\b|"),"\\b)"),i],scope:{' + sLineBreak +
    '1:"keyword",4:"title.class"}}]},f=n.concat(a,"\\b(?!\\()"),E={variants:[{' + sLineBreak +
    'match:[n.concat(/::/,n.lookahead(/(?!class\b)/)),f],scope:{2:"variable.constant"' + sLineBreak +
    '}},{match:[/::/,/class/],scope:{2:"variable.language"}},{' + sLineBreak +
    'match:[i,n.concat(/::/,n.lookahead(/(?!class\b)/)),f],scope:{1:"title.class",' + sLineBreak +
    '3:"variable.constant"}},{match:[i,n.concat("::",n.lookahead(/(?!class\b)/))],' + sLineBreak +
    'scope:{1:"title.class"}},{match:[i,/::/,/class/],scope:{1:"title.class",' + sLineBreak +
    '3:"variable.language"}}]},y={scope:"attr",' + sLineBreak +
    'match:n.concat(a,n.lookahead(":"),n.lookahead(/(?!::)/))},w={relevance:0,' + sLineBreak +
    'begin:/\(/,end:/\)/,keywords:p,contains:[y,s,E,e.C_BLOCK_COMMENT_MODE,d,g,h]' + sLineBreak +
    '},v={relevance:0,' + sLineBreak +
    'match:[/\b/,n.concat("(?!fn\\b|function\\b|",_(b).join("\\b|"),"|",_(m).join("\\b|"),"\\b)"),a,n.concat(c,"*"),n.lookahead(/(?=\()/)],' + sLineBreak +
    'scope:{3:"title.function.invoke"},contains:[w]};w.contains.push(v)' + sLineBreak +
    ';const N=[y,E,e.C_BLOCK_COMMENT_MODE,d,g,h],k={' + sLineBreak +
    'begin:n.concat(/#\[\s*\\?/,n.either(i,r)),beginScope:"meta",end:/]/,' + sLineBreak +
    'endScope:"meta",keywords:{literal:u,keyword:["new","array"]},contains:[{' + sLineBreak +
    'begin:/\[/,end:/]/,keywords:{literal:u,keyword:["new","array"]},' + sLineBreak +
    'contains:["self",...N]},...N,{scope:"meta",variants:[{match:i},{match:r}]}]}' + sLineBreak +
    ';return{case_insensitive:!1,keywords:p,' + sLineBreak +
    'contains:[k,e.HASH_COMMENT_MODE,e.COMMENT("//","$"),e.COMMENT("/\\*","\\*/",{' + sLineBreak +
    'contains:[{scope:"doctag",match:"@[A-Za-z]+"}]}),{match:/__halt_compiler\(\);/,' + sLineBreak +
    'keywords:"__halt_compiler",starts:{scope:"comment",end:e.MATCH_NOTHING_RE,' + sLineBreak +
    'contains:[{match:/\?>/,scope:"meta",endsParent:!0}]}},{scope:"meta",variants:[{' + sLineBreak +
    'begin:/<\?php/,relevance:10},{begin:/<\?=/},{begin:/<\?/,relevance:.1},{' + sLineBreak +
    'begin:/\?>/}]},{scope:"variable.language",match:/\$this\b/},s,v,E,{' + sLineBreak +
    'match:[/const/,/\s/,a],scope:{1:"keyword",3:"variable.constant"}},h,{' + sLineBreak +
    'scope:"function",relevance:0,beginKeywords:"fn function",end:/[;{]/,' + sLineBreak +
    'excludeEnd:!0,illegal:"[$%\\[]",contains:[{beginKeywords:"use"' + sLineBreak +
    '},e.UNDERSCORE_TITLE_MODE,{begin:"=>",endsParent:!0},{scope:"params",' + sLineBreak +
    'begin:"\\(",end:"\\)",excludeBegin:!0,excludeEnd:!0,keywords:p,' + sLineBreak +
    'contains:["self",k,s,E,e.C_BLOCK_COMMENT_MODE,d,g]}]},{scope:"class",variants:[{' + sLineBreak +
    'beginKeywords:"enum",illegal:/[($"]/},{beginKeywords:"class interface trait",' + sLineBreak +
    'illegal:/[:($"]/}],relevance:0,end:/\{/,excludeEnd:!0,contains:[{' + sLineBreak +
    'beginKeywords:"extends implements"},e.UNDERSCORE_TITLE_MODE]},{' + sLineBreak +
    'beginKeywords:"namespace",relevance:0,end:";",illegal:/[.'']/,' + sLineBreak +
    'contains:[e.inherit(e.UNDERSCORE_TITLE_MODE,{scope:"title.class"})]},{' + sLineBreak +
    'beginKeywords:"use",relevance:0,end:";",contains:[{' + sLineBreak +
    'match:/\b(as|const|function)\b/,scope:"keyword"},e.UNDERSCORE_TITLE_MODE]},d,g]}' + sLineBreak +
    '},grmr_php_template:e=>({name:"PHP template",subLanguage:"xml",contains:[{' + sLineBreak +
    'begin:/<\?(php|=)?/,end:/\?>/,subLanguage:"php",contains:[{begin:"/\\*",' + sLineBreak +
    'end:"\\*/",skip:!0},{begin:''b"'',end:''"'',skip:!0},{begin:"b''",end:"''",skip:!0' + sLineBreak +
    '},e.inherit(e.APOS_STRING_MODE,{illegal:null,className:null,contains:null,' + sLineBreak +
    'skip:!0}),e.inherit(e.QUOTE_STRING_MODE,{illegal:null,className:null,' + sLineBreak +
    'contains:null,skip:!0})]}]}),grmr_plaintext:e=>({name:"Plain text",' + sLineBreak +
    'aliases:["text","txt"],disableAutodetect:!0}),grmr_python:e=>{' + sLineBreak +
    'const n=e.regex,t=/[\p{XID_Start}_]\p{XID_Continue}*/u,a=["and","as","assert","async","await","break","case","class","continue","def","del","elif","else","except","finally","for","from","global","if","import","in","is","lambda","match","nonlocal|10",' +
    '"not","or","pass","raise","return","try","while","with","yield"],i={' + sLineBreak +
    '$pattern:/[A-Za-z]\w+|__\w+__/,keyword:a,' + sLineBreak +
    'built_in:["__import__","abs","all","any","ascii","bin","bool","breakpoint","bytearray","bytes","callable","chr","classmethod","compile","complex","delattr","dict","dir","divmod","enumerate","eval","exec","filter","float","format","frozenset","getattr' +
    '","globals","hasattr","hash","help","hex","id","input","int","isinstance","issubclass","iter","len","list","locals","map","max","memoryview","min","next","object","oct","open","ord","pow","print","property","range","repr","reversed","round","set","se' +
    'tattr","slice","sorted","staticmethod","str","sum","super","tuple","type","vars","zip"],' + sLineBreak +
    'literal:["__debug__","Ellipsis","False","None","NotImplemented","True"],' + sLineBreak +
    'type:["Any","Callable","Coroutine","Dict","List","Literal","Generic","Optional","Sequence","Set","Tuple","Type","Union"]' + sLineBreak +
    '},r={className:"meta",begin:/^(>>>|\.\.\.) /},s={className:"subst",begin:/\{/,' + sLineBreak +
    'end:/\}/,keywords:i,illegal:/#/},o={begin:/\{\{/,relevance:0},l={' + sLineBreak +
    'className:"string",contains:[e.BACKSLASH_ESCAPE],variants:[{' + sLineBreak +
    'begin:/([uU]|[bB]|[rR]|[bB][rR]|[rR][bB])?''''''/,end:/''''''/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,r],relevance:10},{' + sLineBreak +
    'begin:/([uU]|[bB]|[rR]|[bB][rR]|[rR][bB])?"""/,end:/"""/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,r],relevance:10},{' + sLineBreak +
    'begin:/([fF][rR]|[rR][fF]|[fF])''''''/,end:/''''''/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,r,o,s]},{begin:/([fF][rR]|[rR][fF]|[fF])"""/,' + sLineBreak +
    'end:/"""/,contains:[e.BACKSLASH_ESCAPE,r,o,s]},{begin:/([uU]|[rR])''/,end:/''/,' + sLineBreak +
    'relevance:10},{begin:/([uU]|[rR])"/,end:/"/,relevance:10},{' + sLineBreak +
    'begin:/([bB]|[bB][rR]|[rR][bB])''/,end:/''/},{begin:/([bB]|[bB][rR]|[rR][bB])"/,' + sLineBreak +
    'end:/"/},{begin:/([fF][rR]|[rR][fF]|[fF])''/,end:/''/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,o,s]},{begin:/([fF][rR]|[rR][fF]|[fF])"/,end:/"/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,o,s]},e.APOS_STRING_MODE,e.QUOTE_STRING_MODE]' + sLineBreak +
    '},c="[0-9](_?[0-9])*",d=`(\\b(${c}))?\\.(${c})|\\b(${c})\\.`,g="\\b|"+a.join("|"),u={' + sLineBreak +
    'className:"number",relevance:0,variants:[{' + sLineBreak +
    'begin:`(\\b(${c})|(${d}))[eE][+-]?(${c})[jJ]?(?=${g})`},{begin:`(${d})[jJ]?`},{' + sLineBreak +
    'begin:`\\b([1-9](_?[0-9])*|0+(_?0)*)[lLjJ]?(?=${g})`},{' + sLineBreak +
    'begin:`\\b0[bB](_?[01])+[lL]?(?=${g})`},{begin:`\\b0[oO](_?[0-7])+[lL]?(?=${g})`' + sLineBreak +
    '},{begin:`\\b0[xX](_?[0-9a-fA-F])+[lL]?(?=${g})`},{begin:`\\b(${c})[jJ](?=${g})`' + sLineBreak +
    '}]},b={className:"comment",begin:n.lookahead(/# type:/),end:/$/,keywords:i,' + sLineBreak +
    'contains:[{begin:/# type:/},{begin:/#/,end:/\b\B/,endsWithParent:!0}]},m={' + sLineBreak +
    'className:"params",variants:[{className:"",begin:/\(\s*\)/,skip:!0},{begin:/\(/,' + sLineBreak +
    'end:/\)/,excludeBegin:!0,excludeEnd:!0,keywords:i,' + sLineBreak +
    'contains:["self",r,u,l,e.HASH_COMMENT_MODE]}]};return s.contains=[l,u,r],{' + sLineBreak +
    'name:"Python",aliases:["py","gyp","ipython"],unicodeRegex:!0,keywords:i,' + sLineBreak +
    'illegal:/(<\/|\?)|=>/,contains:[r,u,{scope:"variable.language",match:/\bself\b/' + sLineBreak +
    '},{beginKeywords:"if",relevance:0},{match:/\bor\b/,scope:"keyword"' + sLineBreak +
    '},l,b,e.HASH_COMMENT_MODE,{match:[/\bdef/,/\s+/,t],scope:{1:"keyword",' + sLineBreak +
    '3:"title.function"},contains:[m]},{variants:[{' + sLineBreak +
    'match:[/\bclass/,/\s+/,t,/\s*/,/\(\s*/,t,/\s*\)/]},{match:[/\bclass/,/\s+/,t]}],' + sLineBreak +
    'scope:{1:"keyword",3:"title.class",6:"title.class.inherited"}},{' + sLineBreak +
    'className:"meta",begin:/^[\t ]*@/,end:/(?=#)|$/,contains:[u,m,l]}]}},' + sLineBreak +
    'grmr_python_repl:e=>({aliases:["pycon"],contains:[{className:"meta.prompt",' + sLineBreak +
    'starts:{end:/ |$/,starts:{end:"$",subLanguage:"python"}},variants:[{' + sLineBreak +
    'begin:/^>>>(?=[ ]|$)/},{begin:/^\.\.\.(?=[ ]|$)/}]}]}),grmr_r:e=>{' + sLineBreak +
    'const n=e.regex,t=/(?:(?:[a-zA-Z]|\.[._a-zA-Z])[._a-zA-Z0-9]*)|\.(?!\d)/,a=n.either(/0[xX][0-9a-fA-F]+\.[0-9a-fA-F]*[pP][+-]?\d+i?/,/0[xX][0-9a-fA-F]+(?:[pP][+-]?\d+)?[Li]?/,/(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?[Li]?/),i=/[=!<>:]=|\|\||&&|:::?|<-' +
    '|<<-|->>|->|\|>|[-+*\/?!$&|:<=>@^~]|\*\*/,r=n.either(/[()]/,/[{}]/,/\[\[/,/[[\]]/,/\\/,/,/)' + sLineBreak +
    ';return{name:"R",keywords:{$pattern:t,' + sLineBreak +
    'keyword:"function if in break next repeat else for while",' + sLineBreak +
    'literal:"NULL NA TRUE FALSE Inf NaN NA_integer_|10 NA_real_|10 NA_character_|10 NA_complex_|10",' + sLineBreak +
    'built_in:"LETTERS letters month.abb month.name pi T F abs acos acosh all any anyNA Arg as.call as.character as.complex as.double as.environment as.integer as.logical as.null.default as.numeric as.raw asin asinh atan atanh attr attributes baseenv brow' +
    'ser c call ceiling class Conj cos cosh cospi cummax cummin cumprod cumsum digamma dim dimnames emptyenv exp expression floor forceAndCall gamma gc.time globalenv Im interactive invisible is.array is.atomic is.call is.character is.complex is.double is' +
    '.environment is.expression is.finite is.function is.infinite is.integer is.language is.list is.logical is.matrix is.na is.name is.nan is.null is.numeric is.object is.pairlist is.raw is.recursive is.single is.symbol lazyLoadDBfetch length lgamma list ' +
    'log max min missing Mod names nargs nzchar oldClass on.exit pos.to.env proc.time prod quote range Re rep retracemem return round seq_along seq_len seq' +
    '.int sign signif sin sinh sinpi sqrt standardGeneric substitute sum switch tan tanh tanpi tracemem trigamma trunc unclass untracemem UseMethod xtfrm"' + sLineBreak +
    '},contains:[e.COMMENT(/#''/,/$/,{contains:[{scope:"doctag",match:/@examples/,' + sLineBreak +
    'starts:{end:n.lookahead(n.either(/\n^#''\s*(?=@[a-zA-Z]+)/,/\n^(?!#'')/)),' + sLineBreak +
    'endsParent:!0}},{scope:"doctag",begin:"@param",end:/$/,contains:[{' + sLineBreak +
    'scope:"variable",variants:[{match:t},{match:/`(?:\\.|[^`\\])+`/}],endsParent:!0' + sLineBreak +
    '}]},{scope:"doctag",match:/@[a-zA-Z]+/},{scope:"keyword",match:/\\[a-zA-Z]+/}]' + sLineBreak +
    '}),e.HASH_COMMENT_MODE,{scope:"string",contains:[e.BACKSLASH_ESCAPE],' + sLineBreak +
    'variants:[e.END_SAME_AS_BEGIN({begin:/[rR]"(-*)\(/,end:/\)(-*)"/' + sLineBreak +
    '}),e.END_SAME_AS_BEGIN({begin:/[rR]"(-*)\{/,end:/\}(-*)"/' + sLineBreak +
    '}),e.END_SAME_AS_BEGIN({begin:/[rR]"(-*)\[/,end:/\](-*)"/' + sLineBreak +
    '}),e.END_SAME_AS_BEGIN({begin:/[rR]''(-*)\(/,end:/\)(-*)''/' + sLineBreak +
    '}),e.END_SAME_AS_BEGIN({begin:/[rR]''(-*)\{/,end:/\}(-*)''/' + sLineBreak +
    '}),e.END_SAME_AS_BEGIN({begin:/[rR]''(-*)\[/,end:/\](-*)''/}),{begin:''"'',end:''"'',' + sLineBreak +
    'relevance:0},{begin:"''",end:"''",relevance:0}]},{relevance:0,variants:[{scope:{' + sLineBreak +
    '1:"operator",2:"number"},match:[i,a]},{scope:{1:"operator",2:"number"},' + sLineBreak +
    'match:[/%[^%]*%/,a]},{scope:{1:"punctuation",2:"number"},match:[r,a]},{scope:{' + sLineBreak +
    '2:"number"},match:[/[^a-zA-Z0-9._]|^/,a]}]},{scope:{3:"operator"},' + sLineBreak +
    'match:[t,/\s+/,/<-/,/\s+/]},{scope:"operator",relevance:0,variants:[{match:i},{' + sLineBreak +
    'match:/%[^%]*%/}]},{scope:"punctuation",relevance:0,match:r},{begin:"`",end:"`",' + sLineBreak +
    'contains:[{begin:/\\./}]}]}},grmr_ruby:e=>{' + sLineBreak +
    'const n=e.regex,t="([a-zA-Z_]\\w*[!?=]?|[-+~]@|<<|>>|=~|===?|<=>|[<>]=?|\\*\\*|[-/+%^&*~`|]|\\[\\]=?)",a=n.either(/\b([A-Z]+[a-z0-9]+)+/,/\b([A-Z]+[a-z0-9]+)+[A-Z]+/),i=n.concat(a,/(::\w+)*/),r={' + sLineBreak +
    '"variable.constant":["__FILE__","__LINE__","__ENCODING__"],' + sLineBreak +
    '"variable.language":["self","super"],' + sLineBreak +
    'keyword:["alias","and","begin","BEGIN","break","case","class","defined","do","else","elsif","end","END","ensure","for","if","in","module","next","not","or","redo","require","rescue","retry","return","then","undef","unless","until","when","while","yie' +
    'ld","include","extend","prepend","public","private","protected","raise","throw"],' + sLineBreak +
    'built_in:["proc","lambda","attr_accessor","attr_reader","attr_writer","define_method","private_constant","module_function"],' + sLineBreak +
    'literal:["true","false","nil"]},s={className:"doctag",begin:"@[A-Za-z]+"},o={' + sLineBreak +
    'begin:"#<",end:">"},l=[e.COMMENT("#","$",{contains:[s]' + sLineBreak +
    '}),e.COMMENT("^=begin","^=end",{contains:[s],relevance:10' + sLineBreak +
    '}),e.COMMENT("^__END__",e.MATCH_NOTHING_RE)],c={className:"subst",begin:/#\{/,' + sLineBreak +
    'end:/\}/,keywords:r},d={className:"string",contains:[e.BACKSLASH_ESCAPE,c],' + sLineBreak +
    'variants:[{begin:/''/,end:/''/},{begin:/"/,end:/"/},{begin:/`/,end:/`/},{' + sLineBreak +
    'begin:/%[qQwWx]?\(/,end:/\)/},{begin:/%[qQwWx]?\[/,end:/\]/},{' + sLineBreak +
    'begin:/%[qQwWx]?\{/,end:/\}/},{begin:/%[qQwWx]?</,end:/>/},{begin:/%[qQwWx]?\//,' + sLineBreak +
    'end:/\//},{begin:/%[qQwWx]?%/,end:/%/},{begin:/%[qQwWx]?-/,end:/-/},{' + sLineBreak +
    'begin:/%[qQwWx]?\|/,end:/\|/},{begin:/\B\?(\\\d{1,3})/},{' + sLineBreak +
    'begin:/\B\?(\\x[A-Fa-f0-9]{1,2})/},{begin:/\B\?(\\u\{?[A-Fa-f0-9]{1,6}\}?)/},{' + sLineBreak +
    'begin:/\B\?(\\M-\\C-|\\M-\\c|\\c\\M-|\\M-|\\C-\\M-)[\x20-\x7e]/},{' + sLineBreak +
    'begin:/\B\?\\(c|C-)[\x20-\x7e]/},{begin:/\B\?\\?\S/},{' + sLineBreak +
    'begin:n.concat(/<<[-~]?''?/,n.lookahead(/(\w+)(?=\W)[^\n]*\n(?:[^\n]*\n)*?\s*\1\b/)),' + sLineBreak +
    'contains:[e.END_SAME_AS_BEGIN({begin:/(\w+)/,end:/(\w+)/,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,c]})]}]},g="[0-9](_?[0-9])*",u={className:"number",' + sLineBreak +
    'relevance:0,variants:[{' + sLineBreak +
    'begin:`\\b([1-9](_?[0-9])*|0)(\\.(${g}))?([eE][+-]?(${g})|r)?i?\\b`},{' + sLineBreak +
    'begin:"\\b0[dD][0-9](_?[0-9])*r?i?\\b"},{begin:"\\b0[bB][0-1](_?[0-1])*r?i?\\b"' + sLineBreak +
    '},{begin:"\\b0[oO][0-7](_?[0-7])*r?i?\\b"},{' + sLineBreak +
    'begin:"\\b0[xX][0-9a-fA-F](_?[0-9a-fA-F])*r?i?\\b"},{' + sLineBreak +
    'begin:"\\b0(_?[0-7])+r?i?\\b"}]},b={variants:[{match:/\(\)/},{' + sLineBreak +
    'className:"params",begin:/\(/,end:/(?=\))/,excludeBegin:!0,endsParent:!0,' + sLineBreak +
    'keywords:r}]},m=[d,{variants:[{match:[/class\s+/,i,/\s+<\s+/,i]},{' + sLineBreak +
    'match:[/\b(class|module)\s+/,i]}],scope:{2:"title.class",' + sLineBreak +
    '4:"title.class.inherited"},keywords:r},{match:[/(include|extend)\s+/,i],scope:{' + sLineBreak +
    '2:"title.class"},keywords:r},{relevance:0,match:[i,/\.new[. (]/],scope:{' + sLineBreak +
    '1:"title.class"}},{relevance:0,match:/\b[A-Z][A-Z_0-9]+\b/,' + sLineBreak +
    'className:"variable.constant"},{relevance:0,match:a,scope:"title.class"},{' + sLineBreak +
    'match:[/def/,/\s+/,t],scope:{1:"keyword",3:"title.function"},contains:[b]},{' + sLineBreak +
    'begin:e.IDENT_RE+"::"},{className:"symbol",' + sLineBreak +
    'begin:e.UNDERSCORE_IDENT_RE+"(!|\\?)?:",relevance:0},{className:"symbol",' + sLineBreak +
    'begin:":(?!\\s)",contains:[d,{begin:t}],relevance:0},u,{className:"variable",' + sLineBreak +
    'begin:"(\\$\\W)|((\\$|@@?)(\\w+))(?=[^@$?])(?![A-Za-z])(?![@$?''])"},{' + sLineBreak +
    'className:"params",begin:/\|(?!=)/,end:/\|/,excludeBegin:!0,excludeEnd:!0,' + sLineBreak +
    'relevance:0,keywords:r},{begin:"("+e.RE_STARTERS_RE+"|unless)\\s*",' + sLineBreak +
    'keywords:"unless",contains:[{className:"regexp",contains:[e.BACKSLASH_ESCAPE,c],' + sLineBreak +
    'illegal:/\n/,variants:[{begin:"/",end:"/[a-z]*"},{begin:/%r\{/,end:/\}[a-z]*/},{' + sLineBreak +
    'begin:"%r\\(",end:"\\)[a-z]*"},{begin:"%r!",end:"![a-z]*"},{begin:"%r\\[",' + sLineBreak +
    'end:"\\][a-z]*"}]}].concat(o,l),relevance:0}].concat(o,l)' + sLineBreak +
    ';c.contains=m,b.contains=m;const p=[{begin:/^\s*=>/,starts:{end:"$",contains:m}' + sLineBreak +
    '},{className:"meta.prompt",' + sLineBreak +
    'begin:"^([>?]>|[\\w#]+\\(\\w+\\):\\d+:\\d+[>*]|(\\w+-)?\\d+\\.\\d+\\.\\d+(p\\d+)?[^\\d][^>]+>)(?=[ ])",' + sLineBreak +
    'starts:{end:"$",keywords:r,contains:m}}];return l.unshift(o),{name:"Ruby",' + sLineBreak +
    'aliases:["rb","gemspec","podspec","thor","irb"],keywords:r,illegal:/\/\*/,' + sLineBreak +
    'contains:[e.SHEBANG({binary:"ruby"})].concat(p).concat(l).concat(m)}},' + sLineBreak +
    'grmr_rust:e=>{' + sLineBreak +
    'const n=e.regex,t=/(r#)?/,a=n.concat(t,e.UNDERSCORE_IDENT_RE),i=n.concat(t,e.IDENT_RE),r={' + sLineBreak +
    'className:"title.function.invoke",relevance:0,' + sLineBreak +
    'begin:n.concat(/\b/,/(?!let|for|while|if|else|match\b)/,i,n.lookahead(/\s*\(/))' + sLineBreak +
    '},s="([ui](8|16|32|64|128|size)|f(32|64))?",o=["drop ","Copy","Send","Sized","Sync","Drop","Fn","FnMut","FnOnce","ToOwned","Clone","Debug","PartialEq","PartialOrd","Eq","Ord","AsRef","AsMut","Into","From","Default","Iterator","Extend","IntoIterator",' +
    '"DoubleEndedIterator","ExactSizeIterator","SliceConcatExt","ToString","assert!","assert_eq!","bitflags!","bytes!","cfg!","col!","concat!","concat_idents!","debug_assert!","debug_assert_eq!","env!","eprintln!","panic!","file!","format!","format_args!"' +
    ',"include_bytes!","include_str!","line!","local_data_key!","module_path!","option_env!","print!","println!","select!","stringify!","try!","unimplemented!","unreachable!","vec!","write!","writeln!","macro_rules!","assert_ne!","debug_assert_ne!"],l=["i' +
    '8","i16","i32","i64","i128","isize","u8","u16","u32","u64","u128","usize","f32","f64","str","char","bool","Box","Option","Result","String","Vec"]' + sLineBreak +
    ';return{name:"Rust",aliases:["rs"],keywords:{$pattern:e.IDENT_RE+"!?",type:l,' + sLineBreak +
    'keyword:["abstract","as","async","await","become","box","break","const","continue","crate","do","dyn","else","enum","extern","false","final","fn","for","if","impl","in","let","loop","macro","match","mod","move","mut","override","priv","pub","ref","re' +
    'turn","self","Self","static","struct","super","trait","true","try","type","typeof","union","unsafe","unsized","use","virtual","where","while","yield"],' + sLineBreak +
    'literal:["true","false","Some","None","Ok","Err"],built_in:o},illegal:"</",' + sLineBreak +
    'contains:[e.C_LINE_COMMENT_MODE,e.COMMENT("/\\*","\\*/",{contains:["self"]' + sLineBreak +
    '}),e.inherit(e.QUOTE_STRING_MODE,{begin:/b?"/,illegal:null}),{' + sLineBreak +
    'className:"symbol",begin:/''[a-zA-Z_][a-zA-Z0-9_]*(?!'')/},{scope:"string",' + sLineBreak +
    'variants:[{begin:/b?r(#*)"(.|\n)*?"\1(?!#)/},{begin:/b?''/,end:/''/,contains:[{' + sLineBreak +
    'scope:"char.escape",match:/\\(''|\w|x\w{2}|u\w{4}|U\w{8})/}]}]},{' + sLineBreak +
    'className:"number",variants:[{begin:"\\b0b([01_]+)"+s},{begin:"\\b0o([0-7_]+)"+s' + sLineBreak +
    '},{begin:"\\b0x([A-Fa-f0-9_]+)"+s},{' + sLineBreak +
    'begin:"\\b(\\d[\\d_]*(\\.[0-9_]+)?([eE][+-]?[0-9_]+)?)"+s}],relevance:0},{' + sLineBreak +
    'begin:[/fn/,/\s+/,a],className:{1:"keyword",3:"title.function"}},{' + sLineBreak +
    'className:"meta",begin:"#!?\\[",end:"\\]",contains:[{className:"string",' + sLineBreak +
    'begin:/"/,end:/"/,contains:[e.BACKSLASH_ESCAPE]}]},{' + sLineBreak +
    'begin:[/let/,/\s+/,/(?:mut\s+)?/,a],className:{1:"keyword",3:"keyword",' + sLineBreak +
    '4:"variable"}},{begin:[/for/,/\s+/,a,/\s+/,/in/],className:{1:"keyword",' + sLineBreak +
    '3:"variable",5:"keyword"}},{begin:[/type/,/\s+/,a],className:{1:"keyword",' + sLineBreak +
    '3:"title.class"}},{begin:[/(?:trait|enum|struct|union|impl|for)/,/\s+/,a],' + sLineBreak +
    'className:{1:"keyword",3:"title.class"}},{begin:e.IDENT_RE+"::",keywords:{' + sLineBreak +
    'keyword:"Self",built_in:o,type:l}},{className:"punctuation",begin:"->"},r]}},' + sLineBreak +
    'grmr_scss:e=>{const n=te(e),t=se,a=re,i="@[a-z-]+",r={className:"variable",' + sLineBreak +
    'begin:"(\\$[a-zA-Z-][a-zA-Z0-9_-]*)\\b",relevance:0};return{name:"SCSS",' + sLineBreak +
    'case_insensitive:!0,illegal:"[=/|'']",' + sLineBreak +
    'contains:[e.C_LINE_COMMENT_MODE,e.C_BLOCK_COMMENT_MODE,n.CSS_NUMBER_MODE,{' + sLineBreak +
    'className:"selector-id",begin:"#[A-Za-z0-9_-]+",relevance:0},{' + sLineBreak +
    'className:"selector-class",begin:"\\.[A-Za-z0-9_-]+",relevance:0' + sLineBreak +
    '},n.ATTRIBUTE_SELECTOR_MODE,{className:"selector-tag",' + sLineBreak +
    'begin:"\\b("+ae.join("|")+")\\b",relevance:0},{className:"selector-pseudo",' + sLineBreak +
    'begin:":("+a.join("|")+")"},{className:"selector-pseudo",' + sLineBreak +
    'begin:":(:)?("+t.join("|")+")"},r,{begin:/\(/,end:/\)/,' + sLineBreak +
    'contains:[n.CSS_NUMBER_MODE]},n.CSS_VARIABLE,{className:"attribute",' + sLineBreak +
    'begin:"\\b("+oe.join("|")+")\\b"},{' + sLineBreak +
    'begin:"\\b(whitespace|wait|w-resize|visible|vertical-text|vertical-ideographic|uppercase|upper-roman|upper-alpha|underline|transparent|top|thin|thick|text|text-top|text-bottom|tb-rl|table-header-group|table-footer-group|sw-resize|super|strict|static|' +
    'square|solid|small-caps|separate|se-resize|scroll|s-resize|rtl|row-resize|ridge|right|repeat|repeat-y|repeat-x|relative|progress|pointer|overline|outside|outset|oblique|nowrap|not-allowed|normal|none|nw-resize|no-repeat|no-drop|newspaper|ne-resize|n-' +
    'resize|move|middle|medium|ltr|lr-tb|lowercase|lower-roman|lower-alpha|loose|list-item|line|line-through|line-edge|lighter|left|keep-all|justify|italic|inter-word|inter-ideograph|inside|inset|inline|inline-block|inherit|inactive|ideograph-space|ideogr' +
    'aph-parenthesis|ideograph-numeric|ideograph-alpha|horizontal|hidden|help|hand|groove|fixed|ellipsis|e-resize|double|dotted|distribute|distribute-space' +
    '|distribute-letter|distribute-all-lines|disc|disabled|default|decimal|dashed|crosshair|collapse|col-resize|circle|char|center|capitalize|break-word|break-all|bottom|both|bolder|bold|block|bidi-override|below|baseline|auto|always|all-scroll|absolute|t' +
    'able|table-cell)\\b"' + sLineBreak +
    '},{begin:/:/,end:/[;}{]/,relevance:0,' + sLineBreak +
    'contains:[n.BLOCK_COMMENT,r,n.HEXCOLOR,n.CSS_NUMBER_MODE,e.QUOTE_STRING_MODE,e.APOS_STRING_MODE,n.IMPORTANT,n.FUNCTION_DISPATCH]' + sLineBreak +
    '},{begin:"@(page|font-face)",keywords:{$pattern:i,keyword:"@page @font-face"}},{' + sLineBreak +
    'begin:"@",end:"[{;]",returnBegin:!0,keywords:{$pattern:/[a-z-]+/,' + sLineBreak +
    'keyword:"and or not only",attribute:ie.join(" ")},contains:[{begin:i,' + sLineBreak +
    'className:"keyword"},{begin:/[a-z-]+(?=:)/,className:"attribute"' + sLineBreak +
    '},r,e.QUOTE_STRING_MODE,e.APOS_STRING_MODE,n.HEXCOLOR,n.CSS_NUMBER_MODE]' + sLineBreak +
    '},n.FUNCTION_DISPATCH]}},grmr_shell:e=>({name:"Shell Session",' + sLineBreak +
    'aliases:["console","shellsession"],contains:[{className:"meta.prompt",' + sLineBreak +
    'begin:/^\s{0,3}[/~\w\d[\]()@-]*[>%$#][ ]?/,starts:{end:/[^\\](?=\s*$)/,' + sLineBreak +
    'subLanguage:"bash"}}]}),grmr_sql:e=>{' + sLineBreak +
    'const n=e.regex,t=e.COMMENT("--","$"),a=["abs","acos","array_agg","asin","atan","avg","cast","ceil","ceiling","coalesce","corr","cos","cosh","count","covar_pop","covar_samp","cume_dist","dense_rank","deref","element","exp","extract","first_value","fl' +
    'oor","json_array","json_arrayagg","json_exists","json_object","json_objectagg","json_query","json_table","json_table_primitive","json_value","lag","last_value","lead","listagg","ln","log","log10","lower","max","min","mod","nth_value","ntile","nullif"' +
    ',"percent_rank","percentile_cont","percentile_disc","position","position_regex","power","rank","regr_avgx","regr_avgy","regr_count","regr_intercept","regr_r2","regr_slope","regr_sxx","regr_sxy","regr_syy","row_number","sin","sinh","sqrt","stddev_pop"' +
    ',"stddev_samp","substring","substring_regex","sum","tan","tanh","translate","translate_regex","treat","trim","trim_array","unnest","upper","value_of",' +
    '"var_pop","var_samp","width_bucket"],i=a,r=["abs","acos","all","allocate","alter","and","any","are","array","array_agg","array_max_cardinality","as","asensitive","asin","asymmetric","at","atan","atomic","authorization","avg","begin","begin_frame","be' +
    'gin_partition","between","bigint","binary","blob","boolean","both","by","call","called","cardinality","cascaded","case","cast","ceil","ceiling","char","char_length","character","character_length","check","classifier","clob","close","coalesce","collat' +
    'e","collect","column","commit","condition","connect","constraint","contains","convert","copy","corr","corresponding","cos","cosh","count","covar_pop","covar_samp","create","cross","cube","cume_dist","current","current_catalog","current_date","current' +
    '_default_transform_group","current_path","current_role","current_row","current_schema","current_time","current_timestamp","current_path","current_role' +
    '","current_transform_group_for_type","current_user","cursor","cycle","date","day","deallocate","dec","decimal","decfloat","declare","default","define","delete","dense_rank","deref","describe","deterministic","disconnect","distinct","double","drop","d' +
    'ynamic","each","element","else","empty","end","end_frame","end_partition","end-exec","equals","escape","every","except","exec","execute","exists","exp","external","extract","false","fetch","filter","first_value","float","floor","for","foreign","frame' +
    '_row","free","from","full","function","fusion","get","global","grant","group","grouping","groups","having","hold","hour","identity","in","indicator","initial","inner","inout","insensitive","insert","int","integer","intersect","intersection","interval' +
    '","into","is","join","json_array","json_arrayagg","json_exists","json_object","json_objectagg","json_query","json_table","json_table_primitive","json_' +
    'value","lag","language","large","last_value","lateral","lead","leading","left","like","like_regex","listagg","ln","local","localtime","localtimestamp","log","log10","lower","match","match_number","match_recognize","matches","max","member","merge","me' +
    'thod","min","minute","mod","modifies","module","month","multiset","national","natural","nchar","nclob","new","no","none","normalize","not","nth_value","ntile","null","nullif","numeric","octet_length","occurrences_regex","of","offset","old","omit","on' +
    '","one","only","open","or","order","out","outer","over","overlaps","overlay","parameter","partition","pattern","per","percent","percent_rank","percentile_cont","percentile_disc","period","portion","position","position_regex","power","precedes","preci' +
    'sion","prepare","primary","procedure","ptf","range","rank","reads","real","recursive","ref","references","referencing","regr_avgx","regr_avgy","regr_c' +
    'ount","regr_intercept","regr_r2","regr_slope","regr_sxx","regr_sxy","regr_syy","release","result","return","returns","revoke","right","rollback","rollup","row","row_number","rows","running","savepoint","scope","scroll","search","second","seek","selec' +
    't","sensitive","session_user","set","show","similar","sin","sinh","skip","smallint","some","specific","specifictype","sql","sqlexception","sqlstate","sqlwarning","sqrt","start","static","stddev_pop","stddev_samp","submultiset","subset","substring","s' +
    'ubstring_regex","succeeds","sum","symmetric","system","system_time","system_user","table","tablesample","tan","tanh","then","time","timestamp","timezone_hour","timezone_minute","to","trailing","translate","translate_regex","translation","treat","trig' +
    'ger","trim","trim_array","true","truncate","uescape","union","unique","unknown","unnest","update","upper","user","using","value","values","value_of","' +
    'var_pop","var_samp","varbinary","varchar","varying","versioning","when","whenever","where","width_bucket","window","with","within","without","year","add","asc","collation","desc","final","first","last","view"].filter((e=>!a.includes(e))),s={' + sLineBreak +
    'match:n.concat(/\b/,n.either(...i),/\s*\(/),relevance:0,keywords:{built_in:i}}' + sLineBreak +
    ';function o(e){' + sLineBreak +
    'return n.concat(/\b/,n.either(...e.map((e=>e.replace(/\s+/,"\\s+")))),/\b/)}' + sLineBreak +
    'const l={scope:"keyword",' + sLineBreak +
    'match:o(["create table","insert into","primary key","foreign key","not null","alter table","add constraint","grouping sets","on overflow","character set","respect nulls","ignore nulls","nulls first","nulls last","depth first","breadth first"]),' + sLineBreak +
    'relevance:0};return{name:"SQL",case_insensitive:!0,illegal:/[{}]|<\//,keywords:{' + sLineBreak +
    '$pattern:/\b[\w\.]+/,keyword:((e,{exceptions:n,when:t}={})=>{const a=t' + sLineBreak +
    ';return n=n||[],e.map((e=>e.match(/\|\d+$/)||n.includes(e)?e:a(e)?e+"|0":e))' + sLineBreak +
    '})(r,{when:e=>e.length<3}),literal:["true","false","unknown"],' + sLineBreak +
    'type:["bigint","binary","blob","boolean","char","character","clob","date","dec","decfloat","decimal","float","int","integer","interval","nchar","nclob","national","numeric","real","row","smallint","time","timestamp","varchar","varying","varbinary"],' + sLineBreak +
    'built_in:["current_catalog","current_date","current_default_transform_group","current_path","current_role","current_schema","current_transform_group_for_type","current_user","session_user","system_time","system_user","current_time","localtime","curre' +
    'nt_timestamp","localtimestamp"]' + sLineBreak +
    '},contains:[{scope:"type",' + sLineBreak +
    'match:o(["double precision","large object","with timezone","without timezone"])' + sLineBreak +
    '},l,s,{scope:"variable",match:/@[a-z0-9][a-z0-9_]*/},{scope:"string",variants:[{' + sLineBreak +
    'begin:/''/,end:/''/,contains:[{match:/''''/}]}]},{begin:/"/,end:/"/,contains:[{' + sLineBreak +
    'match:/""/}]},e.C_NUMBER_MODE,e.C_BLOCK_COMMENT_MODE,t,{scope:"operator",' + sLineBreak +
    'match:/[-+*/=%^~]|&&?|\|\|?|!=?|<(?:=>?|<|>)?|>[>=]?/,relevance:0}]}},' + sLineBreak +
    'grmr_swift:e=>{const n={match:/\s+/,relevance:0},t=e.COMMENT("/\\*","\\*/",{' + sLineBreak +
    'contains:["self"]}),a=[e.C_LINE_COMMENT_MODE,t],i={match:[/\./,m(...ke,...xe)],' + sLineBreak +
    'className:{2:"keyword"}},r={match:b(/\./,m(...Me)),relevance:0' + sLineBreak +
    '},s=Me.filter((e=>"string"==typeof e)).concat(["_|0"]),o={variants:[{' + sLineBreak +
    'className:"keyword",' + sLineBreak +
    'match:m(...Me.filter((e=>"string"!=typeof e)).concat(Oe).map(Ne),...xe)}]},l={' + sLineBreak +
    '$pattern:m(/\b\w+/,/#\w+/),keyword:s.concat(Ce),literal:Ae},c=[i,r,o],g=[{' + sLineBreak +
    'match:b(/\./,m(...Te)),relevance:0},{className:"built_in",' + sLineBreak +
    'match:b(/\b/,m(...Te),/(?=\()/)}],u={match:/->/,relevance:0},p=[u,{' + sLineBreak +
    'className:"operator",relevance:0,variants:[{match:Ie},{match:`\\.(\\.|${De})+`}]' + sLineBreak +
    '}],_="([0-9]_*)+",h="([0-9a-fA-F]_*)+",f={className:"number",relevance:0,' + sLineBreak +
    'variants:[{match:`\\b(${_})(\\.(${_}))?([eE][+-]?(${_}))?\\b`},{' + sLineBreak +
    'match:`\\b0x(${h})(\\.(${h}))?([pP][+-]?(${_}))?\\b`},{match:/\b0o([0-7]_*)+\b/' + sLineBreak +
    '},{match:/\b0b([01]_*)+\b/}]},E=(e="")=>({className:"subst",variants:[{' + sLineBreak +
    'match:b(/\\/,e,/[0\\tnr"'']/)},{match:b(/\\/,e,/u\{[0-9a-fA-F]{1,8}\}/)}]' + sLineBreak +
    '}),y=(e="")=>({className:"subst",match:b(/\\/,e,/[\t ]*(?:[\r\n]|\r\n)/)' + sLineBreak +
    '}),w=(e="")=>({className:"subst",label:"interpol",begin:b(/\\/,e,/\(/),end:/\)/' + sLineBreak +
    '}),v=(e="")=>({begin:b(e,/"""/),end:b(/"""/,e),contains:[E(e),y(e),w(e)]' + sLineBreak +
    '}),N=(e="")=>({begin:b(e,/"/),end:b(/"/,e),contains:[E(e),w(e)]}),k={' + sLineBreak +
    'className:"string",' + sLineBreak +
    'variants:[v(),v("#"),v("##"),v("###"),N(),N("#"),N("##"),N("###")]' + sLineBreak +
    '},x=[e.BACKSLASH_ESCAPE,{begin:/\[/,end:/\]/,relevance:0,' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE]}],O={begin:/\/[^\s](?=[^/\n]*\/)/,end:/\//,' + sLineBreak +
    'contains:x},M=e=>{const n=b(e,/\//),t=b(/\//,e);return{begin:n,end:t,' + sLineBreak +
    'contains:[...x,{scope:"comment",begin:`#(?!.*${t})`,end:/$/}]}},A={' + sLineBreak +
    'scope:"regexp",variants:[M("###"),M("##"),M("#"),O]},S={match:b(/`/,$e,/`/)' + sLineBreak +
    '},C=[S,{className:"variable",match:/\$\d+/},{className:"variable",' + sLineBreak +
    'match:`\\$${Be}+`}],T=[{match:/(@|#(un)?)available/,scope:"keyword",starts:{' + sLineBreak +
    'contains:[{begin:/\(/,end:/\)/,keywords:je,contains:[...p,f,k]}]}},{' + sLineBreak +
    'scope:"keyword",match:b(/@/,m(...ze),d(m(/\(/,/\s+/)))},{scope:"meta",' + sLineBreak +
    'match:b(/@/,$e)}],R={match:d(/\b[A-Z]/),relevance:0,contains:[{className:"type",' + sLineBreak +
    'match:b(/(AV|CA|CF|CG|CI|CL|CM|CN|CT|MK|MP|MTK|MTL|NS|SCN|SK|UI|WK|XC)/,Be,"+")' + sLineBreak +
    '},{className:"type",match:Fe,relevance:0},{match:/[?!]+/,relevance:0},{' + sLineBreak +
    'match:/\.\.\./,relevance:0},{match:b(/\s+&\s+/,d(Fe)),relevance:0}]},D={' + sLineBreak +
    'begin:/</,end:/>/,keywords:l,contains:[...a,...c,...T,u,R]};R.contains.push(D)' + sLineBreak +
    ';const I={begin:/\(/,end:/\)/,relevance:0,keywords:l,contains:["self",{' + sLineBreak +
    'match:b($e,/\s*:/),keywords:"_|0",relevance:0' + sLineBreak +
    '},...a,A,...c,...g,...p,f,k,...C,...T,R]},L={begin:/</,end:/>/,' + sLineBreak +
    'keywords:"repeat each",contains:[...a,R]},B={begin:/\(/,end:/\)/,keywords:l,' + sLineBreak +
    'contains:[{begin:m(d(b($e,/\s*:/)),d(b($e,/\s+/,$e,/\s*:/))),end:/:/,' + sLineBreak +
    'relevance:0,contains:[{className:"keyword",match:/\b_\b/},{className:"params",' + sLineBreak +
    'match:$e}]},...a,...c,...p,f,k,...T,R,I],endsParent:!0,illegal:/["'']/},$={' + sLineBreak +
    'match:[/(func|macro)/,/\s+/,m(S.match,$e,Ie)],className:{1:"keyword",' + sLineBreak +
    '3:"title.function"},contains:[L,B,n],illegal:[/\[/,/%/]},F={' + sLineBreak +
    'match:[/\b(?:subscript|init[?!]?)/,/\s*(?=[<(])/],className:{1:"keyword"},' + sLineBreak +
    'contains:[L,B,n],illegal:/\[|%/},z={match:[/operator/,/\s+/,Ie],className:{' + sLineBreak +
    '1:"keyword",3:"title"}},j={begin:[/precedencegroup/,/\s+/,Fe],className:{' + sLineBreak +
    '1:"keyword",3:"title"},contains:[R],keywords:[...Se,...Ae],end:/}/},U={' + sLineBreak +
    'begin:[/(struct|protocol|class|extension|enum|actor)/,/\s+/,$e,/\s*/],' + sLineBreak +
    'beginScope:{1:"keyword",3:"title.class"},keywords:l,contains:[L,...c,{begin:/:/,' + sLineBreak +
    'end:/\{/,keywords:l,contains:[{scope:"title.class.inherited",match:Fe},...c],' + sLineBreak +
    'relevance:0}]};for(const e of k.variants){' + sLineBreak +
    'const n=e.contains.find((e=>"interpol"===e.label));n.keywords=l' + sLineBreak +
    ';const t=[...c,...g,...p,f,k,...C];n.contains=[...t,{begin:/\(/,end:/\)/,' + sLineBreak +
    'contains:["self",...t]}]}return{name:"Swift",keywords:l,contains:[...a,$,F,{' + sLineBreak +
    'match:[/class\b/,/\s+/,/func\b/,/\s+/,/\b[A-Za-z_][A-Za-z0-9_]*\b/],scope:{' + sLineBreak +
    '1:"keyword",3:"keyword",5:"title.function"}},{match:[/class\b/,/\s+/,/var\b/],' + sLineBreak +
    'scope:{1:"keyword",3:"keyword"}},U,z,j,{beginKeywords:"import",end:/$/,' + sLineBreak +
    'contains:[...a],relevance:0},A,...c,...g,...p,f,k,...C,...T,R,I]}},' + sLineBreak +
    'grmr_typescript:e=>{' + sLineBreak +
    'const n=e.regex,t=ve(e),a=me,i=["any","void","number","boolean","string","object","never","symbol","bigint","unknown"],r={' + sLineBreak +
    'begin:[/namespace/,/\s+/,e.IDENT_RE],beginScope:{1:"keyword",3:"title.class"}' + sLineBreak +
    '},s={beginKeywords:"interface",end:/\{/,excludeEnd:!0,keywords:{' + sLineBreak +
    'keyword:"interface extends",built_in:i},contains:[t.exports.CLASS_REFERENCE]' + sLineBreak +
    '},o={$pattern:me,' + sLineBreak +
    'keyword:pe.concat(["type","interface","public","private","protected","implements","declare","abstract","readonly","enum","override","satisfies"]),' + sLineBreak +
    'literal:_e,built_in:we.concat(i),"variable.language":ye},l={className:"meta",' + sLineBreak +
    'begin:"@"+a},c=(e,n,t)=>{const a=e.contains.findIndex((e=>e.label===n))' + sLineBreak +
    ';if(-1===a)throw Error("can not find mode to replace");e.contains.splice(a,1,t)}' + sLineBreak +
    ';Object.assign(t.keywords,o),t.exports.PARAMS_CONTAINS.push(l)' + sLineBreak +
    ';const d=t.contains.find((e=>"attr"===e.scope)),g=Object.assign({},d,{' + sLineBreak +
    'match:n.concat(a,n.lookahead(/\s*\?:/))})' + sLineBreak +
    ';return t.exports.PARAMS_CONTAINS.push([t.exports.CLASS_REFERENCE,d,g]),' + sLineBreak +
    't.contains=t.contains.concat([l,r,s,g]),' + sLineBreak +
    'c(t,"shebang",e.SHEBANG()),c(t,"use_strict",{className:"meta",relevance:10,' + sLineBreak +
    'begin:/^\s*[''"]use strict[''"]/' + sLineBreak +
    '}),t.contains.find((e=>"func.def"===e.label)).relevance=0,Object.assign(t,{' + sLineBreak +
    'name:"TypeScript",aliases:["ts","tsx","mts","cts"]}),t},grmr_vbnet:e=>{' + sLineBreak +
    'const n=e.regex,t=/\d{1,2}\/\d{1,2}\/\d{4}/,a=/\d{4}-\d{1,2}-\d{1,2}/,i=/(\d|1[012])(:\d+){0,2} *(AM|PM)/,r=/\d{1,2}(:\d{1,2}){1,2}/,s={' + sLineBreak +
    'className:"literal",variants:[{begin:n.concat(/# */,n.either(a,t),/ *#/)},{' + sLineBreak +
    'begin:n.concat(/# */,r,/ *#/)},{begin:n.concat(/# */,i,/ *#/)},{' + sLineBreak +
    'begin:n.concat(/# */,n.either(a,t),/ +/,n.either(i,r),/ *#/)}]' + sLineBreak +
    '},o=e.COMMENT(/''''''/,/$/,{contains:[{className:"doctag",begin:/<\/?/,end:/>/}]' + sLineBreak +
    '}),l=e.COMMENT(null,/$/,{variants:[{begin:/''/},{begin:/([\t ]|^)REM(?=\s)/}]})' + sLineBreak +
    ';return{name:"Visual Basic .NET",aliases:["vb"],case_insensitive:!0,' + sLineBreak +
    'classNameAliases:{label:"symbol"},keywords:{' + sLineBreak +
    'keyword:"addhandler alias aggregate ansi as async assembly auto binary by byref byval call case catch class compare const continue custom declare default delegate dim distinct do each equals else elseif end enum erase error event exit explicit finall' +
    'y for friend from function get global goto group handles if implements imports in inherits interface into iterator join key let lib loop me mid module mustinherit mustoverride mybase myclass namespace narrowing new next notinheritable notoverridable ' +
    'of off on operator option optional order overloads overridable overrides paramarray partial preserve private property protected public raiseevent readonly redim removehandler resume return select set shadows shared skip static step stop structure str' +
    'ict sub synclock take text then throw to try unicode until using when where while widening with withevents writeonly yield",' + sLineBreak +
    'built_in:"addressof and andalso await directcast gettype getxmlnamespace is isfalse isnot istrue like mod nameof new not or orelse trycast typeof xor cbool cbyte cchar cdate cdbl cdec cint clng cobj csbyte cshort csng cstr cuint culng cushort",' + sLineBreak +
    'type:"boolean byte char date decimal double integer long object sbyte short single string uinteger ulong ushort",' + sLineBreak +
    'literal:"true false nothing"},' + sLineBreak +
    'illegal:"//|\\{|\\}|endif|gosub|variant|wend|^\\$ ",contains:[{' + sLineBreak +
    'className:"string",begin:/"(""|[^/n])"C\b/},{className:"string",begin:/"/,' + sLineBreak +
    'end:/"/,illegal:/\n/,contains:[{begin:/""/}]},s,{className:"number",relevance:0,' + sLineBreak +
    'variants:[{begin:/\b\d[\d_]*((\.[\d_]+(E[+-]?[\d_]+)?)|(E[+-]?[\d_]+))[RFD@!#]?/' + sLineBreak +
    '},{begin:/\b\d[\d_]*((U?[SIL])|[%&])?/},{begin:/&H[\dA-F_]+((U?[SIL])|[%&])?/},{' + sLineBreak +
    'begin:/&O[0-7_]+((U?[SIL])|[%&])?/},{begin:/&B[01_]+((U?[SIL])|[%&])?/}]},{' + sLineBreak +
    'className:"label",begin:/^\w+:/},o,l,{className:"meta",' + sLineBreak +
    'begin:/[\t ]*#(const|disable|else|elseif|enable|end|externalsource|if|region)\b/,' + sLineBreak +
    'end:/$/,keywords:{' + sLineBreak +
    'keyword:"const disable else elseif enable end externalsource if region then"},' + sLineBreak +
    'contains:[l]}]}},grmr_wasm:e=>{e.regex;const n=e.COMMENT(/\(;/,/;\)/)' + sLineBreak +
    ';return n.contains.push("self"),{name:"WebAssembly",keywords:{$pattern:/[\w.]+/,' + sLineBreak +
    'keyword:["anyfunc","block","br","br_if","br_table","call","call_indirect","data","drop","elem","else","end","export","func","global.get","global.set","local.get","local.set","local.tee","get_global","get_local","global","if","import","local","loop","' +
    'memory","memory.grow","memory.size","module","mut","nop","offset","param","result","return","select","set_global","set_local","start","table","tee_local","then","type","unreachable"]' + sLineBreak +
    '},contains:[e.COMMENT(/;;/,/$/),n,{match:[/(?:offset|align)/,/\s*/,/=/],' + sLineBreak +
    'className:{1:"keyword",3:"operator"}},{className:"variable",begin:/\$[\w_]+/},{' + sLineBreak +
    'match:/(\((?!;)|\))+/,className:"punctuation",relevance:0},{' + sLineBreak +
    'begin:[/(?:func|call|call_indirect)/,/\s+/,/\$[^\s)]+/],className:{1:"keyword",' + sLineBreak +
    '3:"title.function"}},e.QUOTE_STRING_MODE,{match:/(i32|i64|f32|f64)(?!\.)/,' + sLineBreak +
    'className:"type"},{className:"keyword",' + sLineBreak +
    'match:/\b(f32|f64|i32|i64)(?:\.(?:abs|add|and|ceil|clz|const|convert_[su]\/i(?:32|64)|copysign|ctz|demote\/f64|div(?:_[su])?|eqz?|extend_[su]\/i32|floor|ge(?:_[su])?|gt(?:_[su])?|le(?:_[su])?|load(?:(?:8|16|32)_[su])?|lt(?:_[su])?|max|min|mul|nearest' +
    '|neg?|or|popcnt|promote\/f32|reinterpret\/[fi](?:32|64)|rem_[su]|rot[lr]|shl|shr_[su]|store(?:8|16|32)?|sqrt|sub|trunc(?:_[su]\/f(?:32|64))?|wrap\/i64|xor))\b/' + sLineBreak +
    '},{className:"number",relevance:0,' + sLineBreak +
    'match:/[+-]?\b(?:\d(?:_?\d)*(?:\.\d(?:_?\d)*)?(?:[eE][+-]?\d(?:_?\d)*)?|0x[\da-fA-F](?:_?[\da-fA-F])*(?:\.[\da-fA-F](?:_?[\da-fA-D])*)?(?:[pP][+-]?\d(?:_?\d)*)?)\b|\binf\b|\bnan(?::0x[\da-fA-F](?:_?[\da-fA-D])*)?\b/' + sLineBreak +
    '}]}},grmr_xml:e=>{' + sLineBreak +
    'const n=e.regex,t=n.concat(/[\p{L}_]/u,n.optional(/[\p{L}0-9_.-]*:/u),/[\p{L}0-9_.-]*/u),a={' + sLineBreak +
    'className:"symbol",begin:/&[a-z]+;|&#[0-9]+;|&#x[a-f0-9]+;/},i={begin:/\s/,' + sLineBreak +
    'contains:[{className:"keyword",begin:/#?[a-z_][a-z1-9_-]+/,illegal:/\n/}]' + sLineBreak +
    '},r=e.inherit(i,{begin:/\(/,end:/\)/}),s=e.inherit(e.APOS_STRING_MODE,{' + sLineBreak +
    'className:"string"}),o=e.inherit(e.QUOTE_STRING_MODE,{className:"string"}),l={' + sLineBreak +
    'endsWithParent:!0,illegal:/</,relevance:0,contains:[{className:"attr",' + sLineBreak +
    'begin:/[\p{L}0-9._:-]+/u,relevance:0},{begin:/=\s*/,relevance:0,contains:[{' + sLineBreak +
    'className:"string",endsParent:!0,variants:[{begin:/"/,end:/"/,contains:[a]},{' + sLineBreak +
    'begin:/''/,end:/''/,contains:[a]},{begin:/[^\s"''=<>`]+/}]}]}]};return{' + sLineBreak +
    'name:"HTML, XML",' + sLineBreak +
    'aliases:["html","xhtml","rss","atom","xjb","xsd","xsl","plist","wsf","svg"],' + sLineBreak +
    'case_insensitive:!0,unicodeRegex:!0,contains:[{className:"meta",begin:/<![a-z]/,' + sLineBreak +
    'end:/>/,relevance:10,contains:[i,o,s,r,{begin:/\[/,end:/\]/,contains:[{' + sLineBreak +
    'className:"meta",begin:/<![a-z]/,end:/>/,contains:[i,r,o,s]}]}]' + sLineBreak +
    '},e.COMMENT(/<!--/,/-->/,{relevance:10}),{begin:/<!\[CDATA\[/,end:/\]\]>/,' + sLineBreak +
    'relevance:10},a,{className:"meta",end:/\?>/,variants:[{begin:/<\?xml/,' + sLineBreak +
    'relevance:10,contains:[o]},{begin:/<\?[a-z][a-z0-9]+/}]},{className:"tag",' + sLineBreak +
    'begin:/<style(?=\s|>)/,end:/>/,keywords:{name:"style"},contains:[l],starts:{' + sLineBreak +
    'end:/<\/style>/,returnEnd:!0,subLanguage:["css","xml"]}},{className:"tag",' + sLineBreak +
    'begin:/<script(?=\s|>)/,end:/>/,keywords:{name:"script"},contains:[l],starts:{' + sLineBreak +
    'end:/<\/script>/,returnEnd:!0,subLanguage:["javascript","handlebars","xml"]}},{' + sLineBreak +
    'className:"tag",begin:/<>|<\/>/},{className:"tag",' + sLineBreak +
    'begin:n.concat(/</,n.lookahead(n.concat(t,n.either(/\/>/,/>/,/\s/)))),' + sLineBreak +
    'end:/\/?>/,contains:[{className:"name",begin:t,relevance:0,starts:l}]},{' + sLineBreak +
    'className:"tag",begin:n.concat(/<\//,n.lookahead(n.concat(t,/>/))),contains:[{' + sLineBreak +
    'className:"name",begin:t,relevance:0},{begin:/>/,relevance:0,endsParent:!0}]}]}' + sLineBreak +
    '},grmr_yaml:e=>{' + sLineBreak +
    'const n="true false yes no null",t="[\\w#;/?:@&=+$,.~*''()[\\]]+",a={' + sLineBreak +
    'className:"string",relevance:0,variants:[{begin:/"/,end:/"/},{begin:/\S+/}],' + sLineBreak +
    'contains:[e.BACKSLASH_ESCAPE,{className:"template-variable",variants:[{' + sLineBreak +
    'begin:/\{\{/,end:/\}\}/},{begin:/%\{/,end:/\}/}]}]},i=e.inherit(a,{variants:[{' + sLineBreak +
    'begin:/''/,end:/''/,contains:[{begin:/''''/,relevance:0}]},{begin:/"/,end:/"/},{' + sLineBreak +
    'begin:/[^\s,{}[\]]+/}]}),r={end:",",endsWithParent:!0,excludeEnd:!0,keywords:n,' + sLineBreak +
    'relevance:0},s={begin:/\{/,end:/\}/,contains:[r],illegal:"\\n",relevance:0},o={' + sLineBreak +
    'begin:"\\[",end:"\\]",contains:[r],illegal:"\\n",relevance:0},l=[{' + sLineBreak +
    'className:"attr",variants:[{begin:/[\w*@][\w*@ :()\./-]*:(?=[ \t]|$)/},{' + sLineBreak +
    'begin:/"[\w*@][\w*@ :()\./-]*":(?=[ \t]|$)/},{' + sLineBreak +
    'begin:/''[\w*@][\w*@ :()\./-]*'':(?=[ \t]|$)/}]},{className:"meta",' + sLineBreak +
    'begin:"^---\\s*$",relevance:10},{className:"string",' + sLineBreak +
    'begin:"[\\|>]([1-9]?[+-])?[ ]*\\n( +)[^ ][^\\n]*\\n(\\2[^\\n]+\\n?)*"},{' + sLineBreak +
    'begin:"<%[%=-]?",end:"[%-]?%>",subLanguage:"ruby",excludeBegin:!0,excludeEnd:!0,' + sLineBreak +
    'relevance:0},{className:"type",begin:"!\\w+!"+t},{className:"type",' + sLineBreak +
    'begin:"!<"+t+">"},{className:"type",begin:"!"+t},{className:"type",begin:"!!"+t' + sLineBreak +
    '},{className:"meta",begin:"&"+e.UNDERSCORE_IDENT_RE+"$"},{className:"meta",' + sLineBreak +
    'begin:"\\*"+e.UNDERSCORE_IDENT_RE+"$"},{className:"bullet",begin:"-(?=[ ]|$)",' + sLineBreak +
    'relevance:0},e.HASH_COMMENT_MODE,{beginKeywords:n,keywords:{literal:n}},{' + sLineBreak +
    'className:"number",' + sLineBreak +
    'begin:"\\b[0-9]{4}(-[0-9][0-9]){0,2}([Tt \\t][0-9][0-9]?(:[0-9][0-9]){2})?(\\.[0-9]*)?([ \\t])*(Z|[-+][0-9][0-9]?(:[0-9][0-9])?)?\\b"' + sLineBreak +
    '},{className:"number",begin:e.C_NUMBER_RE+"\\b",relevance:0},s,o,{' + sLineBreak +
    'className:"string",relevance:0,begin:/''/,end:/''/,contains:[{match:/''''/,' + sLineBreak +
    'scope:"char.escape",relevance:0}]},a],c=[...l]' + sLineBreak +
    ';return c.pop(),c.push(i),r.contains=c,{name:"YAML",case_insensitive:!0,' + sLineBreak +
    'aliases:["yml"],contains:l}}});const Pe=ne;for(const e of Object.keys(Ue)){' + sLineBreak +
    'const n=e.replace("grmr_","").replace("_","-");Pe.registerLanguage(n,Ue[e])}' + sLineBreak +
    'return Pe}()' + sLineBreak +
    ';"object"==typeof exports&&"undefined"!=typeof module&&(module.exports=hljs);' + sLineBreak +
    '/*! `delphi` grammar compiled for Highlight.js 11.11.1 */' + sLineBreak +
    '(()=>{var e=(()=>{"use strict";return e=>{' + sLineBreak +
    'const a=["exports","register","file","shl","array","record","property","for","mod","while","set","ally","label","uses","raise","not","stored","class","safecall","var","interface","or","private","static","exit","index","inherited","to","else","stdcall' +
    '","override","shr","asm","far","resourcestring","finalization","packed","virtual","out","and","protected","library","do","xorwrite","goto","near","function","end","div","overload","object","unit","begin","string","on","inline","repeat","until","destr' +
    'uctor","write","message","program","with","read","initialization","except","default","nil","if","case","cdecl","in","downto","threadvar","of","try","pascal","const","external","constructor","type","public","then","implementation","finally","published' +
    '","procedure","absolute","reintroduce","operator","as","is","abstract","alias","assembler","bitpacked","break","continue","cppdecl","cvar","enumerator' +
    '","experimental","platform","deprecated","unimplemented","dynamic","export","far16","forward","generic","helper","implements","interrupt","iochecks","local","name","nodefault","noreturn","nostackframe","oldfpccall","otherwise","saveregisters","softfl' +
    'oat","specialize","strict","unaligned","varargs"],r=[e.C_LINE_COMMENT_MODE,e.COMMENT(/\{/,/\}/,{' + sLineBreak +
    'relevance:0}),e.COMMENT(/\(\*/,/\*\)/,{relevance:10})],t={className:"meta",' + sLineBreak +
    'variants:[{begin:/\{\$/,end:/\}/},{begin:/\(\*\$/,end:/\*\)/}]},n={' + sLineBreak +
    'className:"string",begin:/''/,end:/''/,contains:[{begin:/''''/}]},s={' + sLineBreak +
    'className:"string",variants:[{match:/#\d[\d_]*/},{' + sLineBreak +
    'match:/#\$[\dA-Fa-f][\dA-Fa-f_]*/},{match:/#&[0-7][0-7_]*/},{' + sLineBreak +
    'match:/#%[01][01_]*/}]},i={begin:e.IDENT_RE+"\\s*=\\s*class\\s*\\(",' + sLineBreak +
    'returnBegin:!0,contains:[e.TITLE_MODE]},c={className:"function",' + sLineBreak +
    'beginKeywords:"function constructor destructor procedure",end:/[:;]/,' + sLineBreak +
    'keywords:"function constructor|10 destructor|10 procedure|10",' + sLineBreak +
    'contains:[e.TITLE_MODE,{className:"params",begin:/\(/,end:/\)/,keywords:a,' + sLineBreak +
    'contains:[n,s,t].concat(r)},t].concat(r)};return{name:"Delphi",' + sLineBreak +
    'aliases:["dpr","dfm","pas","pascal"],case_insensitive:!0,keywords:a,' + sLineBreak +
    'illegal:/"|\$[G-Zg-z]|\/\*|<\/|\|/,contains:[n,s,{className:"number",' + sLineBreak +
    'relevance:0,variants:[{match:/\b\d[\d_]*(\.\d[\d_]*)?/},{match:/\$[\dA-Fa-f_]+/' + sLineBreak +
    '},{match:/\$/,relevance:0},{match:/&[0-7][0-7_]*/},{match:/%[01_]+/},{match:/%/,' + sLineBreak +
    'relevance:0}]},i,c,t].concat(r)}}})();hljs.registerLanguage("delphi",e)})();';
  // END GENERATED HIGHLIGHT_JS

  // The HTML shell. Concatenated assets are inlined at panel-construction
  // time via _BuildShell in UI.OutputPanel.Edge — placeholders below are
  // replaced before NavigateToString fires.
  HTML_SHELL: string =
    '<!DOCTYPE html>' + sLineBreak +
    '<html lang="en">' + sLineBreak +
    '<head>' + sLineBreak +
    '<meta charset="UTF-8" />' + sLineBreak +
    '<title>Aefos Output</title>' + sLineBreak +
    '<style>{{THEME_VARS}}{{PANEL_CSS}}{{HIGHLIGHT_CSS}}</style>' + sLineBreak +
    '<script>{{MARKED_JS}}</script>' + sLineBreak +
    '<script>{{HIGHLIGHT_JS}}</script>' + sLineBreak +
    '</head>' + sLineBreak +
    '<body>' + sLineBreak +
    (* Header fixed at the top (replaces FHeaderPanel + FSessionPanel VCL). *)
    '<div id="ds-header">' + sLineBreak +
    '  <div class="ds-hd">' + sLineBreak +
    '    <div class="ds-hd-seg">' +
    '<button id="ds-hd-chat" type="button">Chat</button>' +
    '<button id="ds-hd-agent" class="ds-hd-on" type="button">Agent</button></div>' + sLineBreak +
    '    <button class="ds-hd-trial" id="ds-hd-trial" type="button" ' +
    'style="display:none" title="Upgrade to Pro"></button>' + sLineBreak +
    '    <span class="ds-hd-sp"></span>' + sLineBreak +
    '    <button class="ds-hd-btn ds-hd-accent" id="ds-hd-new" type="button" ' +
    'title="New empty session">&#9998;</button>' + sLineBreak +
    '    <button class="ds-hd-btn" id="ds-hd-sessions" type="button" ' +
    'title="Sessions / history">&#128339;</button>' + sLineBreak +
    '    <button class="ds-hd-btn" id="ds-hd-settings" type="button" ' +
    'title="Settings">&#9881;</button>' + sLineBreak +
    '  </div>' + sLineBreak +
    '  <div id="ds-ctx">' + sLineBreak +
    '    <span class="ds-ctx-dot"></span>' +
    '<span class="ds-ctx-title" id="ds-ctx-title">New session</span>' + sLineBreak +
    '    <span class="ds-ctx-sp"></span>' + sLineBreak +
    '    <span id="ds-ctx-count">0 messages</span>' +
    '<span id="ds-ctx-sep" style="display:none"> ' + #$2022 + ' </span>' +
    '<span id="ds-ctx-time"></span>' + sLineBreak +
    '  </div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<div id="ds-empty">' + sLineBreak +
    '  <img class="ds-logo" alt="Aefos" src="data:image/png;base64,' +
    'iVBORw0KGgoAAAANSUhEUgAAAaQAAAGkCAYAAAB+TFE1AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMA' +
    'AA7DAcdvqGQAAP+lSURBVHhe7P0HmGRVtf4B71NV3V3VXalz7sk5dE/nnMPknPPADGHIooIYMGcElCgZRIJivBdEBcwYUCQjiMBE' +
    'cs7Med/vWXvvU1XT+v3/3/97niuN96z7rHtiFaNM9893rXevrUgGHifDJLNIOsoPP/zwww8//o0hHHrkkUdy9MkeIHIXmTX6JT/8' +
    '8MMPP/z4nw7h0M0335wJpLt8IPnhhx9++PFvC68qJxy66667svQN+iU7P/zwww8//s2RyRxhkL7xCJBz//33Z/tA8sMPP/zw470I' +
    'ktneiSgkH0h++OGHH37820MLo0eQI2dSshMYBTPqeT6Y/PDDDz/8+B8N2zLSecfjj4d1M8n2j1JA8sMPP/zww4//6cg0NdyfUbLz' +
    'geSHH3744ce/P0Qd3XFHSAPJyqVsWYfkA8kPP/zww49/V2QqJK9k5wDI8W3ffvjhhx9+vBfhCSPvIlskkw8kP/zwww8//t1xJs8M' +
    'yNIjfeEBafRLfvjhhx9++PE/FZnObg0kOZGhdiR9IPnhhx9++PFvD1uy05MaAraH5Jfs/PDDDz/8+LeHsCc1y85uPxEc/ZIffvjh' +
    'hx9+/E+HXofk9ZBklp1fsvPDDz/88OO9iDPPtKYGz27nKyQ//PDDDz/+nZG5Dklv0GcvfCD54Ycffvjxb41MIKXWIdmtJ3wg+eGH' +
    'H3748W8PKdml9kOyLjsfSH744Ycffvzbw7aOQikg3eGbGvzwww8//HgPIgUke+GPDvLDDz/88OM9i0wgZd14441+yc4PP/zww49/' +
    'e6TWIfk9JD/88MMPP97LEP6kNuh7/PHHZVKD30Pyww8//PDj3x6pWXYSMqnBNzX44YcffvjxXkRqlp2EP1zVDz/88MOP9yqEPakt' +
    'kLRC8vdD8sMPP/zw4z2IzHVIemSDlOx8heSHH3744ce/O/4ZSL5C8sMPP/zw472J9H5Ivu3bDz/88MOP9yq0qcGbZefvh+SHH374' +
    '4cd7Ff8EJN/27Ycffvjhx3sVqeGq/n5Ifvjhhx9+vFeRUkgSMrLBV0h++OGHH368F5HpsnNk61jfZeeHH3744cd7FSkfg78fkh9+' +
    '+OGHH+9lHAYk32Xnhx9++OHHexGpkp29EFODP6nBDz/88MOP9yRSQJIVsuKy84Hkhx9++OHHvzusQjIuOznxbd9++OGHH368F6Ft' +
    '3972E7Zc5wPJDz/88MOPf3sctg5JFNKNN97oA8kPP/zww49/e4xWSNrUMPolP/zwww8//PifjtEuO12y800Nfvjhhx9+/LvjMCDd' +
    'f//9/iw7P/zwww8/3rNIlexkdJAPJD/88MMPP96r8Cc1+OGHH374MSYic/sJfx2SH3744Ycf71noAd8CJL39hD/t2w8//PDDj/cg' +
    'hEOHA8kv2fnhhx9++PEehK3UmSqduOx8heSHH3744cd7FSmFJAtj5cJfh+SHH3744cd7ESnb9+Nk2HfZ+eGHH3748V5FymV3x+OP' +
    '+0Dyww8//PDjPYtU28ib1OCX7Pzwww8//HgvIgUkf2GsH3744Ycf72WkXHaPPOIDyQ8//PDDj/cuMmzfevsJf1KDH3744Ycf70lo' +
    'BnkLY30g+eGHH3748V5EalKDhGwd6+8Y64cffvjhx3sVaYXk74fkhx9++OHHexSHzbKT/ZD80UF++OGHH368FyEc8jfo8+N/NHp2' +
    '3xGtOuvRySXnPza3+Ox9dYXnPNtUcPVzLfnXPt9WcM1zrbGrX27Pv/aVzorr9rWX3/h0Z/F3n+/Iv/aFzvwrnu7Iv/r59uJrn+4s' +
    'unx/V9GVB7qLrnmmK/mtA93Jqw70ROVc8lJzXXSZzSuf0dfJy5/pkvMiOb/0QHf04v2d0cuf6Sq86GBf8uIDPZKJCw/2Fl54sLfo' +
    '4gM9pRcc7C+9YG9/6fkH+wrPP9hXcvFTg6VfP9hfct6zA8XnPj2cf/bTI0VnH1hQdt4zC8vOeWZh2dkHFpR+7eCikq8+tbTky08t' +
    'q/jqU0vLv/zcirIvPr2y8nMHVld+4elVZZ81WfnZZ9ZUf/rg2spPHVxT/ZmD6yZ9Yt+6SR/Zt3bSx/atnfGhfeumnrxv7fRT96yf' +
    '8+H9G2tP2bt5zkn7N8w9ee+W5hP2HNGye9/2luP27Wg/bv/O9mP272w/eu+u3iP3Hj2wY+9R/dv3Hj2yfe/RSzfuO2bJ5n3HLl3/' +
    '5DErNzx57Io1Txy3cvVjx29Yvef4jav2nrhpxZ4Tdqx44sQjlv7jpCMWmdy56JGTdS549APHLHjs1KNH/v5hyd3Dj52+u//RM07s' +
    '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' +
    'vxxq/DKoiaKKBFiy2HcD1MxtUPOOoao7nmrOCVCdZ0C1fQhqzk6oqZugJq/3oARduqsUpbQAqlynqCRYhQRVIpkCk8kiC6dCUUgD' +
    'BjgCFA0VORfw9EpSJfuQzl45Uj/Tx9QzA65kPxxRTZF2hhK9rL3gADq/AxQ1n+wqNQ4qqxEq2/SinHADAuEGN5DbiKzcZkQKuuHE' +
    'O7Bk5Y6UGMroIRlVNBpGFje2apdZ60vb7lJDH4Df/fb3SMansbq8D5UlnaiQ2Xb5ZmqDVklpICE/XMdkTi0S2XMRl7S9pKiU7IJz' +
    'jCoKmj6S7ieJGtIGB1Oy0yYHJWmeWRiZtUm2dGfLdnoDP9kjSazflaoT41Q/BEgzBEhqM5rUFn101FSc03cjDolCWua6AqT9K128' +
    'vB7ubxY+wbrcHX7JboyG9TIYUQRAdoz1FdIYDgFS5PLnXg2K3duDkSglrZDE9v0rKlFI87YZIEmZa/ximIGlKSCJw86sF9JqRgMp' +
    'vfdRql+U2s4hs2QHs6dQRhqQpbd3MBO2jYNP3HayuFRPUhiENidI+a5GJi8soVYwqZQFvIuhxsnYIJlptwxq/FIDlHECVlFIa6Gm' +
    'ijISRbQbqu5TUGuvpDr6O1B9l0LN+yRVyweoZh9JDSXpKclnpZ9UuYSqfCFV2QLosp2YJEpEJQ3bEp2AR8p2OqHVkFwXCIwGJaXs' +
    'ZmAkYNGgsdBJ9lIlBEy9SB3lnpcJud9HJ9kvZT0LpRGqrEbmTt7E+kteQ/8PgfEbrkJR7xkoHjyTRX2ns6DzZBZ2nsKijpNQPnQC' +
    '8uduQZbYryua8NjjZndZq308c8Nh44G89O7rcUGZ7aaM9pNHuLfefputLf0oLmwzQCrqYKkskk00o0jMDXqUkIFSvjf9W8p2MkbI' +
    's3/rPtJsUUqHKaM83UOS8p1RRinXnddHSgMpYxK4cdsV6rKdjBASIIlC6uckNcKZagXrnU1odLZahTQJZ/dej0MbgL1L4O5dKirJ' +
    'xYsbgN8s2MPZ4W2+y26MRqqHZMnkr0Ma41F95ZOzcq989vWAAOkpmwIjOcousuf/Skp2ULVboLedmCxjgxaYKdvSQ5JxPt76I5mU' +
    'bcp1merIA84oKFkgadt3au+hjPSglLkdhFZJMNMQxG4uQ11liwmxoMtU74VSSqOqlh6XlzLxO3WE6QEJnLSBgWrKGqOo5u6CM+tM' +
    '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' +
    'csbcS1A0+wIULbiAhQsuQMG881k4bw/y5+0w8ubuQMH8PSxYeB7yFu5B/vw9yJu7C7lzdzJ37rnMm7dTP86btwuFC/axYOF+Fiy8' +
    'ADMWX8TiJRdy5uILUbzkUsxZfiWKl13B4qVXsGjBTuTPOBcXjbzBHz9B/urbwBdvAxqWP4LZy97DuSvfi7krr8GclVegeOXlLF55' +
    'mRxz9gp5jytRvPxyzlpxAWYtP8+YW3I+8mefg7bu7SnDmDI70mkyZG7Y1v3bUhLm7dy8yk6YnWKrtv0Cp70+nQ1Mj+zn7JH93N+7' +
    '5u+ds5ilf569mdb+nCaQTOBkV/a2knnmZ7cgpB/Zisx6+YMPfcjwexZolTQzv5Ez8hpQkFNnmhti1UxGq5mQ1F2wwgJSGSK+MlpQ' +
    'MoGkU3arGRJ15CzRSinkMJWSaWYwYRRR5VLlG3HL0JCjgdSsFdIs1Yv5agRL1TquUlu5XKfsluOOii9AgPSdlpSk7PhiB/DTXuBL' +
    'Lb/h3OC6aSCdwUO8DOmDaYV0Zo+CsSfzPbtf/mcxNYhCSqujrwKu75OuT/+aKtkBtUD6IY1RFQ9RFfRQ5bRTxZupog0mkDLFVa1K' +
    'DWm3XVYhVUnZVUBMDQ5/DVy+eni9zYx4ephwTWBV4BA/2vU7vnYJ+cvbgcf2/zPKYnch6tlouMVd5+2gw9NK5W2A8jZQueuhPPVQ' +
    'bjmug+626qmzogZmSBfWGipPLfR5t4Scl2KtDbpga/rYI4+bzMoPHtmA2w3lbUQ0upln1X4bV3T8HM3z74fDN6pdek5tlmg3SxPp' +
    'TbhSEaLBUIEG3X5dNxeUjrfBOriCTboEzY2H7tW39tNSdaYSSt/a02tF6ecFEFrY6P9bGa/T2CPXTU39jf/27//Kf/6Xf+Zvfvtr' +
    'vvWLX+LV1143fvLTn+JHr7yCl195hS/+4GV894UXja9/45v42te/ya9//ev4+te/ga9+9Wv4yle+hq9/7ev45je/xZdeehm//u2v' +
    'bWWUHuZnz1Ji1ie2aJUGkZkkzADTBlEaWjarALzzzjusqe6COOpmz2hDcX4zi/IamZ+og1jAc3XqrpqJUCVigQpEfeUaSmFvGUPe' +
    'UoY1lEoQcpUwlIZRiaTrRCFJmk6gpFN2EVWOqKqguX4kQGpggWqh7EGao/owX41xmVqP1eosrtApuxU4UfEF/KIX+I4opHZJ2Zmm' +
    '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' +
    'REP9a5cXn1t968ZfJvAtBPgW/e/fhohA6JKuZ/PP6/hEjjjnxLBwYM0rXgHR9DrR9Ph7Y3oNaXr8/x7xyo9/buVF5PILgCX7Uli6' +
    'N4UVew2s3AO0XQosrH2Kyis9hzZB5aynyllHlbMeKmcdVO5683xwUFdNWFhzCdZc/wrW3gLU7wDKz5lC1e4pVuw6idIdU1gt4JHY' +
    'KWrIwKrtKazeCVZeQNZeCJRs+R2Laj7OQMEFdAW3/LM/ue2ZUN7O9/tj597tj20/4Y+efcwXPvuwJ7rjNk9sx0FXZMetrsiOg57o' +
    '2bd5olsPuSLnHPREtx/yxbff7ovvus2X3HvIl9x9SI49yT236ePkroO++K5bPckdt/pyzr3Zl9hxsy+569aAnI/tuNmT2HWzL7n9' +
    'Vl/8nIO+uMzbb/XFzpXXHAzI+0bPvd0X2XHQFz/3YEAisu1WX2zHrYH49sOB6Dm3+eK7DwWSOw/p5+Lb5fytvtg5t5gh77fj1kBs' +
    '5y2B2O5bfIntt8j7B2K7bg3Edxz0xbbdEojsuDkQOefmQGTLzYHIWdbxtltCkXNvlud8kXNuCUTOOhgKnXMwENh8UyC0+eaQb/PN' +
    'ocDmmwOB9Tf7fGvNCKy9NRBYc8jnm7jF5xs75POMHvQ4hm50uTpudngab1HO6ve6vd2XzivYc27JvH0Dy+ZsK+suu2UhH2NY7hu/' +
    'vx2h5/YyfOXADxMXDz6Te273t5L7LcecxFktz+kqC9Opuenx/zUyteymN8ZOj/+XkUxuiiYannl99eWk7EFavF/2/EjKDtpg0HUJ' +
    'kLfwMFWwnyp3I1XuBgnoOW8zVHRUl/cpLjmXAxc8x7UHydbzyZKtKbE/s3znFEt3pFiyY0q70VaeK660FFZuT2HljhQqzwNqLoSx' +
    'fP2bzF36frrCW046/H1PR/LWbi3puWvFyI1/mrX1Xsw86y4Wbrvzv2acffi/Z2068Xbx1nvfnrnx9t/N2XXv2zPl+Oy7/zRLntt1' +
    '73/p85tv/P28yRt/MW/L8d/O3nLwt7O3HP/X2Wcflmt+M2v7wbeL5b0kdhz9S9Heu/5SuPXI2zM33vi7OXKNPG/Pm+T4xt/M2njj' +
    'm3PM87+ZtU2uu9F8nz03/mnW/oNvF28/+Ovi7df8Yt5ZB34/V57fds3v5uw88NvZe278zazzD/x29t5rfjdn7zVvztlzzW9mnX/F' +
    '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' +
    'QPhdmrWb27fHqodVw3G5bzNKONoKYDIu2b3qFbTrfxia/LSy+Ofm0/b1m2tDKyKLEKopKiJcBwddQ42IKCMCgfCnNCEKifC7dJ12' +
    'dNRA1WThDAeAibbvYYhiDLTr7wA/NlV8/2Prhbv7zWVqRG4APzMTWlObMpYVOAVEFBGBQPh8RDqILGFOkGSYjHfHziM3veg+4QA0' +
    '77kemjRbkf9ji5WHuoyyG4P+OIkNFREuAcE1y7HWqwkEAuGLIQqJ8LvwAH7qPVJmYKuu6rat+5qtG7r6RD88jxYWtHhZzei1iLBG' +
    '1LC0AYFAIHw1jRQSGWVHEEeaBz9JfqSgwdMljiFNG4ZukxoRgUD4NtA6CJtZsA9JZLaBQGBoQq8myq5eKlqwD7ekaY5AIHxjREuY' +
    'JwIZ1EAgEAiE74dIIZElzAkEAoHwPREpJIqimpI+pP+7TJg1q7uKispgfX39IRoa+kOmzpvXUzIM4fPp06dPd2lp6X6ysrJ95eXl' +
    '++upqw+yMDAYaGBgMNDMTH+IlanpIH19/f6mpqaDLCwsBpqsMxmAW3Tr168faLJu3QBpaWnaWCyBQPg2YNcRvUNbaiAK6f8aLf2C' +
    'g00jHj++m5mVXZSallaXkZlZm5yaVpeWmVmSmZ398GZY2Hq08CN5IeEjWjg7O8uEhNzwTElNjUxLT3/7KiWlOj0jvSo1LbUmLS29' +
    'JjMzszozM+t9ekZGTVZWdlV2dk5lZlZWdVZ2VlVWTnZVRmbmh8zsrOqsnJyqnNzXH0JuhfpIJkIgEL4ebKmjd4i17/9bnPLxmZL4' +
    '6tVTIVDwZ0REPY7WNLAYKBkHgcFqg5V03NPY+Pfv30sW3V/i/sOINKlevZpLpkcgEL4cHFzXMKghMZEM+/4/wrqNG0empadXcIKP' +
    'Qpgt5yihkD4r0lZP4xOSp0yZ0lUyrv8oohGAPj4+MmnpaSJN1FB2AEKhkEJHn2PLFdgixdOsH1P+9A5zDSVkwsTExDzDmlfjpAkE' +
    'wtfSyNo3GdTwfWGtHPwQ9iD8WoMAFQlSkTJCyShEEcrJSVYx+QcFeknG+V+Ee6nPBJ6bUVxS8oEuP1QyXImJKRpWwTQofCFTznhK' +
    'TGFxSomOh9ZeABAXH5cg1b07UUgEwjeCrIf0fwyHfQ6r3pW+EykZFKUStSPxL3taYbHyFHLz8wVmGzZMkozzvwTOpcPVj9XULNqk' +
    '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' +
    'YMBZvP7POrzZJtwfDh3aOzU7J4dpVmTjoh0jzEQDJ5CQ69eFa80tkuYtWBQ6d+7Cc/PnL7qwYMHicwsXLgpatGDR2UWLlpyfN2/h' +
    '+Xnz5p+fO3f+xfnzF1xYuHDJpaXLl19bsWLVDWMjkztbtmxOj46m57NyHeui4ceMsG24F3//M2aY1/z8/E6OTk4m+/fvv7vexuaR' +
    'jbVVjIa6RuLDhw/r2XyL8o4Z52oU6Pf82XO+ubn58012dokbN9q+sLKyilu3bl3Chg0bntrbb3m82d4+ys5+y5Nt27c/3r59+xMe' +
    'jxe9f//+B34Bfte8fHyUd+3iTcjMzCih84uI8so2Y4k39wHA3bv3wGb9hhx5ecXbkyZNuTZjxqzrc+YsPD937oKz6GbNmnNWWnru' +
    'hTlz5l2eJT3n/Jw588/OnTP36pw5c0IVFBRjrK2tcy5euFDPPVOco8bcH90Myj0fUSF5+/ptZZ/nD9jfNnP06PaPHz+hzVOJvyti' +
    '14o+Mp5EPQEzM/OMpUtXXlgwd+G5BXMXnZWWnuM3Z/b8gLlz5gfMn7fIf+H8Rf4LFiwOnD93UcCCeQsDF85fFDRv3uJAen/hknML' +
    'Fyw+N3/uorMLFy45v3jx8ovLlq8KXLZ8ld+yZasCV6xRCtIysFwbGxvbAi20S76D3wIDtTeBW40B7HSElJ0uRW/t0WkLKXstCnaj' +
    'otL5kKcnn9hB8trPpImd/NsYD02Ao8pC6pgyRSuko4p80J1MFNLXIOo2QoVEf0X9ibAifDmcgMf9K1cu6gsFzMdyQ1MLJaS/eFGg' +
    'sVI3LS1NoGdoKIt9R/hsJOL7IZVKbZqdnd3dwMRk0RHHw3QtCS+kXWMBIxJS2Tk59cbGxlPF4/oUbNPgL7du3bLjhJuolsFsmLjZ' +
    'vDo6Hq8aPXL8QWNj46WXL1+eGhYRNu7uw4djIyIixj14/HhMeHj46DsPHowJCwsbd/fu3bG4DQ0NHY/7IaGh4y9dvzTp8OHDs5Yt' +
    'W6Yyecpkn5jYWGYNI1aBcM2OYh/zkBAffxTzWppR2jY+PqXnISenQfuP7h9z7NixX1esXr0yNi6WHhfPVSS4URjiCunZsxfv5s1e' +
    'uJS3c+/Mrdu3S9vzeNPt7XnTt27dPmPzZt6kzZt5E3DL4+2aYLtly/gtO3aM37Rp06Bdu3b1TEpK6u7q6rKhqpKpuXAKVKzsGz1P' +
    '79PeRePGTdq7bJmM7PEjx6edPXt2StCFC9NCQkLG3759e/Tt2+GjQ0PDx1+/fXvS9euMu3HjxoSzly5NCgq6MO3gwSOL5eWVNEaP' +
    'Hn3QwtKysKKinE6Duz2xZjfR874XHv6Is2mItWodHbURUU+i8pmyFfu4YD+MuOtysnPq5dbIn5ORU1AMCgr69cqVkMkhISGT8Xnd' +
    'ufNgDG7xmYaFhY3CfN+8eXcst7127da4qzfvjr158ya9f/367dEXL94eff78zbEhIQ9G3I2IGRhyN2JgTFJ2dwBoFRGR3Prv+BBe' +
    'ofZospnehzorQ4qy0hVS63SElI0eRW0yBNigQ1EbdShqsxYldDACWK9V/LW1pB82ypVEu6gDHFQUUoeVKKGjEkUdUagHg6lPpSUD' +
    'E/4EkGoSyy1hTmpIfx+sQvpRWlq6XfKr5FROIDAyjKK/dJmhvqxEAQDfM75XVE1U0SIAvZzCp+J7nvO8fWFh4QAVFaWdL18mMoKR' +
    'llLMwAFG2bHx0r4Ad+7duS4elyRs3D8ZGhq2jY6LZkYBsk077FBtRgqyWiI5+RVfXUNr97Pk9NE5OTkDcBTgi7QXvVNSUnomJyf3' +
    'wG1ccnKPrKysbngcn5LS89mzZ71wH8+hf05OTo+MjIw+KSkp4+zt7Zds28YLRxt+jLBsEPL0/bD3kZqaegnzi6NDYzMy2qanp3dJ' +
    'TEzsk5aWNsieZ7/oZXJSI4XE1kRF5YJ+aWnpxTzezjm5RUWDXrx4MfDp05eDn6ekDIhPTu73OD6ednFxcX2fPUvtJZ7vuJdxfX2C' +
    'gvqHhd11ZLPT0ATGZpZ9tnQ6MU9iP8ybs8Dm5cu0kWm5uYOio58PiHsU1zcyPp5WbM+fP++KLiYpqXt8fHzPqKhnveLiknvExcX1' +
    'iI6O7h0bm9gnKiqq/+PHcWMiI2NmDB8+cpvjkSO0uQ5xBcQqJdohL5OS3mlqGvVkn2uLTZs2TY6LjaWvo9879iODU9LcB8b1qzfi' +
    'N2/mTa2oqBgcHR09AO87MTGxG+YV84RlQD9LNv/ouHNMvhv2nyQmdnvyJLHb8+cZXdE9fZraOTExsUNYfHy7qKjUNmFhWc14PN43' +
    'N0OlppEbYmkGoK8nFBrrCikzA4pSUXkHckp5YKVPUWu1KcpKWyjcog+wUfN9gaFK7Nf0JTXZKFcSeVwTYJ8SJdynJKQOKQEcUOCD' +
    '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' +
    'xAqFS5Hlfc17eHD/XtiFs2dlra2thw0aNAhrBdhUhQ4n+OKcKqxh4w8Sa3/cPvo1VVNT637kyJHZFy5e9ERl9NG9sTDJM+/YlWvX' +
    '0d5fS7b2IxqJiFtzff3+JjomAyws9HtpamoOVFdX76+goNBHTU2tl5KSUm90uK+trdQbna6ycg9NTc2e6NasWdMdnby8fE90CgoK' +
    '3YzV1buoq6t3sbDQ6Wxvbd1757adFokvmKH3dEGIrWuFmROwIzTDwu9HfHJY9mcw0DLvXFdbgC7raqmua2upruZ1VDdrgK7KiaH9' +
    '5e5t7qtwf1tfuTs7+6wK3d175d1tvZeHbusv88C+/+qIzQNWP7IdsOaB7cDVDzYPXh22vu+iiODB6nwYoSaEkar11Gi1emqCFsCv' +
    'Su9ztLTK2kmmzTFdtujxCnWAJXJCapmCkFquALBCgQ8zSJPdV8HqIKZdXLKTmPBl4I80PSODFlC0YGAnptCCQkx4oL9PgN+F0aNH' +
    't3/69Gnn0NjYtrH5sS0SChJahoWFtUKDqbdu3Wp5JT+2BVqZvpWQ0BLPXYmNbUH7Jdxqift4HrdoMTooMrJ5WFZWM5xYhhaV0UL0' +
    '09TUzuevXh2lrKrKy8nNYZbZZiyAM8qycb8Hna+zF8774b1gTWP1arnp5y9caLgf0T1I1AjYa/Efrv76OjdXkJmVxc/JyfyQkZlR' +
    'nZ6e9j49I706KyuzOjMjvSYjPb0mMyO9OiMj7X1GRnpNVmbG++zszKrMzIzqrMzM6qzszMrMzIyqjIz0ajyXmZFRnZqS+uF17uv3' +
    'paWldYmJiY8sLS0/EhLse9wS+5ASniXQgxoYhUv36NBymrtv9Et6lVK9Sl6ethv4uTUkDixfW96eflu37Txbxxew5cFYVecEr/g8' +
    'KlqDAEBdfT3k5uS8T0pKykp8+fJV8qvkl0nJSS8Tk5ISk5OTEpKSXj7HIe0vk14+f/HixYvnz54nJSYmJufl5haUljLGJ+jnIXpw' +
    'YjVf9nmgf21dPRw7dsIUm5HZ5vgfcPEzvM/bt+/Yvs59XZ6Rnl6ak51VlJGRVp6SmlKalpZanJWZicdFaWkpb1NTXxWlvEouevXq' +
    'VVFaWmpBWmpKYeqrV4Upr169eZWcVPDyZWLRy8SXRSkpKQVpaan56HKys/Pevi0urBRbJ0q8VsTlD0/h1tXT25Ep0S8r/1kb7k/o' +
    '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' +
    'jHjaQfNJXAetuHs9ZB4MkQz/tfSff3t094VRYT3mxSb0nh/zos/8uITeC1487bfo6fNZyx5N58Lh4IlBC6OP9Vvw4sXAec9eDJGO' +
    'eT54zvOnQ+clR42YHjGucayEz0FUQ8IvS9EB4bPAH9PFsLB2ahYWI0bOmKo5d9kyK+nFS+1mLljEmzx7ti3tZs3aOnn2bPuZy5Zp' +
    '8I4e7YODDL6kieJbgEITa2RXwmI7+YbcGTF3pYzKMln5HTKKirtllVV3yysr75JTVNwvo6joqKGlfdjCyuY3k3U2K4NDQ9vSM/kB' +
    'fvK5datlUMiDzjjX6daj6FHmm3gL5ixeZjR73vwDyipqXjoGBmd0DQwCDYyNg3Cro6cXjE7PyChY10A/UNdQz1/PyChAx0A/UEdX' +
    'J1BbTw/DBeno6wfq6OsH6Bka0vu6uvqB+vqGwfQ5Pb0AjFdbT99HQ0f7jJa2rqeskuqphUtXbtvkcLyj5H0iOEz+ysPYPtILFpnP' +
    'mb/AS05exUNWSfG0nKKil6qahqealq6nlraut6GRySldY7NV+HHwLVoG6GHVYVnNgm5Gdrj/Iq+365nro5fL6i2bOn2uxbQZc/fJ' +
    'yim46+jo+unpGQZr6upfUdXQvqauoXlNU1fvqoaO7hVNLa0r2jp6l7X1DC9r6epd0tbWv6yhrX9NXUP7soam1hV1Ld0QDbxGU/uq' +
    'sprWeel5S53HTZptOUNaZqaXV1i/c9fi+vqcf9QFa2z4fkkKevzyjIhIbn3pUkQPfSNrNV09Q28tLb0gbW39cwYGxmf19AzO6ukZ' +
    'ntPXNzqvZ2B8QVdX74Kejv5FXV2D85hnfX2jYF09g7PaOvrButp6Qdo6+he1dQ0uaGvr4bmLWtp6l7U19S7q6BhcUtfSP6+krOG9' +
    'ZJHc0clTFlqPGDdXZckak8mXLiX3CAlJ7ezjc6slKvEvLnOAJl486WbyS+Q7z11m2nf+fOshCxfa9FedqfpnNue+GI1hZh1njbHp' +
    'P20ib9jkMbwh04bb9JUZptFRmic+NQaaaEkfaTd3ws6B06fvGDp9gv3ABTN4feQXWYnXoghfgKgPCUfZEYX0ZeAP6sqVKy2uxIZ1' +
    'up2c0yMkImLg5cjIQdceRg+4Fh09ICQmZuD9hFf9H2Vm9r2fnd0dBbrblSstvsfkY8wrzlXyv327B06qvRr+dPC58MeDL9yNGRgQ' +
    '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' +
    'X4QdZcfoIOw/IrbsCP8r9JC9v6W/KUA/QwH00yquGbgybhDj82XKCGn9a+DUXnKFMFDlAwxUrqYGqtXBIM0PMESzBoZo1cFAjTro' +
    'r1YH/VRroZ9cCQxRqhIOVAMYrFqauVz195vsFii4tR24PCN7sDLAOC2AccsSj3B+A+aEXhmjDDBWCWDiyrxonjTvs/pvh06Ltfx1' +
    'BcCcVQCTFhTWtGnjSBQS4V+DSCElMushEYX0jUBt38+rYm0XX75LJ9/K4508q506edU4dzpd49TFs9Kpi1eNcxevGpdOJ6ucO7hX' +
    'O3U4WePS1b3KuZtHhVOXU9XOndxrnDq5Vh/v5Frn3Mm11rnLiWqXTs41Lp1cak90OVbl0vVYlUt3p+oTXY9WuXY6XO3S6WitS9cj' +
    'tSd6Hao+0etIzYlejrUnuh+ucul6qMql++Fql54Hq0/0PFhzouehGpeu+2ucu+2rdOp6oNql+4Eal+57a5xx2/VQnUuvfTUu/fbU' +
    'OPfbW3ei/96aEwP2VDsP2Fvr3H9PjUvfHRWufXZVo79L/11VLv1wf1etS78dNS79edWu/XfUuvbfUXNi4PYql/47a070317j1s++' +
    '4kSfrRUufbZUn+izpcK132/VJ/pur3Htt6XaZYBtlXN/++oT/eyqT/SzrTrRa2OVS2db4YmeduWbcG6QZJmK00Um3L6XMUBP/XoY' +
    'oPPu/UjN1K8WzJ1+9ZzVTf4N9FJ9D72Uq4R9Fcugx5p86ClbCL1k30J3uQLoLv8Weiq+g34Kb6GvQhnVS5UPfZQK01DpSMbHMXjR' +
    'o/WDlACGKghggnKFYLZMvOLsBeHDxy15OmLQgjCdgaurBSPkBTBGgQ/TVr1UkLz+UwyZmWD96woKZqwWwLjFb2va9D79xfdtrlf+' +
    'q4latYueUpWzrlyFi57sOyc92TInfZl3zmZylcfXKlY4mStWuVjIVThbylUeXydX7WwpW+VsKlvpZKFQ5bxWrsplg0ylk+2aiuN2' +
    'shXOG2TKnKxkKpys1lS5rJetct4oW+28Ua7a2Vamynnj6konO5kq582rq1zsZaqdt8hXO21ZU+2yVabaaYtczfHfFGqct66pcbFf' +
    'VeNsv6rWeeuqGpftMjVO2+RqnHfI1jo7yPCdHGTqnBxW17nskal13iVf47RbocZ5j1yty+5VNc57VtU671td57Jfrsb5gGKN0yH5' +
    'GpdDq2tcDsvVOh9RqHM+IlfnjH4H5Zj9I3K1xx3la487KtQ5H5WrcTkqW+N0VK7WxVGmzvmYTI3Tcdla5+Mydc6HZWqcj8iiq3M+' +
    'urrO6cjqWqeDq2qdj6wRnjisVG+Jq8dKlivhr0MPaiDLT3x7DgUdat7Pq7xy4EOAXvcAeoYD9AgH6BYG0P0e47qGA3S9A9DlNkBn' +
    'dtvtJkDX2wBdbwJ0DwHojschAN1uAHTDbQhA16sA3S8D9MDtJYDuF5htD3TnAHqeBehxHqDXWYC+ZwF6nwXoFQjQM5DdngHo5QvQ' +
    '2w+g1xmAvmcA+vkB9PMH6OcDMOA0QH8fgP5eAINPAwz2ARh4GqCfJ8AAL4D+uPUAGOAO0N8DoJ87s4/n+rsDDHYHGHIKYKAHwBAX' +
    'gCGuAIPcAAa4AAxyARjoxmyHHGfc4OMA/R0B+h0D6O0K0Hnrh2p1mwRm9NnvrK/TY81V5R76ldBd7z30NngPwzQSZCXDfC7tJ3rN' +
    '6CxXAF1Uq6Cr8nvoOueeT7tRe5Z3nuQp233y6TVdJjqtbjfedWXr0UeW9lz88EYfNT50U/4APeXf/K5CGivNa9dn2avcfooAAxVq' +
    'YIRihWCkXEn5aIXS2jEqVXXjVGvzRinW8AfL11FDlQFGrs5/Gqyg8KcfhENmPreesBLg19V8GLW4sLptn1MDJMP8GZbG747abwCw' +
    'MgewMQXYZAKw2RjAzhhgsxnAFnOAreYAv5kDbDMF2GHCuG0mADuNAXYZMW63EcAedovnd+KxIcB+I4ADRgCH9AEOGQIcNgI4glsD' +
    'ZntEH+CwHrN/DJ0BwHFDgOP6ACcMAJzR6QO46AO4GgK46QG46wN4GACc1Adw1wVw1wE4pQ/gqQdwWg/AywDASx/A1wDAVw/ARw/A' +
    'VxfgjA6Avw5AoC5AAO5rAfhrAwRqAQTqMOcCtQGC0OkABGsDnNUG8MNwWgABmozz1wAIUAcI0AI4pgxgJV/SU7JcCX+dRsO+cSVK' +
    'yQCEryMsjPfTOPfMtcNPF3oNPJV/urdHvmc3j0KPbqeLT/byyHftfvK1S2f3ghM9PIo8epwscu96ssSt28miU7jfy63IrYdroUdX' +
    '12L3rieK3bu4Fnv0dCn26ulU7NHzeLFHt+Nvvbo4Fnp2PVrk3tWxwLvH4TzfnkfeePY4WuDd07HQq6djoWePo0XuvQ+/9ex7uNij' +
    '96EC916HCr16HSw83Xt/kUevfYVefQ4Uevc5UOjVe3+hZ599Bd699hWc7rmvyKPPvsLTfXcXnO69K8+j1+5Cn757Ss702VN8uvfu' +
    'tz59dxWe7r+r0LPfzjdefXYVnu6z+61Xn52Fp/psL/DuvSPfp+/2/NN9tuV799te6NFve4F7n+1vPPtvLfDuv7XQs9+WN559txX5' +
    '9t1e4NOHV3i6z9YCv75bCs702fzGs9emAu+edm/8e2zM8+u+uSRgwIYCW5CSoldb/b0muK4LeV06KScWdTUUQBe9WuiiFH9fMszn' +
    '0mqs+4x2cm+go3IF1VmlFjosiDHH859abK7bskdHeqoJoJNyDfSQf5OxWsvrk8O++y54ZNNLQQDd5aqpPqpCGKQBMEgVYKAKBYOV' +
    'AAYpAAySp6C3Yj30la+jBsrzYcz8BDnJeCQZOOPp+tGrACas5sPIBW+qu/Y52V8yzJ9hoJuzSEfr/SlN9Xc+GhpvfXW1Snx11d56' +
    '66u989TVLD6to/nOS1ftnaehZomPmXaJj7nm29PGasXehuolPiZqb31MVYu9jdQLfUzU3542VSv2MFN562OuUuhjofzW00L1rbeN' +
    'xjuv9arFp2xUir2slErOWCu9812v9O40Hm9QKfZar/Tu1HqV4lMbVN952qoWe25SLT61Sa3Yy0612HOzyjuPDcrFnox767lJ9Z23' +
    'vVKZ91aV8lNbVEs97VXfefOUSz1/Uyz12qJUdhq3vym+8/pNsdJru1Kl5w7lCo9tyuVeW+XLTvMUSj13yJV67pYr83GQK/feK1/u' +
    'tRudXLmng2z5KQfFSi88t1+h0tNBocx7t1zZmT2y5af3ypV77VKo9NwlW356t1yl5z7ZSs99clUe+2Wr3PfIvffcIVe13XBF7JdZ' +
    '6SD8KSJLDbiTlZXVjNSQvhEATRRwOXDuMFjqR9rxpH4CntQvwJNulntoavNY3ooWCQfUW95inS/Poo2brW1b3AbvtW3L4/E6ODg4' +
    'dDzu4NDx0KFDHQ7xeB1w6+BwvCOPd7ATbtG57HFp77JnT/s9e1za0+FYh2E2bXLouGfPnvYYz+7djp1xy123adPxjrxDhzrY7T7V' +
    'mcdz67TJwaEjbq3p/eMd7RxPdbbb7dgZ4+EdPNiJx8M4D3XAdNCfvp72c+uE13GO9mPTwPBHjhxpx0N36FAHJg3cop97B8wb+js6' +
    '8tr4HLBpmeq4pCmWmTQPfhIvw0/RduG14+1MAFrp1whbaldCZ7X04FGaj8egMuPCDF4dNm6AZtbJDoqpB6SkPt1P036az/R28rnQ' +
    'VrkEOqrUQdsliVZ4HgdI0IMkRCuiSkl1WBJ1opNKPXRQqIEOcvkZ0p9QSEt+dWzTeWlKTkclPnRREUD3pc9f9JgWeLzH5ODD3Sf6' +
    'OXWZEOjSZWLwga6jfHb1WpKU20uZgp6ooJblPPmzftwh8xOsh60SwIhV9TB0YdGHLl9RQ0LQpJIXT6sZz5TXytbQrS06noVjG57l' +
    'kXabVF3af8pZq7h1MtPw7mgl795hk5l3x00a3h3NNI533KRxvCNPz70DfR799dw7bDLxa49bK71DHTaZuLS31DrSzsTEpT3Gb2l5' +
    'pJ2JKp7zamfIpo3X4rGW1pF2FmqObSzUeG1wi+Gs5A91MFHdQ8eBYVRVXdqjQz8ML9pfzezLyx/qgPucU1Xd03611pF2q1fz2iko' +
    '7G2rpubYZtWqDa3RKSjwWkkr8Frh/hI1XhtpBdNWCxfatFy4UL2lgrRpqxUrVrRYsmRJU6mJUj9LKUj94bMh/DVQD3E1pCaRubnN' +
    'yRLm3xCAJjwe7wdecPAvVkGRzW18brU0DQ5rZRgc2lbV72F7effIDip+YZ00vEM7yniHdtTwftJR/tSDzmtcHnVBp+z+uOti1/vd' +
    '17jG0G7V8Ygey09E9lziGNVr1fG4HtzxGtf73TEsfZ1PQhcFpyfd0HHXoGP24+jwuJU/FNlTmY0Dj9c4RvVafiiy5/JD8T3RD8/L' +
    'H4rviefxGP1W7YvrgU7tcEz3NYeZ+OhzGN8J9jo2zKp9EfQWzynsf9JNeffjrspHH3fFffr4KB4/74rn1Q8kdFF3Seii6vK8vZpj' +
    'ahsFp8RWCsGJvzQogt+nS3+9rm2W3U5stxagrW4VtNZ8D60Us993UkyN6aaacaGTcnZke+XXdS213kNrY4BOq6PPTpz48Vy79tO9' +
    'p7VTyIG2SkXQQbUGOi1PtpQMw9FhefSJdsp10E6uCtquKfhkk133aefXtleogg4qNdBFrpgaOu3sdMkwHAMW3FnXW1kA3dZ8gJ6r' +
    'K2GGXNIfNj0OX/DMcugqPgxb9QEGLSqs6T3yy/uQgoPhRyur3OY808RWPKvIDtbWrzrxDGM72dk97cyzSehip/e863rTxG7rDGK6' +
    '4z7PNLHbZoOk7hvMkntsXpfUnacb18PKKL7nZqP4nhv1o3ptMIvrsV7rSbfNBjHdN+jG9eCZPunGo4+TuuM53Mdr8Jg+rxbTfRcd' +
    '9+Ou6LjwdBxqMd1xyzN+1AX98Ho8h46OG/3YcJzD413sdrPa/e485bge6Ohr2C0dp9aTbnbKj7vy1Jm4cd9O/mlndDbqj7ps0njS' +
    'kScf2WGTRlJHa5XYTlbykR14epEdNqk+b79BN6I1zzC2haNFatM/+2ggfB2NbNmRJru/D1oxAfzACwv7ydAt9mcUuBYhIU0tQlKb' +
    'anmFNZMPimyOW26fc6xwFjldj+TWqzySW6v7JLTE41UeEfT+CrfYFhgeFR8e0/5OYcx1GAe7r3spuTXGgedM2Thxq+sR0VrNN6oN' +
    '56fuU9ASt5gWnkNnSsfD5IGOD+Ngz6HD6zG8+HXob+iW34JxsS0wX7hFh3lm9vNbyB/Kbb7EMbWpoRv8LM0L+4lpqvs8Bg1SGthh' +
    '0YW7HXWLoaOhEFrr1kMrXYA2+kBvW+pQ0EKXD23lUoq7rww3xGchGUf7mV4z2qqUQFvNOuikA9B5WaqtZBiOditiT7XXBGinDNBG' +
    'viR/pqpLo1F2I6T3d+u45HlRWw2AjroAXZe/CqdrbHStOfhHvDd00tLMoI3Rozf26rEio7K7KkBXRYBBMq9jpaXDfnde0tAFCTaD' +
    '5ACGyAEMWlwMPYf7DZYM8zngjx8Hjri5xf7M42U1s7KKbI7ukFVkcxS86A6h0uLFtjhgk9DSxiah5QGbgpaoxHAftxs2JLfm8RJb' +
    '4T6GQUcrOUPmGvo6dXZrk9DSzTC/xQE8Zs9h3FxaXHjmfD5znhfbgkmXiVcUP6aNCoLdd0I/9YYw+9BPLaqNeFhRuqzj0qXditgW' +
    'VvKRzb20sprxtMKaodIRbXmJv6DBWjfD2J8VFOBHnhTvB/idZmTCXwPfSbIe0neD/hqgBRUeMYKSOaYVGAouVGKsAGOEWdhP0mFh' +
    'P+E+OvzSFYXBLb3PXMuFwXP0PjY/BQPrGMGI+7QCoMNI+jUIT8lrGoVh06fPAxdHg+PiEL8XxrH3yIMfxMvh82HLT0pKymqqVPP2' +
    '048bd1gVfqP1ygdFrVfHvW+94ml9y+VPK1uviXvZcumDPV2H7PzdvpaWU46OabnwVmqbZU9edViZkNFlYdjvzgvqMP+aVfslsRnt' +
    'F8emdVwec3XiisYWv/vO9l7WYV54bpuF0Tlt5sfk95x97RM1noYmQKTHrHO7O82JyO4071FGt3mPn09Ycvd3az1DpO+o91/4PGnw' +
    '4pfPhknHRkyY4PsXLTNAExSwIsd8pdL9d3jc+Jl97PAdBIlz3HV4vlF8uC92ng4v9XGczPXM+yG6XixcsAL8GKyA72DDO9TgF0z7' +
    '4fsuHpZzTDgenS6TB2Yft1xa4o57TkQJ/TOIFBI21+EB9yMnEP4X6d9lVNeh83eMHrb4yLThs7cMlu8l1VwyjCQojEZ0lmqFbtAg' +
    'qTbS0lK/21LAk5L6YaiUVOvOUlKtFKSkPrLWPWIE7xf0nygl1XaQVIc2GP5TtTJxsAbVR0qq/QgpqVZTe/Vqzkzu/TTS0tI/yUtJ' +
    'NbcYJNU01lDqo+ZHAuF/FfYjgHn3ybBvwv8y+OX7u4MgvuNHFvflLnm+gd/L2++dJxD+nTRSSLhAHxnUQPifBZtfuGZLtnmQaf78' +
    'I2UgDtdcyjQZSfo24g8VHOtHLwz4memL8snF+0fxEwj/TliFhL9b0cTYT39hEggEAoHwN4J6iAxqIBAIBMJ3p5FCwvWQyIqxBAKB' +
    'QPheiHRQKkWRQQ0EAoFA+G6QGhKBQCAQ/i/QJAy4GhKx1EAgEAiE7wQ7yq5BIZFh3wQCgUD4Xoh0UBYAsfZNIBAIhO+GqNuILD9B' +
    'IBAIhO9JowX6iEIi/FN8rs3Ezw33OdCzwP8F4FpGkuf+1/iUfT/JZ91g4JTwX0FyCXMyMfZfCvfDLiqtnPkqO+83AOgnGYaDoqih' +
    'GTl59tFx8S5ZOa83UxQ1XNw/q6ysXeHbd9av8/O3pWVkbUvPzNyakZVlU1BQ1YULg+/S6zeFRgCwjaKoCXiusrJ2WEpK+p6M7Fw1' +
    'LhxOyC6tqLJ8/77Kobq6mldTW/tbdnbe1tf5RdtLSkp6/ZFAwnxk5b6xyczM/C0zO3drYtIrXuHbt3vLyqrp9JCKav6yJzEvtr9+' +
    'XTKVO1cnoHRiEpK2JiVliyxlF5e/n1RSWr41Jy/P/nV+/qbS8vJNb96+W8b5c1AU1b+susb28pUrR2PinjlQFLUUAEQWv0sqa0dU' +
    'vOdvKy6tUkcFiPkvK6uVfZ1fYpeXl9eRC1deVaP04UPd3sK3JVvflpRuzX+dv+3Nm6IjWbkla7gwz54lj46JebY9O/uNBneOg6Ko' +
    '1ulZOSaXLl11ffI4zgEAFkiGKS//MCgzM++32lpqRcO5qgW1tQL7N5WVnRuHFodRBHl5b7QyM7O3JKekb3nxImV7WkqW3bt373pz' +
    'oQooqmV2foFFfkGJHpoeaxxHAxRFSd+5c2//zZt33T58qMd3gi0vaJKbW94hJeWNEUVRUzDN/Pz8FiUl1VvLy+uU2MubVFZSI7Ky' +
    'Cu1TUl4vF4+X8O8Cn7+ohkSGff+7Yb82f3b19EnUNLSAC9dvhkqGQVB4nPTwKLLeuBF27zsEDvuOgI9/cGV6es5EsTBLfP0CQEtH' +
    'DzZv2wFWG2zB2/cM1NfXTxYL09nD26/KyHwdPIlLeEVRVN/CwpIFRqaW4O3rL1puvIqiupzw8oNde/aBrd0mMDA2hQ229uDi6gGl' +
    'pZWzuXCfgqKoWWcvXAI9Q2PYuMkOjE1NwT8gEOrqBPpcmJSsPG0NHUPgbd9dgoqRoig1b19/2L334JuMjMKuXLi0rNzTG+22wK7d' +
    'e2Dbjl2wyX4rBJ+7HCWuECmKGuN43CXPfstWsNtsD5ZWG4C3Yz/Exiet48JUVL23POLkDnfDI3M4Ie152j/B5aQv1NdTovsJfxQb' +
    'eso7CLZt3wNycipgZm4Jh464wsULt66J4qqo2m1r+xuccD+dg79P7jwqxWPHT8Rq6RjAb7ydYGe3FbZu3Qa5ubk+4rVAgUCgZ2Oz' +
    'GfYfOPIBAMbhuRs3Qq/4B1yETykwcSiKan7p4vW3JsZrYcuW7bDZbht4nvKFDx8+zBULM3fv/qNw7Lgb4EdM4xjod+6nhKfPT1pb' +
    '24KZqSXY22+DTbZb4F74g4cURbXBMFVVVJdzZ6/ynY65x7FxrvT0DAQf76ACAKBX401JyfQ8deocREc92yCZBuHfg0gh0TUkMjH2' +
    'X09sfKK26ykfOO0XJNyyYw9U19aKvpwRAOjmsHdf3jora8jIyEioqq31vnv/0dZL129EJ7xIXiwWTuaY8wlUAlTJu3dvnyelRKSk' +
    'ZYa8fvtWtFgcxrXvqFOeupYBmFnYQEpKRhhFURqr1iiBxymf62Lhfjzq7mN+7/6jw75+fuWrZBUhOTXtfsTjJ66pOTm/uy4QQlHU' +
    'PKcTruCw/6AwMzMzN/5ZfEpycmpCWVXVPPFwl69fv6ytow81tXUZYQ8eVqy1Wi+Ijo5bKR7mRVKqq9V6W0hIeF6XmZXzJjYuLi81' +
    'LSOAM46K+TztG3hXQ8cInj17/pSiqMvPn788ffZCSE5icrohF09ZRdU6RWUtuHz9djYAtMXf1DFn96frbOxRaC/kwsXEv5oR/yz5' +
    'kH/A2Vh1bUMqMSk5Oj7+xbGkFymaXBiKonZZWduBl0/AawBoxZ5reeHCtQemZjYQH/+sgKKooJqamlMWllb8Des3QU1NnaLY9fqb' +
    't2yDWdLzIPJxNCq1cb5+Qec3bOJhXhrdvySYztlzl3P2OBzgF78teVhU9PZ2Vk6ub35+8TCxMEu0dU1gg+1vQoqiRuE5cQVeXVOj' +
    'tX27Azg6noCamtq7FEU5e7h7pigpa0BW1uvjXNiNG3YcMza0xjzNuBsW5WxiYgNhdyKgquID1q4HBgVeLrPfurfmj2r1hP998H3A' +
    'FhP6IJGuIRGF9G+FoqiOx4655J7xDwK+gCrwDQgSRDyOCRcXIACgoKisCrdv362kKIpXUPB2BUVRXQGgk/iXN0VRsq7u7mBpbcOv' +
    'rq7Offuu1LOguLSRgMMa0r6Dx7IuXrpafflqCF967nzIzy94vcFuC1y4FHJRPCyCgvvsuXPptpu3oGDSkvT/FFibs7PfAr9t3Q6l' +
    'ZWXJCQkJ4a+zcw5mZGSIaj5suJ4hN0Pve/n4wzrrjZCWluOI58Xv/XXem32WVuvh0eMoQc7r1zlvikoC84qKREuPUxTVfceuPZVu' +
    'Ht6oBDaXlFZovn///lcAGIA1Ty6u2vr6tWqaenDxWkgeRVG98NzBQ04hGzf9hvclajbkOOnpu4+3Yy/6HZL0A6Fwm+2mLXDp8tUU' +
    'AKBXkcVanvV6W/A9EyCgKOpsVdX7XRRFbc97/SbdxsYWcrLzPbnrKYpah+V5wtUddPSMIT0j59GrlPRHh44cx/REzaafAtNzdHRJ' +
    '22S7uebRo0fP7oc9ePD8ebJzaWmpaMl2VLDrrO3A3n57rWSzLhIXl+BsYGgCVdU1WBb737//gHkNtLJeD4FB57DGSjdhYo1v/4Ej' +
    'pQ8eRCa4epx+o6dj9P5u6D3q5vVbiRRFnbDduBXO+AZ/skZP+PfAtuL8RO8wo+xIk92/lbclb3V19A0g8tETPkVRlZeuXAP7rduw' +
    '6Ua8KW6phrY2HD12vJ6iKFeKouQpitpXWl5uum+fR2uxcHIuJ1xB38CAH/E48sPzxMQU/JrPzc0VLYaHNaQDh50Kjx5ziaEoyt9m' +
    'gy0cdzkpOHzUGa5eu/EphdTt3LlzuXZbt6Gw1JH0/xTYZLSVx4MjR47B8xeJFTFRMa9KSkr3FhcXi/KKYHNXzuvXEUtXroG585dD' +
    'bu6bq9gHIx7mdX6BMzb9BZ87D9dv3ip7/6Eem7/Ey6bl3r0Hszds2lJBUZQvRVHY7zFfUsnU1tdba2obwsUr119TFDWboqjBfoFn' +
    's2w2bv2kQnI96bFr+849IKSo45J+fD5/2/qNm+Hy5evJXPMfRVEj7bf8Bnv3HcD4HlEUdYyiKI+3xcUF66w3QFHRu6Pc9RRFmVrb' +
    'bITw8EdPjhx1TNHVN4ZnCYmVe/YcxGs/6pcSB9M7dsw5VXr2XDh58iTfw8Pr7fUbd89iU55YmCWbNm+D7dsdsElQVHPiyM3Nc9TR' +
    'NYKMzEys3ZzGd4SiqAcWFpbgdtITlRTdbIecdD8dHRh4Fg4cOgInT3qFP4mOebN37wF+9JNYodW69SCgBOaNYyf8G6GNM9BNdmip' +
    'gfQh/SvBL3g3D8/HuvqmkJ9fGBMYGOy4bceunK28HXDv/kNfrvZDUVTvO/fCCzS19eDc+Uv8lNS0nOvXQ8DD8zRk5eaqcvFRFKV4' +
    '8PAh0NHTg3elpfU+Z/zA1dUNqqpqxMN0P3TUqcTHPwAFs01ZRUXArj0HYNGSVRAZFX2TCycWvmtAYGDhuvWbUFgaS/p/Cmyy27Nn' +
    'H6yzXg/xCfF15y+cp+7evUdVVFQ1WoK8sLj4+Nbtu+Dc5SspDg4HyszXWsPbkpK94mFy8gr85JXUIPTePRSg/JOe3nDr7v174s3Y' +
    'SUmpB9dabQS7LdsrY2LjMz19Al4HBJ8HPp8v6mznU/xlx51Pgt0WHpSXlydnZGYnY7PlyVM+WIv4aBl1T09vx9+27QK+kHKV9BMK' +
    'hduw1nb2/IU0roaE+bkXdt9PT98Q/P0DhIkvkzKysrJzNmywhf0HD1HiSo+iKMvNW7eDf+D58xRFrXF1PQXq6lpw9Ai2loF2o8Qk' +
    'wPS8Tvu82Wy/9S1FUSoURU3HJkjxMBRFLbNZbwdW6zZC8svkyMePn4RmZubuwfeNjWPBSXdPvpKSKoSHP6h89vxlWmDQuSorK2uI' +
    'f/Zii3hcMXEJu69dvwU6uoYQFf3U7u3bEl/7LdtAS8sAnJ3dCrHpTjw84d+JSCGR5Sf+vVTW1Eifv3wVAs9eyqUoaoSUlNTPFRUV' +
    'U6/dCn3t5etH5RW8FfUloZB/9DjmpZHpOtixay9stNsMV0Nu4Rd6Xy4Mn6JWB5+/QBkYmwn2HzosNDQ1E9jabYHs3LytYvF0Cb5w' +
    'qdTv7Hkc0DAbBdy1GzeDd+/ZSyWlpJ3jwomF73r56rU3R48fxxqcsqT/p6ivr595+er1eiMT09odu3bXWVpa1WPNITEpiW6SQw4d' +
    'P7Hm2s3bH3wCgv1RIZSXV+3b8tv2uitXb9YWFleu5sJlvX7jse/AYcr1pLtwp8MeSs/QBHwDAkvev39PN7shWEuKiHpyBZXmRrvf' +
    'wNB0LRw7fqKcz+ev4sLgbygpJdXHfK0V7NjhADt3OYDDvoPlH+rqdLkw4ly6fsPNLyCIqqnjH5b0qxcI1p9wdeffvhv2nFNICEVR' +
    'HZ4nJnr/xttJ7di5G3bscoDjTidKKyoqRP1PSE1N7daz5y/D7bvhtLL78OGD4eatvFpv30Ds8xHl+VNgDelBxONMN3fveE7BSII1' +
    'ak8vH8rAwAQcdh+AgweOwK1b9wqKioro/i6krk6gddLN852xqSVstN0MDnsPUk+exDlJDsHHASMnPbxqrK03lVMUNQhrgg4O+7Ot' +
    'rDfz42Ke2YqHJfx7aTQPidSQ/p3kFBf3wP4W7O8QP499HBRFTSspaRC6CA7LpShqkYCicDjvKm60EwcO98XmLIqixuMXOTt67deq' +
    'qkbDvptQFDWpuLJ2GK7gyp5rhWFLSkp6SvRdYdimtRQ1BJt+UPBzfn9EQUJBS1SwKLwwXuy0xy/5kpJKVLo0ReXlA1HYcUONUWFg' +
    '+Pr6+ll5xcX0yDBMv7S0pg97T3g/81glOlO8GVLseulagcASB3dgUyMXh/g9URQ1+VliinZVTY36H33do6LHvGcVFdHxiJNTXt4e' +
    'R699YPqpPhr+zpa7KjahcvkQJzMzE+OeKl6zYe9x7J8NYMJ5QgDQp6jowyBJ5cFRUkK1Yd+B6TggAUc98vnUvNhYUQ2JzjPeP0VR' +
    'y/Gd4gY/fIImuUVFqIhEA2OwH/JTo/cI/15E9lTJPKT/Fp8ScJ8696X8XhyS5yWP/wl+T7B+i7x8VhzfcaLn7937/1W+VzkRvi+i' +
    'GhI22ZEa0n8HyRqK5LnPRbJmII7keW6i6Kdm6XNIXvM5fM01knyqPH4H9OPcN+NP0vwkX3DN54b7Iuj0PyMPf/SOfMTnhiP868B3' +
    'RFRDYoeukhoSgUAgEL4LdKWI/YIhgxoIBAKB8N0Q9W2yCok02REIBALhuyCqFJFBDQQCgUD4njRSSGRQA4FAIBC+F6SGRCAQCITv' +
    'DzOW4UcyqOE/RvyzZ9qHDx703bljx5W7d+9aSJq0wYmp0bGx6wKDA3d7e3sf9vH1OZiUlKTMzWWRHMKLRllv3brhcv3KlcvJySlr' +
    'KYrqIebXNiY+bkdCYuJuboJtRW3t0IKCgh2vCwvHcOFwdn9hYf666zdubL9x4/qu82fPbn+ekLC3vLxcNKkUJ/a+e/dOP/Ru6O1r' +
    'IdecCoqL55SUlND20MIfPlx69vzZfefPnt924dyFHd5eXjuvXr7qWFRUtIi7vqCgYM7tO7f3+Pr5Hgg6G3SosLDQWNymHTc8GV1J' +
    'WZlOcnLy3qysrEZGQ3PLczsEnwu2OXPmzI5rN0N2nL9w4aCPr+/B6Oine3GiKIapqqrq+jIlbXtmdqYGV1bcFs0zRUdHme3d63Dq' +
    '4sVLLuzE40blWVpaOpaiqC1osoezkpCTk7Ma81NUVDpTPOynQHtzaDz1ytWrbvfC7gUlJiZiPLT1hMrKyk6Z2dm/3bt3z4Z77jg5' +
    'NykpcXdOXp7IZBPKg/LycmP/wECv8Hv3TvD5H+ZlZZXRzy+hoKDlzdCbS9zd3TZeuxay6UHkA55/4JndV65c2VuUXySyCl9ZWTv8' +
    '1atU29DQ0K0RDyJ4N27c2Bvz9KkNfvxyYXJzc3+trK7mcctjsOX/Q3Hxu/VR0XEiK+qEfz/0sG9ulB0aVw0jxlX/1aBlBk8vr1s2' +
    'G20hwD8A/M6cgXXWNuAXEPTuwwe++PIS/YLOnoMdu3fDiRMn4ITrCbC2toGgoLM3AKC9WLifMzIzTuBaRKamxrB5sx1YrLOC8IiI' +
    'DE75oLWDbTt3grvnKbRRR1tQyMzJVLp15y5kZ+daiMU159atm7B6zRqw22wH+np64OdHr7FEryGEacXFxUXY2m4EB4fdYGBkCAFn' +
    'z9WghQj0vx0a+uSI41GwslkPauoaoKWpAY6Ox+DduzLRGjopKSk+e/ftBT9/Pzh2zBF+27YdHj58+KysrIxe1kBMeQwLPncOZOUV' +
    'oaCw0Ie7HqmpqVH1D/ADc4t1oKGlA4bGhmBqZgZXr11Hczy0IkaLBIccj4FfYGC+xDpG0719fF4bG5rAjh07wHr9Btiz9wC8eVMY' +
    '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' +
    'SP8PrkrXbspToTQAAAAASUVORK5CYII=' +
    '" />' + sLineBreak +
    '  <h1 class="ds-title">What are we building today?</h1>' + sLineBreak +
    '  <p class="ds-sub">Aefos is ready. Pick a shortcut or just start typing.</p>' + sLineBreak +
    '  <div class="ds-grid">' + sLineBreak +
    '    <button class="ds-card" data-action="explain"><span class="ds-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0' +
    ' 1 1 3.5 2.3c-.8.4-1 .9-1 1.7"/><path d="M12 17h.01"/></svg></span><h4>Explain</h4></button>' + sLineBreak +
    '    <button class="ds-card" data-action="refactor"><span class="ds-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7h11"/><path d="M14 4l3 3-3 3"/><path d="M2' +
    '1 17H10"/><path d="M10 14l-3 3 3 3"/></svg></span><h4>Refactor</h4></button>' + sLineBreak +
    '    <button class="ds-card" data-action="test"><span class="ds-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3h6"/><path d="M10 3v6l-5 8a2 2 0 0 0 1.7 3h10.' +
    '6a2 2 0 0 0 1.7-3l-5-8V3"/></svg></span><h4>Test</h4></button>' + sLineBreak +
    '    <button class="ds-card" data-action="docs"><span class="ds-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5"/><path d="M' +
    '9 13h7"/><path d="M9 17h5"/></svg></span><h4>Document</h4></button>' + sLineBreak +
    '    <button class="ds-card" data-action="find"><span class="ds-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></' +
    'svg></span><h4>Find</h4></button>' + sLineBreak +
    '    <button class="ds-card" data-action="optimize"><span class="ds-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z"/></svg></span>' +
    '<h4>Optimize</h4></button>' + sLineBreak +
    '  </div>' + sLineBreak +
    '  <div class="ds-foot"><span class="ds-dot"></span> Connected ' + #$00B7 + ' ready</div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<div id="ds-feed"></div>' + sLineBreak +
    '<div id="ds-typing" class="ds-typing" style="display:none">' +
    '<span class="ds-gear"><svg viewBox="0 0 24 24" width="17" height="17" fill="none" ' +
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
    '<rect x="4.5" y="8" width="15" height="11" rx="2.5"/><path d="M12 8V4.5"/>' +
    '<circle cx="12" cy="3" r="1"/><path d="M9.5 13v1.4"/><path d="M14.5 13v1.4"/>' +
    '<path d="M2.5 12.5v2.5"/><path d="M21.5 12.5v2.5"/></svg></span>' +
    '<span>Thinking&hellip;</span></div>' + sLineBreak +
    (* Send-during-run queue counter (window.dsQueued); hidden when 0 queued. *)
    '<div id="ds-queued" style="display:none"></div>' + sLineBreak +
    '<footer id="ds-footer">Aefos &#8212; ready.</footer>' + sLineBreak +
    '<div id="ds-composer">' + sLineBreak +
    '  <div id="ds-pick" style="display:none"></div>' + sLineBreak +
    '  <div id="ds-attachbar"></div>' + sLineBreak +
    '  <div class="ds-inbar">' + sLineBreak +
    '    <textarea id="ds-input" rows="1" placeholder="Message Aefos&hellip;"></textarea>' + sLineBreak +
    '    <button class="ds-send-btn" id="ds-send" type="button" title="Send">' +
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" ' +
    'stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5"/>' +
    '<path d="m5 12 7-7 7 7"/></svg></button>' + sLineBreak +
    '  </div>' + sLineBreak +
    (* action bar below the prompt: attach / memory / MCP + the model selector *)
    '  <div class="ds-actbar">' + sLineBreak +
    '    <button class="ds-attach-btn" id="ds-attach-open" type="button" title="Attach">' +
    '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" ' +
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66' +
    'l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg></button>' + sLineBreak +
    '    <button class="ds-mem-btn" id="ds-mem-open" type="button" title="Memory">' +
    '🧠</button>' + sLineBreak +
    '    <button class="ds-mem-btn" id="ds-mcp-open" type="button" title="MCP Servers">' +
    '🔌</button>' + sLineBreak +
    '    <span class="ds-act-sp"></span>' + sLineBreak +
    (* reasoning-effort selector: hidden until the active executor supports it *)
    '    <div class="ds-hd-effort" id="ds-hd-effort-wrap" style="display:none">' +
    '<button class="ds-hd-mbtn" id="ds-hd-effort" type="button" title="Reasoning effort">' +
    '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" ' +
    'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M12 14a4 4 0 1 0-4-4"/><path d="M12 14v4"/><path d="M5 20h14"/></svg>' +
    '<span id="ds-hd-effort-name">Effort</span> ' + #$25BE +
    '</button><div class="ds-hd-mlist ds-hd-mup" id="ds-hd-elist" style="display:none"></div></div>' + sLineBreak +
    '    <div class="ds-hd-model"><button class="ds-hd-mbtn" id="ds-hd-model" ' +
    'type="button" title="Model">' +
    '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" ' +
    'stroke-width="1.8" stroke-linecap="round"><rect x="7" y="7" width="10" height="10" rx="2"/>' +
    '<path d="M10 3v2M14 3v2M10 19v2M14 19v2M3 10h2M3 14h2M19 10h2M19 14h2"/></svg>' +
    '<span id="ds-hd-model-name">model</span> ' + #$25BE +
    '</button><div class="ds-hd-mlist ds-hd-mup" id="ds-hd-mlist" style="display:none"></div></div>' + sLineBreak +
    '  </div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var buffer = "";' + sLineBreak +
    '  var pending = null;' + sLineBreak +
    '  var chunkCount = 0;' + sLineBreak +
    '  var DEBOUNCE_MS = 100;' + sLineBreak +
    '  var HARD_FLUSH_EVERY = 16;' + sLineBreak +
    '  var current = null;' + sLineBreak +
    // A broken shell runtime (e.g. the embedded marked bundle failed to load
    // from a truncated shell file) must be REPORTED, never swallowed: it once
    // ate every assistant response with the footer stuck on "ready". One post
    // per page — the host reloads the shell once on 'shell-error:*'.
    '  var shellErrorSent = false;' + sLineBreak +
    '  function dsShellError(msg){' + sLineBreak +
    '    if(shellErrorSent) return;' + sLineBreak +
    '    shellErrorSent = true;' + sLineBreak +
    '    try{ if(window.chrome && window.chrome.webview) ' +
    'window.chrome.webview.postMessage("shell-error:" + msg); }catch(e){}' + sLineBreak +
    '  }' + sLineBreak +
    '  window.addEventListener("error", function(ev){ ' +
    'dsShellError("js: " + (ev && ev.message ? ev.message : "unknown")); });' + sLineBreak +
    '  if(!(window.marked && window.marked.parse)){ dsShellError("marked-missing"); }' + sLineBreak +
    '  function dsHideEmpty(){' + sLineBreak +
    '    var e = document.getElementById("ds-empty");' + sLineBreak +
    '    if(e){ e.style.display = "none"; }' + sLineBreak +
    '    var nb = document.getElementById("ds-hd-new");' + sLineBreak +
    '    if(nb){ nb.classList.remove("ds-hd-accent"); }' + sLineBreak +
    '  }' + sLineBreak +
    '  function flush(){' + sLineBreak +
    '    pending = null;' + sLineBreak +
    '    chunkCount = 0;' + sLineBreak +
    '    if(!current) return;' + sLineBreak +
    // marked.parse MUST NOT be the single point of failure: when the bundle is
    // broken the response still renders (plain text) and the failure is posted
    // to the host. A silent throw here blanked every assistant bubble AND — via
    // dsFooter's inline flush() — froze the footer on "Aefos — ready".
    '    try{' + sLineBreak +
    '      current.innerHTML = window.marked.parse(buffer);' + sLineBreak +
    '    }catch(e){' + sLineBreak +
    '      current.textContent = buffer;' + sLineBreak +
    '      dsShellError("marked: " + e);' + sLineBreak +
    '    }' + sLineBreak +
    '    try{ if(window.hljs && window.hljs.highlightAll) window.hljs.highlightAll(); }catch(e){}' + sLineBreak +
    '    requestAnimationFrame(function(){ ' +
    'window.scrollTo(0, document.body.scrollHeight); });' + sLineBreak +
    '  }' + sLineBreak +
    '  window.dsAppend = function(text){' + sLineBreak +
    '    dsHideEmpty();' + sLineBreak +
    '    if(!current){' + sLineBreak +
    '      var f = document.getElementById("ds-feed");' + sLineBreak +
    '      if(f){ current = document.createElement("div"); current.className = "ds-msg"; f.appendChild(current); }' + sLineBreak +
    '    }' + sLineBreak +
    '    buffer += text;' + sLineBreak +
    '    chunkCount++;' + sLineBreak +
    '    if(chunkCount >= HARD_FLUSH_EVERY){' + sLineBreak +
    '      if(pending){ clearTimeout(pending); }' + sLineBreak +
    '      flush();' + sLineBreak +
    '      return;' + sLineBreak +
    '    }' + sLineBreak +
    '    if(pending){ clearTimeout(pending); }' + sLineBreak +
    '    pending = setTimeout(flush, DEBOUNCE_MS);' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsClear = function(){' + sLineBreak +
    // Dismiss the Welcome screen the moment a turn BEGINS (not on the first
    // response chunk via dsAppend) so Ctrl+Alt+F10 shows the pulsing brain
    // immediately instead of leaving the dev staring at the Welcome page.
    '    dsHideEmpty();' + sLineBreak +
    '    buffer = "";' + sLineBreak +
    '    chunkCount = 0;' + sLineBreak +
    '    current = null;' + sLineBreak +
    '    if(pending){ clearTimeout(pending); pending = null; }' + sLineBreak +
    '    var footer = document.getElementById("ds-footer");' + sLineBreak +
    '    if(footer){ footer.className = ""; footer.textContent = "Aefos \u2014 working..."; }' + sLineBreak +
    '    var typing = document.getElementById("ds-typing");' + sLineBreak +
    '    if(typing) typing.style.display = "";' + sLineBreak +
    // Turn started -> the composer Send button becomes a Stop button.
    '    if(window.dsSetBusy) window.dsSetBusy(true);' + sLineBreak +
    '    requestAnimationFrame(function(){ ' +
    'window.scrollTo(0, document.body.scrollHeight); });' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsFooter = function(text, isError){' + sLineBreak +
    // The footer update must survive a throwing flush — a stuck footer reads
    // as "the model never answered" (proven live 2026-07-06).
    '    if(pending){ clearTimeout(pending); try{ flush(); }catch(e){} }' + sLineBreak +
    '    var typing = document.getElementById("ds-typing");' + sLineBreak +
    '    if(typing) typing.style.display = "none";' + sLineBreak +
    '    var footer = document.getElementById("ds-footer");' + sLineBreak +
    '    if(!footer) return;' + sLineBreak +
    '    footer.textContent = text;' + sLineBreak +
    '    footer.className = isError ? "error" : "";' + sLineBreak +
    // Turn finished (or errored) -> restore the Send button.
    '    if(window.dsSetBusy) window.dsSetBusy(false);' + sLineBreak +
    '    requestAnimationFrame(function(){ ' +
    'window.scrollTo(0, document.body.scrollHeight); });' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsUser = function(text){' + sLineBreak +
    '    dsHideEmpty();' + sLineBreak +
    '    var feed = document.getElementById("ds-feed");' + sLineBreak +
    '    if(!feed) return;' + sLineBreak +
    '    var div = document.createElement("div");' + sLineBreak +
    '    div.className = "ds-user";' + sLineBreak +
    '    div.textContent = text;' + sLineBreak +
    '    feed.appendChild(div);' + sLineBreak +
    '    requestAnimationFrame(function(){ ' +
    'window.scrollTo(0, document.body.scrollHeight); });' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsReplay = function(items){' + sLineBreak +
    '    dsHideEmpty();' + sLineBreak +
    '    var feed = document.getElementById("ds-feed");' + sLineBreak +
    '    if(!feed) return;' + sLineBreak +
    '    feed.innerHTML = "";' + sLineBreak +
    '    for(var i=0;i<items.length;i++){' + sLineBreak +
    '      var it = items[i];' + sLineBreak +
    '      var el = document.createElement("div");' + sLineBreak +
    '      if(it.role === "user"){ el.className = "ds-user"; el.textContent = it.text; }' + sLineBreak +
    '      else { el.className = "ds-msg"; ' +
    'try{ el.innerHTML = window.marked.parse(it.text); }' +
    'catch(e){ el.textContent = it.text; dsShellError("marked: " + e); } }' + sLineBreak +
    '      feed.appendChild(el);' + sLineBreak +
    '    }' + sLineBreak +
    '    try{ if(window.hljs && window.hljs.highlightAll) window.hljs.highlightAll(); }catch(e){}' + sLineBreak +
    '    current = null;' + sLineBreak +
    '    requestAnimationFrame(function(){ ' +
    'window.scrollTo(0, document.body.scrollHeight); });' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsResetThread = function(){' + sLineBreak +
    '    var feed = document.getElementById("ds-feed");' + sLineBreak +
    '    if(feed){ feed.innerHTML = ""; }' + sLineBreak +
    '    current = null;' + sLineBreak +
    '    var empty = document.getElementById("ds-empty");' + sLineBreak +
    '    if(empty){ empty.style.display = ""; }' + sLineBreak +
    '    var nb = document.getElementById("ds-hd-new");' + sLineBreak +
    '    if(nb){ nb.classList.add("ds-hd-accent"); }' + sLineBreak +
    '    var footer = document.getElementById("ds-footer");' + sLineBreak +
    '    if(footer){ footer.textContent = "Aefos — ready."; footer.className = ""; }' + sLineBreak +
    '    var typing = document.getElementById("ds-typing");' + sLineBreak +
    '    if(typing) typing.style.display = "none";' + sLineBreak +
    '  };' + sLineBreak +
    '  var _cards = document.querySelectorAll("#ds-empty .ds-card");' + sLineBreak +
    '  for(var _i=0; _i<_cards.length; _i++){' + sLineBreak +
    '    (function(c){' + sLineBreak +
    '      c.addEventListener("click", function(){' + sLineBreak +
    '        try{' + sLineBreak +
    '          if(window.chrome && window.chrome.webview){' + sLineBreak +
    '            window.chrome.webview.postMessage("action:" + c.getAttribute("data-action"));' + sLineBreak +
    '          }' + sLineBreak +
    '        }catch(e){}' + sLineBreak +
    '      });' + sLineBreak +
    '    })(_cards[_i]);' + sLineBreak +
    '  }' + sLineBreak +
    '  var _input = document.getElementById("ds-input");' + sLineBreak +
    '  var _send = document.getElementById("ds-send");' + sLineBreak +
    '  var _pick = document.getElementById("ds-pick");' + sLineBreak +
    (* --- Slash-command picker --------------------------------------- *)
    (* v1: static list. TODO(follow-up): populate from Pascal via        *)
    (* window.dsSetCommands(list), filling DS_COMMANDS dynamically from   *)
    (* the plugin's commands / built-ins catalog.                        *)
    '  var DS_COMMANDS = [' + sLineBreak +
    '    { name: "new",     desc: "New empty session",     badge: "builtin" },' + sLineBreak +
    '    { name: "reset",   desc: "Reset the conversation", badge: "builtin" },' + sLineBreak +
    '    { name: "memory",  desc: "Edit the memory",        badge: "builtin" },' + sLineBreak +
    '    { name: "command", desc: "Create/edit a command",  badge: "builtin" },' + sLineBreak +
    '    { name: "new-project", desc: "Create a new Delphi project from a template", badge: "builtin" }' + sLineBreak +
    '  ];' + sLineBreak +
    (* Pascal feeds the full list (static built-ins + registered commands). *)
    '  window.dsSetCommands = function(list){ if(list && list.length){' +
    ' DS_COMMANDS = list; } };' + sLineBreak +
    '  var _pickItems = [];' + sLineBreak +    (* currently visible commands  *)
    '  var _pickIdx = -1;' + sLineBreak +     (* selected index              *)
    '  function dsPickVisible(){ return !!_pick && _pick.style.display !== "none"; }' + sLineBreak +
    '  function dsPickHide(){' + sLineBreak +
    '    if(_pick){ _pick.style.display = "none"; _pick.innerHTML = ""; }' + sLineBreak +
    '    _pickItems = []; _pickIdx = -1;' + sLineBreak +
    '  }' + sLineBreak +
    '  function dsPickHl(){' + sLineBreak +
    '    if(!_pick) return;' + sLineBreak +
    (* only the item rows - exclude the sticky COMMANDS header (children[0]) *)
    '    var rows = _pick.querySelectorAll(".ds-pick-item");' + sLineBreak +
    '    for(var i=0;i<rows.length;i++){' + sLineBreak +
    '      if(i === _pickIdx){' + sLineBreak +
    '        rows[i].className = "ds-pick-item ds-pick-sel";' + sLineBreak +
    '        if(rows[i].scrollIntoView){ rows[i].scrollIntoView({ block: "nearest" }); }' + sLineBreak +
    '      } else { rows[i].className = "ds-pick-item"; }' + sLineBreak +
    '    }' + sLineBreak +
    '  }' + sLineBreak +
    '  function dsPickChoose(cmd){' + sLineBreak +
    '    if(!_input || !cmd) return;' + sLineBreak +
    '    _input.value = "/" + cmd.name;' + sLineBreak +
    '    dsPickHide();' + sLineBreak +
    '    try{ _input.focus();' + sLineBreak +
    '      var n = _input.value.length;' + sLineBreak +
    '      if(_input.setSelectionRange){ _input.setSelectionRange(n, n); }' + sLineBreak +
    '    }catch(e){}' + sLineBreak +
    '  }' + sLineBreak +
    '  function dsPickRender(q){' + sLineBreak +
    '    if(!_pick) return;' + sLineBreak +
    '    _pickItems = DS_COMMANDS.filter(function(c){ return c.name.indexOf(q) === 0; });' + sLineBreak +
    '    if(_pickItems.length === 0){ dsPickHide(); return; }' + sLineBreak +
    '    _pick.innerHTML = "";' + sLineBreak +
    '    var ph = document.createElement("div"); ph.className = "ds-pick-ph";' + sLineBreak +
    '    ph.innerHTML = ''<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 17l5-5-5-5"/><path d="M12 19h8"/></svg><span>COMMANDS</span>'';' +
    sLineBreak +
    '    _pick.appendChild(ph);' + sLineBreak +
    '    var list = document.createElement("div"); list.className = "ds-pick-list";' +
    sLineBreak +
    '    _pick.appendChild(list);' + sLineBreak +
    '    for(var i=0;i<_pickItems.length;i++){' + sLineBreak +
    '      (function(c){' + sLineBreak +
    '        var row = document.createElement("div");' + sLineBreak +
    '        row.className = "ds-pick-item";' + sLineBreak +
    '        var ic = document.createElement("span"); ic.className = "ds-pick-ico";' +
    sLineBreak +
    '        ic.innerHTML = ''<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 17l5-5-5-5"/><path d="M12 19h8"/></svg>'';' +
    sLineBreak +
    '        var meta = document.createElement("div");' + sLineBreak +
    '        meta.className = "ds-pick-meta";' + sLineBreak +
    '        var nm = document.createElement("div");' + sLineBreak +
    '        nm.className = "ds-pick-name"; nm.textContent = "/" + c.name;' + sLineBreak +
    '        var ds = document.createElement("div");' + sLineBreak +
    '        ds.className = "ds-pick-desc"; ds.textContent = c.desc;' + sLineBreak +
    '        meta.appendChild(nm); meta.appendChild(ds);' + sLineBreak +
    '        var bd = document.createElement("span");' + sLineBreak +
    '        bd.className = "ds-pick-badge" + (c.badge === "command" ? " ds-pick-command" : "");' + sLineBreak +
    '        bd.textContent = c.badge;' + sLineBreak +
    '        row.appendChild(ic); row.appendChild(meta); row.appendChild(bd);' + sLineBreak +
    '        row.addEventListener("mousedown", function(ev){ ev.preventDefault(); });' + sLineBreak +
    '        row.addEventListener("click", function(){ dsPickChoose(c); });' + sLineBreak +
    '        list.appendChild(row);' + sLineBreak +
    '      })(_pickItems[i]);' + sLineBreak +
    '    }' + sLineBreak +
    '    var ft = document.createElement("div"); ft.className = "ds-pick-foot";' + sLineBreak +
    '    ft.innerHTML = ''<span><b>&#8593;&#8595;</b> navigate</span><span><b>Enter</b> run</span><span><b>Esc</b> close</span>'';' +
    sLineBreak +
    '    _pick.appendChild(ft);' + sLineBreak +
    '    _pickIdx = 0;' + sLineBreak +
    '    _pick.style.display = "";' + sLineBreak +
    '    list.scrollTop = 0;' + sLineBreak +
    '    dsPickHl();' + sLineBreak +
    '  }' + sLineBreak +
    '  function dsPickSync(){' + sLineBreak +
    '    if(!_input){ return; }' + sLineBreak +
    '    var v = _input.value;' + sLineBreak +
    (* show the picker only while typing the command: starts with / and has no space *)
    '    if(v.charAt(0) === "/" && v.indexOf(" ") === -1){' + sLineBreak +
    '      dsPickRender(v.slice(1).toLowerCase());' + sLineBreak +
    '    } else { dsPickHide(); }' + sLineBreak +
    '  }' + sLineBreak +
    '  function dsSubmit(){' + sLineBreak +
    '    if(!_input) return;' + sLineBreak +
    '    var t = _input.value.trim();' + sLineBreak +
    '    var atts = (window._dsAttachments && window._dsAttachments.length) ? window._dsAttachments : [];' + sLineBreak +
    // Enter ALWAYS posts a non-empty send, even while a run is in flight: the
    // HOST is the gate (its-own-guardian) — a real run queues the message and
    // auto-dispatches it when the turn completes; a STALE busy (lost completion
    // footer, proven live 2026-07-07) dispatches at once. The button click while
    // busy stays a Stop control. An EMPTY Enter while busy probes the host so a
    // stale busy still self-heals without sending anything.
    '    if(!t && atts.length === 0){' + sLineBreak +
    '      if(window._dsBusy){' + sLineBreak +
    '        try{ if(window.chrome && window.chrome.webview){' + sLineBreak +
    '          window.chrome.webview.postMessage("busycheck:"); } }catch(e){}' + sLineBreak +
    '      }' + sLineBreak +
    '      return;' + sLineBreak +
    '    }' + sLineBreak +
    '    if(atts.length){' + sLineBreak +
    '      var paths = atts.map(function(a){ return a.path; }).join("\n");' + sLineBreak +
    '      t = (t ? t + "\n\n" : "") + "[Attached files - read them]:\n" + paths;' + sLineBreak +
    '    }' + sLineBreak +
    '    dsPickHide();' + sLineBreak +
    '    try{ if(window.chrome && window.chrome.webview){' + sLineBreak +
    '      window.chrome.webview.postMessage("send:" + t); } }catch(e){}' + sLineBreak +
    '    _input.value = "";' + sLineBreak +
    '    _input.style.height = "auto";' + sLineBreak +
    '    if(window.dsClearAttachments){ window.dsClearAttachments(); }' + sLineBreak +
    '  }' + sLineBreak +
    (* Send <-> Stop toggle: while a run is in flight the up-arrow becomes a red
       stop square; clicking it posts "stop:" so Pascal cancels the run. *)
    '  var _sendArrow = _send ? _send.innerHTML : "";' + sLineBreak +
    '  var _stopIcon = ''<svg viewBox="0 0 24 24" fill="currentColor">'' +' + sLineBreak +
    '    ''<rect x="6" y="6" width="12" height="12" rx="2.5"/></svg>'';' + sLineBreak +
    (* Send-during-run queue counter: Pascal posts the live count on every
       queue/drain event; 0 hides the line. *)
    '  window.dsQueued = function(n){' + sLineBreak +
    '    var q = document.getElementById("ds-queued");' + sLineBreak +
    '    if(!q) return;' + sLineBreak +
    '    if(n > 0){' + sLineBreak +
    '      q.textContent = "\u23F3 " + n + " message" + (n > 1 ? "s" : "") + " queued";' + sLineBreak +
    '      q.style.display = "";' + sLineBreak +
    '    } else { q.style.display = "none"; }' + sLineBreak +
    '  };' + sLineBreak +
    '  window._dsBusy = false;' + sLineBreak +
    '  window.dsSetBusy = function(b){' + sLineBreak +
    '    window._dsBusy = !!b;' + sLineBreak +
    '    if(!_send) return;' + sLineBreak +
    '    if(b){ _send.title = "Stop"; _send.innerHTML = _stopIcon;' + sLineBreak +
    '      _send.style.background = "#c0392b"; }' + sLineBreak +
    '    else { _send.title = "Send"; _send.innerHTML = _sendArrow;' + sLineBreak +
    '      _send.style.background = ""; }' + sLineBreak +
    '  };' + sLineBreak +
    '  function dsStop(){' + sLineBreak +
    '    try{ if(window.chrome && window.chrome.webview){' + sLineBreak +
    '      window.chrome.webview.postMessage("stop:"); } }catch(e){}' + sLineBreak +
    // Optimistic: flip back to Send at once so the click feels responsive; the
    // real completion (dsFooter) also calls dsSetBusy(false).
    '    window.dsSetBusy(false);' + sLineBreak +
    '  }' + sLineBreak +
    '  if(_send){ _send.addEventListener("click", function(){' + sLineBreak +
    '    if(window._dsBusy){ dsStop(); } else { dsSubmit(); } }); }' + sLineBreak +
    '  if(_input){' + sLineBreak +
    '    _input.addEventListener("keydown", function(e){' + sLineBreak +
    '      if(dsPickVisible()){' + sLineBreak +
    '        if(e.key === "ArrowDown"){' + sLineBreak +
    '          e.preventDefault();' + sLineBreak +
    '          _pickIdx = (_pickIdx + 1) % _pickItems.length; dsPickHl(); return;' + sLineBreak +
    '        }' + sLineBreak +
    '        if(e.key === "ArrowUp"){' + sLineBreak +
    '          e.preventDefault();' + sLineBreak +
    '          _pickIdx = (_pickIdx - 1 + _pickItems.length) % _pickItems.length; dsPickHl(); return;' + sLineBreak +
    '        }' + sLineBreak +
    '        if(e.key === "Enter" && !e.shiftKey){' + sLineBreak +
    '          e.preventDefault();' + sLineBreak +
    '          dsPickChoose(_pickItems[_pickIdx]); return;' + sLineBreak +
    '        }' + sLineBreak +
    '        if(e.key === "Escape"){ e.preventDefault(); dsPickHide(); return; }' + sLineBreak +
    '      }' + sLineBreak +
    '      if(e.key === "Enter" && !e.shiftKey){ e.preventDefault(); dsSubmit(); }' + sLineBreak +
    '    });' + sLineBreak +
    '    _input.addEventListener("input", function(){' + sLineBreak +
    '      _input.style.height = "auto";' + sLineBreak +
    '      _input.style.height = (_input.scrollHeight < 120 ? _input.scrollHeight : 120) + "px";' + sLineBreak +
    '      dsPickSync();' + sLineBreak +
    '      if(window.dsSyncPad) window.dsSyncPad();' + sLineBreak +
    '    });' + sLineBreak +
    '    _input.addEventListener("blur", function(){' + sLineBreak +
    (* timeout: do not cut off the click/mousedown on a row *)
    '      setTimeout(dsPickHide, 120);' + sLineBreak +
    '    });' + sLineBreak +
    (* Docked-focus: when the composer gains focus, ask Pascal to give the WebView2
       host the Win32 keyboard focus via MoveFocus so Ctrl+V/typing do not leak to
       the code editor. Pascal guards against a focus loop. *)
    '    _input.addEventListener("focus", function(){' + sLineBreak +
    '      try{ if(window.chrome && window.chrome.webview){' + sLineBreak +
    '        window.chrome.webview.postMessage("composer:focus"); } }catch(e){}' + sLineBreak +
    '    });' + sLineBreak +
    '    setTimeout(function(){ try{ _input.focus(); }catch(e){} }, 60);' + sLineBreak +
    '  }' + sLineBreak +
    (* The feed never sits behind the composer: the body's padding-bottom tracks
       the REAL composer height (+margin). Re-syncs on load and when the input
       grows (multiline). Fixes the last lines hidden behind the input. *)
    '  window.dsSyncPad = function(){' + sLineBreak +
    '    var c = document.getElementById("ds-composer");' + sLineBreak +
    '    if(c){ document.body.style.paddingBottom = (c.offsetHeight + 28) + "px"; }' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsSyncPad();' + sLineBreak +
    '  window.addEventListener("resize", function(){ window.dsSyncPad(); });' + sLineBreak +
    // A link in an assistant message must never NAVIGATE this page. This page IS
    // the conversation: navigating it away replaces the whole chat with whatever
    // the href pointed at, and the transcript goes with it. Measured live - the
    // agent wrote `.project/analysis/project-overview.md`, the click resolved it
    // to file:///C:/%5CUsers%5C... (a Windows path is not a URL), the WebView
    // showed "can't reach this page", and only Alt+Left brought the chat back.
    // Nobody guesses Alt+Left.
    // So: cancel every anchor click and hand the href to the host, which knows
    // what a project-relative path means and where a real URL should open.
    '  document.addEventListener("click", function(e){' + sLineBreak +
    '    var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;' + sLineBreak +
    '    if(!a) return;' + sLineBreak +
    '    var h = a.getAttribute("href") || "";' + sLineBreak +
    // In-page anchors are the one navigation that is not a navigation: they
    // scroll. Leave those to the browser.
    '    if(h.charAt(0) === "#") return;' + sLineBreak +
    '    e.preventDefault();' + sLineBreak +
    '    try{ window.chrome.webview.postMessage("openlink:" + h); }catch(err){}' + sLineBreak +
    '  }, true);' + sLineBreak +
    '  /* Visual Scanner. A pure function of the payload the Pascal side emits' + sLineBreak +
    '     (TAefosVisualSession.ToJson): no state, no timers, no inference. A step' + sLineBreak +
    '     spins because the payload said "active", and for no other reason. */' + sLineBreak +
    '  /* The screenshots a scanner card shows, keyed by the id its payload' + sLineBreak +
    '     carries. They arrive on their OWN channel and exactly once: the card' + sLineBreak +
    '     payload is re-sent on every step, so putting the picture IN it would' + sLineBreak +
    '     re-push a whole screenshot each time a step moved. */' + sLineBreak +
    '  var _vsImages = {}, _vsImageOrder = [], _VS_IMAGE_MAX = 24;' + sLineBreak +
    '  /* Turns a failed picture into a readable fact: which side, and how many' + sLineBreak +
    '     characters the data URI had. A 40-char ''image'' is a truncated payload;' + sLineBreak +
    '     a 200k one that still fails is a decode problem. Two very different' + sLineBreak +
    '     bugs that look identical as a grey box. */' + sLineBreak +
    '  window._vsImgFail = function(img, side, len){' + sLineBreak +
    '    var box = img.closest ? img.closest(''.vs-live-shot'') : null;' + sLineBreak +
    '    if (!box) return;' + sLineBreak +
    '    box.innerHTML = ''<div class="vs-detail">The '' + side + '' screenshot'' +' + sLineBreak +
    '      '' could not be displayed ('' + len + '' chars received).</div>'';' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsScannerImage = function(id, dataUri){' + sLineBreak +
    '    if (!id || !dataUri || _vsImages[id]) return;' + sLineBreak +
    '    _vsImages[id] = dataUri;' + sLineBreak +
    '    _vsImageOrder.push(id);' + sLineBreak +
    '    /* A long conversation driving many windows would otherwise hold every' + sLineBreak +
    '       screenshot it ever showed. Oldest out first; a card whose picture was' + sLineBreak +
    '       evicted simply stops drawing the comparison rather than breaking. */' + sLineBreak +
    '    while (_vsImageOrder.length > _VS_IMAGE_MAX)' + sLineBreak +
    '      delete _vsImages[_vsImageOrder.shift()];' + sLineBreak +
    '    var open = document.getElementById("vs-" + (window._vsLastId || ""));' + sLineBreak +
    '    if (open && window._vsLastPayload) window.dsScanner(window._vsLastPayload);' + sLineBreak +
    '  };' + sLineBreak +
    '  var _vsIcon = { done: "\u2713", failed: "\u2715" };' + sLineBreak +
    '  function _vsEsc(s){ return String(s == null ? "" : s)' + sLineBreak +
    '    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }' + sLineBreak +
    '  function _vsTone(p){' + sLineBreak +
    '    if (p.state === "failed") return "vs-bad";' + sLineBreak +
    '    if (p.state === "cancelled" || p.state === "timed-out" ||' + sLineBreak +
    '        p.state === "abandoned") return "vs-off";' + sLineBreak +
    '    if (p.state === "completed") return "vs-ok";' + sLineBreak +
    '    var running = (p.steps || []).some(function(s){ return s.s === "active"; });' + sLineBreak +
    '    return running ? "vs-live" : "vs-off";' + sLineBreak +
    '  }' + sLineBreak +
    '  window.dsScanner = function(payload){' + sLineBreak +
    '    var p; try { p = (typeof payload === "string") ? JSON.parse(payload) : payload; }' + sLineBreak +
    '    catch(e){ return; }' + sLineBreak +
    '    if (!p || !p.id) return;' + sLineBreak +
    '    var id = "vs-" + p.id, el = document.getElementById(id);' + sLineBreak +
    '    if (!el){' + sLineBreak +
    '      el = document.createElement("div");' + sLineBreak +
    '      el.id = id;' + sLineBreak +
    '      var feed = document.getElementById("ds-feed") || document.body;' + sLineBreak +
    '      feed.appendChild(el);' + sLineBreak +
    '    }' + sLineBreak +
    '    var steps = (p.steps || []).map(function(s){' + sLineBreak +
    '      return ''<li class="vs-step" data-s="'' + _vsEsc(s.s) + ''">'' +' + sLineBreak +
    '        ''<span class="vs-ico">'' + (_vsIcon[s.s] || "") + ''</span>'' +' + sLineBreak +
    '        ''<span class="vs-label">'' + _vsEsc(s.t) + ''</span></li>''; }).join("");' + sLineBreak +
    '    var detail = (p.state === "failed" && p.detail)' + sLineBreak +
    '      ? ''<div class="vs-detail">'' + _vsEsc(p.detail) + ''</div>'' : "";' + sLineBreak +
    '    var cmp = "";' + sLineBreak +
    '    /* The payload names the pictures; the store holds them. A pair the' + sLineBreak +
    '       machine considers complete still does not draw until BOTH images' + sLineBreak +
    '       have actually arrived -- a half-rendered comparison would show one' + sLineBreak +
    '       screenshot twice, which reads as "nothing changed". */' + sLineBreak +
    '    /* ONE picture, always: the newest capture we have. The before/after' + sLineBreak +
    '       slider is GONE -- the owner asked for it removed three times and I kept' + sLineBreak +
    '       resurrecting it "for when the session ends". What he wants to watch is' + sLineBreak +
    '       the agent looking at a screen, not a comparison widget; a comparison is' + sLineBreak +
    '       a separate feature for a separate day. */' + sLineBreak +
    '    var _shot = _vsImages[p.after] || _vsImages[p.before], cmp = '''';' + sLineBreak +
    '    if (_shot){' + sLineBreak +
    '      cmp = ''<div class="vs-live-shot"><img src="'' + _vsEsc(_shot) +' + sLineBreak +
    '        ''" alt="what the agent sees" onerror="window._vsImgFail(this,'' +' + sLineBreak +
    '        ''&quot;screenshot&quot;,'' + _shot.length + '')">'' +' + sLineBreak +
    '        (p.terminal ? '''' : ''<div class="vs-sweep"></div>'') + ''</div>'';' + sLineBreak +
    '    }' + sLineBreak +
    '    window._vsLastId = p.id; window._vsLastPayload = payload;' + sLineBreak +
    '    el.className = "vs " + _vsTone(p);' + sLineBreak +
    '    el.innerHTML = ''<div class="vs-head"><span class="vs-dot"></span>'' +' + sLineBreak +
    '      ''<span class="vs-title">Visual scanner</span>'' +' + sLineBreak +
    '      ''<span class="vs-status">'' + _vsEsc(p.status) + ''</span></div>'' +' + sLineBreak +
    '      ''<ul class="vs-steps">'' + steps + ''</ul>'' + detail + cmp;' + sLineBreak +
    '    try { window.scrollTo(0, document.body.scrollHeight); } catch(e){}' + sLineBreak +
    '  };' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    '<div id="ds-mem-backdrop" style="display:none">' + sLineBreak +
    '  <div id="ds-mem-modal">' + sLineBreak +
    '    <div class="ds-mem-head">' + sLineBreak +
    '      <div class="ds-mem-badge">🧠</div>' + sLineBreak +
    '      <div>' + sLineBreak +
    '        <div class="ds-mem-title">Aefos Memory</div>' + sLineBreak +
    '        <div class="ds-mem-sub">Instructions that apply to ' +
    '<b>every conversation</b>, on any AI CLI. Saved globally.</div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <button class="ds-mem-close" id="ds-mem-close" type="button">&times;</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-mem-body">' + sLineBreak +
    '      <textarea id="ds-mem-text" spellcheck="false" ' +
    'placeholder="Persistent instructions&hellip;"></textarea>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-mem-foot">' + sLineBreak +
    '      <span id="ds-mem-meter"><span id="ds-mem-chars">0</span> characters ' +
    #$2022 + ' <span id="ds-mem-tok">~0 tokens</span> ' +
    '<span class="ds-mem-warn" id="ds-mem-warn"></span></span>' + sLineBreak +
    '      <span class="ds-mem-spacer"></span>' + sLineBreak +
    '      <button class="ds-mem-act" id="ds-mem-cancel" type="button">Cancel</button>' + sLineBreak +
    '      <button class="ds-mem-act ds-mem-primary" id="ds-mem-save" type="button">Save</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '  </div>' + sLineBreak +
    '</div>' + sLineBreak +
    (* ---- Sessions/History panel (filled by dsShowSessions) ---- *)
    '<div id="ds-ses" style="display:none">' + sLineBreak +
    '  <div class="ds-ses-ph">&#128339; SESSIONS</div>' + sLineBreak +
    '  <div class="ds-ses-search">&#128269; ' +
    '<input id="ds-ses-q" type="text" placeholder="Search history&hellip;"></div>' + sLineBreak +
    '  <div class="ds-ses-list" id="ds-ses-list"></div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var ta = document.getElementById("ds-mem-text");' + sLineBreak +
    '  var bd = document.getElementById("ds-mem-backdrop");' + sLineBreak +
    '  var modal = document.getElementById("ds-mem-modal");' + sLineBreak +
    '  function dsMemUpd(){' + sLineBreak +
    '    if(!ta) return;' + sLineBreak +
    '    var n = ta.value.length;' + sLineBreak +
    '    var c = document.getElementById("ds-mem-chars");' + sLineBreak +
    '    var k = document.getElementById("ds-mem-tok");' + sLineBreak +
    '    var w = document.getElementById("ds-mem-warn");' + sLineBreak +
    '    var t = Math.round(n / 4);' + sLineBreak +
    '    if(c){ c.textContent = n; }' + sLineBreak +
    '    if(k){ k.textContent = "~" + t + " tokens"; }' + sLineBreak +
    '    if(w){ w.textContent = t > 800 ? ' +
    '"' + #$2014 + ' large memories cost more per message" : ""; }' + sLineBreak +
    '  }' + sLineBreak +
    '  window.dsShowMemory = function(text){' + sLineBreak +
    '    if(ta){ ta.value = text || ""; }' + sLineBreak +
    '    if(bd){ bd.style.display = ""; }' + sLineBreak +
    '    dsMemUpd();' + sLineBreak +
    '    if(ta){ try{ ta.focus(); }catch(e){} }' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsHideMemory = function(){' + sLineBreak +
    '    if(bd){ bd.style.display = "none"; }' + sLineBreak +
    '  };' + sLineBreak +
    '  function dsMemPost(msg){' + sLineBreak +
    '    try{ if(window.chrome && window.chrome.webview){ ' +
    'window.chrome.webview.postMessage(msg); } }catch(e){}' + sLineBreak +
    '  }' + sLineBreak +
    '  if(ta){ ta.addEventListener("input", dsMemUpd); }' + sLineBreak +
    '  var memOpen = document.getElementById("ds-mem-open");' + sLineBreak +
    '  if(memOpen){ memOpen.addEventListener("click", function(){ ' +
    'dsMemPost("memory:open"); }); }' + sLineBreak +
    '  var memSave = document.getElementById("ds-mem-save");' + sLineBreak +
    '  if(memSave){ memSave.addEventListener("click", function(){ ' +
    'dsMemPost("memory:save:" + (ta ? ta.value : "")); window.dsHideMemory(); }); }' + sLineBreak +
    '  var memCancel = document.getElementById("ds-mem-cancel");' + sLineBreak +
    '  if(memCancel){ memCancel.addEventListener("click", window.dsHideMemory); }' + sLineBreak +
    '  var memClose = document.getElementById("ds-mem-close");' + sLineBreak +
    '  if(memClose){ memClose.addEventListener("click", window.dsHideMemory); }' + sLineBreak +
    '  if(bd){ bd.addEventListener("click", function(e){ ' +
    'if(e.target === bd){ window.dsHideMemory(); } }); }' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    (* ---- MCP Servers modal markup (plug button + /mcp) ---- *)
    '<div id="ds-mcp-backdrop" style="display:none">' + sLineBreak +
    '  <div id="ds-mcp-modal">' + sLineBreak +
    '    <div class="ds-mcp-head">' + sLineBreak +
    '      <div class="ds-mcp-badge">🔌</div>' + sLineBreak +
    '      <div>' + sLineBreak +
    '        <div class="ds-mcp-title">MCP Servers</div>' + sLineBreak +
    '        <div class="ds-mcp-sub">Extra MCP servers handed to the CLI, ' +
    'alongside the built-in Aefos MCP. The agent can use their tools too.</div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <button class="ds-mcp-close" id="ds-mcp-close" type="button">&times;</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-mcp-body">' + sLineBreak +
    '      <div class="ds-mcp-seclabel">CONNECTED</div>' + sLineBreak +
    '      <div id="ds-mcp-list"></div>' + sLineBreak +
    '      <button class="ds-mcp-add" id="ds-mcp-add" type="button">+ Add MCP server</button>' + sLineBreak +
    '      <div class="ds-mcp-form" id="ds-mcp-form" style="display:none">' + sLineBreak +
    '        <div class="ds-mcp-ftitle" id="ds-mcp-ftitle">Add MCP server</div>' + sLineBreak +
    '        <div class="ds-mcp-grid">' + sLineBreak +
    '          <div><label>NAME</label>' +
    '<input id="ds-mcp-name" placeholder="e.g. github" spellcheck="false"></div>' + sLineBreak +
    '          <div><label>TRANSPORT</label><div class="ds-mcp-seg">' +
    '<button class="ds-mcp-seg-btn on" id="ds-mcp-seg-stdio" type="button">stdio</button>' +
    '<button class="ds-mcp-seg-btn" id="ds-mcp-seg-http" type="button">http</button></div></div>' + sLineBreak +
    '        </div>' + sLineBreak +
    '        <div id="ds-mcp-stdio-fields">' + sLineBreak +
    '          <div class="ds-mcp-row2"><label>COMMAND</label>' +
    '<input id="ds-mcp-cmd" placeholder="npx -y @modelcontextprotocol/server-github" spellcheck="false"></div>' + sLineBreak +
    '          <div class="ds-mcp-row2"><label>ENV ' +
    '<span style="font-weight:400">(KEY=VALUE, space-separated, optional)</span></label>' +
    '<input id="ds-mcp-env" placeholder="GITHUB_TOKEN=ghp_..." spellcheck="false"></div>' + sLineBreak +
    '        </div>' + sLineBreak +
    '        <div id="ds-mcp-http-fields" style="display:none">' + sLineBreak +
    '          <div class="ds-mcp-row2"><label>URL</label>' +
    '<input id="ds-mcp-url" placeholder="https://127.0.0.1:8200/mcp" spellcheck="false"></div>' + sLineBreak +
    '        </div>' + sLineBreak +
    '        <div class="ds-mcp-hint">The Aefos MCP is always included automatically.</div>' + sLineBreak +
    '        <div class="ds-mcp-ffoot">' + sLineBreak +
    '          <button class="ds-mcp-btn sm" id="ds-mcp-fcancel" type="button">Cancel</button>' + sLineBreak +
    '          <button class="ds-mcp-btn sm primary" id="ds-mcp-fsave" type="button">Save server</button>' + sLineBreak +
    '        </div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-mcp-foot">' + sLineBreak +
    '      <span class="ds-mcp-note">Saved with your Aefos settings, ' +
    'merged into the CLI session.</span>' + sLineBreak +
    '      <button class="ds-mcp-btn" id="ds-mcp-closebtn" type="button">Close</button>' + sLineBreak +
    '      <button class="ds-mcp-btn primary" id="ds-mcp-save" type="button">Save</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '  </div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var mcpModel = [];' + sLineBreak +
    '  var mcpAddons = [];' + sLineBreak +
    '  var mcpEdit = -1;' + sLineBreak +
    '  var mcpType = "stdio";' + sLineBreak +
    '  var mb = document.getElementById("ds-mcp-backdrop");' + sLineBreak +
    '  function mcpPost(m){ try{ if(window.chrome && window.chrome.webview){ ' +
    'window.chrome.webview.postMessage(m); } }catch(e){} }' + sLineBreak +
    '  function mcpGet(id){ return document.getElementById(id); }' + sLineBreak +
    '  function mcpParseCmd(s){ s=(s||"").trim(); if(!s) return {command:"",args:[]}; ' +
    'var p=s.split(/\s+/); return {command:p[0], args:p.slice(1)}; }' + sLineBreak +
    '  function mcpEnvObj(s){ var o={}; (s||"").trim().split(/\s+/).forEach(function(kv){ ' +
    'if(!kv) return; var i=kv.indexOf("="); if(i>0){ o[kv.slice(0,i)]=kv.slice(i+1); } }); return o; }' + sLineBreak +
    '  function mcpEnvStr(o){ if(!o) return ""; return Object.keys(o).map(function(k){ ' +
    'return k+"="+o[k]; }).join(" "); }' + sLineBreak +
    '  function mcpRow(name, meta, tagtxt, kind, idx){' + sLineBreak +
    '    var row=document.createElement("div"); row.className="ds-mcp-srv"+(kind==="lock"?" ds-mcp-lock":"");' + sLineBreak +
    '    var dot=document.createElement("span"); dot.className="ds-mcp-dot"; row.appendChild(dot);' + sLineBreak +
    '    var mid=document.createElement("div"); mid.className="ds-mcp-mid";' + sLineBreak +
    '    var nm=document.createElement("span"); nm.className="ds-mcp-nm"; nm.textContent=name; mid.appendChild(nm);' + sLineBreak +
    '    var cm=document.createElement("div"); cm.className="ds-mcp-cmd"; cm.textContent=meta; mid.appendChild(cm);' + sLineBreak +
    '    row.appendChild(mid);' + sLineBreak +
    '    var tag=document.createElement("span"); tag.className="ds-mcp-tag"+(kind==="http"?" ds-mcp-http":"")' +
    '+(kind==="lock"?" ds-mcp-lockt":""); tag.textContent=tagtxt; row.appendChild(tag);' + sLineBreak +
    '    if(idx>=0){' + sLineBreak +
    '      var be=document.createElement("button"); be.className="ds-mcp-act"; be.textContent="✎"; ' +
    'be.title="Edit"; be.addEventListener("click",function(){ mcpOpenForm(idx); }); row.appendChild(be);' + sLineBreak +
    '      var br=document.createElement("button"); br.className="ds-mcp-act"; br.textContent="×"; ' +
    'br.title="Remove"; br.addEventListener("click",function(){ mcpModel.splice(idx,1); mcpRender(); }); row.appendChild(br);' + sLineBreak +
    '    }' + sLineBreak +
    '    return row;' + sLineBreak +
    '  }' + sLineBreak +
    '  function mcpRender(){' + sLineBreak +
    '    var list=mcpGet("ds-mcp-list"); if(!list) return; list.innerHTML="";' + sLineBreak +
    '    list.appendChild(mcpRow("aefos", "In-process - OTA tools (editor, project, build, git)", ' +
    '"BUILT-IN", "lock", -1));' + sLineBreak +
    '    mcpAddons.forEach(function(a){' + sLineBreak +
    // An addon shadowed by a hand-written server of the same name is hidden:
    // the user entry wins the dispatch merge, so showing both would lie.
    '      var shadowed=mcpModel.some(function(s){ return s.name===a.name; });' + sLineBreak +
    '      if(!shadowed){ list.appendChild(mcpRow(a.name, a.meta, "ADDON", "lock", -1)); } });' + sLineBreak +
    '    mcpModel.forEach(function(s,i){ var meta=(s.type==="http")?s.url:s.cmd; ' +
    'list.appendChild(mcpRow(s.name, meta, (s.type==="http")?"HTTP":"STDIO", (s.type==="http")?"http":"", i)); });' + sLineBreak +
    '    var form=mcpGet("ds-mcp-form"); var add=mcpGet("ds-mcp-add");' + sLineBreak +
    '    if(mcpEdit===-2 || mcpEdit>=0){ if(form) form.style.display=""; if(add) add.style.display="none"; mcpFill(); }' + sLineBreak +
    '    else { if(form) form.style.display="none"; if(add) add.style.display=""; }' + sLineBreak +
    '  }' + sLineBreak +
    '  function mcpSetType(t){ mcpType=t;' + sLineBreak +
    '    var ss=mcpGet("ds-mcp-seg-stdio"), sh=mcpGet("ds-mcp-seg-http");' + sLineBreak +
    '    if(ss) ss.className="ds-mcp-seg-btn"+(t==="stdio"?" on":"");' + sLineBreak +
    '    if(sh) sh.className="ds-mcp-seg-btn"+(t==="http"?" on":"");' + sLineBreak +
    '    var sf=mcpGet("ds-mcp-stdio-fields"), hf=mcpGet("ds-mcp-http-fields");' + sLineBreak +
    '    if(sf) sf.style.display=(t==="stdio")?"":"none"; if(hf) hf.style.display=(t==="http")?"":"none"; }' + sLineBreak +
    '  function mcpFill(){' + sLineBreak +
    '    var s=(mcpEdit>=0)?mcpModel[mcpEdit]:{name:"",type:"stdio",cmd:"",env:"",url:""};' + sLineBreak +
    '    mcpGet("ds-mcp-name").value=s.name||""; mcpGet("ds-mcp-cmd").value=s.cmd||"";' + sLineBreak +
    '    mcpGet("ds-mcp-env").value=s.env||""; mcpGet("ds-mcp-url").value=s.url||"";' + sLineBreak +
    '    mcpGet("ds-mcp-ftitle").textContent=(mcpEdit>=0)?"Edit MCP server":"Add MCP server";' + sLineBreak +
    '    mcpSetType(s.type||"stdio"); }' + sLineBreak +
    '  function mcpOpenForm(idx){ mcpEdit=idx; mcpRender(); var n=mcpGet("ds-mcp-name"); ' +
    'if(n){ try{ n.focus(); }catch(e){} } }' + sLineBreak +
    '  function mcpSaveForm(){' + sLineBreak +
    '    var name=(mcpGet("ds-mcp-name").value||"").trim(); if(!name){ mcpGet("ds-mcp-name").focus(); return; }' + sLineBreak +
    '    var e={name:name, type:mcpType, cmd:"", env:"", url:""};' + sLineBreak +
    '    if(mcpType==="http"){ e.url=(mcpGet("ds-mcp-url").value||"").trim(); }' + sLineBreak +
    '    else { e.cmd=(mcpGet("ds-mcp-cmd").value||"").trim(); e.env=(mcpGet("ds-mcp-env").value||"").trim(); }' + sLineBreak +
    '    if(mcpEdit>=0){ mcpModel[mcpEdit]=e; } else { mcpModel.push(e); }' + sLineBreak +
    '    mcpEdit=-1; mcpRender(); }' + sLineBreak +
    '  function mcpBuild(){ var srv={}; mcpModel.forEach(function(s){ if(!s.name) return;' + sLineBreak +
    '    if(s.type==="http"){ srv[s.name]={type:"http", url:s.url}; }' + sLineBreak +
    '    else { var pc=mcpParseCmd(s.cmd); var o={command:pc.command, args:pc.args}; ' +
    'var ev=mcpEnvObj(s.env); if(Object.keys(ev).length){ o.env=ev; } srv[s.name]=o; } });' + sLineBreak +
    '    return JSON.stringify({mcpServers:srv}); }' + sLineBreak +
    '  window.dsShowMcp = function(cfg, addonCfg){' + sLineBreak +
    '    mcpModel=[]; var srv=(cfg && cfg.mcpServers)?cfg.mcpServers:{};' + sLineBreak +
    '    Object.keys(srv).forEach(function(name){ var v=srv[name]||{};' + sLineBreak +
    '      if(v.type==="http" || (v.url && !v.command)){ mcpModel.push({name:name, type:"http", url:v.url||"", cmd:"", env:""}); }' + sLineBreak +
    '      else { var c=v.command||""; if(v.args && v.args.length){ c+=" "+v.args.join(" "); } ' +
    'mcpModel.push({name:name, type:"stdio", url:"", cmd:c, env:mcpEnvStr(v.env)}); } });' + sLineBreak +
    // Installed addons (`aefos install`): display-only rows, never in mcpModel,
    // so Save round-trips the user's own servers untouched.
    '    mcpAddons=[]; var asrv=(addonCfg && addonCfg.mcpServers)?addonCfg.mcpServers:{};' + sLineBreak +
    '    Object.keys(asrv).forEach(function(name){ var v=asrv[name]||{};' + sLineBreak +
    '      var m=(v.type==="http" || (v.url && !v.command))?(v.url||""):' +
    '((v.command||"")+((v.args && v.args.length)?(" "+v.args.join(" ")):""));' + sLineBreak +
    '      mcpAddons.push({name:name, meta:m+" - installed via aefos install"}); });' + sLineBreak +
    '    mcpEdit=-1; mcpRender(); if(mb){ mb.style.display=""; } };' + sLineBreak +
    '  window.dsHideMcp = function(){ if(mb){ mb.style.display="none"; } };' + sLineBreak +
    '  var bO=mcpGet("ds-mcp-open"); if(bO){ bO.addEventListener("click", function(){ mcpPost("mcp:open"); }); }' + sLineBreak +
    '  var bX=mcpGet("ds-mcp-close"); if(bX){ bX.addEventListener("click", window.dsHideMcp); }' + sLineBreak +
    '  var bC=mcpGet("ds-mcp-closebtn"); if(bC){ bC.addEventListener("click", window.dsHideMcp); }' + sLineBreak +
    '  var bS=mcpGet("ds-mcp-save"); if(bS){ bS.addEventListener("click", function(){ ' +
    'mcpPost("mcp:save:"+mcpBuild()); window.dsHideMcp(); }); }' + sLineBreak +
    '  var bA=mcpGet("ds-mcp-add"); if(bA){ bA.addEventListener("click", function(){ mcpOpenForm(-2); }); }' + sLineBreak +
    '  var bFS=mcpGet("ds-mcp-fsave"); if(bFS){ bFS.addEventListener("click", mcpSaveForm); }' + sLineBreak +
    '  var bFC=mcpGet("ds-mcp-fcancel"); if(bFC){ bFC.addEventListener("click", function(){ mcpEdit=-1; mcpRender(); }); }' + sLineBreak +
    '  var sgS=mcpGet("ds-mcp-seg-stdio"); if(sgS){ sgS.addEventListener("click", function(){ mcpSetType("stdio"); }); }' + sLineBreak +
    '  var sgH=mcpGet("ds-mcp-seg-http"); if(sgH){ sgH.addEventListener("click", function(){ mcpSetType("http"); }); }' + sLineBreak +
    '  if(mb){ mb.addEventListener("click", function(e){ if(e.target===mb){ window.dsHideMcp(); } }); }' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    (* ---- New Project wizard (native, /new-project) ---- *)
    '<style>' + sLineBreak +
    '#ds-newproj-backdrop{position:fixed;inset:0;z-index:62;display:none;' +
    'background:rgba(6,7,10,.64);backdrop-filter:blur(3px);align-items:center;justify-content:center;}' + sLineBreak +
    '#ds-newproj-backdrop.on{display:flex;}' + sLineBreak +
    '#ds-newproj-modal{width:min(560px,94vw);max-height:92vh;background:#171a21;' +
    'border:1px solid var(--ds-border);border-radius:16px;box-shadow:0 24px 70px rgba(0,0,0,.55);' +
    'overflow:hidden;display:flex;flex-direction:column;}' + sLineBreak +
    '#ds-newproj-modal .np-head{display:flex;align-items:flex-start;gap:13px;padding:18px 22px 12px;}' + sLineBreak +
    '#ds-newproj-modal .np-badge{width:42px;height:42px;border-radius:11px;flex:none;display:grid;place-items:center;font-size:20px;' +
    'background:linear-gradient(135deg,rgba(var(--ds-primary-rgb),.22),rgba(var(--ds-primary-rgb),.05));' +
    'border:1px solid rgba(var(--ds-primary-rgb),.32);}' + sLineBreak +
    '#ds-newproj-modal .np-title{font-size:16px;font-weight:700;margin:1px 0 3px;color:var(--ds-fg);}' + sLineBreak +
    '#ds-newproj-modal .np-sub{font-size:12.5px;color:var(--ds-secondary);line-height:1.45;}' + sLineBreak +
    '#ds-newproj-modal .np-close{margin-left:auto;color:var(--ds-secondary);font-size:20px;cursor:pointer;background:none;border:none;line-height:1;}' + sLineBreak +
    '#ds-newproj-modal .np-body{padding:4px 22px 6px;overflow-y:auto;}' + sLineBreak +
    '#ds-newproj-modal .np-row{margin:12px 0;}' + sLineBreak +
    '#ds-newproj-modal label{display:block;font-size:11.5px;color:var(--ds-secondary);margin-bottom:5px;font-weight:600;letter-spacing:.2px;}' + sLineBreak +
    '#ds-newproj-modal label .req{color:var(--ds-primary);margin-left:3px;}' + sLineBreak +
    '#ds-newproj-modal input,#ds-newproj-modal select{width:100%;background:var(--ds-bg);border:1px solid var(--ds-border);border-radius:10px;' +
    'color:var(--ds-fg);font-size:13.5px;padding:10px 12px;outline:none;font-family:inherit;}' + sLineBreak +
    '#ds-newproj-modal select{cursor:pointer;}' + sLineBreak +
    '#ds-newproj-modal input:focus,#ds-newproj-modal select:focus{border-color:var(--ds-primary);box-shadow:0 0 0 3px rgba(var(--ds-primary-rgb),.16);}' + sLineBreak +
    '#ds-newproj-modal ::placeholder{color:#5b616b;}' + sLineBreak +
    '#ds-newproj-modal .np-tpldesc{font-size:11.5px;color:#5b616b;margin-top:6px;line-height:1.5;}' + sLineBreak +
    '#ds-newproj-modal .np-savewrap{display:flex;gap:8px;}' + sLineBreak +
    '#ds-newproj-modal .np-savewrap input{flex:1;font-family:"Cascadia Code","Consolas",monospace;font-size:12.5px;}' + sLineBreak +
    '#ds-newproj-modal .np-browse{flex:none;background:#1c2029;border:1px solid var(--ds-border);border-radius:10px;color:var(--ds-fg);font-size:12.5px;padding:0 14px;cursor:pointer;}' + sLineBreak +
    '#ds-newproj-modal .np-browse:hover{border-color:var(--ds-primary);}' + sLineBreak +
    '#ds-newproj-modal .np-summary{margin-top:14px;background:var(--ds-bg);border:1px solid var(--ds-border);border-radius:10px;padding:10px 12px;font-size:11.5px;color:var(--ds-secondary);line-height:1.55;}' + sLineBreak +
    '#ds-newproj-modal .np-summary code{color:var(--ds-fg);font-family:"Cascadia Code","Consolas",monospace;background:#1c2029;padding:1px 6px;border-radius:5px;}' + sLineBreak +
    '#ds-newproj-modal .np-err{margin-top:10px;font-size:12px;color:var(--ds-danger);display:none;}' + sLineBreak +
    '#ds-newproj-modal .np-foot{display:flex;align-items:center;gap:10px;padding:13px 22px 20px;}' + sLineBreak +
    '#ds-newproj-modal .np-open{display:flex;align-items:center;gap:7px;font-size:12px;color:var(--ds-secondary);cursor:pointer;user-select:none;}' + sLineBreak +
    '#ds-newproj-modal .np-open input{width:15px;height:15px;accent-color:var(--ds-primary);}' + sLineBreak +
    '#ds-newproj-modal .np-sp{flex:1;}' + sLineBreak +
    '#ds-newproj-modal .np-btn{padding:9px 18px;border-radius:10px;font-size:13.5px;font-weight:600;cursor:pointer;border:1px solid var(--ds-border);background:#1c2029;color:var(--ds-fg);}' + sLineBreak +
    '#ds-newproj-modal .np-btn.primary{border:none;color:#fff;background:linear-gradient(135deg,var(--ds-primary-hi),var(--ds-primary-lo));box-shadow:0 6px 18px rgba(var(--ds-primary-rgb),.32);}' + sLineBreak +
    '</style>' + sLineBreak +
    '<div id="ds-newproj-backdrop">' + sLineBreak +
    '  <div id="ds-newproj-modal">' + sLineBreak +
    '    <div class="np-head">' + sLineBreak +
    '      <div class="np-badge">&#128230;</div>' + sLineBreak +
    '      <div><div class="np-title">New Project</div>' + sLineBreak +
    '      <div class="np-sub">Scaffold a Delphi project from a template - fill in the fields and create.</div></div>' + sLineBreak +
    '      <button class="np-close" id="ds-newproj-close" type="button">&times;</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="np-body">' + sLineBreak +
    '      <div class="np-row"><label>TEMPLATE</label>' + sLineBreak +
    '        <select id="ds-newproj-tpl"></select>' + sLineBreak +
    '        <div class="np-tpldesc" id="ds-newproj-desc"></div></div>' + sLineBreak +
    '      <div id="ds-newproj-fields"></div>' + sLineBreak +
    '      <div class="np-row"><label>WHERE TO SAVE <span class="req">*</span></label>' + sLineBreak +
    '        <div class="np-savewrap">' + sLineBreak +
    '          <input id="ds-newproj-dir" placeholder="D:\Projects\MyApp" spellcheck="false">' + sLineBreak +
    '          <button class="np-browse" id="ds-newproj-browse" type="button">&#128193; Browse</button>' + sLineBreak +
    '        </div></div>' + sLineBreak +
    '      <div class="np-summary" id="ds-newproj-summary"></div>' + sLineBreak +
    '      <div class="np-err" id="ds-newproj-err"></div>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="np-foot">' + sLineBreak +
    '      <label class="np-open"><input type="checkbox" id="ds-newproj-open" checked> Open in IDE after creating</label>' + sLineBreak +
    '      <span class="np-sp"></span>' + sLineBreak +
    '      <button class="np-btn" id="ds-newproj-cancel" type="button">Cancel</button>' + sLineBreak +
    '      <button class="np-btn primary" id="ds-newproj-create" type="button">Create project</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '  </div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var NP_TEMPLATES = [];' + sLineBreak +
    '  var nb = document.getElementById("ds-newproj-backdrop");' + sLineBreak +
    '  function npPost(m){ try{ if(window.chrome && window.chrome.webview){ window.chrome.webview.postMessage(m); } }catch(e){} }' + sLineBreak +
    '  function npGet(id){ return document.getElementById(id); }' + sLineBreak +
    '  function npCurrent(){ var s=npGet("ds-newproj-tpl"); var v=s?s.value:""; for(var i=0;i<NP_TEMPLATES.length;i++){ if(NP_TEMPLATES[i].id===v){ return NP_TEMPLATES[i]; } } return null; }' + sLineBreak +
    '  function npFill(){ var s=npGet("ds-newproj-tpl"); if(!s){ return; } s.innerHTML="";' +
    ' var cats=[]; var by={}; NP_TEMPLATES.forEach(function(t){ var c=t.category||"Other"; if(!by[c]){ by[c]=[]; cats.push(c); } by[c].push(t); });' +
    ' cats.forEach(function(c){ var og=document.createElement("optgroup"); og.label=c;' +
    ' by[c].forEach(function(t){ var o=document.createElement("option"); o.value=t.id; o.textContent=t.name||t.id; og.appendChild(o); }); s.appendChild(og); }); }' + sLineBreak +
    '  function npSummary(){ var sm=npGet("ds-newproj-summary"); if(!sm){ return; } var ni=npGet("ds-npv-Name");' +
    ' var nm=(ni && ni.value.trim()) || "MyApp"; sm.innerHTML="Creates <code>"+nm+".dpr</code> + <code>"+nm+".dproj</code> in the chosen folder and opens it in the IDE."; }' + sLineBreak +
    '  function npFields(){ var t=npCurrent(); var f=npGet("ds-newproj-fields"); var d=npGet("ds-newproj-desc");' +
    ' if(d){ d.textContent = t ? (t.description||"") : ""; } if(!f){ return; } f.innerHTML="";' +
    ' if(!t || !t.vars){ npSummary(); return; }' +
    ' t.vars.forEach(function(v){ var row=document.createElement("div"); row.className="np-row";' +
    ' var lab=document.createElement("label"); lab.textContent=(v.description||v.key||"").toUpperCase();' +
    ' if(v.required){ var rq=document.createElement("span"); rq.className="req"; rq.textContent="*"; lab.appendChild(rq); }' +
    ' var inp=document.createElement("input"); inp.id="ds-npv-"+v.key; inp.className="np-var"; inp.setAttribute("data-key",v.key);' +
    ' inp.setAttribute("spellcheck","false"); inp.placeholder=v.key; inp.addEventListener("input", npSummary);' +
    ' row.appendChild(lab); row.appendChild(inp); f.appendChild(row); }); npSummary(); }' + sLineBreak +
    '  function npGather(){ var t=npCurrent(); if(!t){ return null; } var vars={};' +
    ' var nodes=npGet("ds-newproj-fields").querySelectorAll(".np-var");' +
    ' for(var i=0;i<nodes.length;i++){ vars[nodes[i].getAttribute("data-key")]=nodes[i].value; }' +
    ' var dir=npGet("ds-newproj-dir"); var op=npGet("ds-newproj-open");' +
    ' return { template_id:t.id, target_dir:dir?dir.value.trim():"", vars:vars, open:op?op.checked:true }; }' + sLineBreak +
    '  function npErr(msg){ var e=npGet("ds-newproj-err"); if(e){ e.textContent=msg||""; e.style.display = msg ? "block" : "none"; } }' + sLineBreak +
    '  window.dsShowNewProject = function(list){ NP_TEMPLATES = (list && list.length) ? list : [];' +
    ' npErr(""); npFill(); npFields(); if(nb){ nb.classList.add("on"); }' +
    ' var ni=npGet("ds-npv-Name"); if(ni){ ni.focus(); } };' + sLineBreak +
    '  window.dsHideNewProject = function(){ if(nb){ nb.classList.remove("on"); } };' + sLineBreak +
    '  window.dsNewProjBrowse = function(path){ var d=npGet("ds-newproj-dir"); if(d && path){ d.value=path; npSummary(); } };' + sLineBreak +
    '  window.dsNewProjResult = function(r){ if(r && r.ok){ window.dsHideNewProject(); } else { npErr((r && r.error) ? r.error : "Could not create the project."); } };' + sLineBreak +
    '  var st=npGet("ds-newproj-tpl"); if(st){ st.addEventListener("change", npFields); }' + sLineBreak +
    '  var bB=npGet("ds-newproj-browse"); if(bB){ bB.addEventListener("click", function(){ npPost("newproj:browse"); }); }' + sLineBreak +
    '  var bCr=npGet("ds-newproj-create"); if(bCr){ bCr.addEventListener("click", function(){ var form=npGather(); if(!form){ return; }' +
    ' if(!form.target_dir){ npErr("Choose where to save the project."); return; } npErr(""); npPost("newproj:create:"+JSON.stringify(form)); }); }' + sLineBreak +
    '  var bXn=npGet("ds-newproj-close"); if(bXn){ bXn.addEventListener("click", window.dsHideNewProject); }' + sLineBreak +
    '  var bKn=npGet("ds-newproj-cancel"); if(bKn){ bKn.addEventListener("click", window.dsHideNewProject); }' + sLineBreak +
    '  if(nb){ nb.addEventListener("click", function(e){ if(e.target===nb){ window.dsHideNewProject(); } }); }' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    (* ---- Attach (paperclip) + paste-image -> attachment chips ---- *)
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  function aPost(m){ try{ if(window.chrome && window.chrome.webview){ ' +
    'window.chrome.webview.postMessage(m); } }catch(e){} }' + sLineBreak +
    '  window._dsAttachments = window._dsAttachments || [];' + sLineBreak +
    '  function dsRenderAttach(){' + sLineBreak +
    '    var bar = document.getElementById("ds-attachbar"); if(!bar) return; bar.innerHTML = "";' + sLineBreak +
    '    window._dsAttachments.forEach(function(a, i){' + sLineBreak +
    '      var chip = document.createElement("div"); chip.className = "ds-chip";' + sLineBreak +
    '      var card = document.createElement("div"); card.className = "ds-chip-card";' + sLineBreak +
    '      if(a.kind === "image" && a.thumb){ var im = document.createElement("img"); ' +
    'im.src = a.thumb; im.title = a.name; card.appendChild(im); }' + sLineBreak +
    '      else { var ic = document.createElement("div"); ic.className = "ds-chip-ic"; ' +
    'ic.textContent = "📄"; card.appendChild(ic);' + sLineBreak +
    '        var nm = document.createElement("div"); nm.className = "ds-chip-nm"; ' +
    'nm.textContent = a.name; nm.title = a.name; card.appendChild(nm); }' + sLineBreak +
    '      chip.appendChild(card);' + sLineBreak +
    '      var x = document.createElement("button"); x.className = "ds-chip-x"; ' +
    'x.type = "button"; x.textContent = "×"; x.title = "Remove";' + sLineBreak +
    '      x.addEventListener("click", function(){ window._dsAttachments.splice(i, 1); dsRenderAttach(); });' + sLineBreak +
    '      chip.appendChild(x); bar.appendChild(chip);' + sLineBreak +
    '    });' + sLineBreak +
    '  }' + sLineBreak +
    '  window.dsAddAttachment = function(path, kind, thumb){' + sLineBreak +
    '    if(!path) return;' + sLineBreak +
    '    var name = String(path).split(/[\\/]/).pop();' + sLineBreak +
    '    window._dsAttachments.push({ path: path, kind: kind || "file", ' +
    'thumb: thumb || "", name: name });' + sLineBreak +
    '    dsRenderAttach();' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsClearAttachments = function(){ window._dsAttachments = []; dsRenderAttach(); };' + sLineBreak +
    '  var aBtn = document.getElementById("ds-attach-open");' + sLineBreak +
    '  if(aBtn){ aBtn.addEventListener("click", function(){ aPost("attach:open"); }); }' + sLineBreak +
    '  var inp = document.getElementById("ds-input");' + sLineBreak +
    '  if(inp){ inp.addEventListener("paste", function(e){' + sLineBreak +
    '    var items = (e.clipboardData && e.clipboardData.items) ? e.clipboardData.items : [];' + sLineBreak +
    '    for(var i=0;i<items.length;i++){' + sLineBreak +
    '      if(items[i].type && items[i].type.indexOf("image") === 0){' + sLineBreak +
    '        var f = items[i].getAsFile(); if(!f) continue;' + sLineBreak +
    '        e.preventDefault();' + sLineBreak +
    '        var r = new FileReader();' + sLineBreak +
    '        r.onload = function(){ var s = String(r.result || ""); var c = s.indexOf(","); ' +
    'if(c >= 0){ aPost("paste:image:" + s.slice(c + 1)); } };' + sLineBreak +
    '        r.readAsDataURL(f);' + sLineBreak +
    '        return;' + sLineBreak +
    '      }' + sLineBreak +
    '    }' + sLineBreak +
    '  }); }' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    (* ---- Header (#ds-header) bridge: actions + toggle + session ---- *)
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  function dsHdPost(msg){' + sLineBreak +
    '    try{ if(window.chrome && window.chrome.webview){ ' +
    'window.chrome.webview.postMessage(msg); } }catch(e){}' + sLineBreak +
    '  }' + sLineBreak +
    '  var bNew = document.getElementById("ds-hd-new");' + sLineBreak +
    '  var bSes = document.getElementById("ds-hd-sessions");' + sLineBreak +
    '  var bSet = document.getElementById("ds-hd-settings");' + sLineBreak +
    '  if(bNew){ bNew.addEventListener("click", function(){ ' +
    'dsHdPost("hdr:newsession"); }); }' + sLineBreak +
    '  if(bSes){ bSes.addEventListener("click", function(){ ' +
    'dsHdPost("hdr:sessions"); }); }' + sLineBreak +
    '  if(bSet){ bSet.addEventListener("click", function(){ ' +
    'dsHdPost("hdr:settings"); }); }' + sLineBreak +
    (* Chat|Agent toggle: today it is visual only (the VCL tabs had no handler);
       posts hdr:mode:* anyway so Pascal can react to it in the future. *)
    '  var tChat = document.getElementById("ds-hd-chat");' + sLineBreak +
    '  var tAgent = document.getElementById("ds-hd-agent");' + sLineBreak +
    '  function dsHdMode(on, off, mode){' + sLineBreak +
    '    if(on){ on.classList.add("ds-hd-on"); }' + sLineBreak +
    '    if(off){ off.classList.remove("ds-hd-on"); }' + sLineBreak +
    '    dsHdPost("hdr:mode:" + mode);' + sLineBreak +
    '  }' + sLineBreak +
    '  if(tChat){ tChat.addEventListener("click", function(){ ' +
    'dsHdMode(tChat, tAgent, "chat"); }); }' + sLineBreak +
    '  if(tAgent){ tAgent.addEventListener("click", function(){ ' +
    'dsHdMode(tAgent, tChat, "agent"); }); }' + sLineBreak +
    (* Pascal-driven mode set (no post-back): /new-project forces Agent. *)
    '  window.dsSetMode = function(mode){' + sLineBreak +
    '    if(mode === "agent"){ if(tAgent){tAgent.classList.add("ds-hd-on");}' +
    ' if(tChat){tChat.classList.remove("ds-hd-on");} }' + sLineBreak +
    '    else { if(tChat){tChat.classList.add("ds-hd-on");}' +
    ' if(tAgent){tAgent.classList.remove("ds-hd-on");} }' + sLineBreak +
    '  };' + sLineBreak +
    (* model selector dropdown: dsSetModels(list,current) fed by Pascal; pick posts hdr:model:<id> *)
    '  var _mBtn = document.getElementById("ds-hd-model");' + sLineBreak +
    '  var _mList = document.getElementById("ds-hd-mlist");' + sLineBreak +
    '  var _mName = document.getElementById("ds-hd-model-name");' + sLineBreak +
    '  window.dsSetModels = function(models, current){' + sLineBreak +
    '    var cur = current || "";' + sLineBreak +
    '    if(_mName){ _mName.textContent = cur || "model"; }' + sLineBreak +
    '    if(!_mList){ return; } _mList.innerHTML = "";' + sLineBreak +
    '    (models||[]).forEach(function(m){' + sLineBreak +
    '      var it = document.createElement("div"); it.className = "ds-hd-mitem" + (m===cur?" on":"");' + sLineBreak +
    '      var ck = document.createElement("span"); ck.className = "ds-hd-mck"; ' +
    'ck.textContent = (m===cur ? "✓" : ""); it.appendChild(ck);' + sLineBreak +
    '      var nm = document.createElement("span"); nm.textContent = m; it.appendChild(nm);' + sLineBreak +
    '      it.addEventListener("click", function(){ if(_mName){ _mName.textContent = m; } ' +
    '_mList.style.display = "none"; dsHdPost("hdr:model:" + m); window.dsSetModels(models, m); });' + sLineBreak +
    '      _mList.appendChild(it);' + sLineBreak +
    '    });' + sLineBreak +
    '  };' + sLineBreak +
    '  if(_mBtn){ _mBtn.addEventListener("click", function(e){ e.stopPropagation(); ' +
    'if(_mList){ _mList.style.display = (_mList.style.display === "none" ? "block" : "none"); } }); }' + sLineBreak +
    '  document.addEventListener("click", function(){ if(_mList){ _mList.style.display = "none"; } });' + sLineBreak +
    (* reasoning-effort dropdown: dsSetEffort(current, supported) fed by Pascal; *)
    (* pick posts hdr:effort:<token> ("default" clears it). Shown only when the *)
    (* active executor supports it (effortSupported in the models payload). *)
    '  var _eWrap = document.getElementById("ds-hd-effort-wrap");' + sLineBreak +
    '  var _eBtn = document.getElementById("ds-hd-effort");' + sLineBreak +
    '  var _eList = document.getElementById("ds-hd-elist");' + sLineBreak +
    '  var _eName = document.getElementById("ds-hd-effort-name");' + sLineBreak +
    '  var _eOpts = [["","Default"],["low","Low"],["medium","Medium"],' +
    '["high","High"],["xhigh","XHigh"]];' + sLineBreak +
    '  window.dsSetEffort = function(current, supported){' + sLineBreak +
    '    if(_eWrap){ _eWrap.style.display = supported ? "" : "none"; }' + sLineBreak +
    '    if(!supported){ return; }' + sLineBreak +
    '    var cur = current || "";' + sLineBreak +
    '    var lbl = "Default"; _eOpts.forEach(function(o){ if(o[0]===cur){ lbl = o[1]; } });' + sLineBreak +
    '    if(_eName){ _eName.textContent = lbl; }' + sLineBreak +
    '    if(!_eList){ return; } _eList.innerHTML = "";' + sLineBreak +
    '    _eOpts.forEach(function(o){' + sLineBreak +
    '      var it = document.createElement("div"); it.className = "ds-hd-mitem" + (o[0]===cur?" on":"");' + sLineBreak +
    '      var ck = document.createElement("span"); ck.className = "ds-hd-mck"; ' +
    'ck.textContent = (o[0]===cur ? "✓" : ""); it.appendChild(ck);' + sLineBreak +
    '      var nm = document.createElement("span"); nm.textContent = o[1]; it.appendChild(nm);' + sLineBreak +
    '      it.addEventListener("click", function(){ if(_eName){ _eName.textContent = o[1]; } ' +
    '_eList.style.display = "none"; dsHdPost("hdr:effort:" + (o[0]||"default")); ' +
    'window.dsSetEffort(o[0], true); });' + sLineBreak +
    '      _eList.appendChild(it);' + sLineBreak +
    '    });' + sLineBreak +
    '  };' + sLineBreak +
    '  if(_eBtn){ _eBtn.addEventListener("click", function(e){ e.stopPropagation(); ' +
    'if(_eList){ _eList.style.display = (_eList.style.display === "none" ? "block" : "none"); } }); }' + sLineBreak +
    '  document.addEventListener("click", function(){ if(_eList){ _eList.style.display = "none"; } });' + sLineBreak +
    '  window.dsModels = function(o){ if(o){ window.dsSetModels(o.models||[], o.current||"");' +
    ' if(window.dsSetEffort){ window.dsSetEffort(o.effort||"", !!o.effortSupported); } } };' + sLineBreak +
    (* Persistent Trial badge: Pascal pushes the text via dsSetTrial (''=hide); *)
    (* a click opens the License manager (hdr:license). *)
    '  var _trial = document.getElementById("ds-hd-trial");' + sLineBreak +
    '  if(_trial){ _trial.addEventListener("click", function(){ dsHdPost("hdr:license"); }); }' + sLineBreak +
    '  window.dsSetTrial = function(text){ if(!_trial){ return; }' + sLineBreak +
    '    if(text){ _trial.textContent = text; _trial.style.display = ""; }' + sLineBreak +
    '    else { _trial.style.display = "none"; } };' + sLineBreak +
    (* host-injected paste: the IDE swallows Ctrl+V, so Pascal reads the clipboard *)
    (* and calls this to drop the text at the input caret (replacing any selection). *)
    '  window.dsInsertAtCursor = function(t){ var i = document.getElementById("ds-input");' +
    ' if(!i){ return; } i.focus(); var s = i.selectionStart, e = i.selectionEnd, v = i.value;' +
    ' i.value = v.slice(0, s) + t + v.slice(e); var p = s + (t ? t.length : 0);' +
    ' i.selectionStart = i.selectionEnd = p; i.dispatchEvent(new Event("input")); };' + sLineBreak +
    (* host prefill (welcome shortcut / toolbar): REPLACE the composer value with t, *)
    (* focus and put the caret at the end so the user can keep typing the target. *)
    '  window.dsPrefillInput = function(t){ var i = document.getElementById("ds-input");' +
    ' if(!i){ return; } i.value = t || ""; i.focus();' +
    ' i.selectionStart = i.selectionEnd = i.value.length;' +
    ' i.dispatchEvent(new Event("input")); };' + sLineBreak +
    '  dsHdPost("hdr:models");' + sLineBreak +
    '  dsHdPost("hdr:trial");' + sLineBreak +
    '  dsHdPost("cmd:picker");' + sLineBreak +
    (* re-validate + reload models/executor whenever the panel regains focus, so *)
    (* a config change (executor/model) made in Options is reflected on click. *)
    '  window.addEventListener("focus", function(){ dsHdPost("hdr:models");' +
    ' dsHdPost("hdr:trial"); dsHdPost("cmd:picker"); });' + sLineBreak +
    (* Pascal -> page: feeds the context line (title / count / time). *)
    '  window.dsSetSessionInfo = function(title, count, timeText){' + sLineBreak +
    '    var t = document.getElementById("ds-ctx-title");' + sLineBreak +
    '    var c = document.getElementById("ds-ctx-count");' + sLineBreak +
    '    var sep = document.getElementById("ds-ctx-sep");' + sLineBreak +
    '    var tm = document.getElementById("ds-ctx-time");' + sLineBreak +
    '    if(t && title){ t.textContent = title; }' + sLineBreak +
    '    if(c){ c.textContent = (count === 1 ? "1 message" : count + " messages"); }' + sLineBreak +
    '    if(tm){ tm.textContent = timeText || ""; }' + sLineBreak +
    '    if(sep){ sep.style.display = (timeText ? "" : "none"); }' + sLineBreak +
    '  };' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var panel = document.getElementById("ds-ses");' + sLineBreak +
    '  var listEl = document.getElementById("ds-ses-list");' + sLineBreak +
    '  var qEl = document.getElementById("ds-ses-q");' + sLineBreak +
    '  var data = [];' + sLineBreak +
    '  function dsSesPost(msg){' + sLineBreak +
    '    try{ if(window.chrome && window.chrome.webview){ ' +
    'window.chrome.webview.postMessage(msg); } }catch(e){}' + sLineBreak +
    '  }' + sLineBreak +
    '  function dsSesRender(filter){' + sLineBreak +
    '    if(!listEl) return;' + sLineBreak +
    '    filter = (filter || "").toLowerCase();' + sLineBreak +
    '    listEl.innerHTML = "";' + sLineBreak +
    '    var shown = 0;' + sLineBreak +
    '    for(var i=0;i<data.length;i++){' + sLineBreak +
    '      var it = data[i];' + sLineBreak +
    '      if(filter && (String(it.title||"")).toLowerCase().indexOf(filter) < 0) continue;' + sLineBreak +
    '      shown++;' + sLineBreak +
    '      var row = document.createElement("div");' + sLineBreak +
    '      row.className = "ds-ses-row" + (it.current ? " ds-ses-cur" : "");' + sLineBreak +
    '      var ri = document.createElement("span"); ri.className = "ds-ses-ri"; ' +
    'ri.innerHTML = "&#128172;";' + sLineBreak +
    '      var rt = document.createElement("div"); rt.className = "ds-ses-rt";' + sLineBreak +
    '      var bEl = document.createElement("b"); ' +
    'bEl.textContent = it.title || "(untitled)";' + sLineBreak +
    '      var spEl = document.createElement("span");' + sLineBreak +
    '      /* Joined from the parts that EXIST. Concatenating fixed separators' + sLineBreak +
    '         left a row with no recorded executor starting on " · ", which' + sLineBreak +
    '         reads as a missing word rather than an absent field. */' + sLineBreak +
    '      var bits = [];' + sLineBreak +
    '      if (it.cli) bits.push(it.cli);' + sLineBreak +
    '      if (it.when) bits.push(it.when);' + sLineBreak +
    '      if (it.count) bits.push(it.count + " msgs");' + sLineBreak +
    '      spEl.textContent = bits.join(" · ");' + sLineBreak +
    '      rt.appendChild(bEl); rt.appendChild(spEl);' + sLineBreak +
    '      row.appendChild(ri); row.appendChild(rt);' + sLineBreak +
    '      if(it.current){ var bdg = document.createElement("span"); ' +
    'bdg.className = "ds-ses-badge"; bdg.textContent = "CURRENT"; row.appendChild(bdg); }' + sLineBreak +
    '      (function(id){ var del = document.createElement("span"); ' +
    'del.title = "Delete session"; del.innerHTML = "&#128465;"; ' +
    'del.style.cssText = "margin-left:auto;cursor:pointer;opacity:.5;' +
    'padding:0 2px;font-size:13px;flex:none;"; ' +
    'del.onmouseenter = function(){ del.style.opacity = "1"; }; ' +
    'del.onmouseleave = function(){ del.style.opacity = ".5"; }; ' +
    'del.addEventListener("click", function(ev){ ev.stopPropagation(); ' +
    'dsSesPost("session:delete:" + id); }); row.appendChild(del); })(it.id);' + sLineBreak +
    '      (function(id){ row.addEventListener("click", function(){ ' +
    'dsSesPost("session:resume:" + id); window.dsHideSessions(); }); })(it.id);' + sLineBreak +
    '      listEl.appendChild(row);' + sLineBreak +
    '    }' + sLineBreak +
    '    if(shown === 0){ var e = document.createElement("div"); ' +
    'e.className = "ds-ses-empty"; e.textContent = "No sessions."; listEl.appendChild(e); }' + sLineBreak +
    '  }' + sLineBreak +
    '  window.dsShowSessions = function(items){' + sLineBreak +
    '    data = items || [];' + sLineBreak +
    '    if(qEl){ qEl.value = ""; }' + sLineBreak +
    '    dsSesRender("");' + sLineBreak +
    '    if(panel){ panel.style.display = ""; }' + sLineBreak +
    '    if(qEl){ try{ qEl.focus(); }catch(e){} }' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsHideSessions = function(){' + sLineBreak +
    '    if(panel){ panel.style.display = "none"; }' + sLineBreak +
    '  };' + sLineBreak +
    '  if(qEl){ qEl.addEventListener("input", function(){ dsSesRender(qEl.value); }); }' + sLineBreak +
    '  if(qEl){ qEl.addEventListener("keydown", function(e){ ' +
    'if(e.key === "Escape"){ window.dsHideSessions(); } }); }' + sLineBreak +
    '  document.addEventListener("mousedown", function(e){' + sLineBreak +
    '    if(panel && panel.style.display !== "none"){' + sLineBreak +
    '      var btn = document.getElementById("ds-hd-sessions");' + sLineBreak +
    '      if(!panel.contains(e.target) && !(btn && btn.contains(e.target))){ ' +
    'window.dsHideSessions(); }' + sLineBreak +
    '    }' + sLineBreak +
    '  });' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    (* ---- Command editor (filled by dsShowCommandEditor) ---- *)
    '<div id="ds-cmd-backdrop" style="display:none">' + sLineBreak +
    '  <div id="ds-cmd-modal">' + sLineBreak +
    '    <div class="ds-cmd-head">' + sLineBreak +
    '      <div class="ds-cmd-badge">&#9000;</div>' + sLineBreak +
    '      <div>' + sLineBreak +
    '        <div class="ds-cmd-title" id="ds-cmd-heading">New command</div>' + sLineBreak +
    '        <div class="ds-cmd-sub">A command = a <b>name</b> + a <b>prompt</b>. ' +
    'Becomes <code>/name</code> in the chat.</div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <div class="ds-cmd-editwrap">' + sLineBreak +
    '        <button class="ds-cmd-edit" id="ds-cmd-editexisting" type="button">' +
    '&#9998; Edit existing &#9662;</button>' + sLineBreak +
    '        <div id="ds-cmd-list" style="display:none"></div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <button class="ds-cmd-close" id="ds-cmd-close" type="button">&times;</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-cmd-body">' + sLineBreak +
    '      <div class="ds-cmd-row">' + sLineBreak +
    '        <label>COMMAND NAME</label>' + sLineBreak +
    '        <div class="ds-cmd-namewrap"><span class="ds-cmd-slash">/</span>' +
    '<input id="ds-cmd-name" spellcheck="false" placeholder="my-command"></div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <div class="ds-cmd-row">' + sLineBreak +
    '        <label>DESCRIPTION <span style="color:var(--ds-secondary);' +
    'font-weight:400">(shown in the "/" picker)</span></label>' + sLineBreak +
    '        <input id="ds-cmd-desc" spellcheck="false" ' +
    'placeholder="What this command does">' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <div class="ds-cmd-row">' + sLineBreak +
    '        <label>WHERE TO SAVE</label>' + sLineBreak +
    '        <div class="ds-cmd-scope" id="ds-cmd-scope">' + sLineBreak +
    '          <button type="button" class="ds-cmd-scopebtn ds-scope-on" ' +
    'data-scope="project" id="ds-cmd-scope-project">This project</button>' + sLineBreak +
    '          <button type="button" class="ds-cmd-scopebtn" ' +
    'data-scope="global" id="ds-cmd-scope-global">Global (all projects)</button>' + sLineBreak +
    '        </div>' + sLineBreak +
    '        <div class="ds-cmd-hint" id="ds-cmd-scopehint">Saved in this ' +
    'project&rsquo;s <code>.aefos\commands</code>.</div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '      <div class="ds-cmd-row">' + sLineBreak +
    '        <label>PROMPT (the instructions sent to the AI)</label>' + sLineBreak +
    '        <textarea id="ds-cmd-prompt" spellcheck="false" ' +
    'placeholder="Command instructions&hellip;"></textarea>' + sLineBreak +
    '        <div class="ds-cmd-hint">&#128161; The <b>editor selection</b> and the ' +
    '<b>project context</b> are attached automatically.</div>' + sLineBreak +
    '        <div class="ds-cmd-err" id="ds-cmd-err"></div>' + sLineBreak +
    '      </div>' + sLineBreak +
    '    </div>' + sLineBreak +
    '    <div class="ds-cmd-foot">' + sLineBreak +
    '      <button class="ds-cmd-del" id="ds-cmd-del" type="button">Delete</button>' + sLineBreak +
    '      <span class="ds-cmd-spacer"></span>' + sLineBreak +
    '      <button class="ds-cmd-act" id="ds-cmd-cancel" type="button">Cancel</button>' + sLineBreak +
    '      <button class="ds-cmd-act ds-cmd-primary" id="ds-cmd-save" type="button">' +
    'Save command</button>' + sLineBreak +
    '    </div>' + sLineBreak +
    '  </div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var bd = document.getElementById("ds-cmd-backdrop");' + sLineBreak +
    '  var nameEl = document.getElementById("ds-cmd-name");' + sLineBreak +
    '  var descEl = document.getElementById("ds-cmd-desc");' + sLineBreak +
    '  var promptEl = document.getElementById("ds-cmd-prompt");' + sLineBreak +
    '  var errEl = document.getElementById("ds-cmd-err");' + sLineBreak +
    '  var delEl = document.getElementById("ds-cmd-del");' + sLineBreak +
    '  var headEl = document.getElementById("ds-cmd-heading");' + sLineBreak +
    '  var listEl = document.getElementById("ds-cmd-list");' + sLineBreak +
    '  var scopeProjectEl = document.getElementById("ds-cmd-scope-project");' + sLineBreak +
    '  var scopeGlobalEl = document.getElementById("ds-cmd-scope-global");' + sLineBreak +
    '  var scopeHintEl = document.getElementById("ds-cmd-scopehint");' + sLineBreak +
    '  var curName = "";' + sLineBreak +
    '  var curScope = "project";' + sLineBreak +
    '  function dsSetScope(s){' + sLineBreak +
    '    curScope = (s === "global") ? "global" : "project";' + sLineBreak +
    '    if(scopeProjectEl){ scopeProjectEl.classList.toggle("ds-scope-on", ' +
    'curScope === "project"); }' + sLineBreak +
    '    if(scopeGlobalEl){ scopeGlobalEl.classList.toggle("ds-scope-on", ' +
    'curScope === "global"); }' + sLineBreak +
    '    if(scopeHintEl){ scopeHintEl.innerHTML = (curScope === "global") ? ' +
    '"Saved for <b>every project</b> in <code>%USERPROFILE%\\.aefos\\commands</code>." : ' +
    '"Saved in this project&rsquo;s <code>.aefos\\commands</code>."; }' + sLineBreak +
    '  }' + sLineBreak +
    '  if(scopeProjectEl){ scopeProjectEl.addEventListener("click", function(){ ' +
    'dsSetScope("project"); }); }' + sLineBreak +
    '  if(scopeGlobalEl){ scopeGlobalEl.addEventListener("click", function(){ ' +
    'dsSetScope("global"); }); }' + sLineBreak +
    '  function dsCmdPost(msg){' + sLineBreak +
    '    try{ if(window.chrome && window.chrome.webview){ ' +
    'window.chrome.webview.postMessage(msg); } }catch(e){}' + sLineBreak +
    '  }' + sLineBreak +
    '  window.dsShowCommandEditor = function(d){' + sLineBreak +
    '    d = d || {};' + sLineBreak +
    '    var isNew = (d.isNew !== false);' + sLineBreak +
    '    curName = d.name || "";' + sLineBreak +
    '    if(nameEl){ nameEl.value = curName; nameEl.readOnly = !isNew; }' + sLineBreak +
    '    if(descEl){ descEl.value = d.description || ""; }' + sLineBreak +
    '    if(promptEl){ promptEl.value = d.prompt || ""; }' + sLineBreak +
    '    dsSetScope(d.scope === "global" ? "global" : "project");' + sLineBreak +
    '    if(errEl){ errEl.textContent = ""; }' + sLineBreak +
    '    if(headEl){ headEl.textContent = isNew ? "New command" : ("Edit /" + curName); }' + sLineBreak +
    '    if(delEl){ delEl.style.display = (!isNew && d.canDelete) ? "" : "none"; }' + sLineBreak +
    '    if(listEl){ listEl.style.display = "none"; }' + sLineBreak +
    '    if(bd){ bd.style.display = ""; }' + sLineBreak +
    '    if(nameEl){ try{ (isNew ? nameEl : promptEl).focus(); }catch(e){} }' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsHideCommandEditor = function(){' + sLineBreak +
    '    if(bd){ bd.style.display = "none"; }' + sLineBreak +
    '    if(listEl){ listEl.style.display = "none"; }' + sLineBreak +
    '  };' + sLineBreak +
    '  window.dsSetCommandList = function(items){' + sLineBreak +
    '    if(!listEl) return;' + sLineBreak +
    '    items = items || [];' + sLineBreak +
    '    listEl.innerHTML = "";' + sLineBreak +
    '    if(items.length === 0){ var e = document.createElement("div"); ' +
    'e.className = "ds-cmd-li-empty"; e.textContent = "No editable commands."; ' +
    'listEl.appendChild(e); }' + sLineBreak +
    '    for(var i=0;i<items.length;i++){' + sLineBreak +
    '      var it = items[i];' + sLineBreak +
    '      var li = document.createElement("div"); li.className = "ds-cmd-li";' + sLineBreak +
    '      var b = document.createElement("b"); b.textContent = "/" + (it.name || "");' + sLineBreak +
    '      var s = document.createElement("span"); s.textContent = it.description || "";' + sLineBreak +
    '      li.appendChild(b); li.appendChild(s);' + sLineBreak +
    '      (function(nm){ li.addEventListener("click", function(ev){ ev.stopPropagation(); ' +
    'listEl.style.display = "none"; dsCmdPost("command:load:" + nm); }); })(it.name || "");' + sLineBreak +
    '      listEl.appendChild(li);' + sLineBreak +
    '    }' + sLineBreak +
    '    listEl.style.display = "";' + sLineBreak +
    '  };' + sLineBreak +
    '  var saveEl = document.getElementById("ds-cmd-save");' + sLineBreak +
    '  if(saveEl){ saveEl.addEventListener("click", function(){' + sLineBreak +
    '    var nm = (nameEl ? nameEl.value : "").trim().toLowerCase();' + sLineBreak +
    '    if(!nm || !/^[a-z0-9_-]+$/.test(nm)){' + sLineBreak +
    '      if(errEl){ errEl.textContent = "Invalid name: use only lowercase ' +
    'letters, digits, hyphen or underscore."; }' + sLineBreak +
    '      if(nameEl){ try{ nameEl.focus(); }catch(e){} } return;' + sLineBreak +
    '    }' + sLineBreak +
    '    var obj = { name: nm, description: (descEl ? descEl.value : ""), ' +
    'prompt: (promptEl ? promptEl.value : ""), scope: curScope };' + sLineBreak +
    '    dsCmdPost("command:save:" + JSON.stringify(obj));' + sLineBreak +
    '    window.dsHideCommandEditor();' + sLineBreak +
    '  }); }' + sLineBreak +
    '  var cancelEl = document.getElementById("ds-cmd-cancel");' + sLineBreak +
    '  if(cancelEl){ cancelEl.addEventListener("click", window.dsHideCommandEditor); }' + sLineBreak +
    '  var closeEl = document.getElementById("ds-cmd-close");' + sLineBreak +
    '  if(closeEl){ closeEl.addEventListener("click", window.dsHideCommandEditor); }' + sLineBreak +
    '  if(delEl){ delEl.addEventListener("click", function(){' + sLineBreak +
    '    if(!curName) return;' + sLineBreak +
    '    if(window.confirm("Delete command /" + curName + "?")){ ' +
    'dsCmdPost("command:delete:" + curName); window.dsHideCommandEditor(); }' + sLineBreak +
    '  }); }' + sLineBreak +
    '  var editEl = document.getElementById("ds-cmd-editexisting");' + sLineBreak +
    '  if(editEl){ editEl.addEventListener("click", function(ev){ ev.stopPropagation();' + sLineBreak +
    '    if(listEl && listEl.style.display !== "none"){ listEl.style.display = "none"; return; }' + sLineBreak +
    '    dsCmdPost("command:list");' + sLineBreak +
    '  }); }' + sLineBreak +
    '  if(bd){ bd.addEventListener("click", function(e){ ' +
    'if(e.target === bd){ window.dsHideCommandEditor(); } }); }' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    (* The permission card -- markup AND behaviour spliced from the shared
       constants above. The chat panel and the standalone window are the same
       card because they are the same characters. *)
    PERMISSION_HTML +
    PERMISSION_JS +
    '</body>' + sLineBreak +
    '</html>';

implementation

end.