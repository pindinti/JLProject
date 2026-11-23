BEGIN;

SET LOCAL search_path = pg_catalog, pg_temp;

-- Keep storage closed until every affected writer and the clone baseline are handled together.
CREATE TABLE public.product_schedule_dependencies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  endpoint_kind text NOT NULL,
  predecessor_activity_id uuid,
  successor_activity_id uuid,
  predecessor_stage_id uuid,
  successor_stage_id uuid,
  CONSTRAINT product_schedule_dependencies_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products (workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT product_schedule_dependencies_endpoint_shape CHECK (
    (endpoint_kind = 'activity'
      AND predecessor_activity_id IS NOT NULL AND successor_activity_id IS NOT NULL
      AND predecessor_activity_id <> successor_activity_id
      AND predecessor_stage_id IS NULL AND successor_stage_id IS NULL)
    OR (endpoint_kind = 'stage'
      AND predecessor_stage_id IS NOT NULL AND successor_stage_id IS NOT NULL
      AND predecessor_stage_id <> successor_stage_id
      AND predecessor_activity_id IS NULL AND successor_activity_id IS NULL)
  ),
  CONSTRAINT product_schedule_dependencies_predecessor_activity_fk
    FOREIGN KEY (workspace_id, product_id, predecessor_activity_id)
    REFERENCES public.stage_activities (workspace_id, product_id, id) ON DELETE RESTRICT,
  CONSTRAINT product_schedule_dependencies_successor_activity_fk
    FOREIGN KEY (workspace_id, product_id, successor_activity_id)
    REFERENCES public.stage_activities (workspace_id, product_id, id) ON DELETE RESTRICT,
  CONSTRAINT product_schedule_dependencies_predecessor_stage_fk
    FOREIGN KEY (workspace_id, product_id, predecessor_stage_id)
    REFERENCES public.discipline_stages (workspace_id, product_id, id) ON DELETE RESTRICT,
  CONSTRAINT product_schedule_dependencies_successor_stage_fk
    FOREIGN KEY (workspace_id, product_id, successor_stage_id)
    REFERENCES public.discipline_stages (workspace_id, product_id, id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX product_schedule_dependencies_activity_pair_idx
  ON public.product_schedule_dependencies (workspace_id, product_id, predecessor_activity_id, successor_activity_id)
  WHERE predecessor_activity_id IS NOT NULL;
CREATE UNIQUE INDEX product_schedule_dependencies_stage_pair_idx
  ON public.product_schedule_dependencies (workspace_id, product_id, predecessor_stage_id, successor_stage_id)
  WHERE predecessor_stage_id IS NOT NULL;
CREATE INDEX product_schedule_dependencies_activity_successor_idx
  ON public.product_schedule_dependencies (workspace_id, product_id, successor_activity_id)
  WHERE successor_activity_id IS NOT NULL;
CREATE INDEX product_schedule_dependencies_stage_successor_idx
  ON public.product_schedule_dependencies (workspace_id, product_id, successor_stage_id)
  WHERE successor_stage_id IS NOT NULL;

REVOKE ALL ON TABLE public.product_schedule_dependencies FROM PUBLIC, jlproject_worker, jlproject_date_executor;

COMMIT;
