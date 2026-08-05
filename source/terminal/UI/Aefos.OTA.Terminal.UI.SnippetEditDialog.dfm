object SnippetEditDialog: TSnippetEditDialog
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu, biMaximize]
  Caption = 'Edit Snippet'
  ClientHeight = 560
  ClientWidth = 686
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  DesignSize = (
    686
    560)
  TextHeight = 15
  object lblTitle: TLabel
    Left = 10
    Top = 10
    Width = 26
    Height = 15
    Caption = 'Title:'
  end
  object lblScope: TLabel
    Left = 10
    Top = 60
    Width = 38
    Height = 15
    Caption = 'Scope:'
  end
  object lblTags: TLabel
    Left = 10
    Top = 88
    Width = 130
    Height = 15
    Caption = 'Tags (comma-separated):'
  end
  object lblCommand: TLabel
    Left = 10
    Top = 138
    Width = 60
    Height = 15
    Caption = 'Command:'
  end
  object lblChips: TLabel
    Left = 10
    Top = 294
    Width = 54
    Height = 15
    Caption = 'Variables:'
  end
  object lblPreview: TLabel
    Left = 10
    Top = 374
    Width = 101
    Height = 15
    Caption = 'Preview (resolved):'
  end
  object edtTitle: TEdit
    Left = 10
    Top = 28
    Width = 662
    Height = 23
    Anchors = [akLeft, akTop, akRight]
    TabOrder = 0
  end
  object rbPersonal: TRadioButton
    Left = 64
    Top = 58
    Width = 80
    Height = 17
    Caption = 'Personal'
    Checked = True
    TabOrder = 1
    TabStop = True
  end
  object rbProject: TRadioButton
    Left = 150
    Top = 58
    Width = 80
    Height = 17
    Caption = 'Project'
    TabOrder = 2
  end
  object rbTeam: TRadioButton
    Left = 236
    Top = 58
    Width = 70
    Height = 17
    Caption = 'Team'
    TabOrder = 3
  end
  object edtTags: TEdit
    Left = 10
    Top = 106
    Width = 662
    Height = 23
    Anchors = [akLeft, akTop, akRight]
    TabOrder = 4
  end
  object memCommand: TMemo
    Left = 10
    Top = 156
    Width = 662
    Height = 130
    Anchors = [akLeft, akTop, akRight]
    Font.Charset = ANSI_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ScrollBars = ssVertical
    TabOrder = 5
    OnChange = memCommandChange
  end
  object pnlChips: TFlowPanel
    Left = 10
    Top = 312
    Width = 662
    Height = 56
    Anchors = [akLeft, akTop, akRight]
    BevelOuter = bvNone
    TabOrder = 6
  end
  object memPreview: TMemo
    Left = 10
    Top = 392
    Width = 662
    Height = 118
    Anchors = [akLeft, akTop, akRight, akBottom]
    Font.Charset = ANSI_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 7
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 520
    Width = 686
    Height = 40
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 8
    DesignSize = (
      686
      40)
    object btnOK: TButton
      Left = 513
      Top = 8
      Width = 75
      Height = 25
      Anchors = [akTop, akRight]
      Caption = 'Save'
      Default = True
      ModalResult = 1
      TabOrder = 0
      OnClick = btnOKClick
    end
    object btnCancel: TButton
      Left = 597
      Top = 8
      Width = 75
      Height = 25
      Anchors = [akTop, akRight]
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 1
    end
  end
end

