unit Aefos.OTA.Terminal.UI.WelcomeHtml;

{
  WebView2 welcome/home HTML for the Terminal (2026-06-09). Mirrors the chat's
  empty-state look: centered logo (embedded base64 data URI) + greeting + shell
  launch cards. Pure string builder — no ToolsAPI, no VCL.

  JS <-> Pascal bridge (TWelcomeWebPane wires it):
    Pascal -> JS : window.dsSetProfiles(json)
    JS -> Pascal : window.chrome.webview.postMessage('launch:<index>')
}

interface

// Full HTML document for the welcome pane (logo data URI baked in).
function BuildWelcomeHtml: string;

implementation

uses
  System.SysUtils,
  Aefos.OTA.Terminal.UI.WelcomeAssets;

function BuildWelcomeHtml: string;
begin
  Result :=
    '<!DOCTYPE html>' + sLineBreak +
    '<html lang="en"><head><meta charset="utf-8">' + sLineBreak +
    '<style>' + sLineBreak +
    ':root{--bg:#1b1f26;--card:#2a313b;--card-hi:#323a46;--line:#3a424e;' +
    '--fg:#e8ebef;--fg2:#9aa4b2;--accent:#d97757;--blue:#2a98ff;--gray:#8a93a0;}' + sLineBreak +
    '*{box-sizing:border-box}' + sLineBreak +
    'html,body{margin:0;padding:0;height:100%}' + sLineBreak +
    'body{background:var(--bg);color:var(--fg);font:14px/1.45 ''Segoe UI'',system-ui,sans-serif;' +
    '-webkit-font-smoothing:antialiased;overflow:auto}' + sLineBreak +
    '.home{max-width:680px;margin:0 auto;padding:40px 28px 48px;text-align:center}' + sLineBreak +
    '.logo{width:104px;height:104px;margin:6px auto 14px;display:block;object-fit:contain;' +
    'filter:drop-shadow(0 6px 20px #0007)}' + sLineBreak +
    'h1{margin:0 0 6px;font-size:22px;font-weight:800;letter-spacing:.2px}' + sLineBreak +
    '.sub{margin:0 0 30px;color:var(--fg2);font-size:13.5px}' + sLineBreak +
    '.news{display:flex;gap:14px;justify-content:center;flex-wrap:wrap;margin-bottom:30px}' + sLineBreak +
    '.ncard{flex:1 1 200px;min-width:180px;max-width:300px;text-align:left;background:var(--card);border:1px solid var(--line);' +
    'border-radius:12px;padding:14px 16px;cursor:pointer;transition:.12s;display:flex;' +
    'align-items:center;gap:13px}' + sLineBreak +
    '.ncard:hover{background:var(--card-hi);border-color:#4a5260;transform:translateY(-1px)}' + sLineBreak +
    '.nicon{width:38px;height:38px;border-radius:9px;display:flex;align-items:center;' +
    'justify-content:center;font-size:18px;flex:0 0 auto;background:#2a98ff22;color:#7cc0ff}' + sLineBreak +
    '.ncard .nt{font-weight:700;font-size:14.5px;' +
    'overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' + sLineBreak +
    '.ncard .nd{color:var(--fg2);font-size:12px;margin-top:1px;' +
    'overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' + sLineBreak +
    '.nmid{flex:1;min-width:0;overflow:hidden}' + sLineBreak +
    '.ncard .go{margin-left:auto;color:var(--accent);font-weight:800}' + sLineBreak +
    '</style></head><body>' + sLineBreak +
    '<div class="home">' + sLineBreak +
    '  <img class="logo" src="data:image/png;base64,' + WelcomeLogoBase64 + '" alt="">' + sLineBreak +
    '  <h1>Welcome to Aefos Terminal</h1>' + sLineBreak +
    '  <div class="sub">Start a new shell or jump back into a session.</div>' + sLineBreak +
    '  <div id="news" class="news"></div>' + sLineBreak +
    '</div>' + sLineBreak +
    '<script>' + sLineBreak +
    'function dsPost(m){ try{ if(window.chrome&&window.chrome.webview)' +
    ' window.chrome.webview.postMessage(m); }catch(e){} }' + sLineBreak +
    'function dsEl(t,c){ var e=document.createElement(t); if(c) e.className=c; return e; }' + sLineBreak +
    'window.dsSetProfiles=function(list){' + sLineBreak +
    '  var host=document.getElementById("news"); host.innerHTML="";' + sLineBreak +
    '  (list||[]).forEach(function(p){' + sLineBreak +
    '    var card=dsEl("div","ncard");' + sLineBreak +
    '    var ic=dsEl("div","nicon"); if(p.dot) ic.style.color=p.dot; ic.textContent=String.fromCharCode(0x276F);' + sLineBreak +
    '    var mid=dsEl("div","nmid");' + sLineBreak +
    '    var nt=dsEl("div","nt"); nt.textContent="New "+p.name;' + sLineBreak +
    '    var nd=dsEl("div","nd"); nd.textContent=p.summary||"";' + sLineBreak +
    '    mid.appendChild(nt); mid.appendChild(nd);' + sLineBreak +
    '    var go=dsEl("div","go"); go.textContent=String.fromCharCode(0x25B8);' + sLineBreak +
    '    card.appendChild(ic); card.appendChild(mid); card.appendChild(go);' + sLineBreak +
    '    card.addEventListener("click",function(){ dsPost("launch:"+p.index); });' + sLineBreak +
    '    host.appendChild(card);' + sLineBreak +
    '  });' + sLineBreak +
    '};' + sLineBreak +
    'dsPost("ready");' + sLineBreak +
    '</script></body></html>';
end;

end.
