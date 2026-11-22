# Plan: cdc-iceberg-bench

The benchmark half of the project. The source system is
[source-app](https://github.com/jacobinagabriel/source-app) (its `docs/PLAN.md` has the
shared decisions and the contract).

## Shared decisions

| Decision | Choice |
|---|---|
| Source | source-app's **RDS for PostgreSQL 17**, through **contract v4** (`/source-app/prod/*` in SSM). The plan fails if the contract version or engine differs |
| What's compared | CDC into **Iceberg**: every change (bronze) and the current state with time travel (silver) |
| Zero-ETL | RDS for PostgreSQL zero-ETL only targets Redshift, not Iceberg, so at most an extra, non-Iceberg data point (Redshift history mode) |
| Lake | One general-purpose S3 bucket + the Glue Data Catalog (IAM access, no Lake Formation), Athena workgroup `cdc-iceberg-bench` |
| Network | DMS and ECS tasks in the public subnets with public IPs and no inbound rules (no NAT or endpoints, like source-app) |
| IaC / CI/CD | Terraform ≥ 1.11, state `cdc-iceberg-bench/prod/terraform.tfstate`; OIDC roles from main-terraform; deploy up/down in the `prod` environment with your approval |
| IAM | Roles named `cdc-iceberg-bench-*`, all with `app-role-boundary`. DMS's fixed-name roles live in main-terraform |
| Source hygiene | The bench only adds to the source database (a DMS user, schema `cdc_bench`, replication slots) and removes all of it on down. On RDS, a slot nobody reads fills the disk |

## PRs

1. **DMS, two ways, end to end** (this PR): one replication instance, two tasks.
   - `dms_stream`: DMS → Kinesis (partitioned by primary key) → two Firehose streams with a
     transform Lambda → Iceberg bronze (append, with before-images) and silver
     (upsert/delete by `id`).
   - `dms_batch`: DMS → Parquet in S3 (bronze) → Glue 5.0 job every 15 minutes, which
     reads only new files (Spark file stream with a checkpoint, `availableNow`) and
     `MERGE`s the latest change per key into Iceberg silver.
   - db-setup/db-teardown as one-off psql tasks; deploy workflow up/down.
2. **Harness and load generator**: a heartbeat table and latency measurement per
   pipeline (p50/p95/p99), correctness checks (source vs silver, gaps and duplicates in
   bronze, time travel vs history rebuilt from bronze), controlled load profiles.
3. **Debezium** (Kafka Connect on ECS → MSK Serverless → Iceberg sink), with its own
   `pgoutput` slot.
4. **Optional: zero-ETL → Redshift Serverless with history mode**.
5. **Table maintenance**: compaction, snapshot expiry, orphan files, and their cost.
6. **Experiments**: each pipeline alone and together, bursts, slot backlog, restarts.
7. **Cost model and report**.

## Known differences between the two DMS pipelines

- Before-images: DMS only writes them to streaming targets, so `dms_batch` bronze has the
  new row only.
- Latency: `dms_stream` ≈ Firehose buffer; `dms_batch` ≈ DMS CDC file interval + merge
  schedule + job run time.
- Ordering: `dms_stream` keeps each row's changes in order through one Kinesis shard per
  key; `dms_batch` orders by DMS timestamp, then file, then position in the file, with
  full-load rows first.

## To check on the first deploy

- The JSON layout DMS writes to Kinesis (where `before` and the transaction metadata sit),
  and the timestamp format Firehose accepts: failures land in `firehose-errors/`.
- The `_dms_ts` type in the DMS Parquet files (declared `string` in the bronze table).
- Whether DMS accepts the non-superuser `cdc_dms` (with `rds_replication`) for CDC.
- Whether `dms.t3.medium` and source-app's `db.t4g.micro` keep up with two slots.
