object AefosTerminalFontDialog: TAefosTerminalFontDialog
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Font Settings'
  ClientHeight = 340
  ClientWidth = 460
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  TextHeight = 15
  object lblFontTitle: TLabel
    Left = 12
    Top = 10
    Width = 33
    Height = 15
    Caption = 'Font:'
  end
  object lblSizeTitle: TLabel
    Left = 330
    Top = 10
    Width = 53
    Height = 15
    Caption = 'Size:'
  end
  object lstFonts: TListBox
    Left = 12
    Top = 28
    Width = 300
    Height = 160
    ItemHeight = 15
    TabOrder = 0
    OnClick = lstFontsClick
  end
  object lstSizes: TListBox
    Left = 330
    Top = 28
    Width = 118
    Height = 160
    ItemHeight = 15
    Items.Strings = (
      '8'
      '9'
      '10'
      '11'
      '12'
      '14'
      '16'
      '18'
      '20'
      '22'
      '24'
      '26'
      '28'
      '36')
    TabOrder = 1
    OnClick = lstSizesClick
  end
  object gbxPreview: TGroupBox
    Left = 12
    Top = 200
    Width = 436
    Height = 85
    Caption = 'Preview'
    TabOrder = 2
    object lblPreview: TLabel
      Left = 2
      Top = 17
      Width = 432
      Height = 66
      Align = alClient
      Alignment = taCenter
      Caption = 'AaBbYyZz 0123 >= <='
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -16
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      Layout = tlCenter
      ExplicitLeft = 10
      ExplicitTop = 20
      ExplicitWidth = 161
      ExplicitHeight = 21
    end
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 295
    Width = 460
    Height = 45
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 3
    object btnOK: TButton
      Left = 286
      Top = 8
      Width = 78
      Height = 26
      Caption = 'OK'
      Default = True
      ModalResult = 1
      TabOrder = 0
    end
    object btnCancel: TButton
      Left = 370
      Top = 8
      Width = 78
      Height = 26
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 1
    end
  end
end


