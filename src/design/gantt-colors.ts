export const ganttPresetColors = [
  "#52694D", "#8D9A89", "#355F52", "#3C8792",
  "#355C7D", "#4A79A8", "#667D91", "#5F68A5",
  "#8560A4", "#A16E8D", "#805069", "#8C3B35",
  "#B9654E", "#B98738", "#D2A357", "#6F7772"
] as const;

export interface MilestoneLabelLayout {
  id: string;
  name: string;
  left: number;
  width: number;
  lane: number;
}

export function layoutMilestoneLabels(
  targets: readonly { id: string; name: string; targetDate: string }[],
  position: (date: string) => number,
  timelineWidth: number
): MilestoneLabelLayout[] {
  const lanes: number[] = [];
  const layouts: MilestoneLabelLayout[] = [];
  const availableWidth = Math.max(0, timelineWidth);
  const ordered = targets.map((target) => {
    const marker = position(target.targetDate);
    const width = Math.min(208, availableWidth, Math.max(56, target.name.length * 7 + 12));
    const left = Math.min(Math.max(0, marker + 8), Math.max(0, availableWidth - width));
    return { ...target, marker, left, right: left + width, width };
  }).sort((left, right) => left.marker - right.marker || left.id.localeCompare(right.id));

  for (const label of ordered) {
    let lane = lanes.findIndex((laneEnd) => label.left >= laneEnd + 8);
    if (lane < 0) lane = lanes.length;
    lanes[lane] = label.right;
    layouts.push({ id: label.id, name: label.name, left: label.left, width: label.width, lane });
  }
  return layouts;
}
