# Aefos.Tools — Naming convention (STANDARD)

Names that are **suggestive** (they say what they do) and **standardized** (same
shape across the whole suite). Each unit exposes its API as **one `sealed` class
with `class function`/`class procedure ... static` members** — the class is the
namespace, so the domain prefix is DROPPED from the method name:

```
T<Domain>.<Verb><Target>    — the class is the namespace; Verb comes first
```

e.g. `TTextEditor.InsertLine`, `TFileIO.Load`, `TTemplateEngine.Render`. The
classes are never instantiated (pure static namespaces). Private helpers stay as
`_`-prefixed loose functions in the implementation section, and records/enums
(`TToolTextResult`, `TToolFileBom`, `TToolTemplateVar`, …) keep their own methods.

## Domains (1 sealed class per unit)
| Class             | Unit                    | Role                                   |
|-------------------|-------------------------|----------------------------------------|
| `TTextEditor`     | `Aefos.Tools.Text`      | pure line/column engine (string→string)|
| `TFileIO`         | `Aefos.Tools.Files`     | on-disk IO (BOM/EOL, atomic)           |
| `TTemplateEngine` | `Aefos.Tools.Templates` | render `{{...}}` + scaffold            |
| `TFileBatch`      | `Aefos.Tools.Batch`     | multi-file fan-out (glob + op)         |
| `TProjectOps`     | `Aefos.Tools.Project`   | project-wide seams (replace/bom/scaffold) that the MCP wraps 1:1 |
| `TProcessRunner`  | `Aefos.Tools.Process`   | pure subprocess (stdin/stdout/stderr, timeout, kill) |
| `TPythonRunner`   | `Aefos.Tools.PyTool`    | Python tool launcher (resolves interpreter + runs script) |

## Canonical verbs (do not invent synonyms)
`Insert` · `Replace` · `Remove` · `Append` · `Delete` · `Get` · `Count` ·
`Detect` · `Load` · `Save` · `Render` · `Scaffold`

## Canonical targets
`Line` · `Lines` · `At` (line+column) · `Range` (start→end) · `Content` · `Eol`

## Text layer — current surface (pattern reference)
Queries: `TTextEditor.CountLines` · `TTextEditor.GetLine` · `TTextEditor.DetectEol`
Line:    `TTextEditor.InsertLine` · `TTextEditor.ReplaceLine` · `TTextEditor.RemoveLine` ·
         `TTextEditor.RemoveLines` · `TTextEditor.AppendLine`
Column:  `TTextEditor.InsertAt` · `TTextEditor.DeleteRange` · `TTextEditor.ReplaceRange`

Standardized outcome: enum `TTool<Domain>Outcome` (`tt*`) + record
`TTool<Domain>Result` (suggestive fields: `Outcome`, `Content`, `Line`,
`Column`, `LinesAffected`, methods `Ok`/`OutcomeText`).

## MCP tools (the name the AGENT calls)
Verb-first PascalCase, aligned with the existing catalog (`EditUnit`,
`OverwriteFile`, `InsertCodeAtCursor`):
`InsertLineInFile` · `ReplaceLineInFile` · `RemoveLineInFile` ·
`AppendLineToFile` · `InsertTextAt` · `DeleteTextRange` · `ReplaceTextRange` ·
`RenderTemplate` · `ScaffoldProject`

## Templates — standardized id
`<type>/<artifact>` — e.g.: `vcl/program`, `vcl/mainform.pas`,
`vcl/mainform.dfm`, `console/program`, `library/program`, `package/dpk`,
`dunitx/program`, `fmx/program`, `fmx/mainform.pas`.

**Types covered (ALL — VCL → library):**
`vcl` · `fmx` · `console` · `library` · `package` · `dunit` · `dunitx`
