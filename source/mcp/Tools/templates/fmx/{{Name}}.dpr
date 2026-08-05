program {{Name}};

uses
  FMX.Forms,
  MainForm in 'MainForm.pas' {MainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, frmMain);
  Application.Run;
end.
