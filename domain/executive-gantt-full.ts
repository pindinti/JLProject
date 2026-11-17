import type { ExecutiveActivity, ExecutiveDiscipline, ExecutiveProduct, ExecutiveStage } from "../worker/executive-gantt";

export type ExecutiveDetailLevel = "products" | "disciplines" | "stages" | "activities";
export type ExecutiveFullRowKind = "product" | "discipline" | "stage" | "activity";

export interface ExecutiveFullRow {
  key: string;
  kind: ExecutiveFullRowKind;
  id: string;
  product: ExecutiveProduct;
  discipline: ExecutiveDiscipline | null;
  stage: ExecutiveStage | null;
  activity: ExecutiveActivity | null;
  label: string;
  depth: number;
  start: string | null;
  end: string | null;
  color: string | null;
  hasChildren: boolean;
  expanded: boolean;
}

export interface ExecutiveCollapsed {
  products: ReadonlySet<string>;
  disciplines: ReadonlySet<string>;
  stages: ReadonlySet<string>;
}

/** Projects the existing API hierarchy into visible rows without changing dates or entity parents. */
export function visibleExecutiveFullRows(products: readonly ExecutiveProduct[], level: ExecutiveDetailLevel,
  collapsed: ExecutiveCollapsed, disciplineFilter: string | null = null): ExecutiveFullRow[] {
  const rows: ExecutiveFullRow[] = [];
  for (const product of products) {
    const disciplines = disciplineFilter
      ? product.disciplines.filter((discipline) => discipline.id === disciplineFilter) : product.disciplines;
    if (disciplineFilter && disciplines.length === 0) continue;
    const productHasChildren = level !== "products" &&
      (disciplines.length > 0 || level === "activities" && !disciplineFilter && product.rootActivities.length > 0);
    rows.push({ key: `product:${product.id}`, kind: "product", id: product.id, product,
      discipline: null, stage: null, activity: null, label: product.name, depth: 0,
      start: product.start, end: product.end, color: null,
      hasChildren: productHasChildren, expanded: !collapsed.products.has(product.id) });
    if (level === "products" || collapsed.products.has(product.id)) continue;
    if (level === "activities" && !disciplineFilter) for (const activity of product.rootActivities) {
      rows.push({ key: `activity:${activity.id}`, kind: "activity", id: activity.id, product,
        discipline: null, stage: null, activity, label: activity.name, depth: 1,
        start: activity.plannedStart, end: activity.plannedEnd, color: activity.color,
        hasChildren: false, expanded: false });
    }
    for (const discipline of disciplines) {
      const disciplineHasChildren = (level === "stages" || level === "activities") && discipline.stages.length > 0;
      rows.push({ key: `discipline:${discipline.id}`, kind: "discipline", id: discipline.id, product,
        discipline, stage: null, activity: null, label: discipline.name, depth: 1,
        start: discipline.start, end: discipline.end, color: discipline.color,
        hasChildren: disciplineHasChildren, expanded: !collapsed.disciplines.has(discipline.id) });
      if (level === "disciplines" || collapsed.disciplines.has(discipline.id)) continue;
      for (const stage of discipline.stages) {
        const stageHasChildren = level === "activities" && stage.activities.length > 0;
        rows.push({ key: `stage:${stage.id}`, kind: "stage", id: stage.id, product,
          discipline, stage, activity: null, label: stage.displayName, depth: 2,
          start: stage.start, end: stage.end, color: stage.color,
          hasChildren: stageHasChildren, expanded: !collapsed.stages.has(stage.id) });
        if (level !== "activities" || collapsed.stages.has(stage.id)) continue;
        for (const activity of stage.activities) rows.push({ key: `activity:${activity.id}`, kind: "activity",
          id: activity.id, product, discipline, stage, activity, label: activity.name, depth: 3,
          start: activity.plannedStart, end: activity.plannedEnd, color: activity.color,
          hasChildren: false, expanded: false });
      }
    }
  }
  return rows;
}
