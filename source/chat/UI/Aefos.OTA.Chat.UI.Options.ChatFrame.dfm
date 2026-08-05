object AefosChatOptionsFrame: TAefosChatOptionsFrame
  Left = 0
  Top = 0
  Width = 500
  Height = 687
  TabOrder = 0
  object LabelHeading: TLabel
    Left = 16
    Top = 12
    Width = 133
    Height = 15
    Caption = 'Chat / Executor settings'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object LabelExecutor: TLabel
    Left = 16
    Top = 48
    Width = 48
    Height = 15
    Caption = 'Executor:'
  end
  object LabelExecutorPath: TLabel
    Left = 16
    Top = 96
    Width = 75
    Height = 15
    Caption = 'Executor path:'
  end
  object LabelModel: TLabel
    Left = 16
    Top = 170
    Width = 37
    Height = 15
    Caption = 'Model:'
  end
  object LabelTimeout: TLabel
    Left = 16
    Top = 218
    Width = 123
    Height = 15
    Caption = 'Run timeout (seconds):'
  end
  object LabelOutputFilter: TLabel
    Left = 280
    Top = 218
    Width = 68
    Height = 15
    Caption = 'Output filter:'
  end
  object LabelNote: TLabel
    Left = 16
    Top = 30
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
  object LabelRequirementsHeading: TLabel
    Left = 16
    Top = 563
    Width = 79
    Height = 15
    Caption = 'Requirements'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object LabelRequirements: TLabel
    Left = 16
    Top = 583
    Width = 468
    Height = 96
    AutoSize = False
    WordWrap = True
  end
  object LabelMcpHeading: TLabel
    Left = 16
    Top = 395
    Width = 72
    Height = 15
    Caption = 'MCP settings'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object LabelAuditCaption: TLabel
    Left = 16
    Top = 419
    Width = 79
    Height = 15
    Caption = 'Audit log path:'
  end
  object LabelServerCaption: TLabel
    Left = 16
    Top = 471
    Width = 63
    Height = 15
    Caption = 'MCP server:'
  end
  object LabelTestStatus: TLabel
    Left = 348
    Top = 68
    Width = 3
    Height = 15
  end
  object ComboExecutor: TComboBox
    Left = 16
    Top = 66
    Width = 240
    Height = 23
    Style = csDropDownList
    TabOrder = 0
    OnChange = ComboExecutorChange
  end
  object EditExecutorPath: TEdit
    Left = 16
    Top = 114
    Width = 330
    Height = 23
    TabOrder = 1
  end
  object ButtonBrowse: TButton
    Left = 352
    Top = 113
    Width = 60
    Height = 25
    Caption = 'Browse...'
    TabOrder = 2
    OnClick = ButtonBrowseClick
  end
  object ButtonLogin: TButton
    Left = 420
    Top = 113
    Width = 64
    Height = 25
    Hint = 'Run "<cli> login" in a console to authenticate (Copilot/Codex)'
    Caption = 'Login'
    ParentShowHint = False
    ShowHint = True
    TabOrder = 11
    OnClick = ButtonLoginClick
  end
  object LabelDownloadCli: TLabel
    Cursor = crHandPoint
    Left = 16
    Top = 141
    Width = 172
    Height = 15
    Caption = 'Download the CLI -> official page'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clHotLight
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = [fsUnderline]
    ParentFont = False
    OnClick = LabelDownloadCliClick
  end
  object ComboModel: TComboBox
    Left = 16
    Top = 188
    Width = 320
    Height = 23
    TabOrder = 3
  end
  object ButtonAddModel: TButton
    Left = 344
    Top = 187
    Width = 28
    Height = 25
    Hint = 'Add the typed model to the list'
    Caption = '+'
    ParentShowHint = False
    ShowHint = True
    TabOrder = 10
    OnClick = ButtonAddModelClick
  end
  object ButtonRemoveModel: TButton
    Left = 376
    Top = 187
    Width = 28
    Height = 25
    Hint = 'Remove the typed/selected model from the list'
    Caption = '-'
    ParentShowHint = False
    ShowHint = True
    TabOrder = 12
    OnClick = ButtonRemoveModelClick
  end
  object EditTimeout: TEdit
    Left = 16
    Top = 236
    Width = 80
    Height = 23
    TabOrder = 4
    Text = '0'
  end
  object ComboOutputFilter: TComboBox
    Left = 280
    Top = 236
    Width = 204
    Height = 23
    Style = csDropDownList
    TabOrder = 5
  end
  object PageProviders: TPageControl
    Left = 16
    Top = 271
    Width = 468
    Height = 108
    ActivePage = TabGemini
    TabOrder = 13
    object TabGemini: TTabSheet
      Caption = 'Gemini'
      object LabelApiKey: TLabel
        Left = 12
        Top = 10
        Width = 43
        Height = 15
        Caption = 'API key:'
      end
      object EditApiKey: TEdit
        Left = 12
        Top = 30
        Width = 300
        Height = 23
        PasswordChar = '*'
        TabOrder = 0
        TextHint = 'paste your Gemini API key'
        OnExit = EditApiKeyExit
      end
      object LabelApiKeyGetLink: TLabel
        Cursor = crHandPoint
        Left = 12
        Top = 56
        Width = 199
        Height = 15
        Caption = 'Get a free API key -> Google AI Studio'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clHotLight
        Font.Height = -12
        Font.Name = 'Segoe UI'
        Font.Style = [fsUnderline]
        ParentFont = False
        OnClick = LabelApiKeyGetLinkClick
      end
    end
    object TabOllama: TTabSheet
      Caption = 'Ollama'
      object LabelOllamaUrl: TLabel
        Left = 12
        Top = 10
        Width = 76
        Height = 15
        Caption = 'Endpoint URL:'
      end
      object EditOllamaUrl: TEdit
        Left = 12
        Top = 30
        Width = 300
        Height = 23
        TabOrder = 0
        TextHint = 'http://localhost:11434'
      end
    end
  end
  object EditAuditPath: TEdit
    Left = 16
    Top = 437
    Width = 468
    Height = 23
    ReadOnly = True
    TabOrder = 6
  end
  object EditServerInfo: TEdit
    Left = 16
    Top = 489
    Width = 468
    Height = 23
    ReadOnly = True
    TabOrder = 8
  end
  object ButtonTestConnection: TButton
    Left = 272
    Top = 64
    Width = 70
    Height = 25
    Caption = 'Test CLI'
    TabOrder = 7
    OnClick = ButtonTestConnectionClick
  end
  object ButtonTestMcp: TButton
    Left = 16
    Top = 523
    Width = 130
    Height = 25
    Caption = 'Test MCP'
    TabOrder = 9
    OnClick = ButtonTestMcpClick
  end
  object LabelMcpTestStatus: TLabel
    Left = 156
    Top = 528
    Width = 3
    Height = 15
  end
  object OpenDialog: TOpenDialog
    Filter = 'Executable (*.exe)|*.exe|All files (*.*)|*.*'
    Options = [ofPathMustExist, ofFileMustExist, ofEnableSizing]
    Left = 432
    Top = 168
  end
end
