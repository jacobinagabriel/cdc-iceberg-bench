"""Firehose transform for the dms_stream pipeline (AWS Lambda, Python 3.12).

DMS writes one JSON message per row change to Kinesis:

    {"data": {...row...}, "before": {...old row...}, "metadata": {"operation": "update", ...}}

Two Firehose streams read the same Kinesis stream and call this function, each with its
own MODE:

- bronze: every change becomes a new row of the changelog table (Firehose operation
  "insert"), with the change's metadata in `_`-prefixed columns.
- silver: every change is applied to the current-state table by primary key (Firehose
  operation insert/update/delete).

Firehose routes each record with `metadata.otfMetadata` and writes the record's
top-level keys to the Iceberg columns of the same name, so this function flattens the
row and converts each value to the column's type (TABLE_SCHEMAS).
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

# DMS operation → bronze `_op` code and silver Firehose operation. "load" rows come
# from the full load, before any change.
OP_CODES = {"load": "L", "insert": "I", "update": "U", "delete": "D"}
SILVER_OPERATIONS = {"load": "insert", "insert": "insert", "update": "update", "delete": "delete"}


@dataclass(frozen=True)
class Config:
    mode: str  # "bronze" or "silver"
    database: str  # Glue database to route to
    source_schema: str  # PostgreSQL schema whose tables are replicated
    tables: dict[str, dict[str, str]]  # table → column → Iceberg/Glue type

    @classmethod
    def from_env(cls) -> Config:
        mode = os.environ["MODE"]
        if mode not in ("bronze", "silver"):
            raise ValueError(f"MODE must be bronze or silver, not {mode!r}")
        return cls(
            mode=mode,
            database=os.environ["DATABASE"],
            source_schema=os.environ["SOURCE_SCHEMA"],
            tables=json.loads(os.environ["TABLE_SCHEMAS"]),
        )


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    config = Config.from_env()
    now = dt.datetime.now(dt.UTC)
    return {"records": [transform_record(r, config, now) for r in event["records"]]}


def transform_record(record: dict[str, Any], config: Config, now: dt.datetime) -> dict[str, Any]:
    """One Firehose record in, one out: Ok (routed), Dropped or ProcessingFailed."""
    try:
        message = json.loads(base64.b64decode(record["data"]))
        metadata = message.get("metadata", {})
        table = metadata.get("table-name")
        operation = metadata.get("operation")

        # Control records (table created, column added, ...) and tables outside the
        # benchmark (such as DMS's own) aren't rows of any target table.
        if (
            metadata.get("record-type") != "data"
            or metadata.get("schema-name") != config.source_schema
            or table not in config.tables
        ):
            return {"recordId": record["recordId"], "result": "Dropped", "data": record["data"]}
        if operation not in OP_CODES:
            raise ValueError(f"unknown DMS operation {operation!r}")

        columns = config.tables[table]
        data = message.get("data") or {}
        row = {name: convert(data.get(name), type_) for name, type_ in columns.items()}

        if config.mode == "bronze":
            before = message.get("before")
            row |= {
                "_op": OP_CODES[operation],
                "_commit_ts": convert(metadata.get("commit-timestamp"), "timestamp"),
                "_dms_ts": convert(metadata.get("timestamp"), "timestamp"),
                "_txid": convert(metadata.get("transaction-id"), "string"),
                "_before": json.dumps(before, sort_keys=True) if before else None,
                "_transform_ts": format_timestamp(now),
            }
            firehose_operation = "insert"
        else:
            firehose_operation = SILVER_OPERATIONS[operation]

        return {
            "recordId": record["recordId"],
            "result": "Ok",
            "data": base64.b64encode(json.dumps(row).encode()).decode(),
            "metadata": {
                "otfMetadata": {
                    "destinationDatabaseName": config.database,
                    "destinationTableName": table,
                    "operation": firehose_operation,
                }
            },
        }
    except (ValueError, TypeError, KeyError, ArithmeticError) as exc:
        print(f"record {record.get('recordId')} failed: {exc!r}")
        return {
            "recordId": record["recordId"],
            "result": "ProcessingFailed",
            "data": record["data"],
        }


def convert(value: Any, type_: str) -> Any:
    """A DMS JSON value as the JSON Firehose expects for an Iceberg column of `type_`."""
    if value is None:
        return None
    if type_ == "string":
        return value if isinstance(value, str) else json.dumps(value)
    if type_ in ("int", "bigint"):
        return int(value)
    if type_ == "double":
        return float(value)
    if type_.startswith("decimal"):
        # numeric(12,2) fits in a double exactly enough to print back as the same digits.
        return float(Decimal(str(value)))
    if type_ == "timestamp":
        return format_timestamp(parse_timestamp(value))
    raise ValueError(f"unsupported column type {type_!r}")


def parse_timestamp(value: Any) -> dt.datetime:
    """DMS timestamps arrive as ISO-like strings, with or without a UTC offset."""
    if not isinstance(value, str):
        raise TypeError(f"expected a timestamp string, got {value!r}")
    text = value.strip().replace(" ", "T", 1)
    # PostgreSQL prints a whole-hour offset as "+00"; fromisoformat wants "+00:00".
    if len(text) > 3 and text[-3] in "+-" and text[-2:].isdigit():
        text += ":00"
    parsed = dt.datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=dt.UTC)
    return parsed.astimezone(dt.UTC)


def format_timestamp(value: dt.datetime) -> str:
    """UTC, microseconds, no offset: the layout Firehose parses into an Iceberg timestamp."""
    return value.astimezone(dt.UTC).strftime("%Y-%m-%d %H:%M:%S.%f")
