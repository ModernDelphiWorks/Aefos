unit Aefos.OTA.UI.MCPToolInspector.Assets;

(*
  Pure HTML/JS for the MCP Tool Inspector page (ADR-117). A string builder only -
  NO VCL, NO ToolsAPI, NO server reference - mirroring the chat/welcome WebView2
  asset units. Fully decoupled: the page knows nothing about who answers 'run'.

  Pascal -> JS : window.insSetTools(json)   // [{ "name", "description" }]
                 window.insSetResult(json)  // { request, response, audit_delta, diff }
                 window.insSetError(text)   // a one-line error banner
  JS -> Pascal : 'ready'
                 'run:' + JSON.stringify({ "tool": "<name>", "args": {<obj>} })
*)

interface

function BuildInspectorHtml: string;

implementation

uses
  System.SysUtils;

function BuildInspectorHtml: string;
begin
  Result :=
    '<!DOCTYPE html><html><head><meta charset="utf-8">' + sLineBreak +
    '<style>' + sLineBreak +
    '  :root { --bg:#1e1e1e; --panel:#252526; --line:#3c3c3c; --fg:#d4d4d4;' +
    ' --dim:#9c9c9c; --accent:#e8772e; --ok:#3fae5a; --err:#e25555; }' + sLineBreak +
    '  * { box-sizing:border-box; }' + sLineBreak +
    '  html,body { margin:0; height:100%; background:var(--bg); color:var(--fg);' +
    ' font-family:"Segoe UI",sans-serif; font-size:13px; }' + sLineBreak +
    '  body { display:flex; flex-direction:column; }' + sLineBreak +
    '  .bar { display:flex; gap:8px; align-items:center; padding:8px 10px;' +
    ' border-bottom:1px solid var(--line); background:var(--panel); }' + sLineBreak +
    '  .bar select { flex:1 1 auto; min-width:0; background:var(--bg); color:var(--fg);' +
    ' border:1px solid var(--line); border-radius:4px; padding:5px 7px; font-size:13px; }' + sLineBreak +
    '  .bar button { flex:0 0 auto; background:var(--accent); color:#fff; border:none;' +
    ' border-radius:4px; padding:6px 16px; font-weight:600; cursor:pointer; }' + sLineBreak +
    '  .desc { padding:5px 10px; color:var(--dim); font-size:11px;' +
    ' border-bottom:1px solid var(--line); line-height:1.35; }' + sLineBreak +
    '  .bar button:active { transform:translateY(1px); }' + sLineBreak +
    '  .args { padding:8px 10px; border-bottom:1px solid var(--line); }' + sLineBreak +
    '  .args label { color:var(--dim); font-size:11px; }' + sLineBreak +
    '  .args textarea { width:100%; height:64px; resize:vertical; margin-top:4px;' +
    ' background:var(--bg); color:var(--fg); border:1px solid var(--line);' +
    ' border-radius:4px; padding:6px 8px; font-family:"Cascadia Mono",Consolas,monospace;' +
    ' font-size:12px; }' + sLineBreak +
    '  #err { display:none; margin:6px 10px 0; padding:6px 8px; border-radius:4px;' +
    ' background:rgba(226,85,85,.12); color:var(--err); font-size:12px; }' + sLineBreak +
    '  .panes { flex:1; display:flex; flex-direction:column; overflow:auto; }' + sLineBreak +
    '  .pane { border-top:1px solid var(--line); }' + sLineBreak +
    '  .pane h4 { margin:0; padding:6px 10px; font-size:11px; letter-spacing:.5px;' +
    ' color:var(--dim); text-transform:uppercase; background:var(--panel); }' + sLineBreak +
    '  .pane pre { margin:0; padding:8px 10px; white-space:pre-wrap; word-break:break-word;' +
    ' font-family:"Cascadia Mono",Consolas,monospace; font-size:12px; color:var(--fg); }' + sLineBreak +
    '  .empty { color:var(--dim); padding:20px; text-align:center; font-size:12px; }' + sLineBreak +
    '</style></head><body>' + sLineBreak +
    '  <div class="bar">' + sLineBreak +
    '    <select id="tool"><option value="">(loading tools...)</option></select>' + sLineBreak +
    '    <button id="run">Run</button>' + sLineBreak +
    '  </div>' + sLineBreak +
    '  <div id="tooldesc" class="desc"></div>' + sLineBreak +
    '  <div class="args">' + sLineBreak +
    '    <label for="args">Arguments (JSON)</label>' + sLineBreak +
    '    <textarea id="args" spellcheck="false">{}</textarea>' + sLineBreak +
    '  </div>' + sLineBreak +
    '  <div id="err"></div>' + sLineBreak +
    '  <div class="panes">' + sLineBreak +
    '    <div class="pane"><h4>Request</h4><pre id="req"></pre></div>' + sLineBreak +
    '    <div class="pane"><h4>Response</h4><pre id="resp"></pre></div>' + sLineBreak +
    '    <div class="pane"><h4>Audit-log delta</h4><pre id="audit"></pre></div>' + sLineBreak +
    '  </div>' + sLineBreak +
    '<script>' + sLineBreak +
    '  function post(m){ try{ if(window.chrome && window.chrome.webview)' +
    ' window.chrome.webview.postMessage(m); }catch(e){} }' + sLineBreak +
    '  function $(id){ return document.getElementById(id); }' + sLineBreak +
    '  function showErr(t){ var e=$("err"); if(!t){ e.style.display="none"; return; }' +
    ' e.textContent=t; e.style.display="block"; }' + sLineBreak +
    '  function updateDesc(){ var s=$("tool"), d="";' +
    ' if(s.selectedOptions && s.selectedOptions[0]) d=s.selectedOptions[0].getAttribute("data-desc")||"";' +
    ' $("tooldesc").textContent=d; }' + sLineBreak +
    '  window.insSetTools = function(list){' + sLineBreak +
    '    var sel=$("tool"); sel.innerHTML="";' + sLineBreak +
    '    if(!list || !list.length){ sel.innerHTML=''<option value="">(no tools)</option>'';' +
    ' $("tooldesc").textContent=""; return; }' + sLineBreak +
    '    for(var i=0;i<list.length;i++){ var o=document.createElement("option");' +
    ' o.value=list[i].name; o.textContent=list[i].name;' +
    ' o.setAttribute("data-desc", list[i].description||""); sel.appendChild(o); }' + sLineBreak +
    '    updateDesc();' + sLineBreak +
    '  };' + sLineBreak +
    '  $("tool").addEventListener("change", updateDesc);' + sLineBreak +
    '  window.insSetResult = function(p){' + sLineBreak +
    '    showErr("");' + sLineBreak +
    '    $("req").textContent  = p && p.request  ? JSON.stringify(p.request,  null, 2) : "";' + sLineBreak +
    '    $("resp").textContent = p && p.response ? JSON.stringify(p.response, null, 2) : "";' + sLineBreak +
    '    $("audit").textContent= p && p.audit_delta ? JSON.stringify(p.audit_delta, null, 2) : "[]";' + sLineBreak +
    '  };' + sLineBreak +
    '  window.insSetError = function(t){ showErr(t); };' + sLineBreak +
    '  $("run").addEventListener("click", function(){' + sLineBreak +
    '    var tool=$("tool").value;' + sLineBreak +
    '    if(!tool){ showErr("Pick a tool first."); return; }' + sLineBreak +
    '    var raw=($("args").value||"").trim(); if(raw==="") raw="{}";' + sLineBreak +
    '    var args; try{ args=JSON.parse(raw); }catch(e){ showErr("Args are not valid JSON: "+e.message); return; }' + sLineBreak +
    '    showErr(""); $("resp").textContent="running...";' + sLineBreak +
    '    post("run:" + JSON.stringify({ tool: tool, args: args }));' + sLineBreak +
    '  });' + sLineBreak +
    '  post("ready");' + sLineBreak +
    '</script></body></html>';
end;

end.
