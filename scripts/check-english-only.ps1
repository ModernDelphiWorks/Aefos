<#
.SYNOPSIS
  English-only guard for shipped .dfm form text (Aefos AI).

.DESCRIPTION
  Aefos rule: nothing user-facing is Portuguese (brand stays English everywhere).
  The 2026-06-19 PT->EN sweep cleaned the .pas units but missed the .dfm forms;
  the 2026-06-27 grand audit found shipped Portuguese in Terminal/Chat .dfm
  Captions/Hints, the single most visible 5-minute-skim defect for an external
  reviewer. This guard scans every source/**/*.dfm and FAILS (exit 1) when a
  user-facing string property (Caption/Hint/Text/TextHint) contains:
    - a Latin-1 accented-letter escape (#160..#255) -> e.g. 'a'#231#227'o' (acao),
      a strong non-English signal. Typographic chars English does use (bullet
      #8226, em/en dash #8212/#8211, ellipsis #8230) are 4-digit and NOT flagged.
    - a clearly-Portuguese word with no English collision (denylist below).

  Pure check: reads only, mutates nothing. Wire it into build-packages.ps1 or a
  future CI step so Portuguese in forms cannot regress.

.EXAMPLE
  pwsh scripts/check-english-only.ps1
#>

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $repoRoot 'source'

# Unaccented PT words with no English substring collision (accented PT words are
# caught by the #160..#255 escape rule instead, since the DFM splits them).
$ptWords = @(
  'Nova','Novo','Comando','Comandos','Fonte','Tamanho','Filtrar','Importar',
  'Exportar','Excluir','Adicionar','Editar','Gerenciar','Cancelar','Titulo',
  'Escopo','mensagens','mensagem','Pesquisar','Arquivo','Salvar','Senha',
  'Usuario','Fechar','Configuracoes','Visualizacao'
)
$wordPattern = '\b(' + ($ptWords -join '|') + ')\b'
$propPattern = "^\s*(Caption|Hint|Text|TextHint)\s*=\s*'"
$accentPattern = '#(1[6-9]\d|2[0-4]\d|25[0-5])'

$violations = New-Object System.Collections.Generic.List[string]
$dfmFiles = Get-ChildItem -Path $sourceDir -Recurse -Filter *.dfm -File

foreach ($file in $dfmFiles) {
  $rel = $file.FullName.Substring($repoRoot.Length + 1)
  $lineNo = 0
  foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
    $lineNo++
    if ($line -notmatch $propPattern) { continue }
    $reason = $null
    if ($line -match $accentPattern) { $reason = 'accented (non-English) char' }
    elseif ($line -match $wordPattern) { $reason = "Portuguese word '$($Matches[1])'" }
    if ($reason) {
      $violations.Add(("{0}:{1}: {2} -> {3}" -f $rel, $lineNo, $reason, $line.Trim()))
    }
  }
}

if ($violations.Count -gt 0) {
  Write-Host "ENGLISH-ONLY GUARD FAILED -- Portuguese / non-English text in shipped .dfm:" -ForegroundColor Red
  $violations | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
  Write-Host ("`n{0} violation(s). User-facing form text must be English (Aefos rule)." -f $violations.Count) -ForegroundColor Red
  exit 1
}

Write-Host ("English-only guard passed: {0} .dfm files clean." -f $dfmFiles.Count) -ForegroundColor Green
exit 0
