object TTerminalMCPOptionsFrame: TTerminalMCPOptionsFrame
  Left = 0
  Top = 0
  Width = 450
  Height = 260
  TabOrder = 0
  object LblEnabled: TLabel
    Left = 8
    Top = 8
    Width = 100
    Height = 13
    Caption = 'MCP Server'
  end
  object ChkEnabled: TCheckBox
    Left = 8
    Top = 28
    Width = 200
    Height = 17
    Caption = 'Enable MCP server'
    TabOrder = 0
  end
  object LblSession: TLabel
    Left = 8
    Top = 56
    Width = 130
    Height = 13
    Caption = 'MCP pipe (advanced):'
  end
  object EdtSession: TEdit
    Left = 8
    Top = 72
    Width = 200
    Height = 21
    Hint = 'Named pipe the MCP server listens on. Change only to resolve a pipe-in-use conflict.'
    ParentShowHint = False
    ShowHint = True
    TabOrder = 1
  end
  object BtnTestMcp: TButton
    Left = 216
    Top = 70
    Width = 96
    Height = 25
    Hint = 'Check the MCP pipe is listening'
    Caption = 'Test MCP'
    ParentShowHint = False
    ShowHint = True
    TabOrder = 5
    OnClick = BtnTestMcpClick
  end
  object LblMcpStatus: TLabel
    Left = 320
    Top = 75
    Width = 3
    Height = 13
  end
  object LblAuditPath: TLabel
    Left = 8
    Top = 104
    Width = 64
    Height = 13
    Caption = 'Audit log path:'
  end
  object EdtAuditPath: TEdit
    Left = 8
    Top = 120
    Width = 350
    Height = 21
    TabOrder = 2
  end
  object BtnOpenAuditDir: TButton
    Left = 8
    Top = 152
    Width = 160
    Height = 25
    Caption = 'Open audit-log folder'
    TabOrder = 3
    OnClick = BtnOpenAuditDirClick
  end
  object LblAuditResolved: TLabel
    Left = 8
    Top = 188
    Width = 420
    Height = 13
    AutoSize = False
    Caption = ''
    WordWrap = False
  end
  object LblConsentTimeout: TLabel
    Left = 8
    Top = 214
    Width = 218
    Height = 13
    Caption = 'Consent timeout (seconds, 0 = wait forever):'
  end
  object EdtConsentTimeout: TEdit
    Left = 232
    Top = 211
    Width = 60
    Height = 21
    TabOrder = 4
  end
end
