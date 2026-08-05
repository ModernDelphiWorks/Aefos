unit Aefos.Compat.NetEncoding;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  System.NetEncoding compatibility shim (Aefos -> Lazarus port, Phase D).

  Single uses-target for the ONE member the Agent CLI needs: base64-encoding an
  image's bytes to a string for a vision model's message "images" payload
  (Aefos.Agent.Attachments). No decode, no URL/HTML encodings.

  - Delphi (not FPC): a pure TYPE ALIAS onto System.NetEncoding.TNetEncoding, so
    TNetEncoding.Base64.EncodeBytesToString behaves exactly as before.
  - FPC: TNetEncoding.Base64 returns a shared encoder over the RTL `base64` unit
    (a TBase64EncodingStream over the raw bytes; the output is ASCII, so the
    widening to string is lossless). Matches System.NetEncoding's continuous
    (newline-free) EncodeBytesToString - the one caller strips CR/LF anyway.
}

interface

{$IFNDEF FPC}

uses
  System.NetEncoding;

type
  TNetEncoding = System.NetEncoding.TNetEncoding;

{$ELSE}

uses
  SysUtils;   // TBytes

type
  // Minimal stand-in for System.NetEncoding.TBase64Encoding: just the one
  // bytes-to-string encode the Agent CLI uses.
  TAefosBase64Encoding = class
  public
    function EncodeBytesToString(const AInput: TBytes): string;
    // System.NetEncoding parity: TNetEncoding.Base64.DecodeStringToBytes(...).
    // Decodes a base64 string (ASCII) back to its raw bytes. Added for the
    // clipboard-image paste path (Aefos.Lazarus.ChatController) - the Delphi side
    // is a plain alias onto System.NetEncoding, which already has this method.
    function DecodeStringToBytes(const AInput: string): TBytes;
  end;

  TNetEncoding = class
  public
    // System.NetEncoding parity: TNetEncoding.Base64.EncodeBytesToString(...).
    // A shared instance (freed at finalization); the caller never owns it.
    class function Base64: TAefosBase64Encoding; static;
  end;

{$ENDIF}

implementation

{$IFDEF FPC}

uses
  Classes,
  base64;

var
  GBase64: TAefosBase64Encoding = nil;

function TAefosBase64Encoding.EncodeBytesToString(const AInput: TBytes): string;
var
  LOut: TMemoryStream;
  LEnc: TBase64EncodingStream;
  LBytes: TBytes;
  LIndex: Integer;
begin
  Result := '';
  if Length(AInput) = 0 then
    Exit;
  LOut := TMemoryStream.Create;
  try
    LEnc := TBase64EncodingStream.Create(LOut);
    try
      LEnc.Write(AInput[0], Length(AInput));
    finally
      LEnc.Free;   // destructor flushes the trailing quantum
    end;
    SetLength(LBytes, LOut.Size);
    LOut.Position := 0;
    if LOut.Size > 0 then
      LOut.ReadBuffer(LBytes[0], LOut.Size);
    // The base64 alphabet is ASCII: map each byte straight to a Char, so no
    // codepage/UTF conversion can corrupt it (DataString did).
    SetLength(Result, Length(LBytes));
    for LIndex := 0 to High(LBytes) do
      Result[LIndex + 1] := Char(LBytes[LIndex]);
  finally
    LOut.Free;
  end;
end;

function TAefosBase64Encoding.DecodeStringToBytes(const AInput: string): TBytes;
var
  LIn: TMemoryStream;
  LDec: TBase64DecodingStream;
  LOut: TMemoryStream;
  LChunk: TBytes;
  LRead: Integer;
  LIdx: Integer;
begin
  Result := nil;
  LChunk := nil;
  if AInput = '' then
    Exit;
  // The base64 text is ASCII; feed each char as a raw byte into the input stream
  // (no codepage/UTF conversion), then read the decoded bytes out in chunks
  // (TBase64DecodingStream has no reliable Size).
  LIn := TMemoryStream.Create;
  try
    SetLength(LChunk, Length(AInput));
    for LIdx := 1 to Length(AInput) do
      LChunk[LIdx - 1] := Byte(Ord(AInput[LIdx]));
    LIn.WriteBuffer(LChunk[0], Length(LChunk));
    LIn.Position := 0;
    LOut := TMemoryStream.Create;
    try
      LDec := TBase64DecodingStream.Create(LIn);
      try
        SetLength(LChunk, 8192);
        repeat
          LRead := LDec.Read(LChunk[0], Length(LChunk));
          if LRead > 0 then
            LOut.WriteBuffer(LChunk[0], LRead);
        until LRead <= 0;
      finally
        LDec.Free;
      end;
      SetLength(Result, LOut.Size);
      if LOut.Size > 0 then
      begin
        LOut.Position := 0;
        LOut.ReadBuffer(Result[0], LOut.Size);
      end;
    finally
      LOut.Free;
    end;
  finally
    LIn.Free;
  end;
end;

class function TNetEncoding.Base64: TAefosBase64Encoding;
begin
  if GBase64 = nil then
    GBase64 := TAefosBase64Encoding.Create;
  Result := GBase64;
end;

initialization

finalization
  GBase64.Free;

{$ENDIF}

end.
