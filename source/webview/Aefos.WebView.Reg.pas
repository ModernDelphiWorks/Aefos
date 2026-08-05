unit Aefos.WebView.Reg;

{
  Design-time registration: puts TAefosWebView on the "Aefos" Tool Palette tab so
  it can be dropped on forms like any VCL control — a composition-hosted WebView2
  that does NOT blank when its host window is deactivated/docked (unlike the
  bundled Vcl.Edge.TEdgeBrowser). Lives in the design-time BPL (dclAefosWebView).
}

interface

procedure Register;

implementation

uses
  System.Classes,
  Aefos.WebView.Control;

procedure Register;
begin
  RegisterComponents('Aefos', [TAefosWebView]);
end;

end.
