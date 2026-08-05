object AefosTerminalSnippetsForm: TAefosTerminalSnippetsForm
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  Caption = 'Manage Snippets'
  ClientHeight = 561
  ClientWidth = 784
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  TextHeight = 15
  object pnlToolbar: TPanel
    Left = 0
    Top = 0
    Width = 784
    Height = 34
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object btnAdd: TSpeedButton
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 24
      Height = 28
      Hint = 'Add Snippet'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = btnAddClick
      ExplicitLeft = 6
      ExplicitTop = 4
      ExplicitHeight = 24
    end
    object btnEdit: TSpeedButton
      AlignWithMargins = True
      Left = 33
      Top = 3
      Width = 24
      Height = 28
      Hint = 'Edit Snippet'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = btnEditClick
      ExplicitLeft = 36
      ExplicitTop = 4
      ExplicitHeight = 24
    end
    object btnDelete: TSpeedButton
      AlignWithMargins = True
      Left = 63
      Top = 3
      Width = 24
      Height = 28
      Hint = 'Delete Snippet'
      Align = alLeft
      Flat = True
      ParentShowHint = False
      ShowHint = True
      OnClick = btnDeleteClick
      ExplicitLeft = 66
      ExplicitTop = 4
      ExplicitHeight = 24
    end
  end
  object lstSnippets: TListView
    Left = 0
    Top = 34
    Width = 784
    Height = 527
    Align = alClient
    Columns = <
      item
        Caption = 'Title'
        Width = 150
      end
      item
        Caption = 'Command'
        Width = 280
      end
      item
        Caption = 'Scope'
        Width = 80
      end
      item
        Caption = 'Tags'
        Width = 150
      end>
    ReadOnly = True
    RowSelect = True
    TabOrder = 1
    ViewStyle = vsReport
    OnDblClick = lstSnippetsDblClick
  end
end


