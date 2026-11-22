import base64
import datetime as dt
import json

import pytest

from cdc_bench import transform

TABLES = {
    "orders": {
        "id": "string",
        "num_of_items": "int",
        "created_at": "timestamp",
        "shipped_at": "timestamp",
    },
    "products": {"id": "bigint", "cost": "decimal(12,2)", "latitude": "double"},
}
NOW = dt.datetime(2026, 11, 22, 12, 0, tzinfo=dt.UTC)


def config(mode):
    return transform.Config(
        mode=mode, database=f"dms_stream_{mode}", source_schema="demo", tables=TABLES
    )


def record(message, record_id="r1"):
    return {"recordId": record_id, "data": base64.b64encode(json.dumps(message).encode()).decode()}


def dms_message(operation, data, table="orders", before=None, **metadata):
    message = {
        "data": data,
        "metadata": {
            "timestamp": "2026-11-22T11:59:58.123456Z",
            "record-type": "data",
            "operation": operation,
            "schema-name": "demo",
            "table-name": table,
            "transaction-id": 4242,
            "commit-timestamp": "2026-11-22T11:59:57.5Z",
            **metadata,
        },
    }
    if before is not None:
        message["before"] = before
    return message


ORDER = {
    "id": "6f1c2a4e-0000-4000-8000-000000000001",
    "num_of_items": 2,
    "created_at": "2026-11-22 11:59:57.5+00",
    "shipped_at": None,
}


def decode(out):
    return json.loads(base64.b64decode(out["data"]))


@pytest.mark.parametrize(
    ("operation", "expected"),
    [("load", "insert"), ("insert", "insert"), ("update", "update"), ("delete", "delete")],
)
def test_silver_routes_by_table_with_the_dms_operation(operation, expected):
    out = transform.transform_record(record(dms_message(operation, ORDER)), config("silver"), NOW)

    assert out["result"] == "Ok"
    assert out["metadata"]["otfMetadata"] == {
        "destinationDatabaseName": "dms_stream_silver",
        "destinationTableName": "orders",
        "operation": expected,
    }
    assert decode(out) == {
        "id": ORDER["id"],
        "num_of_items": 2,
        "created_at": "2026-11-22 11:59:57.500000",
        "shipped_at": None,
    }


def test_bronze_appends_every_change_with_its_metadata():
    before = {**ORDER, "num_of_items": 1}
    message = dms_message("update", ORDER, before=before)

    out = transform.transform_record(record(message), config("bronze"), NOW)

    assert out["result"] == "Ok"
    assert out["metadata"]["otfMetadata"]["operation"] == "insert"
    row = decode(out)
    assert row["num_of_items"] == 2
    assert row["_op"] == "U"
    assert row["_commit_ts"] == "2026-11-22 11:59:57.500000"
    assert row["_dms_ts"] == "2026-11-22 11:59:58.123456"
    assert row["_txid"] == "4242"
    assert json.loads(row["_before"])["num_of_items"] == 1
    assert row["_transform_ts"] == "2026-11-22 12:00:00.000000"


def test_bronze_marks_full_load_rows_and_has_no_before_image_for_inserts():
    out = transform.transform_record(record(dms_message("load", ORDER)), config("bronze"), NOW)

    row = decode(out)
    assert row["_op"] == "L"
    assert row["_before"] is None


def test_values_take_the_column_types():
    data = {"id": "7", "cost": "12.30", "latitude": "-23.5"}

    out = transform.transform_record(
        record(dms_message("insert", data, table="products")), config("silver"), NOW
    )

    assert decode(out) == {"id": 7, "cost": 12.3, "latitude": -23.5}


def test_columns_missing_from_the_message_are_null():
    out = transform.transform_record(
        record(dms_message("delete", {"id": ORDER["id"]})), config("silver"), NOW
    )

    assert decode(out)["num_of_items"] is None


@pytest.mark.parametrize(
    "message",
    [
        dms_message("create-table", {}, **{"record-type": "control"}),
        dms_message("insert", ORDER, table="awsdms_heartbeat"),
        dms_message("insert", ORDER, **{"schema-name": "cdc_bench"}),
    ],
)
def test_control_records_and_other_tables_are_dropped(message):
    out = transform.transform_record(record(message), config("silver"), NOW)

    assert out["result"] == "Dropped"


def test_bad_records_fail_without_failing_the_batch():
    bad = {"recordId": "r2", "data": base64.b64encode(b"not json").decode()}
    unknown_op = record(dms_message("truncate", ORDER), record_id="r3")

    outs = [transform.transform_record(r, config("silver"), NOW) for r in (bad, unknown_op)]

    assert [o["result"] for o in outs] == ["ProcessingFailed", "ProcessingFailed"]
    assert outs[0]["data"] == bad["data"]


@pytest.mark.parametrize(
    "value",
    [
        "2026-11-22 09:59:57.5-02",
        "2026-11-22T11:59:57.500000Z",
        "2026-11-22T11:59:57.5+00:00",
        "2026-11-22 11:59:57.5",
    ],
)
def test_timestamps_are_utc_with_microseconds(value):
    assert transform.convert(value, "timestamp") == "2026-11-22 11:59:57.500000"


def test_handler_reads_its_config_from_the_environment(monkeypatch):
    monkeypatch.setenv("MODE", "silver")
    monkeypatch.setenv("DATABASE", "dms_stream_silver")
    monkeypatch.setenv("SOURCE_SCHEMA", "demo")
    monkeypatch.setenv("TABLE_SCHEMAS", json.dumps(TABLES))

    result = transform.handler({"records": [record(dms_message("insert", ORDER))]})

    assert [r["result"] for r in result["records"]] == ["Ok"]


def test_handler_rejects_an_unknown_mode(monkeypatch):
    monkeypatch.setenv("MODE", "gold")
    with pytest.raises(ValueError):
        transform.Config.from_env()
