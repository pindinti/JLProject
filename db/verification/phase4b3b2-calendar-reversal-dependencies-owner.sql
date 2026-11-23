-- Add the two links after committed calendar history so the intended reversal cases are isolated.
\i db/verification/phase4b5-seed-safety-owner.sql
\set test_product 4b400000-0000-4000-8000-000000000001
\set test_edge_id 4b400000-0000-4000-8000-000000000201
\set test_endpoint_kind stage
\set test_predecessor_id 4b400000-0000-4000-8000-000000000001
\set test_successor_id 4b400000-0000-4000-8000-000000000002
\set test_operation_id 4b400000-0000-4000-8000-000000000301
\i db/verification/phase4b5-seed-one-dependency.sql

\set test_product 4b400000-0000-4000-8000-000000000002
\set test_edge_id 4b400000-0000-4000-8000-000000000202
\set test_endpoint_kind stage
\set test_predecessor_id 4b400000-0000-4000-8000-000000000011
\set test_successor_id 4b400000-0000-4000-8000-000000000012
\set test_operation_id 4b400000-0000-4000-8000-000000000302
\i db/verification/phase4b5-seed-one-dependency.sql

\i db/verification/phase4b5-seed-r00-postflight-owner.sql
