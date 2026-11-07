BEGIN;

ALTER TABLE public.products
  ADD CONSTRAINT products_workspace_id_id_unique UNIQUE (workspace_id, id);

CREATE TABLE public.product_disciplines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 200 AND name = btrim(name)),
  short_code text NOT NULL CHECK (char_length(btrim(short_code)) BETWEEN 1 AND 24 AND short_code = btrim(short_code)),
  color text NOT NULL CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  display_order integer NOT NULL CHECK (display_order >= 0),
  description text CHECK (description IS NULL OR char_length(description) <= 2000),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_disciplines_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT product_disciplines_scope_id_unique UNIQUE (workspace_id, product_id, id)
);

CREATE UNIQUE INDEX product_disciplines_name_unique_idx
  ON public.product_disciplines (product_id, lower(name));
CREATE UNIQUE INDEX product_disciplines_code_unique_idx
  ON public.product_disciplines (product_id, lower(short_code));
CREATE INDEX product_disciplines_order_idx
  ON public.product_disciplines (workspace_id, product_id, display_order, id);

CREATE TABLE public.stage_definitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE RESTRICT,
  code text NOT NULL CHECK (char_length(btrim(code)) BETWEEN 1 AND 24 AND code = btrim(code)),
  color text NOT NULL CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT stage_definitions_scope_id_unique UNIQUE (workspace_id, id)
);
CREATE UNIQUE INDEX stage_definitions_code_unique_idx
  ON public.stage_definitions (workspace_id, lower(code));

CREATE TABLE public.discipline_stages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  discipline_id uuid NOT NULL,
  definition_id uuid NOT NULL,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 200 AND display_name = btrim(display_name)),
  display_order integer NOT NULL CHECK (display_order >= 0),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT discipline_stages_parent_fk FOREIGN KEY (workspace_id, product_id, discipline_id)
    REFERENCES public.product_disciplines(workspace_id, product_id, id) ON DELETE RESTRICT,
  CONSTRAINT discipline_stages_definition_fk FOREIGN KEY (workspace_id, definition_id)
    REFERENCES public.stage_definitions(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT discipline_stages_unique_definition UNIQUE (discipline_id, definition_id),
  CONSTRAINT discipline_stages_scope_id_unique UNIQUE (workspace_id, product_id, discipline_id, id)
);
CREATE INDEX discipline_stages_order_idx
  ON public.discipline_stages (workspace_id, product_id, discipline_id, display_order, id);

CREATE TABLE public.stage_activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  discipline_id uuid NOT NULL,
  stage_id uuid NOT NULL,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 300 AND name = btrim(name)),
  activity_type text CHECK (activity_type IS NULL OR char_length(activity_type) BETWEEN 1 AND 80),
  planned_start date,
  planned_end date,
  display_order integer NOT NULL CHECK (display_order >= 0),
  notes text CHECK (notes IS NULL OR char_length(notes) <= 4000),
  source_external_id text CHECK (source_external_id IS NULL OR char_length(source_external_id) BETWEEN 1 AND 100),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stage_activities_parent_fk FOREIGN KEY (workspace_id, product_id, discipline_id, stage_id)
    REFERENCES public.discipline_stages(workspace_id, product_id, discipline_id, id) ON DELETE RESTRICT,
  CONSTRAINT stage_activities_dates_check CHECK (
    (planned_start IS NULL AND planned_end IS NULL) OR
    (planned_start IS NOT NULL AND planned_end IS NOT NULL AND planned_start <= planned_end)
  )
);
CREATE INDEX stage_activities_order_idx
  ON public.stage_activities (workspace_id, product_id, discipline_id, stage_id, display_order, id);
CREATE UNIQUE INDEX stage_activities_source_id_unique_idx
  ON public.stage_activities (product_id, source_external_id)
  WHERE source_external_id IS NOT NULL;

CREATE FUNCTION public.prevent_activity_date_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.planned_start IS DISTINCT FROM OLD.planned_start OR
     NEW.planned_end IS DISTINCT FROM OLD.planned_end THEN
    RAISE EXCEPTION 'Existing activity dates are immutable until the audited edit operation is implemented.'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER stage_activities_dates_immutable
  BEFORE UPDATE ON public.stage_activities
  FOR EACH ROW EXECUTE FUNCTION public.prevent_activity_date_update();
REVOKE ALL ON FUNCTION public.prevent_activity_date_update() FROM PUBLIC;

CREATE FUNCTION public.create_discipline_stage(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_actor_id uuid,
  p_code text, p_color text, p_display_name text, p_display_order integer
) RETURNS text
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_definition_id uuid;
  v_color text;
  v_stage_id uuid;
BEGIN
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  PERFORM 1 FROM public.product_disciplines AS discipline
    JOIN public.products AS product ON product.id = discipline.product_id
    WHERE discipline.id = p_discipline_id AND discipline.workspace_id = p_workspace_id
      AND discipline.product_id = p_product_id AND product.active = true;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;

  SELECT id, color INTO v_definition_id, v_color FROM public.stage_definitions
    WHERE workspace_id = p_workspace_id AND lower(code) = lower(p_code);
  IF FOUND THEN
    IF v_color <> p_color THEN RETURN 'conflict'; END IF;
  ELSE
    INSERT INTO public.stage_definitions (workspace_id, code, color)
      VALUES (p_workspace_id, p_code, p_color) RETURNING id INTO v_definition_id;
  END IF;
  IF EXISTS (SELECT 1 FROM public.discipline_stages
      WHERE discipline_id = p_discipline_id AND definition_id = v_definition_id) THEN
    RETURN 'duplicate';
  END IF;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name,
     display_order, created_by, updated_by)
    VALUES (p_workspace_id, p_product_id, p_discipline_id, v_definition_id,
      p_display_name, p_display_order, p_actor_id, p_actor_id)
    RETURNING id INTO v_stage_id;
  RETURN v_stage_id::text;
END;
$$;

CREATE FUNCTION public.update_discipline_stage(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_stage_id uuid,
  p_actor_id uuid, p_code text, p_color text, p_display_name text,
  p_display_order integer, p_version bigint
) RETURNS text
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_definition_id uuid;
  v_color text;
  v_version bigint;
BEGIN
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  SELECT stage.version INTO v_version
    FROM public.discipline_stages AS stage
    JOIN public.products AS product ON product.id = stage.product_id
    WHERE stage.id = p_stage_id AND stage.workspace_id = p_workspace_id
      AND stage.product_id = p_product_id AND stage.discipline_id = p_discipline_id
      AND product.active = true
    FOR UPDATE OF stage;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  IF v_version <> p_version THEN RETURN 'stale'; END IF;

  SELECT id, color INTO v_definition_id, v_color FROM public.stage_definitions
    WHERE workspace_id = p_workspace_id AND lower(code) = lower(p_code);
  IF FOUND THEN
    IF v_color <> p_color THEN RETURN 'conflict'; END IF;
  ELSE
    INSERT INTO public.stage_definitions (workspace_id, code, color)
      VALUES (p_workspace_id, p_code, p_color) RETURNING id INTO v_definition_id;
  END IF;
  IF EXISTS (SELECT 1 FROM public.discipline_stages
      WHERE discipline_id = p_discipline_id AND definition_id = v_definition_id
        AND id <> p_stage_id) THEN
    RETURN 'duplicate';
  END IF;
  UPDATE public.discipline_stages SET definition_id = v_definition_id,
    display_name = p_display_name, display_order = p_display_order,
    updated_by = p_actor_id, updated_at = now(), version = version + 1
    WHERE id = p_stage_id;
  RETURN 'updated';
END;
$$;

REVOKE ALL ON FUNCTION public.create_discipline_stage(uuid, uuid, uuid, uuid, text, text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_discipline_stage(uuid, uuid, uuid, uuid, uuid, text, text, text, integer, bigint) FROM PUBLIC;

COMMIT;
