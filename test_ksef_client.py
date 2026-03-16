"""Testy klienta KSeF API z mockowanymi odpowiedziami HTTP."""
import datetime
import json
import logging
import pytest
from unittest.mock import patch, MagicMock, PropertyMock
from pathlib import Path

from ksef_client import KSeFClient, KSeFError, _invoice_subdir

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Valid NIP with correct checksum (weights: 6,5,7,2,3,4,5,6,7)
TEST_NIP = "5261040828"


def _mock_response(status_code=200, json_data=None, text="", content_type="application/json"):
    resp = MagicMock()
    resp.status_code = status_code
    resp.text = text or (json.dumps(json_data) if json_data else "")
    resp.headers = {"Content-Type": content_type}
    if json_data is not None:
        resp.json.return_value = json_data
    else:
        resp.json.side_effect = ValueError("No JSON")
    resp.content = resp.text.encode("utf-8")
    return resp


def _make_client() -> KSeFClient:
    """Create a test KSeFClient with environment='test'."""
    return KSeFClient(nip=TEST_NIP, environment="test")


# ---------------------------------------------------------------------------
# KSeFClient initialization
# ---------------------------------------------------------------------------

def test_init_valid_environment():
    """All supported environment names should initialise without error."""
    for env in ("prod", "test", "demo"):
        client = KSeFClient(nip=TEST_NIP, environment=env)
        assert client.environment == env


def test_init_invalid_environment():
    """Unsupported environment name should raise ValueError."""
    with pytest.raises(ValueError, match="Nieznane srodowisko"):
        KSeFClient(nip=TEST_NIP, environment="staging")


# ---------------------------------------------------------------------------
# _invoice_subdir — date resolution
# ---------------------------------------------------------------------------

def test_subdir_from_invoicing_date():
    """invoicingDate in metadata is the primary date source."""
    logger = logging.getLogger("test")
    meta = {"invoicingDate": "2026-03-15"}
    result = _invoice_subdir(TEST_NIP, meta, "irrelevant-ksef-nr", logger)
    assert result == f"{TEST_NIP}/2026/03"


def test_subdir_from_ksef_number():
    """When invoicingDate is absent, the date embedded in the KSeF number is used."""
    logger = logging.getLogger("test")
    meta = {}
    ksef_nr = f"{TEST_NIP}-20260315-ABCDEF"
    result = _invoice_subdir(TEST_NIP, meta, ksef_nr, logger)
    assert result == f"{TEST_NIP}/2026/03"


def test_subdir_fallback_today():
    """When no date source is available, today's date is used and a warning is logged."""
    logger = logging.getLogger("test")
    with patch.object(logger, "warning") as mock_warning:
        result = _invoice_subdir(TEST_NIP, {}, "no-date-here", logger)

    today = datetime.date.today()
    assert result == f"{TEST_NIP}/{today.year}/{today.month:02d}"
    mock_warning.assert_called_once()


def test_subdir_invalid_date():
    """An unparseable invoicingDate falls through to the KSeF number date source."""
    logger = logging.getLogger("test")
    meta = {"invoicingDate": "invalid"}
    ksef_nr = f"{TEST_NIP}-20260601-XYZ"
    result = _invoice_subdir(TEST_NIP, meta, ksef_nr, logger)
    assert result == f"{TEST_NIP}/2026/06"


# ---------------------------------------------------------------------------
# _request — HTTP error handling
# ---------------------------------------------------------------------------

def test_request_http_400_with_json_error():
    """HTTP 400 with a structured JSON exception should raise KSeFError with detail message."""
    client = _make_client()
    error_body = {
        "exception": {
            "exceptionDetailList": [
                {"exceptionDescription": "Nieprawidlowy token autoryzacji"}
            ]
        }
    }
    resp = _mock_response(status_code=400, json_data=error_body)
    client._session.get = MagicMock(return_value=resp)

    with pytest.raises(KSeFError) as exc_info:
        client._request("GET", "/some/endpoint")

    assert "Nieprawidlowy token autoryzacji" in str(exc_info.value)
    assert exc_info.value.status_code == 400


def test_request_http_500_raw():
    """HTTP 500 with a non-JSON body should raise KSeFError containing raw text."""
    client = _make_client()
    resp = _mock_response(status_code=500, text="Internal Server Error")
    client._session.get = MagicMock(return_value=resp)

    with pytest.raises(KSeFError) as exc_info:
        client._request("GET", "/some/endpoint")

    assert exc_info.value.status_code == 500


def test_request_connection_error():
    """A requests.RequestException should be wrapped in KSeFError."""
    import requests as req_lib

    client = _make_client()
    client._session.get = MagicMock(side_effect=req_lib.RequestException("connection refused"))

    with pytest.raises(KSeFError, match="Blad polaczenia"):
        client._request("GET", "/some/endpoint")


def test_request_success_json():
    """A 200 response with JSON body should be returned as a dict."""
    client = _make_client()
    payload = {"status": "ok", "count": 5}
    resp = _mock_response(status_code=200, json_data=payload)
    client._session.get = MagicMock(return_value=resp)

    result = client._request("GET", "/some/endpoint")

    assert result == payload


def test_request_success_empty():
    """A 200 response with empty body should return an empty dict."""
    client = _make_client()
    resp = _mock_response(status_code=200, text="")
    client._session.get = MagicMock(return_value=resp)

    result = client._request("GET", "/some/endpoint")

    assert result == {}
