from unittest.mock import Mock

import pytest
from botocore.exceptions import ClientError
from fastapi.testclient import TestClient
from sqlalchemy.exc import SQLAlchemyError

from api import main


@pytest.fixture
def client():
    # Avoid the startup hook because these tests do not need a real MySQL server.
    return TestClient(main.app)


def aws_error(operation, code, message="service error"):
    return ClientError(
        {"Error": {"Code": code, "Message": message}},
        operation,
    )


def test_health_returns_healthy_status_and_region(client):
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "healthy"
    assert response.json()["region"] == main.AWS_REGION


def test_transaction_rejects_non_positive_amount_without_opening_session(
    client, monkeypatch
):
    session_factory = Mock()
    monkeypatch.setattr(main, "SessionLocal", session_factory)

    response = client.post(
        "/transaction",
        json={"user_id": "test-user", "amount": 0},
    )

    assert response.status_code == 422
    session_factory.assert_not_called()


def test_transaction_returns_created_record_and_closes_session(client, monkeypatch):
    db = Mock()

    def refresh(transaction):
        transaction.id = "tx-test-123"

    db.refresh.side_effect = refresh
    monkeypatch.setattr(main, "SessionLocal", lambda: db)

    response = client.post(
        "/transaction",
        json={
            "user_id": "test-user",
            "amount": 25.5,
            "description": "test purchase",
        },
    )

    assert response.status_code == 201
    assert response.json()["transaction_id"] == "tx-test-123"
    assert response.json()["user_id"] == "test-user"
    assert response.json()["amount"] == 25.5
    db.commit.assert_called_once()
    db.close.assert_called_once()


def test_transaction_rolls_back_when_database_commit_fails(client, monkeypatch):
    db = Mock()
    db.commit.side_effect = SQLAlchemyError("write failed")
    monkeypatch.setattr(main, "SessionLocal", lambda: db)

    response = client.post(
        "/transaction",
        json={"user_id": "test-user", "amount": 25.5},
    )

    assert response.status_code == 500
    assert "Fallo al registrar en RDS" in response.json()["detail"]
    db.rollback.assert_called_once()
    db.close.assert_called_once()


def test_cart_write_sends_expected_item_to_dynamodb(client, monkeypatch):
    dynamodb = Mock()
    monkeypatch.setattr(main, "dynamodb", dynamodb)

    response = client.post(
        "/cart",
        json={"user_id": "test-user", "item": "SKU-1", "quantity": 3},
    )

    assert response.status_code == 200
    assert response.json()["quantity"] == 3
    dynamodb.put_item.assert_called_once()
    call = dynamodb.put_item.call_args.kwargs
    assert call["TableName"] == main.DYNAMO_TABLE
    assert call["Item"]["user_id"] == {"S": "test-user"}
    assert call["Item"]["item"] == {"S": "SKU-1"}
    assert call["Item"]["quantity"] == {"N": "3"}


def test_cart_returns_404_when_user_has_no_cart(client, monkeypatch):
    dynamodb = Mock()
    dynamodb.get_item.return_value = {}
    monkeypatch.setattr(main, "dynamodb", dynamodb)

    response = client.get("/cart/missing-user")

    assert response.status_code == 404
    assert response.json()["detail"] == "Carrito no encontrado"


def test_invoice_upload_returns_storage_key(client, monkeypatch):
    s3 = Mock()
    s3.put_object.return_value = {"VersionId": "version-1"}
    monkeypatch.setattr(main, "s3", s3)

    response = client.post(
        "/invoice",
        json={
            "invoice_id": "INV-TEST-1",
            "customer_name": "Test Customer",
            "amount": 80,
        },
    )

    assert response.status_code == 201
    assert response.json()["invoice_id"] == "INV-TEST-1"
    assert response.json()["s3_key"] == "invoices/INV-TEST-1.txt"
    assert response.json()["version_id"] == "version-1"
    s3.put_object.assert_called_once()
    call = s3.put_object.call_args.kwargs
    assert call["Bucket"] == main.S3_BUCKET
    assert call["Key"] == "invoices/INV-TEST-1.txt"
    assert b"Test Customer" in call["Body"]


def test_invoice_returns_404_when_s3_object_is_missing(client, monkeypatch):
    s3 = Mock()
    s3.head_object.side_effect = aws_error("HeadObject", "404")
    monkeypatch.setattr(main, "s3", s3)

    response = client.get("/invoice/INV-MISSING")

    assert response.status_code == 404
    assert response.json()["detail"] == "Factura no encontrada"
