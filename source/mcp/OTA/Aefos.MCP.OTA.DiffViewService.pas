unit Aefos.MCP.OTA.DiffViewService;

{
  OTA facade for the IDE-only VCS surface — the three things a terminal can NEVER
  reach:

    1. The IDE's OWN diff viewer (IOTACustomDifferenceManager.ShowDifference):
       hand it two streams and the user sees a real, side-by-side diff window
       instead of a patch dumped into a chat bubble.
    2. The IDE's file-history providers (FileHistoryAPI: IOTAFileHistoryManager ->
       IOTAFileHistoryProvider -> IOTAFileHistory): author / date / comment / the
       CONTENT of each revision, served by the IDE's own Git provider, with no
       subprocess.
    3. The LIVE (unsaved) editor buffer — `git diff` only ever sees the disk.

  This unit is the ONLY OTA-bound part of the group; the diff RENDERING is the
  pure, headless-tested Aefos.MCP.UnifiedDiff, and the committed side comes from
  the existing Aefos.MCP.GitFacade (no second git facade).

  Everything marshals to the IDE main thread via TThread.Synchronize (OTA is
  main-thread only) exactly like Aefos.MCP.OTA.DebugService, and every service is
  resolved with Supports(BorlandIDEServices, ...) at the moment of use — an IDE
  without a difference manager or without a history provider degrades to a
  machine-actionable kebab reason, never to an exception.

  NOTE: IOTACustomDifferenceManager is documented as a BorlandIDEServices service
  but was NOT verified at runtime here — that is exactly why the lookup is a
  Supports() probe with a 'no-difference-manager' reason. Same for the history
  providers (Count = 0 => 'no-history-provider', and the caller falls back to git
  log).
}

interface

type
  // One revision, as the IDE's own history provider reports it. Content is
  // filled only when the caller asks for it (revisions can be large).
  TIDEHistoryEntry = record
    Ident: string;      // provider revision id (a commit hash for Git)
    Author: string;
    // ISO-8601 UTC ('...Z'). The provider reports a TDateTime whose zone it does
    // NOT document; we render it as UTC for a stable, machine-parseable string.
    // A provider that already hands back UTC would be double-shifted here — a
    // known caveat the maintainer confirms live against the real Git provider.
    Date: string;
    Comment: string;
    Style: string;      // buffer | file | local-file | remote-revision | active-revision
    Content: string;
    // True when Content was cut at MAX_REVISION_BYTES — the agent must NOT treat
    // a truncated revision as the whole file.
    Truncated: Boolean;
  end;

// Opens the IDE's native diff viewer on two in-memory texts. ALeftFile/ARightFile
// are optional real paths shown by the viewer. False + AReason on failure:
// 'no-difference-manager' (this IDE exposes none) or 'show-diff-failed'.
function DiffShowInIDE(const ALeftText, ARightText, ALeftTitle, ARightTitle,
  ALeftFile, ARightFile: string; out AReason: string): Boolean;

// Revision history of AFileName from the IDE's registered history providers.
// AMaxEntries <= 0 means "all". False + AReason: 'no-history-provider' (no
// provider registered — the caller falls back to git log), 'file-not-found',
// or 'no-history' (providers exist but none knows this file).
function DiffReadFileHistory(const AFileName: string;
  const AMaxEntries: Integer; const AIncludeContent: Boolean;
  out AEntries: TArray<TIDEHistoryEntry>; out AProvider: string;
  out AResolvedFile: string; out AReason: string): Boolean;

// The LIVE source buffer of the active editor (unsaved edits included) plus its
// file name. False + AReason='no-active-source' when no source editor is active.
function DiffReadActiveSource(out AFileName, AContent: string;
  out AReason: string): Boolean;

// The LIVE source buffer of a named unit (unit name OR path). Falls back to the
// on-disk file when the unit is not open in an editor.
function DiffReadUnitSource(const AUnitNameOrPath: string;
  out AFileName, AContent: string; out AReason: string): Boolean;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  Winapi.ActiveX,
  ToolsAPI,
  FileHistoryAPI,
  Aefos.MCP.GitFacade,
  Aefos.MCP.OTA.FacadeShared;

const
  // Same ceiling FacadeShared._ReadBytes uses for a live buffer — a revision
  // bigger than this is not something the agent should be swallowing whole.
  MAX_REVISION_BYTES = 1024 * 1024;

// --- stream helpers ---------------------------------------------------------

// Wraps text as a UTF-8 IStream for the difference viewer. The BOM is written on
// purpose: it is what a Delphi source file carries on disk, so the IDE's viewer
// detects the encoding exactly as it does for a real file.
function _TextToStream(const AText: string): IStream;
var
  LMem: TMemoryStream;
  LBytes: TBytes;
  LBom: TBytes;
begin
  LMem := TMemoryStream.Create;
  // The adapter takes ownership only AFTER it is constructed; if a write raises
  // in between, LMem would leak. Guard the window explicitly.
  try
    LBom := TEncoding.UTF8.GetPreamble;
    LBytes := TEncoding.UTF8.GetBytes(AText);
    if Length(LBom) > 0 then
      LMem.WriteBuffer(LBom[0], Length(LBom));
    if Length(LBytes) > 0 then
      LMem.WriteBuffer(LBytes[0], Length(LBytes));
    LMem.Position := 0;
  except
    LMem.Free;
    raise;
  end;
  // soOwned: the adapter frees the memory stream when the IStream refcount dies.
  Result := TStreamAdapter.Create(LMem, soOwned) as IStream;
end;

// Reads an IStream (a history revision) back to text, decoded the way the IDE
// loads a unit (BOM -> UTF-8 -> cp1252, via DecodeSourceBytes) so a legacy ANSI
// revision renders instead of mojibaking. ATruncated is set when the content was
// cut at MAX_REVISION_BYTES — the caller MUST NOT present a truncated revision
// as the whole file. The cut is on a BYTE boundary, so it can land mid-codepoint
// and yield a trailing U+FFFD; that is acceptable for a marked-truncated blob.
function _StreamToText(const AStream: IStream; out ATruncated: Boolean): string;
var
  LBuf: array[0..8191] of Byte;
  LRead: FixedUInt;
  LBytes: TBytes;
  LLen: Integer;
begin
  Result := '';
  ATruncated := False;
  if AStream = nil then
    Exit;
  SetLength(LBytes, 0);
  LLen := 0;
  repeat
    LRead := 0;
    if AStream.Read(@LBuf[0], SizeOf(LBuf), @LRead) <> S_OK then
      Break;
    if LRead = 0 then
      Break;
    if LLen + Integer(LRead) > MAX_REVISION_BYTES then
    begin
      // Keep exactly up to the cap, then stop and flag it.
      SetLength(LBytes, MAX_REVISION_BYTES);
      Move(LBuf[0], LBytes[LLen], MAX_REVISION_BYTES - LLen);
      LLen := MAX_REVISION_BYTES;
      ATruncated := True;
      Break;
    end;
    SetLength(LBytes, LLen + Integer(LRead));
    Move(LBuf[0], LBytes[LLen], LRead);
    Inc(LLen, Integer(LRead));
  until LRead < FixedUInt(SizeOf(LBuf));
  if LLen = 0 then
    Exit;
  Result := DecodeSourceBytes(LBytes);
end;

function _StyleToString(const AStyle: TOTAHistoryStyle): string;
begin
  case AStyle of
    hsBuffer:          Result := 'buffer';
    hsFile:            Result := 'file';
    hsLocalFile:       Result := 'local-file';
    hsRemoteRevision:  Result := 'remote-revision';
    hsActiveRevision:  Result := 'active-revision';
  else
    Result := 'unknown';
  end;
end;

// --- 1. the IDE's native diff viewer ----------------------------------------

function DiffShowInIDE(const ALeftText, ARightText, ALeftTitle, ARightTitle,
  ALeftFile, ARightFile: string; out AReason: string): Boolean;
var
  LOk: Boolean;
  LReason: string;
begin
  LOk := False;
  LReason := '';
  TThread.Synchronize(nil,
    procedure
    var
      LMgr: IOTACustomDifferenceManager;
      LLeft, LRight: IStream;
    begin
      if not Supports(BorlandIDEServices, IOTACustomDifferenceManager, LMgr) then
      begin
        LReason := 'no-difference-manager';
        Exit;
      end;
      try
        LLeft := _TextToStream(ALeftText);
        LRight := _TextToStream(ARightText);
        // dfOTABuffer on both sides: these are in-memory contents, not files on
        // disk. dtOTADefault lets the user's configured viewer win.
        LMgr.ShowDifference(LLeft, LRight, ALeftTitle, ARightTitle,
          ALeftFile, ARightFile, dfOTABuffer, dfOTABuffer, dtOTADefault);
        LOk := True;
      except
        // Report ordinary viewer failures as a kebab reason, but let FATAL
        // exceptions (AV / OOM / other hardware faults) propagate — masking a
        // real crash as 'show-diff-failed' would hide a genuine bug.
        on E: EExternal do
          raise;
        on E: EOutOfMemory do
          raise;
        on E: Exception do
          LReason := 'show-diff-failed';
      end;
    end);
  AReason := LReason;
  Result := LOk;
end;

// --- 2. the IDE's file-history providers ------------------------------------

function _AppendHistoryEntries(const AHistory: IOTAFileHistory;
  const AMaxEntries: Integer; const AIncludeContent: Boolean;
  var AEntries: TArray<TIDEHistoryEntry>): Boolean;
var
  LCount, LTake, LFor: Integer;
  LEntry: TIDEHistoryEntry;
begin
  Result := False;
  if AHistory = nil then
    Exit;
  LCount := AHistory.Get_Count;
  if LCount <= 0 then
    Exit;
  LTake := LCount;
  if (AMaxEntries > 0) and (AMaxEntries < LTake) then
    LTake := AMaxEntries;
  for LFor := 0 to LTake - 1 do
  begin
    LEntry := Default(TIDEHistoryEntry);
    try
      LEntry.Ident := AHistory.GetIdent(LFor);
      LEntry.Author := AHistory.GetAuthor(LFor);
      LEntry.Comment := AHistory.GetComment(LFor);
      // DateToISO8601(..., AInputIsUTC=False) treats the provider's TDateTime as
      // LOCAL and converts to UTC ('...Z'). See the TIDEHistoryEntry.Date note
      // for the double-shift caveat when a provider already reports UTC.
      LEntry.Date := DateToISO8601(AHistory.GetDate(LFor), False);
      LEntry.Style := _StyleToString(AHistory.GetHistoryStyle(LFor));
      if AIncludeContent then
        LEntry.Content := _StreamToText(AHistory.GetContent(LFor),
          LEntry.Truncated);
    except
      // A provider that throws on ONE revision must not kill the whole read —
      // keep whatever fields were filled and move on.
    end;
    AEntries := AEntries + [LEntry];
  end;
  Result := True;
end;

function DiffReadFileHistory(const AFileName: string;
  const AMaxEntries: Integer; const AIncludeContent: Boolean;
  out AEntries: TArray<TIDEHistoryEntry>; out AProvider: string;
  out AResolvedFile: string; out AReason: string): Boolean;
var
  LOk: Boolean;
  LReason, LProvider, LResolved: string;
  LEntries: TArray<TIDEHistoryEntry>;
begin
  LOk := False;
  LReason := '';
  LProvider := '';
  LResolved := '';
  SetLength(LEntries, 0);
  TThread.Synchronize(nil,
    procedure
    var
      LMgr: IOTAFileHistoryManager;
      LProv: IOTAFileHistoryProvider;
      LHist: IOTAFileHistory;
      LFor: Integer;
    begin
      if not Supports(BorlandIDEServices, IOTAFileHistoryManager, LMgr) then
      begin
        LReason := 'no-history-provider';
        Exit;
      end;
      if LMgr.Get_Count = 0 then
      begin
        LReason := 'no-history-provider';
        Exit;
      end;
      LResolved := TFacadeShared.FindUnitPath(AFileName);
      if LResolved = '' then
        LResolved := AFileName;
      if not TFile.Exists(LResolved) then
      begin
        LReason := 'file-not-found';
        Exit;
      end;
      for LFor := 0 to LMgr.Get_Count - 1 do
      begin
        LProv := LMgr.GetFileHistoryProvider(LFor);
        if LProv = nil then
          Continue;
        LHist := nil;
        try
          LHist := LProv.GetFileHistory(LResolved);
        except
          LHist := nil;
        end;
        if _AppendHistoryEntries(LHist, AMaxEntries, AIncludeContent,
          LEntries) then
        begin
          try
            LProvider := LProv.Get_Name;
          except
            LProvider := '';
          end;
          LOk := True;
          Exit;
        end;
      end;
      LReason := 'no-history';
    end);
  AEntries := LEntries;
  AProvider := LProvider;
  AResolvedFile := LResolved;
  AReason := LReason;
  Result := LOk;
end;

// --- 3. the LIVE (unsaved) editor buffer ------------------------------------

function DiffReadActiveSource(out AFileName, AContent: string;
  out AReason: string): Boolean;
var
  LOk: Boolean;
  LFile, LText, LReason: string;
begin
  LOk := False;
  LFile := '';
  LText := '';
  LReason := '';
  TThread.Synchronize(nil,
    procedure
    var
      LSource: IOTASourceEditor;
    begin
      if not TFacadeShared.ActiveSourceEditor(LSource) then
      begin
        LReason := 'no-active-source';
        Exit;
      end;
      LFile := LSource.FileName;
      LText := TFacadeShared.ReadBytes(LSource.CreateReader);
      LOk := True;
    end);
  AFileName := LFile;
  AContent := LText;
  AReason := LReason;
  Result := LOk;
end;

function DiffReadUnitSource(const AUnitNameOrPath: string;
  out AFileName, AContent: string; out AReason: string): Boolean;
var
  LOk: Boolean;
  LFile, LText, LReason: string;
begin
  LOk := False;
  LFile := '';
  LText := '';
  LReason := '';
  TThread.Synchronize(nil,
    procedure
    var
      LModule: IOTAModule;
      LSource: IOTASourceEditor;
    begin
      LFile := TFacadeShared.FindUnitPath(AUnitNameOrPath);
      if LFile = '' then
        LFile := AUnitNameOrPath;
      // Live buffer first (unsaved edits are the whole point), disk second.
      if TFacadeShared.ResolveUnitModule(AUnitNameOrPath, LModule) then
      begin
        LSource := TFacadeShared.FirstSourceEditor(LModule);
        if LSource <> nil then
        begin
          LFile := LSource.FileName;
          LText := TFacadeShared.ReadBytes(LSource.CreateReader);
          LOk := True;
          Exit;
        end;
      end;
      if not TFile.Exists(LFile) then
      begin
        LReason := 'file-not-found';
        Exit;
      end;
      LText := TFile.ReadAllText(LFile, TEncoding.UTF8);
      LOk := True;
    end);
  AFileName := LFile;
  AContent := LText;
  AReason := LReason;
  Result := LOk;
end;

end.
