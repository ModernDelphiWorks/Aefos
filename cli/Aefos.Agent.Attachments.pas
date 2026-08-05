unit Aefos.Agent.Attachments;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - image attachments for vision models (harness "eyes").

  The chat attaches files by appending a marker block to the prompt text:

    [Attached files - read them]:
    C:\...\ds_paste_XXXX.png

  A text-only model can do nothing with a path - live Fase E (2026-07-10)
  showed a model first CONFABULATING the image's content, then honestly
  admitting it cannot see it. Vision models (Ollama capability 'vision', e.g.
  minimax-m3:cloud) accept base64 payloads on the message's "images" member -
  so the CLI extracts the paths, loads the bytes and attaches them.

  Parsing is pure (headless-tested); the loader is a thin RTL file read.
*)

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  Aefos.Compat.IO,
  Aefos.Compat.NetEncoding;
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.NetEncoding;
  {$ENDIF}

const
  // Exact marker the chat's composer writes (OutputPanel.Assets attach flow).
  CAttachedFilesMarker = '[Attached files - read them]:';

type
  { Static, sealed namespace for image attachments (harness "eyes"). Never
    instantiated; the class IS the namespace. }
  TAgentAttachments = class sealed
  public
    // Image paths from the prompt's attachment block: the lines following the
    // marker that carry an image extension, stopping at the first blank/non-path
    // line. Multiple marker blocks accumulate. No marker -> empty.
    class function ExtractImagePaths(const APrompt: string): TArray<string>; static;

    // True when APath's extension is an image a vision model reads.
    class function IsImagePath(const APath: string): Boolean; static;

    // Loads a file as base64 (no data: prefix - Ollama wants the raw payload).
    // False when the file is missing/unreadable.
    class function LoadImageBase64(const APath: string;
      out ABase64: string): Boolean; static;
  end;

implementation

// Classic single-delimiter split (FPC 3.2.2 has no TStringHelper), keeping empty
// segments - byte-identical to string.Split([ADelim]) for this unit's inputs.
function _SplitChar(const AText: string; const ADelim: Char): TArray<string>;
var
  LIndex, LStart, LCount: Integer;
begin
  SetLength(Result, 0);
  if AText = '' then
    Exit;
  LStart := 1;
  LCount := 0;
  for LIndex := 1 to Length(AText) do
    if AText[LIndex] = ADelim then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(AText, LStart, LIndex - LStart);
      Inc(LCount);
      LStart := LIndex + 1;
    end;
  SetLength(Result, LCount + 1);
  Result[LCount] := Copy(AText, LStart, Length(AText) - LStart + 1);
end;

class function TAgentAttachments.IsImagePath(const APath: string): Boolean;
var
  LExt: string;
begin
  LExt := LowerCase(ExtractFileExt(Trim(APath)));
  Result := (LExt = '.png') or (LExt = '.jpg') or (LExt = '.jpeg') or
    (LExt = '.bmp') or (LExt = '.gif') or (LExt = '.webp');
end;

class function TAgentAttachments.ExtractImagePaths(
  const APrompt: string): TArray<string>;
var
  LLines: TArray<string>;
  LFor: Integer;
  LInBlock: Boolean;
  LLine: string;
  LNorm: string;
begin
  Result := nil;
  if Pos(CAttachedFilesMarker, APrompt) = 0 then
    Exit;
  LNorm := StringReplace(APrompt, #13#10, #10, [rfReplaceAll]);
  LNorm := StringReplace(LNorm, #13, #10, [rfReplaceAll]);
  LLines := _SplitChar(LNorm, #10);
  LInBlock := False;
  for LFor := 0 to High(LLines) do
  begin
    LLine := Trim(LLines[LFor]);
    if Pos(CAttachedFilesMarker, LLine) > 0 then
    begin
      LInBlock := True;
      Continue;
    end;
    if not LInBlock then
      Continue;
    if (LLine <> '') and TAgentAttachments.IsImagePath(LLine) then
      Result := Result + [LLine]
    else
      LInBlock := False; // blank or non-path line ends the block
  end;
end;

class function TAgentAttachments.LoadImageBase64(const APath: string;
  out ABase64: string): Boolean;
var
  LBytes: TBytes;
begin
  Result := False;
  ABase64 := '';
  try
    if not TFile.Exists(APath) then
      Exit;
    LBytes := TFile.ReadAllBytes(APath);
    if Length(LBytes) = 0 then
      Exit;
    ABase64 := TNetEncoding.Base64.EncodeBytesToString(LBytes);
    ABase64 := StringReplace(ABase64, #13, '', [rfReplaceAll]);
    ABase64 := StringReplace(ABase64, #10, '', [rfReplaceAll]);
    Result := ABase64 <> '';
  except
    Result := False;
  end;
end;

end.
