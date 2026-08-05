program {{Name}};

uses
  Vcl.Forms,
  MainForm in 'MainForm.pas' {MainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, frmMain);
  Application.Run;
end.
