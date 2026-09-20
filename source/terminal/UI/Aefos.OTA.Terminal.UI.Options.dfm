object TTerminalMCPOptionsFrame: TTerminalMCPOptionsFrame
  Left = 0
  Top = 0
  Width = 536
  Height = 440
  TabOrder = 0
  object lblTitle: TLabel
    Left = 16
    Top = 10
    Width = 500
    Height = 15
    Caption = 'In-IDE Terminal & MCP Server Configuration'
  end
  object gbMCPServer: TGroupBox
    Left = 16
    Top = 32
    Width = 500
    Height = 140
    Caption = ' In-IDE MCP Server '
    TabOrder = 0
    object LblMcpHelp: TLabel
      Left = 34
      Top = 46
      Width = 450
      Height = 15
      Caption = 'Allows external agents and MCP tools to access the IDE terminal.'
    end
    object LblSession: TLabel
      Left = 16
      Top = 72
      Width = 220
      Height = 15
      Caption = 'MCP Named Pipe (Advanced):'
    end
    object LblMcpStatus: TLabel
      Left = 330
      Top = 96
      Width = 150
      Height = 15
      AutoSize = True
    end
    object ChkEnabled: TCheckBox
      Left = 16
      Top = 24
      Width = 468
      Height = 17
      Caption = 'Enable MCP server'
      TabOrder = 0
    end
    object EdtSession: TEdit
      Left = 16
      Top = 92
      Width = 200
      Height = 23
      Hint = 
        'Named pipe the MCP server listens on. Change only to resolve a p' +
        'ipe-in-use conflict.'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 1
    end
    object BtnTestMcp: TButton
      Left = 224
      Top = 91
      Width = 96
      Height = 25
      Hint = 'Check the MCP pipe is listening'
      Caption = 'Test MCP'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 2
      OnClick = BtnTestMcpClick
    end
  end
  object gbAudit: TGroupBox
    Left = 16
    Top = 180
    Width = 500
    Height = 142
    Caption = ' Command Audit Log '
    TabOrder = 1
    object LblAuditPath: TLabel
      Left = 16
      Top = 22
      Width = 468
      Height = 15
      Caption = 'Audit log path (leave blank for system default):'
    end
    object LblAuditResolvedTag: TLabel
      Left = 16
      Top = 110
      Width = 80
      Height = 15
      Caption = 'Active folder:'
    end
    object LblAuditResolved: TLabel
      Left = 100
      Top = 110
      Width = 384
      Height = 15
      AutoSize = False
    end
    object EdtAuditPath: TEdit
      Left = 16
      Top = 42
      Width = 468
      Height = 23
      TabOrder = 0
    end
    object BtnOpenAuditDir: TButton
      Left = 16
      Top = 74
      Width = 160
      Height = 26
      Caption = 'Open Log Folder'
      TabOrder = 1
      OnClick = BtnOpenAuditDirClick
    end
  end
  object gbSecurity: TGroupBox
    Left = 16
    Top = 330
    Width = 500
    Height = 72
    Caption = ' Security & Consent '
    TabOrder = 2
    object LblConsentTimeout: TLabel
      Left = 16
      Top = 28
      Width = 370
      Height = 15
      AutoSize = True
      Caption = 
        'Consent timeout (seconds, 0 = wait indefinitely):'
    end
    object EdtConsentTimeout: TEdit
      Left = 405
      Top = 25
      Width = 79
      Height = 23
      TabOrder = 0
    end
  end
end
