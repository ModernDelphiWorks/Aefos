unit Aefos.OTA.Terminal.UI.ComposerHtml;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  HTML/CSS/JS for the Terminal's AI composer bar - a chat-style prompt input the
  user drives from the terminal footer (toggled by the toolbar 'AI' button). It
  mirrors the chat composer's look: a rounded dark box holding the textarea, an
  action bar below it with monochrome SVG icons (paperclip attach + brain memory)
  on the left and the orange round send on the right. No model picker / agent
  toggle (not meaningful here). Hosted in the same composition TAefosWebView the
  WelcomeWebPane uses (no new dependency).

  The '/' command picker is NOT drawn here - a webview can only paint inside its
  own footer strip, so a long list would push the terminal up. Instead the picker
  is a floating VCL window (Aefos.OTA.Terminal.UI.ComposerPicker) that overlays
  the terminal. This doc keeps keyboard ownership (focus stays in the textarea)
  and posts the user's intent to the Pascal side, which drives that window.

  Bridge:
    Pascal -> JS : window.dsClear()             // clear the input after a commit
                   window.dsSetAttachments(list) // list = [{id,name}] chip bar
    JS -> Pascal : 'ready'
                   'height:<px>'                // grow the bar for multi-line text
                   'send:<text>'                // Enter with no picker open
                   'filter:<query>'             // input starts with '/', query = rest
                   'navdown' | 'navup'          // arrow keys while picker open
                   'commit'                     // Enter while picker open
                   'cancel'                     // Escape / input no longer a slash
                   'attach:open'                // paperclip clicked
                   'attach:remove:<id>'         // chip's X clicked
                   'memory:open'                // brain clicked

  ASCII-only source: every glyph (icons + X) is an inline monochrome SVG using
  stroke="currentColor", so the .pas needs no BOM and nothing renders as an emoji.
*)

interface

{ The full composer document (self-contained; UTF-8). }
function BuildComposerHtml: string;

implementation

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF};

function BuildComposerHtml: string;
const
  NL = #10;
  // Reusable inline SVGs (stroke = currentColor so each button controls the tint).
  SVG_CLIP =
    '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" ' +
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
    'stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49' +
    'l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>';
  SVG_BRAIN =
    '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" ' +
    'stroke="currentColor" stroke-width="1.7" stroke-linecap="round" ' +
    'stroke-linejoin="round"><path d="M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 ' +
    '5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z"/><path d="M12 5a3 3 0 1 1 5.997' +
    '.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z"/></svg>';
  SVG_SEND =
    '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" ' +
    'stroke="currentColor" stroke-width="2.2" stroke-linecap="round" ' +
    'stroke-linejoin="round"><path d="M12 19V5"/><path d="m5 12 7-7 7 7"/></svg>';
  SVG_FILE =
    '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" ' +
    'stroke="currentColor" stroke-width="1.8" stroke-linecap="round" ' +
    'stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12' +
    'a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>';
  SVG_X =
    '<svg viewBox="0 0 24 24" width="11" height="11" fill="none" ' +
    'stroke="currentColor" stroke-width="2.4" stroke-linecap="round">' +
    '<path d="M18 6 6 18M6 6l12 12"/></svg>';
begin
  Result :=
    '<!doctype html><html><head><meta charset="utf-8">' + NL +
    '<style>' + NL +
    'html,body{margin:0;height:100%;background:#1e1e1e;overflow:hidden;' + NL +
    ' font-family:"Segoe UI",system-ui,sans-serif;}' + NL +
    '#wrap{box-sizing:border-box;min-height:100%;padding:8px 10px;' + NL +
    ' display:flex;flex-direction:column;justify-content:flex-end;}' + NL +
    '#chips{display:flex;flex-wrap:wrap;gap:8px;padding:0 2px 8px;}' + NL +
    '#chips:empty{display:none;}' + NL +
    '.chip{position:relative;display:flex;align-items:center;gap:6px;' + NL +
    ' max-width:190px;background:#242427;border:1px solid #3a3a3c;' + NL +
    ' border-radius:9px;padding:4px 9px 4px 8px;}' + NL +
    '.chip .ic{color:#9a9a9a;display:flex;}' + NL +
    '.chip .nm{font-size:11px;color:#c8c8c8;overflow:hidden;' + NL +
    ' text-overflow:ellipsis;white-space:nowrap;}' + NL +
    '.chip .x{width:17px;height:17px;min-width:17px;border:none;' + NL +
    ' border-radius:50%;background:rgba(20,22,28,0.92);color:#fff;' + NL +
    ' cursor:pointer;padding:0;display:flex;align-items:center;' + NL +
    ' justify-content:center;}' + NL +
    '.chip .x:hover{background:#e0664a;}' + NL +
    '#box{background:#2a2a2b;border:1px solid #3a3a3c;border-radius:16px;' + NL +
    ' padding:9px 12px 8px;}' + NL +
    '#inp{display:block;width:100%;box-sizing:border-box;background:transparent;' + NL +
    ' border:none;outline:none;color:#e6e6e6;font-size:14px;resize:none;' + NL +
    ' max-height:120px;line-height:1.45;font-family:inherit;}' + NL +
    '#inp::placeholder{color:#8a8a8a;}' + NL +
    '#actbar{display:flex;align-items:center;gap:2px;margin-top:6px;}' + NL +
    '#sp{flex:1;}' + NL +
    '.ico{width:30px;height:30px;min-width:30px;border:none;border-radius:8px;' + NL +
    ' background:transparent;color:#9a9a9a;cursor:pointer;display:flex;' + NL +
    ' align-items:center;justify-content:center;}' + NL +
    '.ico:hover{background:rgba(127,127,127,0.16);color:#e6e6e6;}' + NL +
    '#send{width:32px;height:32px;min-width:32px;border:none;border-radius:50%;' + NL +
    ' background:linear-gradient(135deg,#ff9a5c,#f2662f);color:#fff;' + NL +
    ' cursor:pointer;display:flex;align-items:center;justify-content:center;}' + NL +
    '#send:hover{filter:brightness(1.07);}' + NL +
    '</style></head><body>' + NL +
    '<div id="wrap">' + NL +
    '  <div id="chips"></div>' + NL +
    '  <div id="box">' + NL +
    '    <textarea id="inp" rows="1" spellcheck="false" ' + NL +
    '      placeholder="Message Aefos&hellip;   (type / for a command)"></textarea>' + NL +
    '    <div id="actbar">' + NL +
    '      <button id="attach" class="ico" title="Attach a file">' + SVG_CLIP + '</button>' + NL +
    '      <button id="mem" class="ico" title="Edit Aefos memory">' + SVG_BRAIN + '</button>' + NL +
    '      <span id="sp"></span>' + NL +
    '      <button id="send" title="Send (Enter)">' + SVG_SEND + '</button>' + NL +
    '    </div>' + NL +
    '  </div>' + NL +
    '  <template id="tpl-file">' + SVG_FILE + '</template>' + NL +
    '  <template id="tpl-x">' + SVG_X + '</template>' + NL +
    '</div>' + NL +
    '<script>' + NL +
    '(function(){' + NL +
    '  var inp=document.getElementById("inp");' + NL +
    '  var sendBtn=document.getElementById("send");' + NL +
    '  var attachBtn=document.getElementById("attach");' + NL +
    '  var memBtn=document.getElementById("mem");' + NL +
    '  var tplFile=document.getElementById("tpl-file");' + NL +
    '  var tplX=document.getElementById("tpl-x");' + NL +
    '  function icon(t){return t.content.cloneNode(true);}' + NL +
    '  var pickerOpen=false;' + NL +
    '  function post(m){try{if(window.chrome&&window.chrome.webview)' + NL +
    '    window.chrome.webview.postMessage(m);}catch(e){}}' + NL +
    '  function reportHeight(){' + NL +
    '    post("height:"+document.getElementById("wrap").scrollHeight);}' + NL +
    '  function grow(){inp.style.height="auto";' + NL +
    '    inp.style.height=Math.min(inp.scrollHeight,120)+"px";reportHeight();}' + NL +
    '  window.dsSetAttachments=function(list){' + NL +
    '    var bar=document.getElementById("chips");if(!bar)return;bar.innerHTML="";' + NL +
    '    (list||[]).forEach(function(a){' + NL +
    '      var chip=document.createElement("div");chip.className="chip";' + NL +
    '      var ic=document.createElement("span");ic.className="ic";' + NL +
    '      ic.appendChild(icon(tplFile));chip.appendChild(ic);' + NL +
    '      var nm=document.createElement("span");nm.className="nm";' + NL +
    '      nm.textContent=a.name;nm.title=a.name;chip.appendChild(nm);' + NL +
    '      var x=document.createElement("button");x.type="button";' + NL +
    '      x.className="x";x.appendChild(icon(tplX));x.title="Remove";' + NL +
    '      x.addEventListener("click",function(){post("attach:remove:"+a.id);});' + NL +
    '      chip.appendChild(x);bar.appendChild(chip);' + NL +
    '    });' + NL +
    '    reportHeight();' + NL +
    '  };' + NL +
    '  window.dsClear=function(){inp.value="";pickerOpen=false;' + NL +
    '    window.dsSetAttachments([]);grow();};' + NL +
    '  function sendNow(){var t=inp.value.trim();if(!t)return;' + NL +
    '    post("send:"+t);inp.value="";pickerOpen=false;grow();}' + NL +
    '  function isSlash(v){' + NL +
    '    return v.length>0&&v.charAt(0)==="/"&&v.indexOf(" ")<0;}' + NL +
    '  inp.addEventListener("input",function(){grow();' + NL +
    '    var v=inp.value;' + NL +
    '    if(isSlash(v)){pickerOpen=true;post("filter:"+v.substring(1));}' + NL +
    '    else if(pickerOpen){pickerOpen=false;post("cancel");}});' + NL +
    '  inp.addEventListener("keydown",function(e){' + NL +
    '    if(pickerOpen){' + NL +
    '      if(e.key==="ArrowDown"){e.preventDefault();post("navdown");return;}' + NL +
    '      if(e.key==="ArrowUp"){e.preventDefault();post("navup");return;}' + NL +
    '      if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();post("commit");return;}' + NL +
    '      if(e.key==="Escape"){e.preventDefault();pickerOpen=false;post("cancel");return;}}' + NL +
    '    if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();sendNow();}});' + NL +
    '  sendBtn.addEventListener("click",sendNow);' + NL +
    '  attachBtn.addEventListener("click",function(){post("attach:open");});' + NL +
    '  memBtn.addEventListener("click",function(){post("memory:open");});' + NL +
    '  window.addEventListener("load",function(){' + NL +
    '    post("ready");reportHeight();inp.focus();});' + NL +
    '})();' + NL +
    '</script></body></html>';
end;

end.
