object AefosAIFlowOptionsFrame: TAefosAIFlowOptionsFrame
  Left = 0
  Top = 0
  Width = 536
  Height = 666
  TabOrder = 0
  object lblTitle: TLabel
    Left = 16
    Top = 10
    Width = 500
    Height = 15
    Caption = 'Smooth AI workflow (applies to both Chat and Terminal)'
  end
  object gbPermissions: TGroupBox
    Left = 16
    Top = 32
    Width = 500
    Height = 162
    Caption = ' Tool permissions '
    TabOrder = 0
    object lblConsent: TLabel
      Left = 16
      Top = 20
      Width = 468
      Height = 15
      Caption = 'When the agent runs a tool that needs permission:'
    end
    object cmbConsentMode: TComboBox
      Left = 16
      Top = 38
      Width = 468
      Height = 23
      Style = csDropDownList
      TabOrder = 0
    end
    object chkNativeTools: TCheckBox
      Left = 16
      Top = 68
      Width = 468
      Height = 17
      Caption =
        'Let the AI CLI use its own file and shell tools (Write / Edit / ' +
        'Bash)'
      TabOrder = 1
    end
    object lblNativeTools: TLabel
      Left = 34
      Top = 88
      Width = 450
      Height = 60
      AutoSize = False
      WordWrap = True
    end
  end
  object gbEdits: TGroupBox
    Left = 16
    Top = 202
    Width = 500
    Height = 104
    Caption = ' Agent edits '
    TabOrder = 1
    object lblEditReview: TLabel
      Left = 16
      Top = 20
      Width = 468
      Height = 15
      Caption = 'Inline edit review:'
    end
    object cmbEditReview: TComboBox
      Left = 16
      Top = 38
      Width = 468
      Height = 23
      Style = csDropDownList
      TabOrder = 0
    end
    object chkAgentAutoSave: TCheckBox
      Left = 16
      Top = 72
      Width = 468
      Height = 17
      Caption = 'Agent auto-save edits (let edits pass without manual approval)'
      TabOrder = 1
    end
  end
  object gbInline: TGroupBox
    Left = 16
    Top = 314
    Width = 500
    Height = 80
    Caption = ' Inline code completion '
    TabOrder = 2
    object chkInlineEnabled: TCheckBox
      Left = 16
      Top = 20
      Width = 468
      Height = 17
      Caption =
        'Suggest code inline as grey ghost text (nothing is written until' +
        ' you press Tab)'
      TabOrder = 0
    end
    object lblInlineShortcut: TLabel
      Left = 34
      Top = 48
      Width = 140
      Height = 15
      Caption = 'Press this key to ask:'
    end
    object hkInlineShortcut: THotKey
      Left = 180
      Top = 44
      Width = 160
      Height = 23
      HotKey = 0
      TabOrder = 1
    end
  end
  object gbIDE: TGroupBox
    Left = 16
    Top = 402
    Width = 500
    Height = 74
    Caption = ' IDE behavior '
    TabOrder = 3
    object chkSilentReload: TCheckBox
      Left = 16
      Top = 20
      Width = 468
      Height = 17
      Caption =
        'Reload externally modified files without asking (silent reload)'
      TabOrder = 0
    end
    object chkWebViewTrace: TCheckBox
      Left = 16
      Top = 44
      Width = 468
      Height = 17
      Caption =
        'Enable WebView2 diagnostic trace (writes %TEMP%\aefos_comp.log)'
      TabOrder = 1
    end
  end
  object gbIssue: TGroupBox
    Left = 16
    Top = 484
    Width = 500
    Height = 50
    Caption = ' Issue reporting '
    TabOrder = 4
    object chkIssueReporting: TCheckBox
      Left = 16
      Top = 20
      Width = 468
      Height = 17
      Caption =
        'Let the agent report issues (opens a confirmation dialog before ' +
        'anything is filed)'
      TabOrder = 0
    end
  end
  object gbShortcuts: TGroupBox
    Left = 16
    Top = 542
    Width = 500
    Height = 116
    Caption = ' Aefos keyboard shortcuts '
    TabOrder = 5
    object lblShortcutInline: TLabel
      Left = 16
      Top = 22
      Width = 468
      Height = 15
    end
    object lblShortcutSuggest: TLabel
      Left = 16
      Top = 44
      Width = 468
      Height = 15
      Caption = 'Ctrl+Alt+F10       Ask the agent about the selected code'
    end
    object lblShortcutReview: TLabel
      Left = 16
      Top = 66
      Width = 468
      Height = 15
      Caption = 'Ctrl+Alt+R          Show / hide the change review in the gutter'
    end
    object lblShortcutReplicate: TLabel
      Left = 16
      Top = 88
      Width = 468
      Height = 15
      Caption = 'Ctrl+Alt+F11       Save the Aefos commands to your AI CLI'
    end
  end
end
