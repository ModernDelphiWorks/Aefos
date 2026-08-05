unit Aefos.MCP.OTA.FacadeShared;

{
  Shared OTA helper functions hoisted out of the TMCPWorkspaceFacade god-object
  during the SOLID split (audit S6 / facade split), so the extracted domain
  services AND the facade itself draw them from ONE place instead of the facade
  owning them privately. Pure relocations — the bodies are byte-for-byte the same
  as when they lived in the facade; only their home (the sealed static class
  TFacadeShared) changes. The old misleading `_` prefix (it read "private" yet
  they were public) is dropped with the move; call sites qualify as
  TFacadeShared.Name.

  Tiers hoisted so far:
    1. Active-context getters: TryProject, TryModuleServices.
    2. Project options / .dproj / IDE-library-path getters (this tier) — the
       self-contained read/resolve/write helpers the config, paths and
       project-read/write services share. Each depends only on TryProject + RTL +
       ToolsAPI.

  RTL + ToolsAPI only — no Aefos coupling, no cycle; stays in the MCP.Tools.OTA BPL.
}

interface

uses
  ToolsAPI;

type
  // The shared OTA helper surface as a sealed static namespace (facade split,
  // audit S6). The extracted domain services AND the facade itself draw these
  // from ONE place. Never instantiated — the class is the namespace. Bodies are
  // byte-for-byte the same as when they lived as loose routines / in the facade;
  // only their home and the misleading `_` prefix change (the `_` read "private"
  // yet they were public).
  TFacadeShared = class sealed
  public
    // --- Tier 1: active context -----------------------------------------------
    // Active project via IOTAModuleServices.GetActiveProject (main-thread caller).
    // False (and AProject nil) when there are no IDE services or no active project.
    class function TryProject(out AProject: IOTAProject): Boolean; static;

    // IOTAModuleServices from BorlandIDEServices. False when unavailable.
    class function TryModuleServices(out AServices: IOTAModuleServices): Boolean; static;

    // --- Tier 2: project options / .dproj / IDE library path ------------------
    // Reads the active project's .dproj XML text from disk (resolves the path on the
    // main thread, then reads the file). '' when no project / file missing / read fails.
    class function ReadActiveDProjXml: string; static;

    // The active project's IOTAProjectOptions. False when no project / no options.
    class function TryProjectOptions(out AOptions: IOTAProjectOptions): Boolean; static;

    // Resolves an option key by probing AAlternates against the project's live option
    // names (cross-release drift). '' when none match.
    class function ResolveOptionKey(const AOptions: IOTAProjectOptions;
      const AAlternates: array of string): string; static;

    // Reads a project-option string value via the IOTAProjectOptions.Values getter.
    class function ReadOptionString(const AOptions: IOTAProjectOptions;
      const AKey: string): string; static;

    // ResolveOptionKey, but falls back to the canonical first alternate when the
    // project exposes none yet, so a first-time write lands on a well-known name.
    class function ResolveOrDefaultKey(const AOptions: IOTAProjectOptions;
      const AAlternates: array of string): string; static;

    // Writes a project-option string value via the IOTAProjectOptions.Values setter.
    class function WriteOptionString(const AOptions: IOTAProjectOptions;
      const AKey, AValue: string): Boolean; static;

    // Reads the IDE-global library path (IOTAEnvironmentOptions.Values).
    class function ReadIDELibraryPathRaw: string; static;

    // Writes the IDE-global library path — the only IDE-global write surface.
    class function WriteIDELibraryPathRaw(const AValue: string): Boolean; static;

    // --- Tier 3: editor / source-buffer access --------------------------------
    // The active edit view's buffer (IOTAEditorServices.TopView.Buffer). False when
    // no editor/view is active.
    class function TryBuffer(out ABuffer: IOTAEditBuffer): Boolean; static;

    // Reads the full text from an IOTAEditReader (UTF-8, up to 256 KB). '' when the
    // reader is nil or empty.
    class function ReadBytes(const AReader: IOTAEditReader): string; static;

    // The first IOTASourceEditor of AModule (nil when the module has none).
    class function FirstSourceEditor(const AModule: IOTAModule): IOTASourceEditor; static;

    // The IOTASourceEditor of the IDE's current editor module — the active scratch
    // unit for buffer edits. False when no source editor is active.
    class function ActiveSourceEditor(out ASource: IOTASourceEditor): Boolean; static;

    // True when any of the module's editor buffers has unsaved changes. Backs the
    // soft-write save/close paths and the build pre-save.
    class function IsModuleModified(const AModule: IOTAModule): Boolean; static;

    // Serializes AModule's live (possibly unsaved) design form to text DFM via the
    // VCL streaming system — the Designer's in-memory truth, not the stale on-disk
    // .dfm. False when the module holds no live IOTAFormEditor (caller may fall back
    // to the disk file). Shared by the form-designer reads AND the pas<->dfm desync
    // guard on the wholesale editor write. Main thread only (callers Synchronize).
    class function TryModuleLiveDfmText(const AModule: IOTAModule;
      out AText: string): Boolean; static;

    // --- Tier 4: unit resolution ----------------------------------------------
    // Resolves a unit by bare name or path (retries with `.pas` for a bare name).
    class function ResolveUnitModule(const AUnitNameOrPath: string;
      out AModule: IOTAModule): Boolean; static;

    // The `.pas` paths of every module in the active project.
    class function EnumProjectUnitPaths: TArray<string>; static;

    // Finds the first source editor + its body text for a loaded module by path/name.
    class function FindSourceForPath(const APath: string;
      out ASource: IOTASourceEditor; out ABody: string): Boolean; static;

    // Resolves a unit to its `.pas` path (OTA FindModule, then project-scan
    // fallback). Must be called from within TThread.Synchronize.
    class function FindUnitPath(const AUnitNameOrPath: string): string; static;

    // --- Tier 5: whole-buffer write primitive ---------------------------------
    // The single OTA content-write primitive (ESP-087, S2 / R1): replace ASource's
    // whole buffer with ANewText in one undoable IOTAEditWriter action, so D3
    // UndoEditor restores the scratch baseline between drives. Every buffer write
    // funnels through here after its pure surgery in ContentWritePolicy. Edit-writer
    // offsets are UTF-8 byte positions, so the delete length is the byte length of
    // the current buffer. Caller marshals to the main thread (BR7).
    class function ReplaceWholeBuffer(const ASource: IOTASourceEditor;
      const ANewText: string): Boolean; static;

    // 1-based line number of char offset AOffset within ABuf (counts the #10s before
    // it). After a whole-buffer replace we know WHERE the freshly injected method
    // text sits, but the editor still opens at the old caret — this turns that text
    // offset into the line that EnsureCodeView scrolls into view. AOffset <= 0
    // (e.g. a Pos miss) yields 1, which the caller treats as "no reliable line".
    class function LineOfOffset(const ABuf: string; const AOffset: Integer): Integer; static;

    // AI-flow fix (ToolsAPI:3186 — "Reloads the file/project from disk"): after a
    // DISK write to a file that may be open in the IDE, reload its module in place
    // with IOTAModule.Refresh(True). The buffer/designer re-syncs immediately, so
    // the IDE's "file has been changed, reload?" dialog never fires AND the open
    // tab live-updates with the new code instead of being closed. No-op when the
    // file is not open. A .dfm is keyed by its unit source — retry with .pas.
    class procedure RefreshModuleFromDisk(const APath: string); static;

    // Persists ANewSource for the unit at APath so a follow-up disk read observes
    // the change (R5). When the unit is open in the editor the write goes through
    // the undoable source-editor buffer + IOTAModule.Save (reversible, AC7); when it
    // is not open the file is written directly. Runs on the OTA main thread.
    class function WriteUnitSource(const APath, ANewSource: string): Boolean; static;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Variants,
  System.Generics.Collections,
  System.IOUtils;

class function TFacadeShared.TryProject(out AProject: IOTAProject): Boolean;
var
  LMS: IOTAModuleServices;
begin
  AProject := nil;
  Result := False;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
  AProject := LMS.GetActiveProject;
  Result := Assigned(AProject);
end;

class function TFacadeShared.TryModuleServices(out AServices: IOTAModuleServices): Boolean;
begin
  AServices := nil;
  Result := False;
  if not Assigned(BorlandIDEServices) then Exit;
  Result := Supports(BorlandIDEServices, IOTAModuleServices, AServices);
end;

class function TFacadeShared.ReadActiveDProjXml: string;
var
  LDProjPath: string;
begin
  Result := '';
  LDProjPath := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if TFacadeShared.TryProject(LProject) then
        LDProjPath := LProject.FileName;
    end);
  except
    LDProjPath := '';
  end;
  if (LDProjPath = '') or not TFile.Exists(LDProjPath) then
    Exit;
  try
    Result := TFile.ReadAllText(LDProjPath);
  except
    Result := '';
  end;
end;

class function TFacadeShared.TryProjectOptions(out AOptions: IOTAProjectOptions): Boolean;
var
  LProject: IOTAProject;
begin
  AOptions := nil;
  Result := False;
  if not TryProject(LProject) then Exit;
  AOptions := LProject.ProjectOptions;
  Result := Assigned(AOptions);
end;

class function TFacadeShared.ResolveOptionKey(const AOptions: IOTAProjectOptions;
  const AAlternates: array of string): string;
var
  LNames: TOTAOptionNameArray;
  LFor, LIdx: Integer;
begin
  Result := '';
  if not Assigned(AOptions) then Exit;
  try
    LNames := AOptions.GetOptionNames;
  except
    SetLength(LNames, 0);
  end;
  for LFor := Low(AAlternates) to High(AAlternates) do
    for LIdx := 0 to High(LNames) do
      if SameText(LNames[LIdx].Name, AAlternates[LFor]) then
        Exit(LNames[LIdx].Name);
end;

class function TFacadeShared.ReadOptionString(const AOptions: IOTAProjectOptions;
  const AKey: string): string;
begin
  Result := '';
  try
    Result := VarToStr(AOptions.Values[AKey]);
  except
    Result := '';
  end;
end;

class function TFacadeShared.ResolveOrDefaultKey(const AOptions: IOTAProjectOptions;
  const AAlternates: array of string): string;
begin
  Result := ResolveOptionKey(AOptions, AAlternates);
  if (Result = '') and (Length(AAlternates) > 0) then
    Result := AAlternates[Low(AAlternates)];
end;

class function TFacadeShared.WriteOptionString(const AOptions: IOTAProjectOptions;
  const AKey, AValue: string): Boolean;
begin
  Result := False;
  if not Assigned(AOptions) or (AKey = '') then Exit;
  try
    AOptions.Values[AKey] := AValue;
    Result := True;
  except
    Result := False;
  end;
end;

class function TFacadeShared.ReadIDELibraryPathRaw: string;
var
  LServices: IOTAServices;
  LOptions: IOTAEnvironmentOptions;
begin
  Result := '';
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then Exit;
  try
    LOptions := LServices.GetEnvironmentOptions;
    if not Assigned(LOptions) then Exit;
    Result := VarToStr(LOptions.Values['LibraryPath']);
  except
    Result := '';
  end;
end;

class function TFacadeShared.WriteIDELibraryPathRaw(const AValue: string): Boolean;
var
  LServices: IOTAServices;
  LOptions: IOTAEnvironmentOptions;
begin
  Result := False;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then Exit;
  try
    LOptions := LServices.GetEnvironmentOptions;
    if not Assigned(LOptions) then Exit;
    LOptions.Values['LibraryPath'] := AValue;
    Result := True;
  except
    Result := False;
  end;
end;

class function TFacadeShared.TryBuffer(out ABuffer: IOTAEditBuffer): Boolean;
var
  LES: IOTAEditorServices;
  LView: IOTAEditView;
begin
  ABuffer := nil;
  Result := False;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then Exit;
  LView := LES.TopView;
  if not Assigned(LView) then Exit;
  ABuffer := LView.Buffer;
  Result := Assigned(ABuffer);
end;

class function TFacadeShared.ReadBytes(const AReader: IOTAEditReader): string;
const
  CChunk = 256 * 1024;
var
  LChunk, LAll: TBytes;
  LRead, LPos, LTotal: Integer;
begin
  // R2: read the WHOLE buffer, chunk by chunk, instead of a single 256KB GetText. The old
  // single read capped at 256KB, and ReplaceWholeBuffer derived DeleteTo() from that capped
  // length — so on a unit >256KB the delete removed only the first 256KB and the original tail
  // survived (silent corruption = new text + stale tail). Reading fully fixes read AND replace.
  Result := '';
  if not Assigned(AReader) then Exit;
  SetLength(LChunk, CChunk);
  LPos := 0;
  LTotal := 0;
  repeat
    LRead := AReader.GetText(LPos, PAnsiChar(@LChunk[0]), CChunk);
    if LRead > 0 then
    begin
      if LTotal + LRead > Length(LAll) then
        SetLength(LAll, (LTotal + LRead) * 2 + CChunk);
      Move(LChunk[0], LAll[LTotal], LRead);
      Inc(LTotal, LRead);
      Inc(LPos, LRead);
    end;
  until LRead < CChunk; // a short (or zero) read means we reached the buffer end
  if LTotal > 0 then
    Result := TEncoding.UTF8.GetString(LAll, 0, LTotal);
end;

class function TFacadeShared.FirstSourceEditor(const AModule: IOTAModule): IOTASourceEditor;
var
  LEdIdx: Integer;
begin
  Result := nil;
  if not Assigned(AModule) then Exit;
  for LEdIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LEdIdx), IOTASourceEditor, Result) then
      Exit;
  Result := nil;
end;

class function TFacadeShared.ActiveSourceEditor(out ASource: IOTASourceEditor): Boolean;
var
  LMS: IOTAModuleServices;
  LModule: IOTAModule;
begin
  Result := False;
  ASource := nil;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
  LModule := LMS.CurrentModule;
  if not Assigned(LModule) then Exit;
  ASource := FirstSourceEditor(LModule);
  Result := Assigned(ASource);
end;

class function TFacadeShared.ResolveUnitModule(const AUnitNameOrPath: string;
  out AModule: IOTAModule): Boolean;
var
  LServices: IOTAModuleServices;
begin
  AModule := nil;
  Result := False;
  if AUnitNameOrPath = '' then Exit;
  if not TryModuleServices(LServices) then Exit;
  AModule := LServices.FindModule(AUnitNameOrPath);
  // Retry with `.pas` only for bare unit names. Dotted names like
  // "Aefos.MCP.AuditLog" have ExtractFileExt = ".AuditLog" (not ""),
  // so check for path separators instead of relying on ExtractFileExt = ''.
  if not Assigned(AModule)
    and (Pos('\', AUnitNameOrPath) = 0) and (Pos('/', AUnitNameOrPath) = 0)
    and not SameText(ExtractFileExt(AUnitNameOrPath), '.pas') then
    AModule := LServices.FindModule(AUnitNameOrPath + '.pas');
  Result := Assigned(AModule);
end;

class function TFacadeShared.EnumProjectUnitPaths: TArray<string>;
var
  LProject: IOTAProject;
  LFor: Integer;
  LInfo: IOTAModuleInfo;
  LList: TList<string>;
begin
  SetLength(Result, 0);
  if not TryProject(LProject) then Exit;
  LList := TList<string>.Create;
  try
    for LFor := 0 to LProject.GetModuleCount - 1 do
    begin
      LInfo := LProject.GetModule(LFor);
      if not Assigned(LInfo) then Continue;
      if SameText(ExtractFileExt(LInfo.FileName), '.pas') then
        LList.Add(LInfo.FileName);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class function TFacadeShared.FindSourceForPath(const APath: string;
  out ASource: IOTASourceEditor; out ABody: string): Boolean;
var
  LMS: IOTAModuleServices;
  LModule: IOTAModule;
  LIdx: Integer;
  LEditor: IOTAEditor;
begin
  Result := False;
  ASource := nil;
  ABody := '';
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
  LModule := LMS.FindModule(APath);
  if not Assigned(LModule) then Exit;
  for LIdx := 0 to LModule.GetModuleFileCount - 1 do
  begin
    LEditor := LModule.GetModuleFileEditor(LIdx);
    if Supports(LEditor, IOTASourceEditor, ASource) then
    begin
      ABody := ReadBytes(ASource.CreateReader);
      Result := True;
      Exit;
    end;
  end;
end;

class function TFacadeShared.FindUnitPath(const AUnitNameOrPath: string): string;
var
  LModule: IOTAModule;
  LProject: IOTAProject;
  LFor: Integer;
  LInfo: IOTAModuleInfo;
  LBase: string;
begin
  Result := '';
  // If already a resolvable absolute path, use it directly.
  if TFile.Exists(AUnitNameOrPath) then
  begin
    Result := AUnitNameOrPath;
    Exit;
  end;
  // Try OTA FindModule (covers loaded modules — includes dotted unit names).
  if ResolveUnitModule(AUnitNameOrPath, LModule) then
  begin
    Result := LModule.FileName;
    Exit;
  end;
  // Fallback: scan project modules by base-name match.
  // For bare dotted names like "Aefos.MCP.AuditLog", ChangeFileExt would
  // strip ".AuditLog" (the last segment) as if it were an extension — wrong.
  // Use the name as-is when there are no path separators and it doesn't end
  // with .pas; otherwise strip path + extension.
  if not TryProject(LProject) then Exit;
  if (Pos('\', AUnitNameOrPath) = 0) and (Pos('/', AUnitNameOrPath) = 0)
    and not SameText(ExtractFileExt(AUnitNameOrPath), '.pas') then
    LBase := LowerCase(AUnitNameOrPath)
  else
    LBase := LowerCase(ChangeFileExt(ExtractFileName(AUnitNameOrPath), ''));
  for LFor := 0 to LProject.GetModuleCount - 1 do
  begin
    LInfo := LProject.GetModule(LFor);
    if not Assigned(LInfo) then Continue;
    if LowerCase(ChangeFileExt(ExtractFileName(LInfo.FileName), '')) = LBase then
    begin
      Result := LInfo.FileName;
      Exit;
    end;
  end;
end;

class function TFacadeShared.IsModuleModified(const AModule: IOTAModule): Boolean;
var
  LIdx: Integer;
  LBuffer: IOTAEditBuffer;
begin
  Result := False;
  if not Assigned(AModule) then Exit;
  for LIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LIdx), IOTAEditBuffer, LBuffer) then
      if LBuffer.IsModified then
        Exit(True);
end;

class function TFacadeShared.TryModuleLiveDfmText(const AModule: IOTAModule;
  out AText: string): Boolean;
var
  LFor: Integer;
  LFormEditor: IOTAFormEditor;
  LRoot: IOTAComponent;
  LNativeRoot: INTAComponent;
  LForm: TComponent;
  LBin, LTxt: TMemoryStream;
  LBytes: TBytes;
begin
  AText := '';
  Result := False;
  if not Assigned(AModule) then Exit;
  LFormEditor := nil;
  for LFor := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LFor), IOTAFormEditor,
      LFormEditor) then
      Break;
  if not Assigned(LFormEditor) then Exit;
  LRoot := LFormEditor.GetRootComponent;
  if not Supports(LRoot, INTAComponent, LNativeRoot) then Exit;
  LForm := LNativeRoot.GetComponent;
  if not Assigned(LForm) then Exit;
  LBin := TMemoryStream.Create;
  LTxt := TMemoryStream.Create;
  try
    LBin.WriteComponent(LForm);
    LBin.Position := 0;
    ObjectBinaryToText(LBin, LTxt);
    LTxt.Position := 0;
    SetLength(LBytes, LTxt.Size);
    if LTxt.Size > 0 then
      LTxt.ReadBuffer(LBytes[0], LTxt.Size);
    AText := TEncoding.UTF8.GetString(LBytes);
    Result := AText <> '';
  finally
    LTxt.Free;
    LBin.Free;
  end;
end;

// True when any file of the module OTHER than AWrittenPath has unsaved buffer
// edits. A module bundles the .pas AND its .dfm; a disk write only touched
// AWrittenPath, so refreshing the whole module from disk would silently discard
// unsaved edits in the SIBLING file. Clobbering the WRITTEN file's own buffer is
// the write's intent (SetDFMContent replaces the .dfm, OverwriteFile replaces the
// file), so it is excluded — only a dirty sibling must veto the refresh.
function _ModuleHasUnsavedSibling(const AModule: IOTAModule;
  const AWrittenPath: string): Boolean;
var
  LIdx: Integer;
  LEditor: IOTAEditor;
  LBuffer: IOTAEditBuffer;
begin
  Result := False;
  if not Assigned(AModule) then Exit;
  for LIdx := 0 to AModule.GetModuleFileCount - 1 do
  begin
    LEditor := AModule.GetModuleFileEditor(LIdx);
    if Supports(LEditor, IOTAEditBuffer, LBuffer) and LBuffer.IsModified
      and not SameText(LEditor.FileName, AWrittenPath) then
      Exit(True);
  end;
end;

// Forces the active edit view to repaint. After an OTA buffer write the view
// does NOT always redraw on its own when it is ALREADY the visible Code view —
// the change sits in the buffer until the user clicks/scrolls (observed with a
// silent, non-diff edit). The inline-diff path repaints via its overlay; the
// silent paths need this. Main-thread only (callers are inside Synchronize).
procedure _RepaintTopView;
var
  LES: IOTAEditorServices;
begin
  if Supports(BorlandIDEServices, IOTAEditorServices, LES)
     and Assigned(LES.TopView) then
    LES.TopView.Paint;
end;

class function TFacadeShared.ReplaceWholeBuffer(const ASource: IOTASourceEditor;
  const ANewText: string): Boolean;
var
  LWriter: IOTAEditWriter;
  LCurrent: string;
  LCurrentBytes: TBytes;
  LNewUtf8: UTF8String;
begin
  Result := False;
  if not Assigned(ASource) then Exit;
  LCurrent := ReadBytes(ASource.CreateReader);
  LCurrentBytes := TEncoding.UTF8.GetBytes(LCurrent);
  LNewUtf8 := UTF8Encode(ANewText);
  LWriter := ASource.CreateUndoableWriter;
  if not Assigned(LWriter) then Exit;
  // Insert the new text at position 0, then delete the original span — the
  // writer's output becomes exactly ANewText (see ESP-087 ADR-087-07 caller).
  LWriter.Insert(PAnsiChar(LNewUtf8));
  LWriter.DeleteTo(Length(LCurrentBytes));
  LWriter := nil;       // commit the edit before forcing the repaint
  _RepaintTopView;      // redraw now, not on the next user click
  Result := True;
end;

class function TFacadeShared.LineOfOffset(const ABuf: string; const AOffset: Integer): Integer;
var
  LI: Integer;
begin
  Result := 1;
  for LI := 1 to AOffset - 1 do
  begin
    if LI > Length(ABuf) then Break;
    if ABuf[LI] = #10 then Inc(Result);
  end;
end;

class procedure TFacadeShared.RefreshModuleFromDisk(const APath: string);
var
  LModule: IOTAModule;
begin
  try
    if not ResolveUnitModule(APath, LModule)
      and SameText(ExtractFileExt(APath), '.dfm') then
      ResolveUnitModule(ChangeFileExt(APath, '.pas'), LModule);
    // R3: Refresh(True) reloads the ENTIRE module from disk, discarding unsaved
    // edits in EVERY file of it — but the write only changed APath. Skip the forced
    // refresh when a SIBLING file has unsaved buffer edits, so SetDFMContent (writes
    // the .dfm) never clobbers an unsaved .pas buffer. The live module then stays
    // one reload behind on APath, which is far preferable to silently losing the
    // agent's/user's unsaved code.
    if Assigned(LModule) and not _ModuleHasUnsavedSibling(LModule, APath) then
      LModule.Refresh(True);
  except
    // Best-effort flow polish: a refresh failure must never break the disk
    // write that already succeeded.
  end;
end;

class function TFacadeShared.WriteUnitSource(const APath, ANewSource: string): Boolean;
var
  LModule: IOTAModule;
  LSource: IOTASourceEditor;
begin
  Result := False;
  if ResolveUnitModule(APath, LModule) then
  begin
    LSource := FirstSourceEditor(LModule);
    if Assigned(LSource) then
    begin
      if ReplaceWholeBuffer(LSource, ANewSource) then
        Result := LModule.Save(False, True);
      Exit;
    end;
  end;
  try
    TFile.WriteAllText(APath, ANewSource, TEncoding.UTF8);
    Result := True;
  except
    Result := False;
  end;
end;

end.
