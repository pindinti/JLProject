-- Create the isolated clone fixture workspaces and memberships before direct Worker seeding.
-- Run once as neondb_owner on a verified disposable child.
\i db/verification/phase4b5-seed-safety-owner.sql
\i db/verification/phase4b5-seed-auth-identities-owner.sql

SELECT md5('jlproject.phase4b3c4.clone.workspace')::uuid AS workspace,
  md5('jlproject.phase4b3c4.clone.other_workspace')::uuid AS other_workspace,
  :'test_actor'::text AS editor,
  :'test_viewer'::text AS viewer
\gset

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.phase4b3c4_seed_workspaces', jsonb_build_object(
  'workspace', :'workspace', 'otherWorkspace', :'other_workspace')::text, true);
DO $no_duplicate$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_seed_workspaces')::jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM public.workspaces
       WHERE id IN ((v_scope->>'workspace')::uuid, (v_scope->>'otherWorkspace')::uuid)
          OR name IN ('Synthetic Phase 4B.3c.4 clone source workspace',
            'Synthetic Phase 4B.3c.4 clone other workspace')) THEN
    RAISE EXCEPTION 'Phase 4B.3c.4 clone setup was already applied to this child.';
  END IF;
END;
$no_duplicate$;
INSERT INTO public.workspaces (id, name)
VALUES (:'workspace', 'Synthetic Phase 4B.3c.4 clone source workspace'),
  (:'other_workspace', 'Synthetic Phase 4B.3c.4 clone other workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'workspace', :'editor', 'admin', true),
  (:'workspace', :'viewer', 'viewer', true),
  (:'other_workspace', :'editor', 'editor', true);
COMMIT;

\set test_workspace :workspace
\set test_actor :editor
\set test_viewer :viewer
\set test_other_workspace :other_workspace
\i db/verification/phase4b5-seed-r00-postflight-owner.sql
SELECT row_count::text AS historical_r00_count, fingerprint AS historical_r00_fingerprint
FROM pg_temp.phase4b5_seed_r00_baseline \gset
\echo Clone seed Worker variables: test_workspace=:test_workspace test_actor=:test_actor test_viewer=:test_viewer test_other_workspace=:test_other_workspace
\echo Historical R00 baseline: historical_r00_count=:historical_r00_count historical_r00_fingerprint=:historical_r00_fingerprint
