object AefosAddonStoreForm: TAefosAddonStoreForm
  Left = 0
  Top = 0
  ActiveControl = AefosWebView1
  BorderIcons = [biSystemMenu, biMaximize]
  Caption = 'Aefos Addons'
  ClientHeight = 620
  ClientWidth = 900
  Color = clBtnFace
  Constraints.MinHeight = 420
  Constraints.MinWidth = 640
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  TextHeight = 15
  object AefosWebView1: TAefosWebView
    Left = 0
    Top = 0
    Width = 900
    Height = 620
    Align = alClient
  end
end
