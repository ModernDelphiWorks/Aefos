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
    Height = 70
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object LabelTitle: TLabel
      Left = 16
      Top = 12
      Width = 145
      Height = 18
      Caption = 'Cat'#225'logo de Agentes'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -15
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object LabelSubtitle: TLabel
      Left = 16
      Top = 36
      Width = 380
      Height = 15
      Caption = 'Descubra e instale agentes compat'#237'veis com o protocolo ACP para o Chat.'
    end
    object EditSearch: TEdit
      Left = 320
      Top = 26
      Width = 160
      Height = 23
      TabOrder = 0
      TextHint = 'Filtrar agentes...'
      OnChange = EditSearchChange
    end
    object ButtonUpdateCatalog: TButton
      Left = 490
      Top = 24
      Width = 114
      Height = 27
      Caption = 'Atualizar Cat'#225'logo'
      TabOrder = 1
      OnClick = ButtonUpdateCatalogClick
    end
  end
  object ScrollBoxCards: TScrollBox
    Left = 0
    Top = 70
    Width = 620
    Height = 580
    Align = alClient
    BorderStyle = bsNone
    TabOrder = 1
  end
end
