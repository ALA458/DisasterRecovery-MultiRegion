import os
import sys
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "api"))

import main as api_module


@pytest.fixture
def api(monkeypatch, tmp_path):
    engine = create_engine(
        f"sqlite:///{tmp_path / 'api-validation.db'}",
        connect_args={"check_same_thread": False},
    )
    api_module.Base.metadata.create_all(bind=engine)
    session_local = sessionmaker(autocommit=False, autoflush=False, bind=engine)

    dynamodb = MagicMock()
    dynamodb.get_item.side_effect = lambda **kwargs: (
        {"Item": dynamodb._items[key]}
        if (key := kwargs["Key"]["user_id"]["S"]) in dynamodb._items
        else {}
    )
    dynamodb._items = {}

    def put_item(**kwargs):
        item = kwargs["Item"]
        dynamodb._items[item["user_id"]["S"]] = item
        return {}

    dynamodb.put_item.side_effect = put_item
    dynamodb.describe_table.return_value = {"Table": {"TableStatus": "ACTIVE"}}

    s3 = MagicMock()
    s3._objects = {}

    def put_object(**kwargs):
        s3._objects[kwargs["Key"]] = kwargs["Body"]
        return {"VersionId": "test-version"}

    s3.put_object.side_effect = put_object

    def head_object(**kwargs):
        key = kwargs["Key"]
        if key not in s3._objects:
            from botocore.exceptions import ClientError

            raise ClientError(
                {"Error": {"Code": "404", "Message": "Not Found"}},
                "HeadObject",
            )
        body = s3._objects[key]
        return {"ContentLength": len(body), "Metadata": {}, "VersionId": "test-version"}

    s3.head_object.side_effect = head_object
    s3.head_bucket.return_value = {}

    monkeypatch.setattr(api_module, "engine", engine)
    monkeypatch.setattr(api_module, "SessionLocal", session_local)
    monkeypatch.setattr(api_module, "dynamodb", dynamodb)
    monkeypatch.setattr(api_module, "s3", s3)

    with TestClient(api_module.app) as client:
        yield client, dynamodb, s3


def test_health_returns_healthy(api):
    client, _, _ = api

    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "healthy"
    assert body["region"] == api_module.AWS_REGION
    assert body["timestamp"]


def test_readiness_reports_all_dependencies_connected(api):
    client, _, _ = api

    response = client.get("/readiness")

    assert response.status_code == 200
    body = response.json()
    assert body["region"] == api_module.AWS_REGION
    assert body["rds_mysql"] == "connected"
    assert body["dynamodb"] == "connected"
    assert body["s3"] == "connected"


def test_readiness_reports_dependency_failures(api):
    client, dynamodb, s3 = api
    dynamodb.describe_table.side_effect = RuntimeError("DynamoDB unavailable")
    s3.head_bucket.side_effect = RuntimeError("S3 unavailable")

    response = client.get("/readiness")

    assert response.status_code == 200
    body = response.json()
    assert "DynamoDB unavailable" in body["dynamodb"]
    assert "S3 unavailable" in body["s3"]


@pytest.mark.parametrize(
    "payload",
    [
        {"user_id": "", "amount": 10, "description": "invalid user"},
        {"user_id": "user-1", "amount": 0, "description": "zero amount"},
        {"user_id": "user-1", "amount": -1, "description": "negative amount"},
        {"amount": 10, "description": "missing user"},
    ],
)
def test_transaction_rejects_invalid_payload(api, payload):
    client, _, _ = api

    response = client.post("/transaction", json=payload)

    assert response.status_code == 422


def test_transaction_create_and_latest(api):
    client, _, _ = api

    create_response = client.post(
        "/transaction",
        json={
            "user_id": "validation-user",
            "amount": 250.75,
            "description": "Validation transaction",
        },
    )

    assert create_response.status_code == 201
    created = create_response.json()
    assert created["transaction_id"]
    assert created["user_id"] == "validation-user"
    assert created["amount"] == 250.75

    latest_response = client.get("/transactions/latest?limit=10")

    assert latest_response.status_code == 200
    latest = latest_response.json()
    assert any(transaction["id"] == created["transaction_id"] for transaction in latest)


@pytest.mark.parametrize(
    "payload",
    [
        {"user_id": "", "item": "server", "quantity": 1},
        {"user_id": "user-1", "item": "", "quantity": 1},
        {"user_id": "user-1", "item": "server", "quantity": 0},
        {"user_id": "user-1", "item": "server", "quantity": -1},
    ],
)
def test_cart_rejects_invalid_payload(api, payload):
    client, _, _ = api

    response = client.post("/cart", json=payload)

    assert response.status_code == 422


def test_cart_create_read_and_missing_user(api):
    client, _, _ = api
    payload = {"user_id": "cart-user", "item": "server", "quantity": 3}

    create_response = client.post("/cart", json=payload)

    assert create_response.status_code == 200
    assert create_response.json()["region"] == api_module.AWS_REGION

    read_response = client.get("/cart/cart-user")

    assert read_response.status_code == 200
    assert read_response.json()["item"] == "server"
    assert read_response.json()["quantity"] == 3

    missing_response = client.get("/cart/unknown-user")
    assert missing_response.status_code == 404


def test_invoice_create_and_get(api):
    client, _, s3 = api

    create_response = client.post(
        "/invoice",
        json={
            "invoice_id": "INV-VALIDATION",
            "customer_name": "UTB Validation",
            "amount": 800,
        },
    )

    assert create_response.status_code == 201
    created = create_response.json()
    assert created["invoice_id"] == "INV-VALIDATION"
    assert created["s3_key"] == "invoices/INV-VALIDATION.txt"
    assert created["version_id"] == "test-version"
    assert "invoices/INV-VALIDATION.txt" in s3._objects

    get_response = client.get("/invoice/INV-VALIDATION")

    assert get_response.status_code == 200
    assert get_response.json()["invoice_id"] == "INV-VALIDATION"
    assert get_response.json()["content_length"] > 0


def test_invoice_returns_404_when_missing(api):
    client, _, _ = api

    response = client.get("/invoice/INV-MISSING")

    assert response.status_code == 404
