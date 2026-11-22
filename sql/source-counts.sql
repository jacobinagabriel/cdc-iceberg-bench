-- Row counts of the source tables, to compare with the silver tables in Athena.
--
-- psql variables: db_schema.

SELECT format(
  'SELECT %L AS table_name, count(*) AS row_count FROM %I.%I',
  table_name, table_schema, table_name
)
FROM information_schema.tables
WHERE table_schema = :'db_schema' AND table_type = 'BASE TABLE'
ORDER BY table_name \gexec
