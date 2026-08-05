{
  Aefos.OTA.Terminal Compiler Directives
}

{$IFDEF MSWINDOWS}
  {$DEFINE AEFOS_OTA_TERMINAL_WINDOWS}
{$ENDIF}

{$IFNDEF DEBUG}
  {$DEFINE RELEASE}
{$ENDIF}

// L5 self-test channel (ESP-068 / ADR-068-01). Default OFF — never defined in
// release or normal builds. To enable, pass -DAEFOS_OTA_TERMINAL_SELFTEST
// on the dcc32 command line or uncomment the directive below for an IDE build.
// The named-pipe listener and OTA executor compile ONLY when this is active.
//{$DEFINE AEFOS_OTA_TERMINAL_SELFTEST}

{$SCOPEDENUMS ON}
{$BOOLEVAL OFF}
{$STACKFRAMES OFF}
{$ASSERTIONS ON}
{$OPTIMIZATION ON}


