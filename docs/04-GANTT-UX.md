# 04 — Gantt User Experience and Visualization

## Proposed navigation

- **Home:** searchable/filterable product portfolio and entry to consolidated Gantt.
- **Product view:** product name, active revision/scenario, `pt-BR` actions for Import, Export, Compare, Revisions, New Scenario; target date panel.
- **Detailed Gantt:** discipline → stage → activity expandable tree with date columns and timeline.
- **Portfolio Gantt:** one logical row per product, including all stage bars even if they overlap.
- **Activity editor:** side drawer or modal with dates, kind, notes, dependencies, and audit history; changing a date requires a reason.
- **Impact preview:** compare before/after date changes, affected activities, audit reason, and threatened goals before commit.

## Detailed Gantt within a product

Phase 1D.1 implementation: the product schedule uses a full-viewport, initially 50/50 table and Gantt with an adjustable divider, a shared vertical scroll container, persistent headers, and synchronized visible rows. Day/week/month zoom changes horizontal scale without changing civil dates. Targets are separate vertical markers fetched through a workspace-scoped Worker endpoint. Admin/editor metadata forms open in a contextual drawer; narrow screens switch between table and timeline panes. Filters, dependency connectors, and drag-based scheduling remain later work.

Phase 1D.1.1 refinement: the only visible horizontal Gantt scrollbar stays in the workspace footer while table and Gantt rows use one vertical scroller. The header, body, and footer reserve matching scrollbar gutters for divider alignment. A distinct Today line uses the current `America/Sao_Paulo` civil date and updates while the workspace is open. Header or empty-grid clicks select an exact civil date, highlighted through the plotted rows and shown as `DD/MM/YYYY`; keyboard arrows change it and a control clears it. Selection does not modify schedule data.

Phase 1D.2A adds a separate planned-date form inside the existing activity side drawer for active admins/editors. It shows the current and proposed `DD/MM/YYYY` dates and requires a justification for an actual change. The editor submits ISO civil dates with the current version, refreshes the authorized hierarchy and audit history after saving, and keeps the workspace mounted to retain zoom, scroll, expansion, and row selection. Active viewers can open read-only date history. Stage and discipline boundaries remain derived from their activities; no related activity or target moves automatically. Both development migrations and the synthetic database check passed. The development administrator reported that the synthetic browser edit blocked missing justification, persisted after reload, refreshed the Gantt/stage range, and appeared in history.

Phase 1D.3 adds a “Adicionar marco” action and a target dialog opened from the toolbar or a Gantt marker. Active admins/editors can create, edit, and soft-delete business targets; viewers can inspect them read-only. Dates display in `DD/MM/YYYY` and use ISO civil dates in Worker requests. Successful mutations update the marker list in place, preserving timeline selection, zoom, and scroll. Date edits require a justification and append-only audit record. The additive migration is pending explicit approval for Neon development; live persistence verification must follow migration approval.

Phase 3A.3C.2 displays the read-only calendar-impact response in the product schedule. A compact notice counts affected working-day activities and opens a review panel with current and proposed end dates, civil-day difference, calendar versions, and optional-holiday coverage warnings. Date-changing proposals render as transparent dashed activity-row overlays while saved bars remain visible; version-only proposals remain in the panel without an overlay. Hiding the panel removes overlays without acknowledging or changing data. Refresh fetches the current impact response, and a mismatch with the loaded hierarchy withholds the overlay until the schedule is reloaded. Manual and imported activities receive no proposals. No apply or rescheduling operation is available.

- Header offers day/week/month zoom, date navigation, `Hoje`, filters, and legend, all labeled in `pt-BR`.
- Discipline and stage rows expand/collapse; individual activities appear underneath.
- A stage bar represents aggregate `MIN(child start_date)` → `MAX(child end_date)` in the selected revision; activities may overlap.
- Activity bars reflect actual civil dates, not fabricated sequential spans from the source worksheet order.
- Optional dependency connectors can be shown or hidden. Selecting one bar highlights immediate predecessor/successor links; avoid noisy default views.
- Left table can scroll alongside the timeline while retaining visible task names, start, end, duration, kind, and compared-revision differences.
- Clicking opens details. Start with safe form-based editing before introducing drag-to-move or resize interactions.

## Consolidated Gantt across the portfolio

**Core invariant: exactly one logical row per product, with a dynamic number of inner lanes when time intervals overlap.** A fixed-height row must never hide one of its overlapping stage bars.

Conceptual layout (all positions are calendar-based):

```text
                  NOV       DEC       JAN       FEB
Torre A  ┌ ARQ·EC ────┐ ┌ ARQ·EP ─────┐
         └ PAI·EC ─────────────┐
             └ LUM·EP ───────────────┐
Torre B  ┌ ARQ·AP ───────────────────────┐
         └ PAI·EP ─────┐ ┌ GAR·AP ───┐
Torre C  ┌ ARQ·PL ───────────────┐
```

- For each product, load activities from its selected version, then aggregate by product + discipline + stage, producing **one interval per stage**.
- Pack overlapping intervals into non-overlapping *visual* lanes using an interval-partitioning algorithm. Preserve all original start/end dates; visual placement must never change schedule values.
- Default display label: `ARQ · EP`, `PAI · EC`, `LUM · AP`; accessible descriptions and tooltips provide the complete names.
- Switch between **color by discipline** and **color by stage**, with consistent palettes. The `EC` stage uses the same stage color in any discipline; discipline coloring follows each discipline's identity.
- Clicking a bar opens the corresponding product/stage in the detailed Gantt.
- Support filtering disciplines/products, zoom, collapsible details, and navigation to a selected date.
- In comparisons, render a ghost/outline of the old position, displacement in days, and clear source/destination revision labels.

## Target dates on Gantt charts

- Each target has name, civil date, and optional color; quantity is unlimited.
- **Product Gantt:** a named vertical marker crosses the product's schedule area on the target date.
- **Portfolio Gantt:** a product-specific marker crosses **only that product's logical row**, with a readable tooltip. Never draw the targets of Torre A over Torre B.
- At dense zoom scales, prevent overlapping target captions without hiding database records.
- Targets do not move automatically when activities shift. Show alerts when relevant activities exceed their deadlines.
- Portfolio-wide markers across all products are a future option; never assume that the five source goals are global.

## Accessibility and layout

- Desktop-first, synchronized vertical scrolling between pinned left table and timeline, and sticky time headers.
- Brazilian Portuguese (`pt-BR`) display, `DD/MM/YYYY` dates, multiple zoom levels, and local business terminology.
- Use icons/labels in addition to color to indicate risk, comparisons, and status.
- Provide keyboard navigation, adequate contrast, readable tooltips, and empty/loading/error states.
- Do not require paid Gantt libraries or licenses incompatible with corporate usage or free hosting. Evaluate license, interval overlaps, custom portfolio lanes, performance, and flexibility before choosing a library.

## Dependency editor UX

When editing a stage or activity, provide a section titled **`Depende de`**:

1. Searchable picker of other stages/tasks **within the same product**, grouped by discipline and stage.
2. Multiple predecessor links for a single successor.
3. Each link has its own type (`TI` by default; advanced `II`, `TT`, `IT`) and optional lag.
4. Immediate feedback on cycles and on constraints conflicting with existing dates.
5. Preview required date shifts before persisting the new link.

Example: `Torre A / Arquitetura / EP / Validação` depends on `Torre A / Paisagismo / EC / Análise`.
