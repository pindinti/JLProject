# Executive Gantt UI Refinements — Phase D.1

The `/produtos` page now renders product actions and cards before the compact Executive Gantt. Existing product loading, error, and empty states retain their behavior; the portfolio projection remains below those states.

Both product-level visualizations label stage bars with their discipline and stage. Home prefers the existing discipline short code and stage code to fit the compact row. The full view uses full entity names. Bar widths match the plotted civil-date interval. Text clips inside a narrow bar; the title and accessible label retain the complete discipline, stage, and date details. Partially dated stages render as small boundary markers. Root activities remain activities and are not included as stage bars.

The full view initializes to Produtos with Mês zoom. Hierarchy and temporal controls remain independent. No Home scale default, API contract, database, schedule data, or individual product Gantt behavior changed.
