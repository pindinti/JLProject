# 09 — Language and Localization Contract

## Purpose

Development is conducted in English for consistent engineering terminology and compact prompts, while JLProject is a **Brazilian Portuguese (`pt-BR`) application** used by Brazilian project-management staff. This is an acceptance requirement, not a cosmetic preference.

## Engineering language vs. product language

| Surface | Required language | Notes |
|---|---|---|
| Codex prompts and completion summaries | English | The human may provide new requirements in Portuguese; translate decisions into English documentation. |
| Markdown documentation, ADRs, code comments, tests and names | English | Internal domain identifiers may use `product`, `discipline`, `stage`, `activity`, `milestone`. |
| Visible product UI | Brazilian Portuguese | Menus, buttons, page headings, tooltips, status texts, role display labels, form hints, dialog text, banners, empty/error/loading states. |
| Authentication and authorization messages | Brazilian Portuguese | Never leak sensitive implementation details via translated error text. |
| Gantt legend, chart labels, history, scenario comparison | Brazilian Portuguese | Stage abbreviations such as `EC`, `EP`, `AP`, `PL`, `MV` remain domain abbreviations. |
| Excel import/export sheets and user-oriented headers | Brazilian Portuguese | Keep exact source headers for input parsing, and use PT-BR headers for newly generated workbooks. |
| Business task names and imported data | Preserve originals | Never automatically translate imported descriptions, source task names, notes or titles. |
| Logs and diagnostic messages not exposed to users | English | No sensitive workbook content or secrets in logs. |

## Date, time and numeric formatting

- Store dates in the schedule domain as date-only `YYYY-MM-DD`, **not UTC timestamps**.
- Render schedule dates as `DD/MM/YYYY` in UI and as actual Excel date cells in exports.
- Store audit event timestamps as UTC instants; present them in the configured Brazilian business timezone (initial default: `America/Sao_Paulo`) and with `pt-BR` formatting. The business timezone is a configuration assumption, not a source of schedule-date shifts.
- Use Brazilian number conventions (e.g. `1.234` as a count, decimal comma where relevant), and calendar/workweek rules defined by each product rather than browser locale guessing.
- Preserve target dates even when they fall on weekends or public holidays.

## Suggested UI terminology

| Internal concept | Preferred `pt-BR` display |
|---|---|
| Product / Products | Produto / Produtos |
| Discipline / Disciplines | Disciplina / Disciplinas |
| Stage / Stages | Etapa / Etapas |
| Activity / Activities | Atividade / Atividades |
| Task / Tasks | Tarefa / Tarefas |
| Milestone (business target) | Meta / Metas |
| Start / End | Início / Fim |
| Predecessor / Successor | Predecessora / Sucessora |
| Dependencies | Dependências |
| Reschedule | Reprogramar |
| Impact preview | Prévia de impactos |
| Change reason | Justificativa da alteração |
| Change history | Histórico de alterações |
| Revision / Scenario | Revisão / Cenário |
| Import / Export | Importar / Exportar |
| Save / Cancel | Salvar / Cancelar |
| Viewer / Editor / Administrator | Leitor / Editor / Administrador |
| Finish-to-Start (FS) | Término–Início (TI) |
| Start-to-Start (SS) | Início–Início (II) |
| Finish-to-Finish (FF) | Término–Término (TT) |
| Start-to-Finish (SF) | Início–Término (IT) |

## Implementation and QA guidance

- Centralize user-visible strings in a locale dictionary or equivalent structure, even if `pt-BR` is the only MVP language. Avoid scattered hard-coded English messages.
- Prefer established internationalization/date-formatting utilities, but do not introduce unnecessary localization framework complexity in Phase 0.
- Validate accessibility text (`aria-label`, chart tooltip descriptions, keyboard hints), file download names, exported sheet labels, and authentication views — these are user-facing surfaces too.
- Add a basic automated or manual QA checklist that detects accidental English text in common screens. Test accent characters and longer Portuguese labels on small screens.
- Do not translate literal source spreadsheet names, column names, user-entered task names, or external identifiers; preserve them exactly as needed for import matching and traceability.
