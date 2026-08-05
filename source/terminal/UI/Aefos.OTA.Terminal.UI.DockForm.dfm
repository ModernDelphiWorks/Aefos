object AefosTerminalDockForm: TAefosTerminalDockForm
  Left = 0
  Top = 0
  Caption = 'Aefos Terminal'
  ClientHeight = 240
  ClientWidth = 622
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object splSidebar: TSplitter
    Left = 489
    Top = 62
    Height = 178
    Align = alRight
  end
  object pnlFind: TPanel
    Left = 210
    Top = 40
    Width = 404
    Height = 36
    BevelOuter = bvNone
    TabOrder = 0
    Visible = False
    object edtFind: TEdit
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 190
      Height = 30
      Align = alLeft
      TabOrder = 0
      OnChange = edtFindChange
      OnKeyDown = edtFindKeyDown
      ExplicitHeight = 23
    end
    object btnFindNext: TSpeedButton
      AlignWithMargins = True
      Left = 199
      Top = 3
      Width = 26
      Height = 30
      Align = alLeft
      OnClick = btnFindNextClick
    end
    object btnFindPrev: TSpeedButton
      AlignWithMargins = True
      Left = 231
      Top = 3
      Width = 26
      Height = 30
      Align = alLeft
      OnClick = btnFindPrevClick
    end
    object chkCaseSensitive: TCheckBox
      AlignWithMargins = True
      Left = 263
      Top = 3
      Width = 60
      Height = 30
      Align = alLeft
      Caption = 'Case'
      TabOrder = 1
    end
    object lblFindCount: TLabel
      AlignWithMargins = True
      Left = 329
      Top = 3
      Width = 72
      Height = 30
      Align = alLeft
      Alignment = taCenter
      AutoSize = False
      Caption = ''
      Layout = tlCenter
    end
  end
  object pnlTerminalSidebar: TPanel
    Left = 492
    Top = 62
    Width = 130
    Height = 178
    Align = alRight
    BevelOuter = bvNone
    ParentBackground = False
    TabOrder = 1
    object lstTerminals: TListBox
      Left = 0
      Top = 0
      Width = 130
      Height = 178
      Style = lbOwnerDrawFixed
      Align = alClient
      BorderStyle = bsNone
      ItemHeight = 24
      TabOrder = 0
      OnClick = lstTerminalsClick
      OnDrawItem = lstTerminalsDrawItem
      OnMouseDown = lstTerminalsMouseDown
      OnMouseMove = lstTerminalsMouseMove
    end
  end
  object splSnippetsSidebar: TSplitter
    Left = 130
    Top = 62
    Height = 178
    Align = alLeft
    Visible = False
    ExplicitLeft = 130
  end
  object pnlSnippetsSidebar: TPanel
    Left = 0
    Top = 62
    Width = 130
    Height = 178
    Align = alLeft
    BevelOuter = bvNone
    ParentBackground = False
    TabOrder = 4
    Visible = False
  end
  object pgcTerminals: TPageControl
    Left = 0
    Top = 62
    Width = 489
    Height = 178
    Align = alClient
    MultiLine = True
    TabOrder = 2
    OnChange = _OnTabChange
  end
  object pnlToolbar: TAefosTerminalToolbarPanel
    Left = 0
    Top = 0
    Width = 622
    Height = 32
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 3
    object btnNewTab: TSpeedButton
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 36
      Height = 26
      Align = alLeft
      OnClick = btnNewTabClick
      ExplicitLeft = 6
      ExplicitTop = 4
      ExplicitHeight = 24
    end
    object btnActions: TSpeedButton
      AlignWithMargins = True
      Left = 45
      Top = 3
      Width = 30
      Height = 26
      Align = alLeft
      OnClick = btnActionsClick
    end
    object btnClosePane: TSpeedButton
      AlignWithMargins = True
      Left = 595
      Top = 3
      Width = 24
      Height = 26
      Align = alRight
      OnClick = btnClosePaneClick
      ExplicitLeft = 592
      ExplicitTop = 4
      ExplicitHeight = 24
    end
    object btnShowFind: TSpeedButton
      AlignWithMargins = True
      Left = 565
      Top = 3
      Width = 24
      Height = 26
      Align = alRight
      OnClick = btnShowFindClick
      ExplicitLeft = 562
      ExplicitTop = 4
      ExplicitHeight = 24
    end
    object btnSplitV: TSpeedButton
      AlignWithMargins = True
      Left = 535
      Top = 3
      Width = 24
      Height = 26
      Align = alRight
      OnClick = btnSplitVClick
      ExplicitLeft = 532
      ExplicitTop = 4
      ExplicitHeight = 24
    end
    object btnSplitH: TSpeedButton
      AlignWithMargins = True
      Left = 505
      Top = 3
      Width = 24
      Height = 26
      Align = alRight
      OnClick = btnSplitHClick
      ExplicitLeft = 502
      ExplicitTop = 4
      ExplicitHeight = 24
    end
    object btnSnippetsSidebar: TSpeedButton
      AlignWithMargins = True
      Left = 140
      Top = 3
      Width = 30
      Height = 26
      Align = alLeft
    end
  end
  object dlgFont: TFontDialog
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = []
    Left = 240
    Top = 120
  end
end


