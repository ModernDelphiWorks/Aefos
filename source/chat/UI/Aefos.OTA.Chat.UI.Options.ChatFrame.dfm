object AefosChatOptionsFrame: TAefosChatOptionsFrame
  Left = 0
  Top = 0
  Width = 500
  Height = 560
  TabOrder = 0
  object LabelHeading: TLabel
    Left = 16
    Top = 16
    Width = 118
    Height = 15
    Caption = 'Chat & MCP Settings'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object LabelNote: TLabel
    Left = 16
    Top = 36
    Width = 320
    Height = 15
    Caption = 'No active Delphi project '#8212' open a project to edit its settings.'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clRed
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    Visible = False
  end
  object GroupBoxExecution: TGroupBox
    Left = 16
    Top = 56
    Width = 468
    Height = 88
    Caption = 'Chat Execution'
    TabOrder = 0
    object LabelTimeout: TLabel
      Left = 16
      Top = 24
      Width = 123
      Height = 15
      Caption = 'Run timeout (seconds):'
    end
    object LabelOutputFilter: TLabel
      Left = 230
      Top = 24
      Width = 68
      Height = 15
      Caption = 'Output filter:'
    end
    object EditTimeout: TEdit
      Left = 16
      Top = 45
      Width = 80
      Height = 23
      TabOrder = 0
      Text = '0'
    end
    object ComboOutputFilter: TComboBox
      Left = 230
      Top = 45
      Width = 220
      Height = 23
      Style = csDropDownList
      TabOrder = 1
    end
  end
  object GroupBoxMCP: TGroupBox
    Left = 16
    Top = 156
    Width = 468
    Height = 194
    Caption = 'MCP Settings'
    TabOrder = 1
    object LabelAuditCaption: TLabel
      Left = 16
      Top = 24
      Width = 79
      Height = 15
      Caption = 'Audit log path:'
    end
    object EditAuditPath: TEdit
      Left = 16
      Top = 44
      Width = 434
      Height = 23
      ReadOnly = True
      TabOrder = 0
    end
    object LabelServerCaption: TLabel
      Left = 16
      Top = 78
      Width = 63
      Height = 15
      Caption = 'MCP server:'
    end
    object EditServerInfo: TEdit
      Left = 16
      Top = 98
      Width = 434
      Height = 23
      ReadOnly = True
      TabOrder = 1
    end
    object ButtonTestMcp: TButton
      Left = 16
      Top = 140
      Width = 110
      Height = 28
      Caption = 'Test MCP'
      TabOrder = 2
      OnClick = ButtonTestMcpClick
    end
    object LabelMcpTestStatus: TLabel
      Left = 136
      Top = 146
      Width = 3
      Height = 15
    end
  end
  object GroupBoxRequirements: TGroupBox
    Left = 16
    Top = 362
    Width = 468
    Height = 160
    Caption = 'Requirements'
    TabOrder = 2
    object LabelRequirements: TLabel
      Left = 16
      Top = 24
      Width = 434
      Height = 120
      AutoSize = False
      WordWrap = True
    end
  end
end
