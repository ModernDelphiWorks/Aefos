object AefosChatPanel: TAefosChatPanel
  Left = 0
  Top = 0
  Caption = 'Aefos Chat'
  ClientHeight = 615
  ClientWidth = 420
  Color = 1578261
  DoubleBuffered = True
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object FSplitter: TSplitter
    Left = 0
    Top = 426
    Width = 420
    Height = 4
    Cursor = crVSplit
    Align = alBottom
    Color = 1578261
    ParentColor = False
    ExplicitTop = 435
  end
  object FHeaderPanel: TPanel
    Left = 0
    Top = 0
    Width = 420
    Height = 36
    Align = alTop
    BevelOuter = bvNone
    Color = 1184271
    ParentBackground = False
    ShowCaption = False
    TabOrder = 0
    object FLabelChatTab: TLabel
      Left = 16
      Top = 10
      Width = 44
      Height = 15
      Caption = #10022' CHAT'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWhite
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object FLabelAgentTab: TLabel
      Left = 84
      Top = 10
      Width = 39
      Height = 15
      Caption = 'AGENT'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = 10854560
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object FNewTag: TPanel
      Left = 132
      Top = 10
      Width = 42
      Height = 16
      BevelOuter = bvNone
      Color = 31487
      ParentBackground = False
      TabOrder = 1
      object LabelNewTagText: TLabel
        Left = 0
        Top = 0
        Width = 42
        Height = 16
        Align = alClient
        Alignment = taCenter
        Caption = 'NEW'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWhite
        Font.Height = -9
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
        Layout = tlCenter
        ExplicitWidth = 27
        ExplicitHeight = 12
      end
    end
  end
  object FSessionPanel: TPanel
    Left = 0
    Top = 36
    Width = 420
    Height = 32
    Align = alTop
    BevelOuter = bvNone
    Color = 1578261
    ParentBackground = False
    ShowCaption = False
    TabOrder = 1
    object ShapeSessionDot: TShape
      AlignWithMargins = True
      Left = 16
      Top = 12
      Width = 8
      Height = 8
      Margins.Left = 16
      Margins.Top = 12
      Margins.Right = 4
      Margins.Bottom = 12
      Align = alLeft
      Brush.Color = 2478950
      Pen.Style = psClear
      Shape = stCircle
    end
    object LabelSessionInfoText: TLabel
      AlignWithMargins = True
      Left = 31
      Top = 8
      Width = 146
      Height = 16
      Margins.Top = 8
      Margins.Bottom = 8
      Align = alLeft
      Caption = 'New session  '#8226'  3 messages'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = 10854560
      Font.Height = -11
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      ExplicitHeight = 13
    end
    object FLabelSessionTime: TLabel
      AlignWithMargins = True
      Left = 360
      Top = 8
      Width = 44
      Height = 16
      Margins.Top = 8
      Margins.Right = 16
      Margins.Bottom = 8
      Align = alRight
      Caption = '1 min ago'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGray
      Font.Height = -11
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      ExplicitHeight = 13
    end
  end
  object FClientContainer: TPanel
    Left = 0
    Top = 68
    Width = 420
    Height = 358
    Align = alClient
    BevelOuter = bvNone
    Color = 1578261
    ParentBackground = False
    ShowCaption = False
    TabOrder = 2
    object FOutput: TRichEdit
      Left = 0
      Top = 0
      Width = 420
      Height = 358
      Align = alClient
      BorderStyle = bsNone
      Color = 1578261
      Font.Charset = ANSI_CHARSET
      Font.Color = clWhite
      Font.Height = -13
      Font.Name = 'Consolas'
      Font.Style = []
      HideSelection = False
      ParentFont = False
      ReadOnly = True
      ScrollBars = ssBoth
      TabOrder = 0
      Visible = False
      WordWrap = False
    end
    object FWelcomePanel: TPanel
      Left = 0
      Top = 0
      Width = 420
      Height = 358
      Align = alClient
      BevelOuter = bvNone
      Color = 1578261
      ParentBackground = False
      ShowCaption = False
      TabOrder = 1
      DesignSize = (
        420
        358)
      object FWelcomePanelCenter: TPanel
        Left = 20
        Top = 0
        Width = 380
        Height = 334
        Anchors = []
        BevelOuter = bvNone
        ParentBackground = False
        ShowCaption = False
        TabOrder = 0
        object FLabelSparkle: TLabel
          Left = 0
          Top = 10
          Width = 380
          Height = 60
          Alignment = taCenter
          AutoSize = False
          Caption = #10022
          Font.Charset = DEFAULT_CHARSET
          Font.Color = 31487
          Font.Height = -48
          Font.Name = 'Segoe UI'
          Font.Style = []
          ParentFont = False
        end
        object FLabelGreetingSub: TLabel
          Left = 0
          Top = 115
          Width = 380
          Height = 20
          Alignment = taCenter
          AutoSize = False
          Caption = 'How can I help you with the project today?'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = 10854560
          Font.Height = -13
          Font.Name = 'Segoe UI'
          Font.Style = []
          ParentFont = False
        end
        object PanelGreeting: TPanel
          Left = 20
          Top = 80
          Width = 340
          Height = 32
          BevelOuter = bvNone
          ShowCaption = False
          TabOrder = 0
          object LabelGreetingLeft: TLabel
            Left = 40
            Top = 0
            Width = 157
            Height = 30
            Caption = 'Good morning, '
            Font.Charset = DEFAULT_CHARSET
            Font.Color = clWhite
            Font.Height = -21
            Font.Name = 'Segoe UI'
            Font.Style = [fsBold]
            ParentFont = False
          end
          object LabelGreetingRight: TLabel
            Left = 197
            Top = 0
            Width = 70
            Height = 30
            Caption = 'Isaque.'
            Font.Charset = DEFAULT_CHARSET
            Font.Color = 31487
            Font.Height = -21
            Font.Name = 'Segoe UI'
            Font.Style = [fsBold]
            ParentFont = False
          end
        end
        object FGridCommands: TGridPanel
          Left = 10
          Top = 150
          Width = 360
          Height = 170
          BevelOuter = bvNone
          ColumnCollection = <
            item
              Value = 50.000000000000000000
            end
            item
              Value = 50.000000000000000000
            end>
          ControlCollection = <
            item
              Column = 0
              Control = CardExplain
              Row = 0
            end
            item
              Column = 1
              Control = CardRefactor
              Row = 0
            end
            item
              Column = 0
              Control = CardTest
              Row = 1
            end
            item
              Column = 1
              Control = CardDocs
              Row = 1
            end
            item
              Column = 0
              Control = CardFind
              Row = 2
            end
            item
              Column = 1
              Control = CardOptimize
              Row = 2
            end>
          RowCollection = <
            item
              Value = 33.330000000000000000
            end
            item
              Value = 33.330000000000000000
            end
            item
              Value = 33.340000000000000000
            end>
          TabOrder = 1
          object CardExplain: TPanel
            AlignWithMargins = True
            Left = 3
            Top = 3
            Width = 174
            Height = 51
            Cursor = crHandPoint
            Align = alClient
            BevelOuter = bvNone
            Color = 1578261
            ParentBackground = False
            ShowCaption = False
            TabOrder = 0
            OnClick = _OnExplainClick
            OnMouseEnter = CardMouseEnter
            OnMouseLeave = CardMouseLeave
            object ShapeExplainBg: TShape
              Left = 0
              Top = 0
              Width = 174
              Height = 51
              Align = alClient
              Brush.Color = 2301727
              Enabled = False
              Pen.Color = 3156522
              Shape = stRoundRect
            end
            object LabelExplainTitle: TLabel
              Left = 40
              Top = 6
              Width = 39
              Height = 15
              Cursor = crHandPoint
              Caption = 'Explain'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              Transparent = True
              OnClick = _OnExplainClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object LabelExplainDesc: TLabel
              Left = 40
              Top = 22
              Width = 107
              Height = 13
              Cursor = crHandPoint
              Caption = 'Summarize unit / m...'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = 10854560
              Font.Height = -11
              Font.Name = 'Segoe UI'
              Font.Style = []
              ParentFont = False
              Transparent = True
              OnClick = _OnExplainClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object BtnExplainIcon: TBitBtn
              AlignWithMargins = True
              Left = 6
              Top = 10
              Width = 28
              Height = 28
              Cursor = crHandPoint
              Caption = #10022
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              TabOrder = 0
              OnClick = _OnExplainClick
            end
          end
          object CardRefactor: TPanel
            AlignWithMargins = True
            Left = 183
            Top = 3
            Width = 174
            Height = 51
            Cursor = crHandPoint
            Align = alClient
            BevelOuter = bvNone
            Color = 1578261
            ParentBackground = False
            ShowCaption = False
            TabOrder = 1
            OnClick = _OnRefactorClick
            OnMouseEnter = CardMouseEnter
            OnMouseLeave = CardMouseLeave
            object ShapeRefactorBg: TShape
              Left = 0
              Top = 0
              Width = 174
              Height = 51
              Align = alClient
              Brush.Color = 2301727
              Enabled = False
              Pen.Color = 3156522
              Shape = stRoundRect
            end
            object LabelRefactorTitle: TLabel
              Left = 40
              Top = 6
              Width = 49
              Height = 15
              Cursor = crHandPoint
              Caption = 'Refactor'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              Transparent = True
              OnClick = _OnRefactorClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object LabelRefactorDesc: TLabel
              Left = 40
              Top = 22
              Width = 110
              Height = 13
              Cursor = crHandPoint
              Caption = 'Suggest improveme...'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = 10854560
              Font.Height = -11
              Font.Name = 'Segoe UI'
              Font.Style = []
              ParentFont = False
              Transparent = True
              OnClick = _OnRefactorClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object BtnRefactorIcon: TBitBtn
              AlignWithMargins = True
              Left = 6
              Top = 10
              Width = 28
              Height = 28
              Cursor = crHandPoint
              Caption = #10022
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              TabOrder = 0
              OnClick = _OnRefactorClick
            end
          end
          object CardTest: TPanel
            AlignWithMargins = True
            Left = 3
            Top = 60
            Width = 174
            Height = 50
            Cursor = crHandPoint
            Align = alClient
            BevelOuter = bvNone
            Color = 1578261
            ParentBackground = False
            ShowCaption = False
            TabOrder = 2
            OnClick = _OnTestClick
            OnMouseEnter = CardMouseEnter
            OnMouseLeave = CardMouseLeave
            object ShapeTestBg: TShape
              Left = 0
              Top = 0
              Width = 174
              Height = 50
              Align = alClient
              Brush.Color = 2301727
              Enabled = False
              Pen.Color = 3156522
              Shape = stRoundRect
            end
            object LabelTestTitle: TLabel
              Left = 40
              Top = 6
              Width = 23
              Height = 15
              Cursor = crHandPoint
              Caption = 'Test'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              Transparent = True
              OnClick = _OnTestClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object LabelTestDesc: TLabel
              Left = 40
              Top = 22
              Width = 107
              Height = 13
              Cursor = crHandPoint
              Caption = 'Generate DUnit / D...'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = 10854560
              Font.Height = -11
              Font.Name = 'Segoe UI'
              Font.Style = []
              ParentFont = False
              Transparent = True
              OnClick = _OnTestClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object BtnTestIcon: TBitBtn
              AlignWithMargins = True
              Left = 6
              Top = 10
              Width = 28
              Height = 28
              Cursor = crHandPoint
              Caption = #10022
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              TabOrder = 0
              OnClick = _OnTestClick
            end
          end
          object CardDocs: TPanel
            AlignWithMargins = True
            Left = 183
            Top = 60
            Width = 174
            Height = 50
            Cursor = crHandPoint
            Align = alClient
            BevelOuter = bvNone
            Color = 1578261
            ParentBackground = False
            ShowCaption = False
            TabOrder = 3
            OnClick = _OnDocsClick
            OnMouseEnter = CardMouseEnter
            OnMouseLeave = CardMouseLeave
            object ShapeDocsBg: TShape
              Left = 0
              Top = 0
              Width = 174
              Height = 50
              Align = alClient
              Brush.Color = 2301727
              Enabled = False
              Pen.Color = 3156522
              Shape = stRoundRect
            end
            object LabelDocsTitle: TLabel
              Left = 40
              Top = 6
              Width = 59
              Height = 15
              Cursor = crHandPoint
              Caption = 'Document'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              Transparent = True
              OnClick = _OnDocsClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object LabelDocsDesc: TLabel
              Left = 40
              Top = 22
              Width = 108
              Height = 13
              Cursor = crHandPoint
              Caption = 'Add XML Doc / com...'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = 10854560
              Font.Height = -11
              Font.Name = 'Segoe UI'
              Font.Style = []
              ParentFont = False
              Transparent = True
              OnClick = _OnDocsClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object BtnDocsIcon: TBitBtn
              AlignWithMargins = True
              Left = 6
              Top = 10
              Width = 28
              Height = 28
              Cursor = crHandPoint
              Caption = #10022
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              TabOrder = 0
              OnClick = _OnDocsClick
            end
          end
          object CardFind: TPanel
            AlignWithMargins = True
            Left = 3
            Top = 116
            Width = 174
            Height = 51
            Cursor = crHandPoint
            Align = alClient
            BevelOuter = bvNone
            Color = 1578261
            ParentBackground = False
            ShowCaption = False
            TabOrder = 4
            OnClick = _OnFindClick
            OnMouseEnter = CardMouseEnter
            OnMouseLeave = CardMouseLeave
            object ShapeFindBg: TShape
              Left = 0
              Top = 0
              Width = 174
              Height = 51
              Align = alClient
              Brush.Color = 2301727
              Enabled = False
              Pen.Color = 3156522
              Shape = stRoundRect
            end
            object LabelFindTitle: TLabel
              Left = 40
              Top = 6
              Width = 23
              Height = 15
              Cursor = crHandPoint
              Caption = 'Find'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              Transparent = True
              OnClick = _OnFindClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object LabelFindDesc: TLabel
              Left = 40
              Top = 22
              Width = 107
              Height = 13
              Cursor = crHandPoint
              Caption = 'Symbol, class, usag...'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = 10854560
              Font.Height = -11
              Font.Name = 'Segoe UI'
              Font.Style = []
              ParentFont = False
              Transparent = True
              OnClick = _OnFindClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object BtnFindIcon: TBitBtn
              AlignWithMargins = True
              Left = 6
              Top = 10
              Width = 28
              Height = 28
              Cursor = crHandPoint
              Caption = #10022
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              TabOrder = 0
              OnClick = _OnFindClick
            end
          end
          object CardOptimize: TPanel
            AlignWithMargins = True
            Left = 183
            Top = 116
            Width = 174
            Height = 51
            Cursor = crHandPoint
            Align = alClient
            BevelOuter = bvNone
            Color = 1578261
            ParentBackground = False
            ShowCaption = False
            TabOrder = 5
            OnClick = _OnOptimizeClick
            OnMouseEnter = CardMouseEnter
            OnMouseLeave = CardMouseLeave
            object ShapeOptimizeBg: TShape
              Left = 0
              Top = 0
              Width = 174
              Height = 51
              Align = alClient
              Brush.Color = 2301727
              Enabled = False
              Pen.Color = 3156522
              Shape = stRoundRect
            end
            object LabelOptimizeTitle: TLabel
              Left = 40
              Top = 6
              Width = 51
              Height = 15
              Cursor = crHandPoint
              Caption = 'Optimize'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              Transparent = True
              OnClick = _OnOptimizeClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object LabelOptimizeDesc: TLabel
              Left = 40
              Top = 22
              Width = 103
              Height = 13
              Cursor = crHandPoint
              Caption = 'Performance, mem...'
              Font.Charset = DEFAULT_CHARSET
              Font.Color = 10854560
              Font.Height = -11
              Font.Name = 'Segoe UI'
              Font.Style = []
              ParentFont = False
              Transparent = True
              OnClick = _OnOptimizeClick
              OnMouseEnter = CardMouseEnter
              OnMouseLeave = CardMouseLeave
            end
            object BtnOptimizeIcon: TBitBtn
              AlignWithMargins = True
              Left = 6
              Top = 10
              Width = 28
              Height = 28
              Cursor = crHandPoint
              Caption = #10022
              Font.Charset = DEFAULT_CHARSET
              Font.Color = clWhite
              Font.Height = -12
              Font.Name = 'Segoe UI'
              Font.Style = [fsBold]
              ParentFont = False
              TabOrder = 0
              OnClick = _OnOptimizeClick
            end
          end
        end
      end
    end
  end
  object FBottomContainer: TPanel
    Left = 0
    Top = 430
    Width = 420
    Height = 185
    Align = alBottom
    BevelOuter = bvNone
    Color = 1578261
    ParentBackground = False
    ShowCaption = False
    TabOrder = 3
    object FTipLabel: TLabel
      AlignWithMargins = True
      Left = 3
      Top = 122
      Width = 414
      Height = 24
      Margins.Top = 10
      Margins.Bottom = 15
      Align = alBottom
      Alignment = taCenter
      AutoSize = False
      Caption = 
        'Tip: Ctrl+Shift+Space over a selection opens a quick prompt with' +
        'out leaving the editor.'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGray
      Font.Height = -11
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      WordWrap = True
      ExplicitLeft = 24
      ExplicitTop = 114
      ExplicitWidth = 372
    end
    object FStatusPanel: TPanel
      Left = 0
      Top = 161
      Width = 420
      Height = 24
      Align = alBottom
      BevelOuter = bvNone
      Color = 1184271
      ParentBackground = False
      ShowCaption = False
      TabOrder = 0
      object FLabelStatusText: TLabel
        AlignWithMargins = True
        Left = 16
        Top = 3
        Width = 388
        Height = 18
        Margins.Left = 16
        Margins.Right = 16
        Align = alClient
        Caption =
          #$2726' Workspace: -   '#$2022'   '#$2726' Approvals: Default   '#$2022' ' +
          '  '#$2726' Model: -'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clGray
        Font.Height = -10
        Font.Name = 'Segoe UI'
        Font.Style = []
        ParentFont = False
        Layout = tlCenter
        ExplicitWidth = 373
        ExplicitHeight = 12
      end
    end
    object FInputPanel: TPanel
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 414
      Height = 106
      Align = alClient
      BevelOuter = bvNone
      Color = 1578261
      ParentBackground = False
      ShowCaption = False
      TabOrder = 1
      DesignSize = (
        414
        106)
      object ShapeInputBg: TShape
        Left = 0
        Top = 0
        Width = 414
        Height = 106
        Align = alClient
        Brush.Color = 2301727
        Enabled = False
        Pen.Color = 3156522
        Shape = stRoundRect
        ExplicitWidth = 408
        ExplicitHeight = 107
      end
      object FAttachIcon: TLabel
        Left = 12
        Top = 76
        Width = 44
        Height = 13
        Caption = #62670' Anexar'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = 10854560
        Font.Height = -11
        Font.Name = 'Segoe UI'
        Font.Style = []
        ParentFont = False
        Transparent = True
      end
      object FShortcutLabel: TLabel
        Left = 80
        Top = 76
        Width = 62
        Height = 13
        Caption = '/ Commands'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clGray
        Font.Height = -11
        Font.Name = 'Segoe UI'
        Font.Style = []
        ParentFont = False
        Transparent = True
      end
      object FMicIcon: TLabel
        Left = 332
        Top = 76
        Width = 8
        Height = 17
        Alignment = taRightJustify
        Anchors = [akTop, akRight]
        Caption = #62372
        Font.Charset = DEFAULT_CHARSET
        Font.Color = 10854560
        Font.Height = -13
        Font.Name = 'Segoe UI'
        Font.Style = []
        ParentFont = False
        Transparent = True
      end
      object FSendBtn: TButton
        Left = 360
        Top = 70
        Width = 36
        Height = 26
        Cursor = crHandPoint
        Anchors = [akTop, akRight]
        Caption = #8593
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -16
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
        TabOrder = 0
        OnClick = _OnSendClick
      end
      object FInput: TMemo
        Left = 12
        Top = 8
        Width = 384
        Height = 56
        BorderStyle = bsNone
        Color = 2301727
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWhite
        Font.Height = -13
        Font.Name = 'Segoe UI'
        Font.Style = []
        ParentFont = False
        TabOrder = 1
        StyleElements = [seFont]
        OnChange = _OnInputChange
        OnKeyDown = _OnInputKeyDown
      end
    end
  end
  object FCmdList: TListBox
    Left = 0
    Top = 301
    Width = 420
    Height = 100
    Color = 2301727
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = []
    ItemHeight = 15
    ParentFont = False
    TabOrder = 4
    Visible = False
    OnDblClick = _OnCmdListDblClick
  end
end
