"""Testy generatora PDF z faktur KSeF XML."""
import pytest
from pathlib import Path

from ksef_pdf import parse_ksef_xml, generate_invoice_pdf, _parse_header, _parse_invoice_details


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def test_xml_path():
    return Path(__file__).parent / "test_faktura.xml"


@pytest.fixture
def parsed_data(test_xml_path):
    return parse_ksef_xml(test_xml_path)


# ---------------------------------------------------------------------------
# XML parsing — basic structure
# ---------------------------------------------------------------------------

def test_parse_basic_structure(parsed_data):
    """Parsed dict must contain all top-level keys required by the renderer."""
    required_keys = {"sprzedawca", "nabywca", "numer_faktury", "data_wystawienia", "wiersze", "vat_summary"}
    assert required_keys.issubset(parsed_data.keys())


def test_parse_seller(parsed_data):
    """Sprzedawca fields should match Podmiot1 in the fixture XML."""
    sprzedawca = parsed_data["sprzedawca"]
    assert sprzedawca["nazwa"] == "Firma Testowa Sprzedawca Sp. z o.o."
    assert sprzedawca["nip"] == "1234567890"


def test_parse_buyer(parsed_data):
    """Nabywca fields should match Podmiot2 in the fixture XML."""
    nabywca = parsed_data["nabywca"]
    assert "Nabywca Testowy" in nabywca["nazwa"]
    assert nabywca["nip"] == "9876543210"


def test_parse_line_items(parsed_data):
    """Fixture has 3 line items; the first should be a programming service at 8000.00."""
    wiersze = parsed_data["wiersze"]
    assert len(wiersze) == 3
    first = wiersze[0]
    assert "programistyczne" in first["nazwa"]
    assert first["wartosc_netto"] == "8000.00"


def test_parse_vat_summary(parsed_data):
    """Fixture has VAT at 23% and 5%; P_13_1 (23% net) should equal 10000.00."""
    vat_summary = parsed_data["vat_summary"]
    assert len(vat_summary) == 2
    rates = {entry["stawka"] for entry in vat_summary}
    assert "23%" in rates
    assert "5%" in rates
    entry_23 = next(e for e in vat_summary if e["stawka"] == "23%")
    assert entry_23["netto"] == "10000.00"


def test_parse_payment(parsed_data):
    """Payment section should contain due date and IBAN fragment."""
    platnosc = parsed_data["platnosc"]
    assert platnosc["termin"] == "2025-02-14"
    assert "PL123" in platnosc["nr_rachunku"]


def test_parse_invoice_number(parsed_data):
    """Invoice number (P_2) should be parsed exactly."""
    assert parsed_data["numer_faktury"] == "FV/2025/01/001"


def test_parse_dates(parsed_data):
    """Issue date (P_1) and delivery date (P_6) must match fixture values."""
    assert parsed_data["data_wystawienia"] == "2025-01-15"
    assert parsed_data["data_dostawy"] == "2025-01-14"


def test_parse_podmiot3(parsed_data):
    """Fixture contains two Podmiot3 entries (Faktor + Odbiorca)."""
    podmioty3 = parsed_data.get("podmioty3", [])
    assert len(podmioty3) == 2
    roles = {p["rola"] for p in podmioty3}
    assert "Faktor" in roles
    assert "Odbiorca" in roles


def test_parse_stopka(parsed_data):
    """Stopka section must contain KRS and REGON from the fixture."""
    stopka = parsed_data["stopka"]
    assert stopka["krs"] == "0000123456"
    assert stopka["regon"] == "123456789"


def test_parse_annotations(parsed_data):
    """Adnotacje dict should contain P_16 and P_17 keys."""
    adnotacje = parsed_data.get("adnotacje", {})
    assert "P_16" in adnotacje
    assert "P_17" in adnotacje


def test_parse_dodatkowy_opis(parsed_data):
    """DodatkowyOpis list should contain the 'Nr zamówienia' entry from the fixture."""
    opisy = parsed_data.get("dodatkowy_opis", [])
    keys = [entry["klucz"] for entry in opisy]
    assert "Nr zamówienia" in keys


# ---------------------------------------------------------------------------
# PDF generation
# ---------------------------------------------------------------------------

def test_generate_pdf_creates_file(parsed_data, test_xml_path, tmp_path):
    """generate_invoice_pdf should produce a non-empty file at the given path."""
    output = tmp_path / "faktura.pdf"
    generate_invoice_pdf(parsed_data, output, xml_path=test_xml_path)
    assert output.exists()
    assert output.stat().st_size > 0


def test_generate_pdf_starts_with_pdf_header(parsed_data, test_xml_path, tmp_path):
    """The generated file must start with the PDF magic bytes %PDF-."""
    output = tmp_path / "faktura.pdf"
    generate_invoice_pdf(parsed_data, output, xml_path=test_xml_path)
    assert output.read_bytes()[:5] == b"%PDF-"


def test_generate_pdf_reasonable_size(parsed_data, test_xml_path, tmp_path):
    """PDF size should be between 10 KB and 500 KB (sanity check)."""
    output = tmp_path / "faktura.pdf"
    generate_invoice_pdf(parsed_data, output, xml_path=test_xml_path)
    size = output.stat().st_size
    assert 10 * 1024 <= size <= 500 * 1024


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

def test_parse_unknown_namespace(tmp_path):
    """XML with an unknown namespace must raise ValueError mentioning 'Nieznany'."""
    xml_content = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Faktura xmlns="http://unknown.example.com/schema/">'
        "<Naglowek/>"
        "</Faktura>"
    )
    xml_file = tmp_path / "unknown_ns.xml"
    xml_file.write_text(xml_content, encoding="utf-8")

    with pytest.raises(ValueError, match="Nieznany"):
        parse_ksef_xml(xml_file)


def test_parse_empty_xml(tmp_path):
    """Malformed / empty XML should raise an appropriate error."""
    xml_file = tmp_path / "empty.xml"
    xml_file.write_text("", encoding="utf-8")

    with pytest.raises(Exception):
        parse_ksef_xml(xml_file)
