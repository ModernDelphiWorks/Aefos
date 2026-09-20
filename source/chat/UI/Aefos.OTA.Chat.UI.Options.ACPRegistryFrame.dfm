object AefosACPRegistryOptionsFrame: TAefosACPRegistryOptionsFrame
  Left = 0
  Top = 0
  Width = 620
  Height = 650
  TabOrder = 0
  object PanelTop: TPanel
    Left = 0
    Top = 0
    Width = 620
    Height = 84
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object LabelTitle: TLabel
      Left = 16
      Top = 10
      Width = 145
      Height = 18
      Caption = 'Agent Catalog'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -15
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object LabelSubtitle: TLabel
      Left = 16
      Top = 32
      Width = 330
      Height = 15
      Caption = 'Discover and install agents compatible with the ACP standard.'
    end
    object LabelPortalLink: TLabel
      Left = 16
      Top = 54
      Width = 270
      Height = 15
      Cursor = crHandPoint
      Caption = 'Browse all agents on the Official ACP Portal (Web) ->'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clHotLight
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsUnderline]
      ParentFont = False
      OnClick = LabelPortalLinkClick
    end
    object EditSearch: TEdit
      Left = 356
      Top = 26
      Width = 136
      Height = 23
      Anchors = [akTop, akRight]
      TabOrder = 0
      TextHint = 'Filter agents...'
      OnChange = EditSearchChange
    end
    object ButtonUpdateCatalog: TButton
      Left = 498
      Top = 24
      Width = 110
      Height = 27
      Anchors = [akTop, akRight]
      Caption = 'Update Catalog'
      TabOrder = 1
      OnClick = ButtonUpdateCatalogClick
    end
  end
  object ScrollBoxCards: TScrollBox
    Left = 0
    Top = 84
    Width = 620
    Height = 566
    Align = alClient
    BorderStyle = bsNone
    HorzScrollBar.Visible = False
    TabOrder = 1
  end
end
