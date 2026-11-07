# 03 — Excel Import Specification: Multi 05 Beach

## Mandatory invariant

> The legacy schedule has unreliable predecessor values. **Ignore the entirety of column H (`Predecessora`)**: do not import, interpret, guess, validate, or calculate dependencies from it. Import the original start and end dates exactly. The first published baseline is `R00` and must remain immutable.

The user must not be required to understand or repair Excel dependencies just to import existing work.

## Verified reference workbook (local, confidential)

Reference filename: `Cronograma_Multi_05_Beach_Produto.xlsx`. Keep the actual file **out of git**.

| Worksheet (exact source name) | JLProject use |
|---|---|
| `Cronograma Produto` | **Canonical source of activity data and dates** |
| `Metas e Premissas` | **Canonical source of company targets and dates** |
| `Resumo Gantt` | **Ignore** — derived presentation and formulas, not source of truth |

### Worksheet `Cronograma Produto`

- Header: **row 4**, columns `A` through `L`.
- Data rows: **5–50** (46 source records, IDs `T001`–`T046`).
- **41 operational activities**; **5 rows** with `Tipo = Meta`.
- All 46 source rows have start/end values.
- Seven disciplines, 21 discipline–stage combinations, eight distinct stage labels.

| Column | Literal Excel header | Mapping | Rule |
|---|---|---|---|
| A | `ID` | `source_external_id` | Preserve the external identifier for reporting and deduplication. |
| B | `Disciplina` | Discipline | Create/reuse by normalized name within workspace. |
| C | `Etapa` | Stage | Create under discipline; preserve literal label (`Lanç.`, `MV`, etc.). |
| D | `Atividade de Produto` | Activity name | Never strip `R00`/`R01` from an activity title. |
| E | `Início` | Start date | Required; convert Excel date to `YYYY-MM-DD`. |
| F | `Fim` | End date | Required; never replace with target date or formula result. |
| G | `Duração (dias úteis)` | **Do not import** | Calculate a displayed value from dates/calendar later. |
| H | `Predecessora` | **IGNORE** | Create no dependency links. |
| I | `Data-meta` | Secondary reference only | Business targets come from the designated goals worksheet. |
| J | `Status` | Optional source metadata | Preserve if useful; never use to automatically change dates. |
| K | `Tipo` | `kind` or business target | `Meta` rows are reconciled, not duplicated as tasks. |
| L | `Observações` | Activity notes | Import source text when present. |
| M onward | Gantt timescale grid | **Ignore** | Presentation cells must not become schedule records. |

**Five source rows with `Tipo=Meta`:** do not create operational tasks for them. Reconcile against five official targets in `Metas e Premissas` using name/date matching. Preserve provenance; report ambiguity and require user review instead of silently combining unmatched records.

### Worksheet `Metas e Premissas`

- Header range: `A3:E3`.
- Official goals: `A4:E8` (**five rows**).
- `A`: target name; `B`: target date; `C`: operational planned date (optional); `D`: informational status; `E`: notes.
- Ignore later narrative rows in the initial import.
- Business targets are independent of tasks and never move automatically with dependencies.
- Real example: the BID 01 target falls on a Sunday. **Do not shift this date to Friday or Monday.**

### Acceptance counts for the reference dataset

- 46 distinct source IDs, `T001`–`T046` = **41 activities + 5 targets**.
- 7 disciplines: `Arquitetura` (21 source rows), `Paisagismo` (6), `Luminotécnico` (3), `Comunicação Visual` (5), `Imagens de Venda` (5), `Maquete` (4), `Garagem` (2).
- Source kinds: `Marco` (9), `Acompanhamento` (14), `Análise` (16), `Validação` (2), `Meta` (5).
- Overall source date span: **October 21, 2026 through January 17, 2028**.
- Stage labels: `EC`, `EP`, `AP`, `PL`, `MV`, `Pré-executivo`, `Executivo`, `Lanç.`.
- The source contains concurrent stages. Never serialize them merely to simplify a visualization.

## Import flow

1. An authorized editor selects a `.xlsx` file and a destination product or chooses to create one. Suggest a product name from the workbook but allow editing.
2. Parse **without writing business data**. Validate file bounds and structure, required headers, dates, ranges, and duplicate source IDs.
3. Show a `pt-BR` **preview** organized by discipline: counts, target dates, date span, errors, warnings, and the explicit notice `As predecessoras da planilha serão ignoradas.`
4. Allow users to review discipline/stage aliases, duplicate targets, and invalid fields without modifying the original workbook.
5. On confirmation, commit product, disciplines, stages, activities, milestones, `R00`, source identifiers, and import report **atomically**.
6. On failure, roll back fully. Offer a downloadable validation report without creating partial schedule data.
7. Reimporting the same workbook must never silently duplicate tasks/products. Require an explicit create/compare/cancel choice. Updating an existing product may be developed later through a scenario/revision, never by overwriting `R00`.

## Technical safeguards

- Excel dates may be serials or date objects: normalize correctly, including the Excel 1900 date system, without timezone-driven day shifts.
- Use **values from E/F**; do not execute workbook formulas or derive dates from `Resumo Gantt`.
- Column G may contain a formula or a stale calculated duration; do not treat it as source of truth.
- With zero dependencies in `R00`, import must trigger **no rescheduling**.
- Enforce size, signature, worksheet count, rows, parsing time, and memory limits; defend against zip bombs. Do not leak spreadsheet contents into telemetry or logs; safely render text.
- Keep the original confidential workbook local and outside version control; store import checksum/metadata, not raw workbook bytes by default.

## Structured Excel export (MVP)

Create a `.xlsx` with **user-visible `pt-BR` sheet names**, initially `Atividades`, `Metas`, `Informações da Revisão`, and optionally `Histórico de Alterações` when permitted. Include typed Excel dates, persistent IDs, product/discipline/stage/activity/kind/dates/notes, source revision, and target dates. A predictable structure should support future reimports.

**Formula injection defense:** imported and edited untrusted strings must not be emitted as executable formulas when leading spaces/control characters precede `=`, `+`, `-`, or `@`.

## Non-negotiable acceptance

After importing the verified reference workbook: **41 activities, five targets, zero dependencies**, source-matching civil dates (including weekend targets), correct stages in both Gantts, and an immutable `R00` that can be viewed without recalculating its dates.
