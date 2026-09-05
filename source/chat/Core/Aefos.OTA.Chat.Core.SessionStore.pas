unit Aefos.OTA.Chat.Core.SessionStore;

// CLI-agnostic chat session store — ABSTRACTION + provider seam.
//
// A session (one --session-id) carries the title (first user message), CLI,
// project root, last-updated time, the user-message count and the recorded
// conversation (role/text pairs) so it can be listed AND replayed on resume,
// independent of any CLI's own on-disk history.
//
// This unit owns ONLY the contract: the TSessionEntry record, the ISessionStore
// interface, the provider seam (SetSessionStoreProvider / SessionStore) and a
// thin back-compat facade so existing callers stay unchanged. It has NO storage
// dependency — it does not know SQLite (or anything else) exists. The concrete
// provider lives in Aefos.OTA.Chat.Core.SessionStore.SQLite and registers
// itself as the default. Tests can swap it via SetSessionStoreProvider.
//
// Seam mirrors the established SetGlobalConsentPresenter / TReviewGate.SetGlobalDiffApprover
// pattern used elsewhere in the codebase.

interface

uses
  System.SysUtils;

type
  TSessionEntry = record
    Id: string;            // the CLI session UUID (--session-id)
    Title: string;         // first user message (display title)
    Cli: string;           // 'claude' | 'codex' | ...
    Project: string;       // project root path
    Updated: TDateTime;    // local time of last save
    Count: Integer;        // user-message count (shown in the list subtitle)
    MessagesJson: string;  // a JSON array string: [{"role":"user","text":".."},..]
  end;

  // Persistence contract for chat sessions. The default implementation is
  // SQLite-backed; any ISessionStore can be injected (e.g. a test double).
  ISessionStore = interface
    ['{2F8A1C64-9D37-4B05-AE21-6C90F4D8B3E7}']
    procedure SaveSession(const AEntry: TSessionEntry);
    // Light list for the panel: every row MINUS MessagesJson (left ''),
    // ordered by Updated DESCENDING (most recent first).
    function LoadSessions: TArray<TSessionEntry>;
    // Full load (with MessagesJson) to resume a session.
    function TryLoadSession(const AId: string; out AEntry: TSessionEntry): Boolean;
    procedure DeleteSession(const AId: string);
  end;

// Pure guard against the resume-then-save corruption: True when a save would
// overwrite a real conversation with nothing — an empty message array ('' or
// '[]') but a positive user-message count means the in-memory history is not
// loaded (e.g. just after a resume). Callers skip the messages write then.
function SessionSaveWouldClobber(const AMessagesJson: string;
  ACount: Integer): Boolean;

// Appends one line to %AppData%\Aefosefos-session-save.log naming what the
// save path decided. Every way a session fails to reach disk today is SILENT --
// a missing session id, the clobber guard and a database error all simply
// return -- so a user reporting "no sessions" leaves nothing behind to tell the
// three apart. This records the reason instead of an OutputDebugString nobody
// is watching. Never raises: a diagnostic that can break the caller it is
// diagnosing is worse than no diagnostic at all.
procedure SessionSaveTrace(const AReason: string);

// ── Provider seam ────────────────────────────────────────────────────────────
// Registers the active store. Pass nil to fall back to the no-op null store.
procedure SetSessionStoreProvider(const AStore: ISessionStore);
// The active store (never nil — a null-object stands in until a real provider
// self-registers, so the facade can never dereference nil).
function SessionStore: ISessionStore;

// ── Back-compat convenience facade (delegates to the active provider) ─────────
// Legacy per-session JSON directory — the historical location, kept for the
// SQLite provider's one-time import and as a reference.
function SessionsDir: string;
procedure SaveSession(const AEntry: TSessionEntry);
function LoadSessions: TArray<TSessionEntry>;
function TryLoadSession(const AId: string; out AEntry: TSessionEntry): Boolean;
procedure DeleteSession(const AId: string);

implementation

uses
  System.Classes,
  System.IOUtils;

var
  GProvider: ISessionStore;

type
  // Null-object: keeps the facade safe before a real provider registers (e.g. a
  // very early call during package load) and in degenerate test setups.
  TNullSessionStore = class(TInterfacedObject, ISessionStore)
  public
    procedure SaveSession(const AEntry: TSessionEntry);
    function LoadSessions: TArray<TSessionEntry>;
    function TryLoadSession(const AId: string; out AEntry: TSessionEntry): Boolean;
    procedure DeleteSession(const AId: string);
  end;

procedure TNullSessionStore.SaveSession(const AEntry: TSessionEntry);
begin
  // no-op
end;

function TNullSessionStore.LoadSessions: TArray<TSessionEntry>;
begin
  Result := nil;
end;

function TNullSessionStore.TryLoadSession(const AId: string;
  out AEntry: TSessionEntry): Boolean;
begin
  AEntry := Default(TSessionEntry);
  Result := False;
end;

procedure TNullSessionStore.DeleteSession(const AId: string);
begin
  // no-op
end;

function SessionSaveWouldClobber(const AMessagesJson: string;
  ACount: Integer): Boolean;
var
  LTrim: string;
begin
  LTrim := Trim(AMessagesJson);
  Result := (ACount > 0) and ((LTrim = '') or (LTrim = '[]'));
end;

procedure SessionSaveTrace(const AReason: string);
var
  LDir: string;
  LPath: string;
  LBytes: TBytes;
  LMode: Word;
  LStream: TFileStream;
begin
  try
    LDir := TPath.Combine(TPath.GetHomePath, 'Aefos');
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LPath := TPath.Combine(LDir, 'aefos-session-save.log');
    LBytes := TEncoding.UTF8.GetBytes(
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now) + ' ' + AReason +
      sLineBreak);
    if TFile.Exists(LPath) then
      LMode := fmOpenWrite or fmShareDenyWrite
    else
      LMode := fmCreate or fmShareDenyWrite;
    LStream := TFileStream.Create(LPath, LMode);
    try
      LStream.Seek(0, soEnd);
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
    finally
      LStream.Free;
    end;
  except
    // Swallowed on purpose -- see the declaration.
  end;
end;

procedure SetSessionStoreProvider(const AStore: ISessionStore);
begin
  GProvider := AStore;
end;

function SessionStore: ISessionStore;
begin
  if GProvider = nil then
    GProvider := TNullSessionStore.Create;
  Result := GProvider;
end;

function SessionsDir: string;
begin
  // Global (all projects), next to the other Aefos user data
  // (%AppData%\Roaming\Aefos\). TPath.GetHomePath = %AppData% on Windows.
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
    'sessions');
end;

procedure SaveSession(const AEntry: TSessionEntry);
begin
  SessionStore.SaveSession(AEntry);
end;

function LoadSessions: TArray<TSessionEntry>;
begin
  Result := SessionStore.LoadSessions;
end;

function TryLoadSession(const AId: string; out AEntry: TSessionEntry): Boolean;
begin
  Result := SessionStore.TryLoadSession(AId, AEntry);
end;

procedure DeleteSession(const AId: string);
begin
  SessionStore.DeleteSession(AId);
end;

initialization

finalization
  GProvider := nil;

end.
