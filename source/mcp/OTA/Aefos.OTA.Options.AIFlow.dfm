object AefosAIFlowOptionsFrame: TAefosAIFlowOptionsFrame
  Left = 0
  Top = 0
  Width = 531
  Height = 614
  TabOrder = 0
  object lblTitle: TLabel
    Left = 16
    Top = 10
    Width = 400
    Height = 15
    Caption = 'Smooth AI workflow (applies to both Chat and Terminal)'
  end
  object gbPermissions: TGroupBox
    Left = 12
    Top = 30
    Width = 507
    Height = 124
    Caption = ' Tool permissions '
    TabOrder = 0
    object lblConsent: TLabel
      Left = 16
      Top = 20
      Width = 470
      Height = 15
      Caption = 'When the agent runs a tool that needs permission:'
    end
    object cmbConsentMode: TComboBox
      Left = 16
      Top = 39
      Width = 340
      Height = 23
      Style = csDropDownList
      TabOrder = 0
    end
    object chkNativeTools: TCheckBox
      Left = 16
      Top = 70
      Width = 483
      Height = 17
      Caption =
        'Let the AI CLI use its own file and shell tools (Write / Edit / ' +
        'Bash)'
      TabOrder = 1
    end
    object lblNativeTools: TLabel
      Left = 34
      Top = 90
      Width = 465
      Height = 30
      AutoSize = False
      WordWrap = True
    end
  end
  object gbEdits: TGroupBox
    Left = 12
    Top = 158
    Width = 507
    Height = 100
    Caption = ' Agent edits '
    TabOrder = 1
    object lblEditReview: TLabel
      Left = 16
      Top = 20
      Width = 120
      Height = 15
      Caption = 'Inline edit review:'
    end
    object cmbEditReview: TComboBox
      Left = 16
      Top = 38
      Width = 340
      Height = 23
      Style = csDropDownList
      TabOrder = 0
    end
    object chkAgentAutoSave: TCheckBox
      Left = 16
      Top = 72
      Width = 483
      Height = 17
      Caption = 'Agent auto-save edits (let edits pass without manual approval)'
      TabOrder = 1
    end
  end
  object gbInline: TGroupBox
    Left = 12
    Top = 262
    Width = 507
    Height = 78
    Caption = ' Inline code completion '
    TabOrder = 2
    object lblInlineShortcut: TLabel
      Left = 32
      Top = 50
      Width = 200
      Height = 15
      Caption = 'Press this key to ask:'
    end
    object chkInlineEnabled: TCheckBox
      Left = 16
      Top = 20
      Width = 483
      Height = 17
      Caption =
        'Suggest code inline as grey ghost text (nothing is written until' +
        ' you press Tab)'
      TabOrder = 0
    end
    object hkInlineShortcut: THotKey
      Left = 240
      Top = 46
      Width = 150
      Height = 21
      HotKey = 0
      TabOrder = 1
    end
  end
  object gbIDE: TGroupBox
    Left = 12
    Top = 344
    Width = 507
    Height = 76
    Caption = ' IDE behavior '
    TabOrder = 3
    object chkSilentReload: TCheckBox
      Left = 16
      Top = 22
      Width = 483
      Height = 17
      Caption =
        'Reload externally modified files without asking (silent reload' +
        ')'
      TabOrder = 0
    end
    object chkWebViewTrace: TCheckBox
      Left = 16
      Top = 46
      Width = 483
      Height = 17
      Caption =
        'Enable WebView2 diagnostic trace (writes %TEMP%\aefos_comp.log)'
      TabOrder = 1
    end
  end
  object gbIssue: TGroupBox
    Left = 12
    Top = 424
    Width = 507
    Height = 52
    Caption = ' Issue reporting '
    TabOrder = 4
    object chkIssueReporting: TCheckBox
      Left = 16
      Top = 22
      Width = 483
      Height = 17
      Caption =
        'Let the agent report issues (opens a confirmation dialog before ' +
        'anything is filed)'
      TabOrder = 0
    end
  end
  object gbShortcuts: TGroupBox
    Left = 12
    Top = 484
    Width = 507
    Height = 118
    Caption = ' Aefos keyboard shortcuts '
    TabOrder = 5
    object lblShortcutInline: TLabel
      Left = 16
      Top = 22
      Width = 483
      Height = 15
    end
    object lblShortcutSuggest: TLabel
      Left = 16
      Top = 44
      Width = 483
      Height = 15
      Caption = 'Ctrl+Alt+F10       Ask the agent about the selected code'
    end
    object lblShortcutReview: TLabel
      Left = 16
      Top = 66
      Width = 483
      Height = 15
      Caption = 'Ctrl+Alt+R          Show / hide the change review in the gutter'
    end
    object lblShortcutReplicate: TLabel
      Left = 16
      Top = 88
      Width = 483
      Height = 15
      Caption = 'Ctrl+Alt+F11       Save the Aefos commands to your AI CLI'
    end
  end
end
