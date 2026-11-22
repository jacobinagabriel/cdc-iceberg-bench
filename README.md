# cdc-iceberg-bench

Near-real-time CDC from PostgreSQL into Apache Iceberg on AWS, with several approaches
compared on latency, correctness and cost. The source is the RDS for PostgreSQL database
of [source-app](https://github.com/jacobinagabriel/source-app), which this repo reads
only through source-app's SSM contract (v4, `/source-app/prod/*`).

Every pipeline produces, per source table:

- **bronze**: every change (insert, update, delete), append-only;
- **silver**: the current state, an Iceberg table with time travel (`FOR TIMESTAMP AS OF`).

## Pipelines

| Pipeline | Path | Bronze | Silver |
|---|---|---|---|
| `dms_stream` | DMS → Kinesis → Firehose (+ Lambda) → Iceberg | Iceberg, with the row before each change | Iceberg, upserted by Firehose |
| `dms_batch` | DMS → Parquet in S3 → scheduled Glue job → Iceberg | the DMS Parquet files | Iceberg, `MERGE` by the job |

Both run as separate tasks on one DMS replication instance, each with its own
replication slot. Debezium and zero-ETL (to Redshift) come next; see
[docs/PLAN.md](docs/PLAN.md).

```
RDS PostgreSQL ── DMS task 1 ── Kinesis ──┬─ Firehose (bronze) ── dms_stream_bronze.*
 (source-app)   │                         └─ Firehose (silver) ── dms_stream_silver.*
                └ DMS task 2 ── S3 Parquet (dms_batch_bronze.*) ── Glue MERGE ── dms_batch_silver.*
```

## Running it

Prerequisites: main-terraform's bootstrap stack trusts this repo (its `cdc-iceberg-bench-`
role prefix, the DMS roles and Lambda in the boundary), and source-app is **up**.

1. **Actions → Deploy → up** (approve the `prod` environment). It applies the stack,
   creates the DMS user (`sql/db-setup.sql`), tests the DMS endpoints, starts both DMS
   tasks, waits for the full load, runs the merge job once and schedules it.
2. Query in Athena, workgroup `cdc-iceberg-bench`:
   ```sql
   SELECT status, count(*) FROM dms_stream_silver.orders GROUP BY 1;
   SELECT _op, count(*) FROM dms_stream_bronze.orders GROUP BY 1;
   SELECT "Op", count(*) FROM dms_batch_bronze.orders GROUP BY 1;
   SELECT count(*) FROM dms_batch_silver.orders FOR TIMESTAMP AS OF (current_timestamp - interval '10' minute);
   ```
   `make source-counts` prints the source's row counts to compare with.
3. **Actions → Deploy → down** before bringing source-app down (its down refuses while
   `/cdc-iceberg-bench/prod/*` exists). It stops the schedule and both tasks, drops the
   DMS replication slots and user (`sql/db-teardown.sql`), then destroys everything.

## Knobs

| Variable (`infra/envs/prod`) | Default | Effect |
|---|---|---|
| `dms_instance_class` | `dms.t3.medium` | Shared by both DMS tasks |
| `firehose_buffer_seconds` | 60 | dms_stream: time between Iceberg commits |
| `dms_s3_batch_seconds` | 60 | dms_batch: time between DMS CDC files |
| `batch_schedule` | every 15 min | dms_batch: when the merge job runs |

Rough cost while up (us-east-1), on top of source-app: DMS ≈ $0.08/h, Kinesis ≈ $0.015/h,
the Glue job every 15 minutes ≈ $0.10/h, Firehose, Lambda, S3 and Athena a few cents
per GB: about $0.20/h. Down: $0.

## Development

```bash
uv sync
make lint test      # the Spark tests of the merge job need Java (CI has it)
make tf-check       # terraform fmt + validate
```

`src/cdc_bench/transform.py` is the Firehose Lambda; `src/cdc_bench/batch_merge.py` is
the Glue job script. Terraform: `infra/envs/prod` and `infra/modules/*`. Every IAM role
carries main-terraform's `app-role-boundary` (checkov `CKV2_CUSTOM_1`).
