object ActionCenterView: TActionCenterView
  Left = 0
  Top = 0
  BorderStyle = bsSizeable
  Caption = 'Aefos Action Center'
  ClientHeight = 441
  ClientWidth = 304
  Constraints.MinHeight = 320
  Constraints.MinWidth = 420
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  TextHeight = 15
  object FToolbar: TPanel
    Left = 0
    Top = 0
    Width = 304
    Height = 64
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object FBtnRun: TSpeedButton
      AlignWithMargins = True
      Left = 93
      Top = 36
      Width = 24
      Height = 25
      Hint = 'Run action'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = FBtnRunClick
      ExplicitLeft = 96
      ExplicitTop = 34
      ExplicitHeight = 24
    end
    object FBtnNew: TSpeedButton
      AlignWithMargins = True
      Left = 3
      Top = 36
      Width = 24
      Height = 25
      Hint = 'New action'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = FBtnNewClick
      ExplicitLeft = 8
      ExplicitTop = 35
      ExplicitHeight = 24
    end
    object FBtnEdit: TSpeedButton
      AlignWithMargins = True
      Left = 33
      Top = 36
      Width = 24
      Height = 25
      Hint = 'Edit action'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = FBtnEditClick
      ExplicitLeft = 36
      ExplicitTop = 35
      ExplicitHeight = 24
    end
    object FBtnDelete: TSpeedButton
      AlignWithMargins = True
      Left = 63
      Top = 36
      Width = 24
      Height = 25
      Hint = 'Delete action'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = FBtnDeleteClick
      ExplicitLeft = 64
      ExplicitTop = 35
      ExplicitHeight = 24
    end
    object FSearch: TEdit
      AlignWithMargins = True
      Left = 5
      Top = 5
      Width = 294
      Height = 23
      Margins.Left = 5
      Margins.Top = 5
      Margins.Right = 5
      Margins.Bottom = 5
      Align = alTop
      TabOrder = 0
      TextHint = 'Filter actions...'
      OnChange = FSearchChange
    end
    object FBtnImport: TSpeedButton
      AlignWithMargins = True
      Left = 123
      Top = 36
      Width = 24
      Height = 25
      Hint = 'Import actions'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = FBtnImportClick
    end
    object FBtnExport: TSpeedButton
      AlignWithMargins = True
      Left = 153
      Top = 36
      Width = 24
      Height = 25
      Hint = 'Export actions'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = FBtnExportClick
    end
  end
  object FTree: TTreeView
    Left = 0
    Top = 64
    Width = 304
    Height = 377
    Align = alClient
    HideSelection = False
    Indent = 19
    ReadOnly = True
    TabOrder = 1
    OnDblClick = FTreeDblClick
  end
end

