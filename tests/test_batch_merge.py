import os
import shutil

import pytest

pyspark = pytest.importorskip("pyspark")

from cdc_bench import batch_merge  # noqa: E402

# CI sets REQUIRE_SPARK_TESTS so a missing Java fails instead of skipping.
if shutil.which("java") is None and not os.environ.get("REQUIRE_SPARK_TESTS"):
    pytest.skip("Spark tests need Java", allow_module_level=True)


@pytest.fixture(scope="module")
def spark():
    from pyspark.sql import SparkSession

    session = (
        SparkSession.builder.master("local[1]")
        .appName("batch-merge-tests")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.shuffle.partitions", "1")
        .getOrCreate()
    )
    yield session
    session.stop()


LANDING = "s3://lake/dms-landing/demo/orders/"
COLUMNS = ["id", "status", "Op", "_dms_ts", "_file", "_pos"]


def latest(spark, rows):
    df = spark.createDataFrame(rows, COLUMNS)
    return {r["id"]: (r["status"], r["Op"]) for r in batch_merge.latest_changes(df).collect()}


def test_the_last_change_per_key_wins(spark):
    rows = [
        (
            "a",
            "created",
            "I",
            "2026-11-22 10:00:00.000000",
            LANDING + "20261122-100000000.parquet",
            0,
        ),
        (
            "a",
            "shipped",
            "U",
            "2026-11-22 10:05:00.000000",
            LANDING + "20261122-100500000.parquet",
            1,
        ),
        (
            "b",
            "created",
            "I",
            "2026-11-22 10:00:00.000000",
            LANDING + "20261122-100000000.parquet",
            2,
        ),
        (
            "b",
            "created",
            "D",
            "2026-11-22 10:06:00.000000",
            LANDING + "20261122-100600000.parquet",
            3,
        ),
    ]

    assert latest(spark, rows) == {"a": ("shipped", "U"), "b": ("created", "D")}


def test_changes_in_one_transaction_keep_their_order_in_the_file(spark):
    ts = "2026-11-22 10:00:00.000000"
    file = LANDING + "20261122-100000000.parquet"
    rows = [
        ("a", "created", "I", ts, file, 10),
        ("a", "paid", "U", ts, file, 11),
        ("a", "shipped", "U", ts, file, 12),
    ]

    assert latest(spark, rows) == {"a": ("shipped", "U")}


def test_changes_made_during_the_full_load_win_over_the_load(spark):
    # Committed while the full load ran, so its timestamp is older than the load row's.
    rows = [
        ("a", "created", "I", "2026-11-22 10:00:05.000000", LANDING + "LOAD00000001.parquet", 0),
        ("a", "paid", "U", "2026-11-22 10:00:01.000000", LANDING + "20261122-100010000.parquet", 1),
    ]

    assert latest(spark, rows) == {"a": ("paid", "U")}


def test_insert_after_delete_brings_the_row_back(spark):
    rows = [
        (
            "a",
            "created",
            "D",
            "2026-11-22 10:00:00.000000",
            LANDING + "20261122-100000000.parquet",
            0,
        ),
        (
            "a",
            "created",
            "I",
            "2026-11-22 10:01:00.000000",
            LANDING + "20261122-100100000.parquet",
            1,
        ),
    ]

    assert latest(spark, rows) == {"a": ("created", "I")}


def test_merge_statement():
    sql = batch_merge.merge_statement("glue_catalog.s.orders", "changes", ["id", "status"])

    assert sql == (
        "MERGE INTO glue_catalog.s.orders t USING changes s ON t.`id` = s.`id` "
        "WHEN MATCHED AND s.Op = 'D' THEN DELETE "
        "WHEN MATCHED THEN UPDATE SET t.`status` = s.`status` "
        "WHEN NOT MATCHED AND s.Op <> 'D' THEN INSERT (`id`, `status`) VALUES (s.`id`, s.`status`)"
    )
