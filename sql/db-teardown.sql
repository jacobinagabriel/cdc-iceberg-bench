-- Removes what db-setup and the DMS tasks left in the source database. Run by the ops
-- task as the RDS master user on `down`, after both DMS tasks have stopped. Safe to
-- run again: every step checks first.
--
-- psql variables: dms_user, app_user, db_schema, db_name.

-- A replication slot nobody reads keeps WAL until the RDS disk is full. DMS's slots
-- use the test_decoding plugin (Debezium's will use pgoutput and its own teardown).
-- An active slot means a task is still running: fail instead.
DO $$
BEGIN
  IF EXISTS (
    SELECT FROM pg_replication_slots
    WHERE plugin = 'test_decoding' AND database = current_database() AND active
  ) THEN
    RAISE EXCEPTION 'A DMS replication slot is still active: stop the DMS tasks first';
  END IF;
END
$$;

SELECT slot_name, pg_drop_replication_slot(slot_name) IS NULL AS dropped
FROM pg_replication_slots
WHERE plugin = 'test_decoding' AND database = current_database();

-- Everything below only applies while the DMS user exists.
SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = :'dms_user') AS dms_user_exists \gset
\if :dms_user_exists

-- Its schema (DMS's heartbeat table), dropped as its owner.
SELECT format('GRANT %I TO CURRENT_USER WITH INHERIT FALSE, SET TRUE', :'dms_user') \gexec
SET ROLE :"dms_user";
DROP SCHEMA IF EXISTS cdc_bench CASCADE;
RESET ROLE;
SELECT format('REVOKE %I FROM CURRENT_USER', :'dms_user') \gexec

-- The grants on the source tables, revoked by their owner like db-setup made them.
SELECT format('GRANT %I TO CURRENT_USER WITH INHERIT FALSE, SET TRUE', :'app_user') \gexec
SET ROLE :"app_user";
REVOKE SELECT ON ALL TABLES IN SCHEMA :"db_schema" FROM :"dms_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"db_schema" REVOKE SELECT ON TABLES FROM :"dms_user";
RESET ROLE;
SELECT format('REVOKE %I FROM CURRENT_USER', :'app_user') \gexec

REVOKE USAGE ON SCHEMA :"db_schema" FROM :"dms_user";
REVOKE CONNECT ON DATABASE :"db_name" FROM :"dms_user";
REVOKE rds_replication FROM :"dms_user";
DROP ROLE :"dms_user";

\endif

SELECT count(*) AS dms_slots_left
FROM pg_replication_slots
WHERE plugin = 'test_decoding' AND database = current_database();
