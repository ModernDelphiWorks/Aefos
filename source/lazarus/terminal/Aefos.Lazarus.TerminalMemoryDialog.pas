unit Aefos.Lazarus.TerminalMemoryDialog;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

{
  Global-memory editor for the Lazarus terminal composer's brain (memory) button.
  A tiny dark LCL dialog (TMemo + Save / Cancel) that edits the SAME file the chat
  and the Delphi terminal edit: %APPDATA%\Aefos\memory.md (one brain across both
  IDEs). The load/save go through TAefosLazMemoryStore, which is byte-compatible
  with the Delphi twin (UTF-8 + BOM), so a memory edited in one IDE shows up in the
  other.

  Built in code (no .lfm), modal, English-only, ASCII source (no BOM). Static
  facade (house rule: no loose exported routines).
}

interface

uses
  Classes;

type
  TAefosLazTerminalMemoryDialog = class
  public
    // Loads the global memory into the editor, shows it modally, and persists the
    // edited text on Save. Returns True when the user saved. Caller owns nothing.
    class function Execute(AOwner: TComponent): Boolean; static;
  end;

implementation

uses
  SysUtils,
  Controls,
  Forms,
  StdCtrls,
  ExtCtrls,
  Graphics,
  Aefos.Lazarus.MemoryStore;

class function TAefosLazTerminalMemoryDialog.Execute(AOwner: TComponent): Boolean;
var
  LForm: TForm;
  LMemo: TMemo;
  LButtons: TPanel;
  LSave, LCancel: TButton;
  LRoot: string;
begin
  Result := False;
  // The SHARED %APPDATA%\Aefos root -- the same file the chat memory store and the
  // Delphi terminal composer read/write (one brain).
  LRoot := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('APPDATA'))
    + 'Aefos';

  LForm := TForm.CreateNew(AOwner);
  try
    LForm.Caption := 'Aefos Memory';
    LForm.Width := 540;
    LForm.Height := 440;
    LForm.Position := poScreenCenter;
    LForm.BorderStyle := bsSizeable;
    LForm.Color := TColor($001E1E1E);

    // Button strip at the bottom (built first so the memo's alClient fills above it).
    LButtons := TPanel.Create(LForm);
    LButtons.Parent := LForm;
    LButtons.Align := alBottom;
    LButtons.Height := 44;
    LButtons.BevelOuter := bvNone;
    LButtons.Color := TColor($00252526);

    LSave := TButton.Create(LForm);
    LSave.Parent := LButtons;
    LSave.Caption := 'Save';
    LSave.ModalResult := mrOK;
    LSave.Default := True;
    LSave.Width := 84;
    LSave.Height := 26;
    LSave.Top := 9;
    LSave.Left := LButtons.Width - 84 - 12;
    LSave.Anchors := [akTop, akRight];

    LCancel := TButton.Create(LForm);
    LCancel.Parent := LButtons;
    LCancel.Caption := 'Cancel';
    LCancel.ModalResult := mrCancel;
    LCancel.Cancel := True;
    LCancel.Width := 84;
    LCancel.Height := 26;
    LCancel.Top := 9;
    LCancel.Left := LButtons.Width - 84 - 12 - 84 - 8;
    LCancel.Anchors := [akTop, akRight];

    LMemo := TMemo.Create(LForm);
    LMemo.Parent := LForm;
    LMemo.Align := alClient;
    LMemo.BorderStyle := bsNone;
    LMemo.Color := TColor($001E1E1E);
    LMemo.Font.Color := TColor($00E6E6E6);
    LMemo.Font.Name := 'Consolas';
    LMemo.Font.Size := 10;
    LMemo.ScrollBars := ssVertical;
    LMemo.WordWrap := True;

    // Load the shared memory (UTF-8; TMemo.Lines is UTF-8 at the LCL boundary).
    LMemo.Lines.Text := TAefosLazMemoryStore.Load(LRoot);

    if LForm.ShowModal = mrOK then
    begin
      TAefosLazMemoryStore.Save(LRoot, LMemo.Lines.Text);
      Result := True;
    end;
  finally
    LForm.Free;
  end;
end;

end.
