object AefosProvidersOptionsFrame: TAefosProvidersOptionsFrame
  Left = 0
  Top = 0
  Width = 650
  Height = 650
  TabOrder = 0
  object PanelMaster: TPanel
    Left = 0
    Top = 0
    Width = 220
    Height = 650
    Align = alLeft
    BevelOuter = bvNone
    TabOrder = 0
    object LabelInstalled: TLabel
      Left = 12
      Top = 12
      Width = 110
      Height = 15
      Caption = 'Installed Agents'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object EditFilter: TEdit
      Left = 12
      Top = 32
      Width = 196
      Height = 23
      TabOrder = 0
      TextHint = 'Filter agents...'
      OnChange = EditFilterChange
    end
    object ListBoxAgents: TListBox
      Left = 12
      Top = 64
      Width = 196
      Height = 528
      ItemHeight = 24
      TabOrder = 1
      OnClick = ListBoxAgentsClick
      OnDblClick = ListBoxAgentsDblClick
    end
    object ButtonCatalogLink: TButton
      Left = 12
      Top = 604
      Width = 196
      Height = 32
      Caption = '+ Browse Agent Catalog...'
      TabOrder = 2
      OnClick = ButtonCatalogLinkClick
    end
  end
  object Splitter1: TSplitter
    Left = 220
    Top = 0
    Width = 4
    Height = 650
  end
  object PanelDetail: TPanel
    Left = 224
    Top = 0
    Width = 426
    Height = 650
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 1
    object LabelAgentHeader: TLabel
      Left = 16
      Top = 12
      Width = 120
      Height = 18
      Caption = 'Agent Details'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -15
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object LabelStatus: TLabel
      Left = 16
      Top = 36
      Width = 84
      Height = 15
      Caption = 'Status: Ready'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
    end
    object GroupBoxAuth: TGroupBox
      Left = 16
      Top = 68
      Width = 394
      Height = 150
      Caption = 'Authentication && Subscription'
      TabOrder = 0
      object RadioOAuth: TRadioButton
        Left = 16
        Top = 24
        Width = 250
        Height = 17
        Caption = 'Subscription (Browser Login)'
        Checked = True
        TabOrder = 0
        TabStop = True
        OnClick = RadioOAuthClick
      end
      object ButtonLoginBrowser: TButton
        Left = 36
        Top = 48
        Width = 130
        Height = 28
        Caption = 'Login / Connect'
        TabOrder = 1
        OnClick = ButtonLoginBrowserClick
      end
      object LabelAuthStatus: TLabel
        Left = 176
        Top = 54
        Width = 100
        Height = 15
        Caption = 'Status: Connected'
        Font.Color = clGreen
      end
      object RadioApiKey: TRadioButton
        Left = 16
        Top = 86
        Width = 200
        Height = 17
        Caption = 'API Key / Token'
        TabOrder = 2
        OnClick = RadioApiKeyClick
      end
      object EditApiKey: TEdit
        Left = 36
        Top = 110
        Width = 340
        Height = 23
        PasswordChar = '*'
        TabOrder = 3
        TextHint = 'Paste your API key here...'
      end
    end
    object GroupBoxModels: TGroupBox
      Left = 16
      Top = 228
      Width = 394
      Height = 120
      Caption = 'Supported Models (ACP)'
      TabOrder = 1
      object LabelModelSelect: TLabel
        Left = 16
        Top = 26
        Width = 44
        Height = 15
        Caption = 'Model:'
      end
      object ComboBoxModels: TComboBox
        Left = 16
        Top = 46
        Width = 290
        Height = 23
        Style = csDropDownList
        TabOrder = 0
      end
      object ButtonAddModel: TButton
        Left = 312
        Top = 45
        Width = 32
        Height = 25
        Caption = '+'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -13
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
        TabOrder = 1
        OnClick = ButtonAddModelClick
      end
      object ButtonRemoveModel: TButton
        Left = 348
        Top = 45
        Width = 32
        Height = 25
        Caption = '-'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -13
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
        TabOrder = 2
        OnClick = ButtonRemoveModelClick
      end
      object LabelContextInfo: TLabel
        Left = 16
        Top = 82
        Width = 240
        Height = 15
        Caption = 'Context: 200k tokens | Tools: Yes'
        Font.Color = clGrayText
      end
    end
    object GroupBoxMCP: TGroupBox
      Left = 16
      Top = 360
      Width = 394
      Height = 110
      Caption = 'Aefos MCP Integration'
      TabOrder = 2
      object CheckBoxShareMCP: TCheckBox
        Left = 16
        Top = 28
        Width = 360
        Height = 17
        Caption = 'Share IDE tools with the agent'
        Checked = True
        State = cbChecked
        TabOrder = 0
      end
      object CheckBoxConsent: TCheckBox
        Left = 16
        Top = 56
        Width = 360
        Height = 17
        Caption = 'Require consent before modifying code files'
        Checked = True
        State = cbChecked
        TabOrder = 1
      end
    end
    object ButtonSetActive: TButton
      Left = 16
      Top = 490
      Width = 180
      Height = 34
      Caption = 'Set as Default Agent'
      TabOrder = 3
      OnClick = ButtonSetActiveClick
    end
    object ButtonTestConnection: TButton
      Left = 210
      Top = 490
      Width = 140
      Height = 34
      Caption = 'Test Connection'
      TabOrder = 4
      OnClick = ButtonTestConnectionClick
    end
  end
end
