# JLProject — Design System v1.1

**Product:** Internal product schedule management for architecture and real estate development teams.  
**Visual direction:** **Nordic Precision** — clarity, proportion, restraint, and function.  
**Implementation status:** Design guidance; features described as *planned* are not yet implemented.  
**Source of truth for navigation:** **No sidebar.** Preserve the existing full-width schedule table + Gantt workspace. The fixed application header provides global navigation.

> **UI language:** All user-facing application strings must be **Brazilian Portuguese (pt-BR)**. Code, technical documentation, and implementation prompts may be written in English.

## 1. Design principles

1. **Clarity before decoration.** Scheduling information is the protagonist; spacing and hierarchy should support it.
2. **Precision without rigidity.** Use consistent geometry, alignment, and feedback, with restrained human touches.
3. **Controlled density.** Tables and Gantt timelines may be information-dense; forms and general navigation should breathe.
4. **Actions in context.** Edit products, stages, activities, and milestones without losing the user's place.
5. **Operational safety.** Date changes, deletion, import, and audited actions require explicit, trustworthy feedback.
6. **Maximum workspace, minimum chrome.** Never compromise the usable Gantt area for decorative navigation.

## 2. Brand and color system

Use the **approved SVG artwork**, unchanged. Do not redraw the JL monogram or recreate the wordmark with a web font.

| Brand color | Hex | Role |
|---|---|---|
| Graphite | `#333733` | Main brand text and logo |
| Sage | `#8D9A89` | Brand accent |
| Cream | `#F3EFE9` | Brand background |
| Dark graphite | `#252B28` | Dark surfaces |

### Functional light-theme tokens

| Token | Value | Purpose |
|---|---|---|
| `--jl-bg` | `#F3EFE9` | Application background |
| `--jl-surface` | `#FFFFFF` | Cards, forms, table, and Gantt |
| `--jl-surface-alt` | `#F8F7F4` | Headers and secondary surfaces |
| `--jl-text` | `#333733` | Primary text |
| `--jl-text-muted` | `#5C6B61` | Secondary text |
| `--jl-border` | `#DADFD7` | Subtle separators |
| `--jl-border-strong` | `#7D887E` | Input borders |
| `--jl-primary` | `#52694D` | Primary actions and links |
| `--jl-primary-soft` | `#E4EBE1` | Soft selection and hover |
| `--jl-focus` | `#355F52` | Visible keyboard focus |

The logo's sage green alone is too low-contrast for small text on white (approximately 2.95:1). Use the stronger functional green `#52694D` for accessible interactive text (approximately 6.02:1 on white). Never communicate a state by color alone.

### Semantic states

| State | Foreground | Background | Suggested icon |
|---|---|---|---|
| Not started | `#475569` | `#F1F4F6` | Empty circle |
| In progress | `#355C7D` | `#E8EFF7` | Partial circle |
| Completed | `#355F52` | `#E6F3ED` | Check |
| At risk | `#8A5A25` | `#FFF1DC` | Warning |
| Overdue / blocked | `#8C3B35` | `#FBE5E3` | Warning plus text |

**Execution status and schedule health are distinct dimensions.** An activity can be “Em andamento” and “Atrasada” simultaneously. Do not infer completion from elapsed time or planned dates. Product summary metrics must be based on actual persisted activity state once implemented.

## 3. Typography

- **Inter:** preferred interface font, with system font fallback for resilience.
- **IBM Plex Mono (optional):** identifiers and technical values; do not apply automatically to every date.
- **Wordmark:** always use the supplied outlined SVG.

| Role | Size / line height | Weight |
|---|---|---|
| Page title | 28px / 36px | 600 |
| Section title | 22px / 30px | 600 |
| Card title | 18px / 26px | 600 |
| Large body | 16px / 24px | 400–500 |
| Standard body / rows | 14px / 21px | 400–500 |
| Control label | 13px / 18px | 600 |
| Metadata | 12px / 17px | 500 |

Use sentence case rather than all caps. Prefer typographic weight over excessive colors. Dates and numeric columns use `font-variant-numeric: tabular-nums`. Avoid 12px text for extended paragraphs.

## 4. Geometry, spacing, and elevation

- **4px** base spacing scale: 4, 8, 12, 16, 20, 24, 32, 40, 48, 64px.
- Radii: 4px tags, 6px chips, **8px controls**, **12px cards and dialogs**. Avoid excessively rounded 20–30px controls.
- Prefer thin borders to shadows; use only minimal elevation.
- Fixed global header: approximately **56px** high, adapted as necessary for responsive behavior.
- Standard page padding: approximately **24px**; the schedule workspace may use tighter padding to maximize usable area.
- Standard control height: **36px**.
- Compact mode (tables and Gantt only): table rows **34px**, Gantt rows **34px**, controls **32px**.
- Key actions should have a usable target of approximately **40×40px**, even when the visible icon is 16–20px.

**Do not implement a sidebar.** If the supplied CSS includes an unused `--jl-sidebar-width` legacy token, it does not authorize a sidebar or reserve layout space.

## 5. Application layout and navigation

### 5.1 Global fixed header

A single header spans the top of the authenticated application and stays visible across Home, Schedule, Settings, and Administration.

```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│ [JLProject logo]   Sistema de Cronogramas de Produto                                │
│                      Bom dia, Jana! Que seu dia seja lindo ❤️   [⚙] [Devloop] [Sair] │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

This is a structural example, not a literal spacing specification.

- Use the approved horizontal JLProject SVG and the subtitle **“Sistema de Cronogramas de Produto”**.
- Greeting is time-aware in **America/Sao_Paulo**: “Bom dia”, “Boa tarde”, or “Boa noite”, followed by the user's preferred/display first name and **“Que seu dia seja lindo ❤️”**.
- Right-side actions: **Configurações**, **Devloop**, and **Sair**. Provide accessible labels and tooltips for icon-only controls.
- Admin-specific user management lives under Settings or an appropriate privileged destination; never expose privileged actions to non-admin users.
- The header must not overlap scrollable content. Preserve the existing Gantt viewport height and its scrollbars.
- On smaller screens, compress or wrap header elements thoughtfully; do not introduce a permanent sidebar.

### 5.2 Home — product overview

Home is a clean product-selection surface, **not** a large analytics dashboard.

```text
┌────────────────────────── Fixed global header ──────────────────────────────────────┐
│ Produtos                                          [+ Cadastrar produto] [Importar planilha]│
│                                                                                     │
│ ┌─────────────────────────────┐  ┌─────────────────────────────┐                    │
│ │ Multi 05 Beach     [📒] [⚙] │  │ Outro produto       [📒] [⚙] │                    │
│ │ 41 atividades               │  │ ...                         │                    │
│ │ xx/41 concluídas · xx%      │  │ ...                         │                    │
│ │ Em andamento · Atenção      │  │ ...                         │                    │
│ └─────────────────────────────┘  └─────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

- Immediately load cards for registered products; do not require the user to open an additional listing panel.
- Primary horizontal actions: **Cadastrar produto** and **Importar planilha**.
- Clicking the main card area opens the existing product schedule workspace.
- The card's **⚙** menu contains authorized actions such as edit, archive, and delete. Show appropriate confirmation and respect retention, ownership, and existing API capabilities; do not imply hard deletion if unsupported.
- The **📒** action opens the product's available change history/audit log. Where full product-level history is not yet implemented, indicate the feature as planned rather than fabricating records.
- Product summaries should eventually show: total activities; completed count and percentage; in-progress count; overdue count; at-risk count. Until execution status is persisted, display only truthful available metrics or clearly marked unavailable states.
- Use one clear hierarchy of title, metrics, and actions; avoid visually heavy cards.

### 5.3 Product schedule — preserve the existing workspace

**This section overrides any older design mockup featuring a sidebar, tab-heavy page, or a Gantt embedded in a decorative dashboard card.**

```text
┌────────────────────────── Fixed global header ──────────────────────────────────────┐
│ ‹ Produtos   Multi 05 Beach                                [existing schedule actions]│
│ ┌────────────────────── Task table ──────────────┬────────── Gantt ────────────────┐│
│ │ Product / Discipline / Stage / Activity        │ Timeline + bars + milestones    ││
│ │ Planned dates, expand/collapse, row actions    │ Today + selected date markers   ││
│ │                                                │                                ││
│ │       Synchronized rows and vertical scroll    │                                ││
│ └────────────────────────────────────────────────┴────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────────────┘
```

- Keep the current **full-width, initially 50/50, resizable table + Gantt split**.
- Preserve shared visible-row order and synchronized vertical scrolling, sticky date headers, accessible horizontal timeline scrolling, and contextual edit drawer.
- Preserve day/week/month zoom, Today marker, selected-date highlighting, target markers, hierarchy expansion, and all existing interactions.
- No persistent left navigation rail, oversized surrounding card, or redundant dashboard panels.
- Provide a compact way back to Products; keep schedule context visible without consuming excessive vertical space.
- Hierarchy remains **Product → Discipline → Stage → Activity**. Use the actual domain terminology, not interchangeable project/product labels.

### 5.4 Responsive behavior

- **≥1440px:** full-width split view with flexible table and chart; prioritize timeline visibility.
- **1024–1439px:** same layout, with restrained padding and resizable split.
- **768–1023px:** preserve usable table and chart through responsive pane behavior and horizontal scrolling; do not shrink dates into unreadable columns.
- **<768px:** simplified product cards and controls; use a mobile-appropriate table/timeline presentation with explicit horizontal scroll. Do not force the entire Gantt to fit the screen.
- No responsive breakpoint should introduce a persistent sidebar.

## 6. Component standards

| Component | Behavior |
|---|---|
| Button | Primary, secondary, ghost, danger; clear loading/disabled states; one primary action per context |
| Icon | Consistent ~1.75px stroke; 16/18/20px; accessible label or tooltip |
| Input | Persistent label, optional hint, contextual errors, sufficient border contrast |
| Date picker | `dd/mm/aaaa` in UI; ISO civil date for persistence; explicit timezone handling where needed |
| Select / combobox | Searchable for large sets, keyboard navigable |
| Table | Aligned columns, useful filtering where applicable, sticky headers, clear empty/loading states |
| Badge | Label plus color/icon; never color alone |
| Card | Compact summaries and low-density information; do not turn table rows into cards |
| Popover / menu | Contextual actions positioned near the invoking control |
| Drawer | Contextual editing without losing Gantt/table position |
| Modal | Focused data entry, destructive confirmation, and conflicts |
| Toast | Short success/error feedback; significant errors also appear in the relevant form |
| Audit history | Actor, date/time, previous/new values, reason when applicable |
| Excel importer | File selection → mapping → preview/validation → review → confirm → result |

### Interaction rules

- `Enter`: confirm an action or begin cell editing when supported; `Escape`: cancel; `Tab`: navigate.
- Show **saving / saved / error** state for server-backed changes.
- Confirm destructive actions and explain implications.
- Date changes must disclose old and new dates, format expectations, and any scheduling impact.
- All controls must be keyboard accessible. Use an ARIA grid interaction model only if actual cell-by-cell navigation exists.

## 7. Gantt — primary work surface

**Visual composition:** hierarchy/table at left, calendar at right, pinned date header and perfectly aligned rows. The Gantt should remain visually unobstructed and free of heavy decorative framing.

### Hierarchy

- **Discipline:** prominent collapsible group, subtly differentiated background.
- **Stage:** intermediate level with dates derived from activities, summary bar where applicable.
- **Activity:** standard row with name, dates, and execution status when available.
- Empty stages remain visible without invented activities or dates.

### Critical color compatibility requirement

- **Every currently user-customizable Gantt bar/line color must remain editable and persisted exactly as before.** Do not replace existing saved colors with sage, status colors, or a fixed design-system palette.
- Preserve the existing scope of color assignment; do not silently change whether colors apply to stages, disciplines, activities, or milestones.
- Apply saved colors after reload, edits, imports, density changes, and theme changes.
- **Add 16 preset color swatches for quick selection while retaining the existing unrestricted custom color picker / hexadecimal input.** Presets are suggestions, not validation constraints or automatic replacements.
- Apply the same quick-pick/custom-color principle to milestones. Changing a preset should be an explicit user action.

Suggested 16 quick-pick colors (final UI palette may be refined without changing storage semantics):

| | | | |
|---|---|---|---|
| `#52694D` | `#8D9A89` | `#355F52` | `#3C8792` |
| `#355C7D` | `#4A79A8` | `#667D91` | `#5F68A5` |
| `#8560A4` | `#A16E8D` | `#805069` | `#8C3B35` |
| `#B9654E` | `#B98738` | `#D2A357` | `#6F7772` |

### Timeline structure and interactions

- Day grid: `#E1E5DF`; weekends: `#F4F5F1`; Today line: `#355F52`. These colors apply to the **chart structure**, not user-colored bars.
- Keep Today, selected date, and persisted milestones visually distinguishable.
- Preserve an exact selected civil date and the **“Limpar data selecionada”** action.
- Milestone editing remains contextual. **Show each milestone's complete name directly on the Gantt when space allows**, with readable overflow/overlap handling and a full-name tooltip as a fallback. Do not truncate silently without an alternative.
- Preserve existing milestone name, description, date, color, audited date edits, and soft deletion.
- In day/week/month zoom, use consistent civil-date geometry. Avoid shifting dates through timezone conversion.
- Do not infer progress from time elapsed. When actual progress exists, represent it through a secondary pattern/overlay without overwriting the selected bar color.

### Microinteractions

- Hover: highlight the corresponding row and show full name and dates without losing context.
- Click: explicit selection; editing is a deliberate separate action where appropriate.
- Date edits: show before → after, justification, save status, and audit trail.
- Preserve zoom and scroll positions where practical.
- Prefer explicit scheduling controls over accidental drag-to-reschedule.

## 8. Activity and stage forms

Preferred field order: **Name → Discipline/Stage → Dates → Owner/Execution status (if implemented) → Description**. Put infrequent fields under **More details**.

- Display start/end side by side and reject end dates earlier than start dates.
- Keep date editing auditable: previous value, new value, reason, outcome, and history.
- Stage dates derived from child activities must not be independently overridden. Any future stage-wide rescheduling must preview its activity-level impact before confirmation.
- Show importer validation by source row/column. Error downloads may be added separately.
- Use the existing contextual drawer rather than placing forms at the bottom of long schedules.

## 9. Settings, Devloop, feedback, and copy

### Settings — planned product surface

Open a dedicated **Configurações** area from the fixed header. Organize by permission:

- **Meu perfil:** display name, profile picture, and email/account information. Profile photos may appear alongside activity audit entries; audit attribution must continue to rely on stable user IDs, not editable names or images.
- **Notificações:** notification destination email and configurable lead time (N days before an activity's planned end date). Do not imply email alerts work before a delivery/scheduler integration is implemented.
- **Usuários (admin only):** invite/provision users and manage roles. Production onboarding must not expose the project-scoped Neon Management API key in the public Worker. Until a safe supported production invitation flow exists, retain the operator-only procedure.

### Devloop — planned feedback flow

A **Devloop** action is always visible in the global header. Open a small modal or dedicated page for:

- **Reportar problema** — bug report.
- **Sugerir funcionalidade** — feature request.
- Free-text description, optional relevant context, and clear submission feedback.

The eventual delivery must send a message to the developer's configured email via an appropriate server-side integration. Do not implement a fake successful submit action, and do not include confidential data or credentials by default.

### Feedback language

- **Loading:** skeleton for table/card loading; spinner for a specific pending operation.
- **Empty:** contextual message and next action, e.g. “Nenhuma atividade nesta etapa” / “Criar atividade”.
- **Success:** subtle toast, e.g. “Atividade atualizada”.
- **Failure:** concrete guidance and retry, e.g. “Não foi possível salvar a nova data. Tente novamente.”
- **No permission:** explain unavailable actions appropriately.
- **Preferred vocabulary:** “Cadastrar produto”, “Importar planilha”, “Nova atividade”, “Editar etapa”, “Adicionar marco”, “Configurações”, “Sair”. Avoid bureaucratic wording.

## 10. Accessibility and quality

- Target **WCAG 2.2 AA**: at least 4.5:1 contrast for normal text and 3:1 for large text and key non-text UI indicators.
- Visible keyboard focus; never rely only on subtle shadow.
- Status colors always have an accompanying label, icon, or visual pattern.
- Tooltips supplement rather than replace labels.
- Honor `prefers-reduced-motion`.
- At up to 200% browser zoom, forms remain usable and the Gantt remains navigable through scrolling.
- Verify keyboard navigation and screen reader labels for critical flows.

References: [W3C WCAG 2.2](https://www.w3.org/TR/WCAG22/) and [WAI-ARIA Data Grid](https://www.w3.org/WAI/ARIA/apg/patterns/grid/).

## 11. Dark theme

Dark mode extends the identity but **is not a pilot priority**. Tokens already exist in `jlproject-tokens.css`, together with dark-background logo versions. Validate each component's contrast when activating the theme; never invert the SVG artwork automatically. Keep user-selected Gantt and milestone colors unchanged.

## 12. Incremental implementation plan

1. **UI 2A — Foundation:** integrate design tokens and supplied logos; introduce the fixed global header and greeting; preserve existing navigation, authentication, and Gantt layout.
2. **UI 2B — Home:** horizontal product actions, product cards, contextual edit/archive/delete, and available activity counts. Do not fabricate completion metrics.
3. **UI 2C — Gantt styling:** 16 quick-pick swatches plus unrestricted custom colors; display milestone names; preserve current behavior and saved colors.
4. **UI 2D — Execution status:** introduce an explicit activity execution-state model and grounded completed/in-progress/overdue/at-risk card metrics, separately from planned dates.
5. **UI 2E — Settings:** profile and avatar; notification preferences; permission-appropriate user management.
6. **UI 2F — Devloop and notifications:** working feedback delivery and scheduled activity reminders; use supported secure server-side integrations.
7. **Optional:** dark mode, density refinement, and subtle transitions after core usability is validated.

**Engineering rule:** avoid mixing visual refactors with scheduling/business-logic refactors in the same PR. Use small, scoped changes; targeted tests while developing; one complete validation pass at the end. Work against localhost and Neon development; deploy to production only after separate review and approval.

## 13. Files and source precedence

Recommended repository locations:

```text
docs/11-DESIGN-SYSTEM.md
src/design/jlproject-tokens.css
public/brand/jlproject-logo.svg
public/brand/jlproject-logo-dark.svg
public/brand/jlproject-mark.svg
public/brand/jlproject-mark-dark.svg
```

- `jlproject-tokens.css` contains semantic tokens, optional `.jl-*` component classes, compact-density overrides, and dark-theme tokens. **Its legacy sidebar-width token must not be used to create a sidebar.**
- The four supplied SVGs are approved assets; do not replace or redraw them.
- An optional `preview.html`, if present, is **visual reference only**. Any sidebar or page layout shown there is superseded by **Section 5** of this document and the currently implemented full-width schedule workspace.
- Existing persisted dates, bar colors, milestone colors, audit history, authorization rules, and immutable R00 must take precedence over visual styling changes.

**When instructions conflict:** the user's latest approved layout decisions and this document's no-sidebar/full-width Gantt requirements override older layout sketches. Existing application security and persistence invariants remain mandatory.
