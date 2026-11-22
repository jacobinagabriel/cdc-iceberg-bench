"""Glue job of the dms_batch pipeline: DMS Parquet files (bronze) → Iceberg (silver).

DMS writes each source table's changes to s3://<lake>/dms-landing/<schema>/<table>/:
LOAD*.parquet files from the full load, then one timestamp-named file per CDC batch.
Every row has an `Op` column (I/U/D) and `_dms_ts`.

Each run reads, per table, only the files it hasn't processed yet (a Spark file stream
with an S3 checkpoint, run as one batch with `availableNow`), keeps the latest change per
primary key and MERGEs it into the silver Iceberg table: deletes remove the row, inserts
and updates upsert it.

The pure functions at the top are unit tested with a local Spark; `main()` runs only
on Glue (Glue 5.0, Spark 3.5, Python 3.11).
"""

from __future__ import annotations

import sys

from pyspark.sql import DataFrame, SparkSession, Window
from pyspark.sql import functions as F

KEY = "id"
CATALOG = "glue_catalog"


def with_order_columns(df: DataFrame) -> DataFrame:
    """Adds what orders a table's changes: the source file and the row's place in it."""
    return df.withColumn("_file", F.input_file_name()).withColumn(
        "_pos", F.monotonically_increasing_id()
    )


def latest_changes(df: DataFrame) -> DataFrame:
    """The last change per primary key.

    Full-load rows come first: DMS applies changes made during the full load after it,
    with commit timestamps that can be older than the load's own. After that, changes
    are ordered by `_dms_ts`, then by file (CDC files are named by time), then by
    position in the file, since one transaction's changes share a timestamp.
    """
    is_cdc = ~F.element_at(F.split("_file", "/"), -1).startswith("LOAD")
    order = Window.partitionBy(KEY).orderBy(
        is_cdc.desc(),
        F.to_timestamp("_dms_ts").desc(),
        F.col("_file").desc(),
        F.col("_pos").desc(),
    )
    return (
        df.withColumn("_rank", F.row_number().over(order)).where(F.col("_rank") == 1).drop("_rank")
    )


def merge_statement(target: str, source: str, columns: list[str]) -> str:
    """MERGE of the latest changes (`source`, with an `Op` column) into `target`."""
    set_clause = ", ".join(f"t.`{c}` = s.`{c}`" for c in columns if c != KEY)
    names = ", ".join(f"`{c}`" for c in columns)
    values = ", ".join(f"s.`{c}`" for c in columns)
    return (
        f"MERGE INTO {target} t USING {source} s ON t.`{KEY}` = s.`{KEY}` "
        "WHEN MATCHED AND s.Op = 'D' THEN DELETE "
        f"WHEN MATCHED THEN UPDATE SET {set_clause} "
        f"WHEN NOT MATCHED AND s.Op <> 'D' THEN INSERT ({names}) VALUES ({values})"
    )


def apply_batch(batch: DataFrame, target: str) -> None:
    """Casts the batch to the target's schema and merges its latest changes."""
    if batch.isEmpty():
        return
    # A micro-batch has its own session; its temp views live there.
    spark = batch.sparkSession
    schema = spark.table(target).schema
    latest = latest_changes(batch).select(
        "Op", *[F.col(f.name).cast(f.dataType).alias(f.name) for f in schema.fields]
    )
    latest.createOrReplaceTempView("changes")
    spark.sql(merge_statement(target, "changes", schema.fieldNames()))


def merge_table(spark: SparkSession, args: dict[str, str], table: str) -> None:
    source = f"{args['landing_path']}/{args['source_schema']}/{table}/"
    target = f"{CATALOG}.{args['silver_database']}.{table}"
    try:
        schema = spark.read.parquet(source).schema
    except Exception as exc:  # no files yet: DMS creates the folder with the first one
        print(f"{table}: nothing to read yet ({exc.__class__.__name__})")
        return

    stream = with_order_columns(spark.readStream.schema(schema).parquet(source))
    query = (
        stream.writeStream.foreachBatch(lambda batch, _: apply_batch(batch, target))
        .option("checkpointLocation", f"{args['checkpoint_path']}/{table}")
        .trigger(availableNow=True)
        .start()
    )
    query.awaitTermination()
    print(f"{table}: merged into {target}")


def main() -> None:
    from awsglue.context import GlueContext
    from awsglue.job import Job
    from awsglue.utils import getResolvedOptions
    from pyspark import SparkConf
    from pyspark.context import SparkContext

    args = getResolvedOptions(
        sys.argv,
        [
            "JOB_NAME",
            "landing_path",
            "checkpoint_path",
            "warehouse_path",
            "source_schema",
            "silver_database",
            "tables",
        ],
    )
    conf = SparkConf().setAll(
        [
            (
                "spark.sql.extensions",
                "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
            ),
            (f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog"),
            (
                f"spark.sql.catalog.{CATALOG}.catalog-impl",
                "org.apache.iceberg.aws.glue.GlueCatalog",
            ),
            (f"spark.sql.catalog.{CATALOG}.io-impl", "org.apache.iceberg.aws.s3.S3FileIO"),
            (f"spark.sql.catalog.{CATALOG}.warehouse", args["warehouse_path"]),
        ]
    )
    glue_context = GlueContext(SparkContext.getOrCreate(conf))
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)
    for table in args["tables"].split(","):
        merge_table(glue_context.spark_session, args, table)
    job.commit()


if __name__ == "__main__":
    main()
