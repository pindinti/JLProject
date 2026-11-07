BEGIN;

CREATE TABLE public.workspaces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 200),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.workspace_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE RESTRICT,
  auth_user_id uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  role text NOT NULL CHECK (role IN ('admin', 'editor', 'viewer')),
  active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT workspace_memberships_unique_user UNIQUE (workspace_id, auth_user_id)
);

CREATE INDEX workspace_memberships_user_active_idx
  ON public.workspace_memberships (auth_user_id, workspace_id)
  WHERE active = true;

COMMIT;
