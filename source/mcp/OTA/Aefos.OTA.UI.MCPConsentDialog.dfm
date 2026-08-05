object TMCPConsentDialog: TMCPConsentDialog
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = 'Aefos AI - permission required'
  ClientHeight = 372
  ClientWidth = 560
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  TextHeight = 15
  object shpBadge: TShape
    Left = 22
    Top = 20
    Width = 42
    Height = 42
    Brush.Color = 3684408
    Pen.Color = 4948935
    Shape = stRoundSquare
  end
  object lblBadge: TLabel
    Left = 22
    Top = 20
    Width = 42
    Height = 42
    Alignment = taCenter
    AutoSize = False
    Caption = #128274
    Font.Charset = DEFAULT_CHARSET
    Font.Color = 4948935
    Font.Height = -19
    Font.Name = 'Segoe UI Emoji'
    Font.Style = []
    Layout = tlCenter
    ParentFont = False
    Transparent = True
  end
  object lblHeading: TLabel
    Left = 77
    Top = 21
    Width = 461
    Height = 22
    AutoSize = False
    Caption = 'Permission required'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -16
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object lblSummary: TLabel
    Left = 77
    Top = 44
    Width = 461
    Height = 34
    AutoSize = False
    Caption =
      'The AI wants to run an action that changes project files. You dec' +
      'ide whether it can.'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    WordWrap = True
  end
  object lblTool: TLabel
    Left = 22
    Top = 90
    Width = 200
    Height = 21
    AutoSize = False
    Caption = 'tool'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = 4948935
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    Layout = tlCenter
    ParentFont = False
    ShowAccelChar = False
  end
  object lblToolHint: TLabel
    Left = 230
    Top = 90
    Width = 200
    Height = 21
    AutoSize = False
    Caption = 'Aefos MCP tool'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'Segoe UI'
    Font.Style = []
    Layout = tlCenter
    ParentFont = False
  end
  object lblWhat: TLabel
    Left = 22
    Top = 120
    Width = 516
    Height = 34
    AutoSize = False
    Caption = 'A destructive action requires your confirmation.'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    WordWrap = True
  end
  object lblDetailLabel: TLabel
    Left = 22
    Top = 162
    Width = 200
    Height = 15
    AutoSize = False
    Caption = 'PREVIEW'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object lblFootHint: TLabel
    Left = 22
    Top = 330
    Width = 220
    Height = 17
    AutoSize = False
    Caption = 'Safe default: Deny.'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'Segoe UI'
    Font.Style = []
    Layout = tlCenter
    ParentFont = False
  end
  object memoDetail: TMemo
    Left = 22
    Top = 181
    Width = 516
    Height = 132
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssBoth
    TabOrder = 3
    WordWrap = False
  end
  object btnDeny: TButton
    Left = 198
    Top = 328
    Width = 72
    Height = 30
    Cancel = True
    Caption = 'Deny'
    Default = True
    TabOrder = 0
    OnClick = btnDenyClick
  end
  object btnAllowSession: TButton
    Left = 278
    Top = 328
    Width = 152
    Height = 30
    Caption = 'Allow for this session'
    TabOrder = 1
    OnClick = btnAllowSessionClick
  end
  object btnAllowOnce: TButton
    Left = 438
    Top = 328
    Width = 100
    Height = 30
    Caption = 'Allow once'
    TabOrder = 2
    OnClick = btnAllowOnceClick
  end
end
