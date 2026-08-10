unit Aefos.OTA.Terminal.UI.ComposerMemory;

(*
  Global-memory editor for the Terminal composer's brain (memory) button. A tiny
  dark VCL dialog (TMemo + Save / Cancel) that edits the SAME file the chat edits:
  %AppData%\Roaming\Aefos\memory.md (TPath.GetHomePath = %AppData% on Windows).

  The terminal is a DIFFERENT BPL from the chat, so the read/write is reimplemented
  here (a couple of TFile calls) rather than depending on the chat's CommandExecutor.
  All text is English only; no non-ASCII in this source.
*)

interface

uses
  System.Classes,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.Controls;

type
  TComposerMemoryForm = class(TForm)
  private
    FMemo: TMemo;
    FButtons: TPanel;
    FSave: TButton;
    FCancel: TButton;
    procedure _BuildUI;
  public
    // Loads the global memory into the editor, shows it modally, and persists the
    // edited text on Save. Returns True when the user saved. Caller owns nothing.
    class function Execute(AOwner: TComponent): Boolean;
  end;

// The global (all-projects) memory file, next to the other Aefos user data.
function GlobalMemoryPath: string;
function LoadGlobalMemory: string;
procedure SaveGlobalMemory(const AText: string);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Aefos.Compat.IO,
  Vcl.Graphics;

function GlobalMemoryPath: string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
    'memory.md');
end;

function LoadGlobalMemory: string;
var
  LPath: string;
begin
  Result := '';
  LPath := GlobalMemoryPath;
  if not TFile.Exists(LPath) then
    Exit;
  try
    Result := TAefosText.ReadAllUtf8(LPath);
  except
    // A locked / garbled memory file must never break the editor.
    Result := '';
  end;
end;

procedure SaveGlobalMemory(const AText: string);
var
  LPath: string;
begin
  LPath := GlobalMemoryPath;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(LPath));
  TFile.WriteAllText(LPath, AText, TEncoding.UTF8);
end;

{ TComposerMemoryForm }

procedure TComposerMemoryForm._BuildUI;
begin
  Caption := 'Aefos global memory';
  BorderStyle := bsSizeable;
  Position := poScreenCenter;
  ClientWidth := 560;
  ClientHeight := 420;
  Color := $001E1E1E;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  Font.Color := $00E6E6E6;

  FButtons := TPanel.Create(Self);
  FButtons.Parent := Self;
  FButtons.Align := alBottom;
  FButtons.Height := 48;
  FButtons.BevelOuter := bvNone;
  FButtons.ParentBackground := False;
  FButtons.Color := $001E1E1E;

  FSave := TButton.Create(Self);
  FSave.Parent := FButtons;
  FSave.Caption := 'Save';
  FSave.ModalResult := mrOk;
  FSave.Default := True;
  FSave.Width := 90;
  FSave.Height := 28;
  FSave.Top := 10;
  FSave.Anchors := [akTop, akRight];
  FSave.Left := FButtons.Width - FSave.Width - 16;

  FCancel := TButton.Create(Self);
  FCancel.Parent := FButtons;
  FCancel.Caption := 'Cancel';
  FCancel.ModalResult := mrCancel;
  FCancel.Cancel := True;
  FCancel.Width := 90;
  FCancel.Height := 28;
  FCancel.Top := 10;
  FCancel.Anchors := [akTop, akRight];
  FCancel.Left := FButtons.Width - FSave.Width - FCancel.Width - 26;

  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.Align := alClient;
  FMemo.AlignWithMargins := True;
  FMemo.Margins.SetBounds(12, 12, 12, 4);
  FMemo.BorderStyle := bsNone;
  FMemo.WordWrap := False;
  FMemo.ScrollBars := ssBoth;
  FMemo.Color := $00252526;
  FMemo.Font.Name := 'Consolas';
  FMemo.Font.Size := 10;
  FMemo.Font.Color := $00E6E6E6;
end;

class function TComposerMemoryForm.Execute(AOwner: TComponent): Boolean;
var
  LForm: TComposerMemoryForm;
begin
  Result := False;
  LForm := TComposerMemoryForm.CreateNew(AOwner);
  try
    LForm._BuildUI;
    LForm.FMemo.Lines.Text := LoadGlobalMemory;
    if LForm.ShowModal = mrOk then
    begin
      SaveGlobalMemory(LForm.FMemo.Lines.Text);
      Result := True;
    end;
  finally
    LForm.Free;
  end;
end;

end.
