-- Prepares the source database for the DMS pipelines. Run by the ops task as the RDS
-- master user, on every `up`, so it must be idempotent.
--
-- psql variables: dms_user, dms_password, app_user (owner of the source tables),
-- db_schema, db_name.

-- The DMS user: replication (rds_replication) and read-only access to the source
-- schema. Its password comes from the secret DMS reads, so it is set on every run.
SELECT format('CREATE ROLE %I LOGIN', :'dms_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'dms_user') \gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'dms_user', :'dms_password') \gexec

GRANT rds_replication TO :"dms_user";
GRANT CONNECT ON DATABASE :"db_name" TO :"dms_user";
GRANT USAGE ON SCHEMA :"db_schema" TO :"dms_user";

-- The source tables belong to the app user, so only it can grant on them (the RDS
-- master user isn't a true superuser). The master user created that role, so it holds
-- the ADMIN option and can let itself SET ROLE to it for these grants, then drop
-- that membership again.
SELECT format('GRANT %I TO CURRENT_USER WITH INHERIT FALSE, SET TRUE', :'app_user') \gexec
SET ROLE :"app_user";
GRANT SELECT ON ALL TABLES IN SCHEMA :"db_schema" TO :"dms_user";
-- Tables added by later migrations are readable too.
ALTER DEFAULT PRIVILEGES IN SCHEMA :"db_schema" GRANT SELECT ON TABLES TO :"dms_user";
RESET ROLE;
SELECT format('REVOKE %I FROM CURRENT_USER', :'app_user') \gexec

-- DMS's own objects (its WAL heartbeat table) live apart from the source schema, in
-- a schema it owns (creating a schema for another role needs SET on that role).
SELECT format('GRANT %I TO CURRENT_USER WITH INHERIT FALSE, SET TRUE', :'dms_user') \gexec
CREATE SCHEMA IF NOT EXISTS cdc_bench AUTHORIZATION :"dms_user";
SELECT format('REVOKE %I FROM CURRENT_USER', :'dms_user') \gexec

SELECT rolname, rolcanlogin, pg_has_role(rolname, 'rds_replication', 'MEMBER') AS replication
FROM pg_roles
WHERE rolname = :'dms_user';
