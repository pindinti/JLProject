-- Validate provider-created identities before assigning fixture workspace roles.
-- Neon Auth users must be created through the branch-scoped Neon API, never inserted here.
-- The embedded Neon CLI psql mishandles \if in -f files and ignores \quit's status,
-- so every failed preflight condition is a real SQL error under ON_ERROR_STOP.
\set ON_ERROR_STOP on

BEGIN READ ONLY;

SELECT set_config('jlproject.phase4b5.branch_id', :'phase4b5_branch_id', true),
  set_config('jlproject.phase4b5.admin_user_id', :'phase4b5_admin_user_id', true),
  set_config('jlproject.phase4b5.viewer_user_id', :'phase4b5_viewer_user_id', true);

DO $phase4b5_identity_preflight$
DECLARE
  v_branch_id text := current_setting('jlproject.phase4b5.branch_id');
  v_admin_id_text text := current_setting('jlproject.phase4b5.admin_user_id');
  v_viewer_id_text text := current_setting('jlproject.phase4b5.viewer_user_id');
  v_admin_id uuid;
  v_viewer_id uuid;
BEGIN
  IF current_user <> 'neondb_owner' THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Synthetic identity preflight must run as neondb_owner.';
  END IF;

  IF v_branch_id !~ '^br-[a-z0-9-]+$' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Invalid Phase 4B.5 child branch ID; expected a verified br- branch ID.';
  END IF;

  IF v_admin_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR v_viewer_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Invalid Neon Auth identity input; provide the UUIDs returned by the two branch-scoped Auth create responses.';
  END IF;

  v_admin_id := v_admin_id_text::uuid;
  v_viewer_id := v_viewer_id_text::uuid;

  IF v_admin_id = v_viewer_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'The synthetic admin and viewer must be distinct Neon Auth identities.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM neon_auth."user"
    WHERE id = v_admin_id
      AND email = 'jlproject-phase4b5-admin-' || v_branch_id || '@example.invalid'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'Synthetic admin identity is missing or does not match this child branch; no fixture workspace was written.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM neon_auth."user"
    WHERE id = v_viewer_id
      AND email = 'jlproject-phase4b5-viewer-' || v_branch_id || '@example.invalid'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'Synthetic viewer identity is missing or does not match this child branch; no fixture workspace was written.';
  END IF;
END;
$phase4b5_identity_preflight$;

SELECT current_setting('jlproject.phase4b5.admin_user_id')::uuid::text AS test_actor,
  current_setting('jlproject.phase4b5.viewer_user_id')::uuid::text AS test_viewer
\gset

COMMIT;

\set editor :test_actor
\set viewer :test_viewer
\echo Verified branch-scoped Neon Auth actors: admin :test_actor viewer :test_viewer
