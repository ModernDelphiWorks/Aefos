unit Aefos.OTA.Terminal.Core.Reflow;
{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Pure scrollback reflow — ESP-034 / ADR-034-02.

  Reflows an array of (cells, continuation) rows plus a parallel array of
  link-range snapshots to a new column count. Continuation chains are
  collapsed into logical lines, re-wrapped at ANewCols, and link ranges are
  remapped in lockstep.

  Purity rule: this unit MUST stay free of libvterm and VCL. Allowed imports
  are System.SysUtils, System.Math, System.Generics.Collections,
  Aefos.OTA.Terminal.Core.CellColor, Aefos.OTA.Terminal.Core.Hyperlink. Anything else is a bug.

  Conventions: locals `L*`, params `A*` with `const`, private helpers `_*`,
  `string` not `String`. ESP-034 / .claude/rules/delphi/20-delphi-conventions.md.
*)

interface

uses
  {$IFDEF FPC}SysUtils, Math, Generics.Collections,{$ELSE}System.SysUtils, System.Math, System.Generics.Collections,{$ENDIF}
  Aefos.OTA.Terminal.Core.CellColor, Aefos.OTA.Terminal.Core.Hyperlink;

type
  /// <summary>One row in the scrollback list: the row's cells plus the
  /// flow-continuation bit captured at eviction time by libvterm's
  /// sb_pushline4 callback. Continuation = True iff the row is the wrap
  /// continuation of the previous scrollback row. ESP-034 / ADR-034-01.</summary>
  TScrollbackRow = record
    Cells: TTerminalRow;
    Continuation: Boolean;
  end;

  /// <summary>Pure scrollback-reflow facade. The single entry point is the
  /// class-static Reflow; no instance is ever created.</summary>
  TScrollbackReflow = class sealed
  public
    /// <summary>Reflows AOldRows + AOldLinks to ANewCols and returns the new
    /// row array. ANewLinks is the parallel link-range snapshot for each output
    /// row. Pure — no exceptions, no globals.
    ///
    /// Edge cases:
    ///  - ANewCols &lt;= 0  → returns AOldRows unchanged and AOldLinks unchanged.
    ///  - empty input    → returns empty arrays.
    ///  - empty row      → passes through unchanged (Continuation preserved).
    ///  - ANewCols = 1   → each cell becomes its own row.
    ///
    /// Trailing blanks are NOT stripped — preserves user-visible whitespace
    /// alignment in pre-formatted output (htop, top). ESP-034 §Out of scope.
    /// </summary>
    class function Reflow(
      const AOldRows: TArray<TScrollbackRow>;
      const AOldLinks: TArray<TArray<TLinkRange> >;
      const ANewCols: Integer;
      out ANewLinks: TArray<TArray<TLinkRange> >): TArray<TScrollbackRow>; static;
  end;

implementation

type
  /// <summary>Working buffer for one logical line under construction.
  /// Cells are appended row-by-row; links are kept in chain-relative
  /// coordinates (offset by the count of prior cells in the chain).</summary>
  TLogicalLine = record
    Cells: TTerminalRow;
    Links: TList<TLinkRange>;
    StartedChain: Boolean;
  end;

procedure _AppendCells(var ATarget: TTerminalRow;
  const ASource: TTerminalRow);
// Concatenates ASource onto ATarget in-place. Avoids the dynamic-array
// `+` operator's H2077 warning chain by using SetLength + Move.
var
  LOldLen, LAddLen: Integer;
begin
  LAddLen := Length(ASource);
  if LAddLen = 0 then Exit;
  LOldLen := Length(ATarget);
  SetLength(ATarget, LOldLen + LAddLen);
  Move(ASource[0], ATarget[LOldLen], LAddLen * SizeOf(TTerminalCell));
end;

procedure _AppendLinksShifted(const ATarget: TList<TLinkRange>;
  const ASource: TArray<TLinkRange>; const ABaseCol: Integer);
// Appends ASource onto ATarget, shifting StartCol/EndCol by ABaseCol so the
// link's chain-relative window is preserved. Negative-width ranges (which
// the buffer should never produce) are dropped defensively. Adjacent ranges
// with the same UrlIdx are merged in-place — that's what makes a link that
// spans a chain boundary surface as a single TLinkRange after reflow
// (ESP-034 / AC4 — TestLinkRangeSpansChainBoundary).
var
  LFor, LLastIdx: Integer;
  LRange, LLast: TLinkRange;
begin
  for LFor := 0 to High(ASource) do
  begin
    LRange := ASource[LFor];
    if LRange.EndCol <= LRange.StartCol then Continue;
    LRange.StartCol := LRange.StartCol + ABaseCol;
    LRange.EndCol   := LRange.EndCol   + ABaseCol;
    LLastIdx := ATarget.Count - 1;
    if LLastIdx >= 0 then
    begin
      LLast := ATarget[LLastIdx];
      if (LLast.UrlIdx = LRange.UrlIdx)
        and (LLast.EndCol = LRange.StartCol) then
      begin
        LLast.EndCol := LRange.EndCol;
        ATarget[LLastIdx] := LLast;
        Continue;
      end;
    end;
    ATarget.Add(LRange);
  end;
end;

function _ClipLinks(const ALinks: TList<TLinkRange>;
  const AWinStart, AWinEnd: Integer): TArray<TLinkRange>;
// Returns the subset of ALinks whose [StartCol, EndCol) intersects the
// half-open window [AWinStart, AWinEnd), with coordinates shifted into the
// window (so cells 0..AWinEnd-AWinStart). Adjacent links are NOT merged —
// preserves the input granularity exactly.
var
  LFor, LStart, LEnd, LWinWidth: Integer;
  LRange, LOutRange: TLinkRange;
  LList: TList<TLinkRange>;
begin
  LList := TList<TLinkRange>.Create;
  try
    LWinWidth := AWinEnd - AWinStart;
    for LFor := 0 to ALinks.Count - 1 do
    begin
      LRange := ALinks[LFor];
      LStart := Max(LRange.StartCol, AWinStart);
      LEnd   := Min(LRange.EndCol,   AWinEnd);
      if LEnd <= LStart then Continue;
      LOutRange.StartCol := LStart - AWinStart;
      LOutRange.EndCol   := LEnd   - AWinStart;
      LOutRange.UrlIdx   := LRange.UrlIdx;
      if LOutRange.EndCol > LWinWidth then
        LOutRange.EndCol := LWinWidth;
      LList.Add(LOutRange);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

function _SliceCells(const ACells: TTerminalRow;
  const AStart, AEnd: Integer): TTerminalRow;
// Half-open [AStart, AEnd). Returns a fresh array copy.
var
  LLen: Integer;
begin
  LLen := AEnd - AStart;
  if LLen <= 0 then
    Exit(nil);
  SetLength(Result, LLen);
  Move(ACells[AStart], Result[0], LLen * SizeOf(TTerminalCell));
end;

procedure _FlushChain(const ALogical: TLogicalLine; const ANewCols: Integer;
  const ARowsOut: TList<TScrollbackRow>;
  const ALinksOut: TList<TArray<TLinkRange> >);
// Emits the logical line as N output rows of width ANewCols (last row may
// be shorter). The first emitted row carries Continuation = StartedChain
// (i.e., the original chain anchor's bit); subsequent rows have
// Continuation := True. Links are clipped to each window.
var
  LFor, LRowStart, LRowEnd, LTotal: Integer;
  LOutRow: TScrollbackRow;
  LFirst: Boolean;
begin
  LTotal := Length(ALogical.Cells);
  if LTotal = 0 then
  begin
    // Empty logical line passes through as a single zero-length row, so
    // tests that seed `Length(Cells) = 0` rows see them again on output.
    LOutRow.Cells := nil;
    LOutRow.Continuation := ALogical.StartedChain;
    ARowsOut.Add(LOutRow);
    ALinksOut.Add(nil);
    Exit;
  end;
  LFor := 0;
  LFirst := True;
  while LFor < LTotal do
  begin
    LRowStart := LFor;
    LRowEnd := Min(LFor + ANewCols, LTotal);
    LOutRow.Cells := _SliceCells(ALogical.Cells, LRowStart, LRowEnd);
    if LFirst then
      LOutRow.Continuation := ALogical.StartedChain
    else
      LOutRow.Continuation := True;
    ARowsOut.Add(LOutRow);
    ALinksOut.Add(_ClipLinks(ALogical.Links, LRowStart, LRowEnd));
    LFor := LRowEnd;
    LFirst := False;
  end;
end;

procedure _StartChain(var ALogical: TLogicalLine;
  const ARow: TScrollbackRow; const ALinks: TArray<TLinkRange>);
begin
  ALogical.Cells := Copy(ARow.Cells);
  ALogical.Links.Clear;
  _AppendLinksShifted(ALogical.Links, ALinks, 0);
  ALogical.StartedChain := ARow.Continuation;
end;

procedure _ExtendChain(var ALogical: TLogicalLine;
  const ARow: TScrollbackRow; const ALinks: TArray<TLinkRange>);
var
  LBaseCol: Integer;
begin
  LBaseCol := Length(ALogical.Cells);
  _AppendCells(ALogical.Cells, ARow.Cells);
  _AppendLinksShifted(ALogical.Links, ALinks, LBaseCol);
end;

class function TScrollbackReflow.Reflow(
  const AOldRows: TArray<TScrollbackRow>;
  const AOldLinks: TArray<TArray<TLinkRange> >;
  const ANewCols: Integer;
  out ANewLinks: TArray<TArray<TLinkRange> >): TArray<TScrollbackRow>;
var
  LRowsOut: TList<TScrollbackRow>;
  LLinksOut: TList<TArray<TLinkRange> >;
  LLogical: TLogicalLine;
  LFor: Integer;
  LRowLinks: TArray<TLinkRange>;
  LHasChain: Boolean;
begin
  if ANewCols <= 0 then
  begin
    // BR1 + AC7: invalid widths pass through unchanged. Callers (Resize)
    // already guard the (LNewCols = LOldCols) case so this branch only
    // fires on the explicit invalid-input contract.
    ANewLinks := Copy(AOldLinks);
    Result := Copy(AOldRows);
    Exit;
  end;
  if Length(AOldRows) = 0 then
  begin
    ANewLinks := nil;
    Result := nil;
    Exit;
  end;
  LRowsOut := TList<TScrollbackRow>.Create;
  LLinksOut := TList<TLinkRangeArray>.Create;
  LLogical.Links := TList<TLinkRange>.Create;
  try
    LLogical.StartedChain := False;
    LLogical.Cells := nil;
    LHasChain := False;
    for LFor := 0 to High(AOldRows) do
    begin
      if LFor < Length(AOldLinks) then
        LRowLinks := AOldLinks[LFor]
      else
        LRowLinks := nil;
      if not AOldRows[LFor].Continuation then
      begin
        if LHasChain then
          _FlushChain(LLogical, ANewCols, LRowsOut, LLinksOut);
        _StartChain(LLogical, AOldRows[LFor], LRowLinks);
        LHasChain := True;
      end
      else
      begin
        if not LHasChain then
        begin
          // Defensive: continuation row with no preceding anchor. Treat as
          // a new chain anchor but preserve the Continuation bit so the
          // first emitted row keeps the same shape it had on input.
          _StartChain(LLogical, AOldRows[LFor], LRowLinks);
          LHasChain := True;
        end
        else
          _ExtendChain(LLogical, AOldRows[LFor], LRowLinks);
      end;
    end;
    if LHasChain then
      _FlushChain(LLogical, ANewCols, LRowsOut, LLinksOut);
    Result := LRowsOut.ToArray;
    ANewLinks := LLinksOut.ToArray;
  finally
    LLogical.Links.Free;
    LLinksOut.Free;
    LRowsOut.Free;
  end;
end;

end.


