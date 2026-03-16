"""
KSeF XML to PDF converter using reportlab.

Parses KSeF invoice XML (FA(1), FA(2), FA(3) schemas) and generates
a readable A4 PDF invoice document. Also supports UPO (Urzędowe Poświadczenie
Odbioru) generation in landscape A4.

Author: IT TASK FORCE Piotr Mierzenski <biuro@ittf.pl> — https://ittf.pl
Source: https://github.com/call2pedro/KSeF-xml-download

Źródła KSeF:
  CIRFMF/ksef-pdf-generator (TypeScript/pdfmake) — struktura wizualna faktury,
  układ sekcji (nagłówek, strony, pozycje, podsumowanie VAT, płatność).
  Original: https://github.com/CIRFMF/ksef-pdf-generator
  Fork:     https://github.com/aiv/ksef-pdf-generator
Reimplementacja w Pythonie z użyciem reportlab.
"""

import argparse
import base64
import hashlib
import io
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

from defusedxml import ElementTree as SafeET
from reportlab.graphics.shapes import Drawing, Line
from reportlab.lib.colors import HexColor, black, white
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    Flowable,
    Image,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus import Paragraph

try:
    import qrcode

    HAS_QRCODE = True
except ImportError:
    HAS_QRCODE = False


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Known KSeF namespace URIs
KSEF_NAMESPACES = {
    "http://crd.gov.pl/wzor/2021/11/29/11089/",  # FA(1)
    "http://crd.gov.pl/wzor/2023/06/29/12648/",  # FA(2)
    "http://crd.gov.pl/wzor/2025/06/25/13775/",  # FA(3)
}

# UPO namespace URIs
UPO_NAMESPACES = {
    "http://ksef.mf.gov.pl/schema/gtw/svc/online/types/2021/10/01/0001",  # UPO v4.2
    "http://ksef.mf.gov.pl/schema/gtw/svc/types/2024/08/01/0001",  # UPO v4.3
}

# Payment method codes -> labels
PAYMENT_METHODS = {
    "1": "gotowka",
    "2": "karta",
    "3": "bon",
    "4": "czek",
    "5": "kredyt",
    "6": "przelew",
    "7": "platnosc mobilna",
}

# VAT rate field pairs: (net field suffix, VAT field suffix, rate label)
VAT_RATE_FIELDS = [
    ("1", "1", "23%"),
    ("2", "2", "22%"),
    ("3", "3", "5%"),
    ("4", "4", "7%"),
    ("5", "5", "8%"),
    ("6", "6", "0%"),
    ("7", "7", "zw."),
    ("8", "8", "4%"),
    ("9", "9", "3%"),
    ("10", "10", "np."),
    ("11", "11", "oo"),
]

# Invoice type labels (CIRFMF standard)
RODZAJ_FAKTURY_LABELS = {
    "VAT": "Faktura podstawowa",
    "ZAL": "Faktura zaliczkowa",
    "ROZ": "Faktura rozliczeniowa",
    "KOR_ROZ": "Faktura korygujaca rozliczeniowa",
    "KOR_ZAL": "Faktura korygujaca zaliczkowa",
    "KOR": "Faktura korygujaca",
    "UPR": "Faktura uproszczona",
}

# Font directory relative to this file
FONTS_DIR = Path(__file__).parent / "fonts"

# Colors (CIRFMF standard)
COLOR_HEADER_BG = HexColor("#343A40")
COLOR_SECTION_BG = HexColor("#F6F7FA")
COLOR_TEXT = HexColor("#343A40")
COLOR_LINE = HexColor("#C0BFC1")
COLOR_WATERMARK = HexColor("#B4B4B4")
COLOR_RED = HexColor("#FF0000")

# QR verification URL base
QR_BASE_URL = "https://qr.ksef.mf.gov.pl/invoice"

# Generator footer lines
GENERATOR_LINE_1 = (
    "Wygenerowano przez: KSeF-xml-download "
    "(https://github.com/call2pedro/KSeF-xml-download)"
)
GENERATOR_LINE_2 = (
    "Na podstawie: ksef-pdf-generator CIRFMF "
    "(https://github.com/CIRFMF/ksef-pdf-generator)"
)
GENERATOR_LINE_3 = "Autor: IT TASK FORCE Piotr Mierzenski — https://ittf.pl"

# Szerokości kolumn tabeli pozycji (mm, None = elastyczna)
ITEM_COL_WIDTHS = [10, None, 18, 22, 35, 22, 38]
ITEM_COL_WIDTHS_WALUTA = [10, None, 18, 18, 30, 18, 32, 32]


# ---------------------------------------------------------------------------
# Font registration and styles
# ---------------------------------------------------------------------------

def _register_fonts() -> None:
    """Register Lato fonts for reportlab."""
    if getattr(_register_fonts, '_done', False):
        return
    _register_fonts._done = True
    pdfmetrics.registerFont(TTFont("Lato", str(FONTS_DIR / "Lato-Regular.ttf")))
    pdfmetrics.registerFont(TTFont("Lato-Bold", str(FONTS_DIR / "Lato-Bold.ttf")))


_CACHED_STYLES = None


def _get_styles() -> dict:
    """Return a dict of ParagraphStyle objects for the document."""
    global _CACHED_STYLES
    if _CACHED_STYLES is not None:
        return _CACHED_STYLES
    _CACHED_STYLES = {
        "normal": ParagraphStyle(
            "normal",
            fontName="Lato",
            fontSize=7,
            leading=9,
            textColor=COLOR_TEXT,
        ),
        "normal_right": ParagraphStyle(
            "normal_right",
            fontName="Lato",
            fontSize=7,
            leading=9,
            textColor=COLOR_TEXT,
            alignment=TA_RIGHT,
        ),
        "bold": ParagraphStyle(
            "bold",
            fontName="Lato-Bold",
            fontSize=7,
            leading=9,
            textColor=COLOR_TEXT,
        ),
        "header": ParagraphStyle(
            "header",
            fontName="Lato-Bold",
            fontSize=10,
            leading=13,
            textColor=COLOR_TEXT,
        ),
        "title": ParagraphStyle(
            "title",
            fontName="Lato-Bold",
            fontSize=14,
            leading=18,
            textColor=COLOR_TEXT,
        ),
        "ksef_brand": ParagraphStyle(
            "ksef_brand",
            fontName="Lato",
            fontSize=16,
            leading=20,
        ),
        "table_header": ParagraphStyle(
            "table_header",
            fontName="Lato-Bold",
            fontSize=7,
            leading=9,
            textColor=white,
        ),
        "table_cell": ParagraphStyle(
            "table_cell",
            fontName="Lato",
            fontSize=7,
            leading=9,
            textColor=COLOR_TEXT,
        ),
        "table_cell_right": ParagraphStyle(
            "table_cell_right",
            fontName="Lato",
            fontSize=7,
            leading=9,
            textColor=COLOR_TEXT,
            alignment=TA_RIGHT,
        ),
        "table_cell_center": ParagraphStyle(
            "table_cell_center",
            fontName="Lato",
            fontSize=7,
            leading=9,
            textColor=COLOR_TEXT,
            alignment=TA_CENTER,
        ),
        "section_header": ParagraphStyle(
            "section_header",
            fontName="Lato-Bold",
            fontSize=9,
            leading=12,
            textColor=COLOR_TEXT,
        ),
        "label": ParagraphStyle(
            "label",
            fontName="Lato-Bold",
            fontSize=8,
            leading=10,
            textColor=COLOR_TEXT,
        ),
        "value": ParagraphStyle(
            "value",
            fontName="Lato",
            fontSize=8,
            leading=10,
            textColor=COLOR_TEXT,
        ),
        "value_medium": ParagraphStyle(
            "value_medium",
            fontName="Lato",
            fontSize=9,
            leading=12,
            textColor=COLOR_TEXT,
        ),
        "grand_total": ParagraphStyle(
            "grand_total",
            fontName="Lato-Bold",
            fontSize=10,
            leading=13,
            textColor=COLOR_TEXT,
            alignment=TA_RIGHT,
        ),
        "watermark": ParagraphStyle(
            "watermark",
            fontName="Lato",
            fontSize=6,
            leading=8,
            textColor=COLOR_WATERMARK,
        ),
        "qr_text": ParagraphStyle(
            "qr_text",
            fontName="Lato",
            fontSize=7,
            leading=9,
            textColor=COLOR_TEXT,
        ),
        "link": ParagraphStyle(
            "link",
            fontName="Lato",
            fontSize=7,
            leading=9,
            textColor=HexColor("#0000FF"),
        ),
    }
    return _CACHED_STYLES


# ---------------------------------------------------------------------------
# XML Parsing — invoice
# ---------------------------------------------------------------------------

def _find(element, path, ns):
    """Find element by path with namespace."""
    return element.find(path, ns)


def _findall(element, path, ns):
    """Find all elements by path with namespace."""
    return element.findall(path, ns)


def _text(element, path, ns, default=None):
    """Get text content of a child element."""
    el = _find(element, path, ns)
    if el is not None and el.text:
        return el.text.strip()
    return default


# --- Role podmiotów wg schematu FA(2) XSD (CRD 2023/06/29/12648) ---

ROLA_PODMIOT3 = {
    "1": "Faktor",
    "2": "Odbiorca",
    "3": "Podmiot pierwotny",
    "4": "Dodatkowy nabywca",
    "5": "Wystawca faktury",
    "6": "Dokonujacy platnosci",
    "7": "JST - wystawca",
    "8": "JST - odbiorca",
    "9": "Czlonek grupy VAT - wystawca",
    "10": "Czlonek grupy VAT - odbiorca",
}

ROLA_PODMIOTU_UPOWAZNIONEGO = {
    "1": "Organ egzekucyjny",
    "2": "Komornik sadowy",
    "3": "Przedstawiciel podatkowy",
}


def _parse_podmiot(element, ns):
    """Parse Podmiot1 or Podmiot2 section."""
    if element is None:
        return {}

    data = {}

    # DaneIdentyfikacyjne
    dane = _find(element, "ksef:DaneIdentyfikacyjne", ns)
    if dane is not None:
        data["nip"] = _text(dane, "ksef:NIP", ns)
        data["nazwa"] = _text(dane, "ksef:Nazwa", ns)

    # Adres
    adres = _find(element, "ksef:Adres", ns)
    if adres is not None:
        data["kod_kraju"] = _text(adres, "ksef:KodKraju", ns)
        data["adres_l1"] = _text(adres, "ksef:AdresL1", ns)
        data["adres_l2"] = _text(adres, "ksef:AdresL2", ns)

    # DaneKontaktowe
    kontakt = _find(element, "ksef:DaneKontaktowe", ns)
    if kontakt is not None:
        data["email"] = _text(kontakt, "ksef:Email", ns)
        data["telefon"] = _text(kontakt, "ksef:Telefon", ns)

    # NrKlienta (only on Podmiot2)
    data["nr_klienta"] = _text(element, "ksef:NrKlienta", ns)

    return data


def _parse_podmiot3(element, ns):
    """Parse Podmiot3 section (third party with role)."""
    if element is None:
        return {}

    data = _parse_podmiot(element, ns)

    # Rola (choice: Rola OR RolaInna+OpisRoli)
    rola_kod = _text(element, "ksef:Rola", ns)
    if rola_kod:
        data["rola_kod"] = rola_kod
        data["rola"] = ROLA_PODMIOT3.get(rola_kod, f"Rola {rola_kod}")
    else:
        opis = _text(element, "ksef:OpisRoli", ns)
        if opis:
            data["rola"] = opis
            data["rola_kod"] = "inna"

    # IDNabywcy, NrEORI, Udzial
    data["id_nabywcy"] = _text(element, "ksef:IDNabywcy", ns)
    data["nr_eori"] = _text(element, "ksef:NrEORI", ns)
    data["udzial"] = _text(element, "ksef:Udzial", ns)

    return data


def _parse_podmiot_upowazniony(element, ns):
    """Parse PodmiotUpowazniony section."""
    if element is None:
        return {}

    data = _parse_podmiot(element, ns)

    rola_kod = _text(element, "ksef:RolaPU", ns)
    if rola_kod:
        data["rola_kod"] = rola_kod
        data["rola"] = ROLA_PODMIOTU_UPOWAZNIONEGO.get(rola_kod, f"Rola {rola_kod}")

    data["nr_eori"] = _text(element, "ksef:NrEORI", ns)

    return data


def _parse_wiersz(element, ns):
    """Parse a single FaWiersz element."""
    return {
        "nr": _text(element, "ksef:NrWierszaFa", ns),
        "nazwa": _text(element, "ksef:P_7", ns, ""),
        "jednostka": _text(element, "ksef:P_8A", ns),
        "ilosc": _text(element, "ksef:P_8B", ns),
        "cena_jedn": _text(element, "ksef:P_9A", ns),
        "cena_jedn_brutto": _text(element, "ksef:P_9B", ns),
        "wartosc_netto": _text(element, "ksef:P_11", ns),
        "wartosc_netto_waluta": _text(element, "ksef:P_11A", ns),
        "stawka_vat": _text(element, "ksef:P_12", ns),
    }


def _parse_header(root, ns: dict) -> dict:
    """Extract Naglowek fields from invoice root element."""
    data: dict = {}
    naglowek = _find(root, "ksef:Naglowek", ns)
    if naglowek is not None:
        kod_form = _find(naglowek, "ksef:KodFormularza", ns)
        data["kod_formularza"] = kod_form.text if kod_form is not None else None
        data["kod_systemowy"] = (
            kod_form.get("kodSystemowy") if kod_form is not None else None
        )
        data["wersja_schemy"] = (
            kod_form.get("wersjaSchemy") if kod_form is not None else None
        )
        data["wariant"] = _text(naglowek, "ksef:WariantFormularza", ns)
        data["data_wytworzenia"] = _text(naglowek, "ksef:DataWytworzeniaFa", ns)
        data["system_info"] = _text(naglowek, "ksef:SystemInfo", ns)
    return data


def _parse_invoice_details(fa, ns: dict) -> dict:
    """Extract Fa section fields: dates, amounts, currency, corrections, line items."""
    data: dict = {}
    data["waluta"] = _text(fa, "ksef:KodWaluty", ns, "PLN")
    data["data_wystawienia"] = _text(fa, "ksef:P_1", ns)  # P_1
    data["miejsce_wystawienia"] = _text(fa, "ksef:P_1M", ns)  # P_1M
    data["numer_faktury"] = _text(fa, "ksef:P_2", ns)  # P_2
    data["data_dostawy"] = _text(fa, "ksef:P_6", ns)  # P_6
    data["brutto_total"] = _text(fa, "ksef:P_15", ns)  # P_15
    data["rodzaj_faktury"] = _text(fa, "ksef:RodzajFaktury", ns)
    data["fp"] = _text(fa, "ksef:FP", ns)
    data["tp"] = _text(fa, "ksef:TP", ns)

    # OkresFa (okres fakturowania od-do)
    okres = _find(fa, "ksef:OkresFa", ns)
    if okres is not None:
        data["okres_od"] = _text(okres, "ksef:P_4A", ns)
        data["okres_do"] = _text(okres, "ksef:P_4B", ns)

    # KursWalutyZ (kurs walutowy)
    data["kurs_waluty"] = _text(fa, "ksef:KursWalutyZ", ns)

    # Dane faktury korygowanej (korekta)
    data["korekta_nr"] = _text(fa, "ksef:P_3A", ns)
    data["korekta_data"] = _text(fa, "ksef:P_3B", ns)
    data["korekta_przyczyna"] = _text(fa, "ksef:P_3C", ns)
    data["korekta_nr_ksef"] = _text(fa, "ksef:P_3L", ns)

    # FaWiersz (line items)
    data["wiersze"] = [_parse_wiersz(w, ns) for w in _findall(fa, "ksef:FaWiersz", ns)]

    return data


def _parse_vat_summary(fa, ns: dict) -> dict:
    """Extract VAT summary (P_13_x / P_14_x) per rate from Fa element."""
    vat_summary = []
    for net_suffix, vat_suffix, rate_label in VAT_RATE_FIELDS:
        netto = _text(fa, f"ksef:P_13_{net_suffix}", ns)
        vat = _text(fa, f"ksef:P_14_{vat_suffix}", ns)
        if netto is not None:
            vat_summary.append(
                {
                    "stawka": rate_label,
                    "netto": netto,
                    "vat": vat or "0.00",
                }
            )
    return {"vat_summary": vat_summary}


def _parse_annotations(fa, ns: dict) -> dict:
    """Extract Adnotacje fields from Fa element."""
    adnotacje: dict = {}
    adnotacje_el = _find(fa, "ksef:Adnotacje", ns)
    if adnotacje_el is not None:
        for field in ["P_16", "P_17", "P_18", "P_18A", "P_23"]:
            val = _text(adnotacje_el, f"ksef:{field}", ns)
            if val:
                adnotacje[field] = val
        # Zwolnienie (P_19 + przepisy)
        zwolnienie = _find(adnotacje_el, "ksef:Zwolnienie", ns)
        if zwolnienie is not None:
            p19 = _text(zwolnienie, "ksef:P_19", ns)
            if p19:
                adnotacje["P_19"] = p19
            adnotacje["P_19A"] = _text(zwolnienie, "ksef:P_19A", ns)
            adnotacje["P_19B"] = _text(zwolnienie, "ksef:P_19B", ns)
            adnotacje["P_19C"] = _text(zwolnienie, "ksef:P_19C", ns)
    return {"adnotacje": adnotacje}


def _parse_payment(fa, ns: dict) -> dict:
    """Extract Platnosc fields from Fa element."""
    platnosc_el = _find(fa, "ksef:Platnosc", ns)
    if platnosc_el is None:
        return {"platnosc": {}}
    platnosc: dict = {
        "zaplacono": _text(platnosc_el, "ksef:Zaplacono", ns),
        "data_zaplaty": _text(platnosc_el, "ksef:DataZaplaty", ns),
        "forma": _text(platnosc_el, "ksef:FormaPlatnosci", ns),
        "termin": _text(platnosc_el, "ksef:TerminPlatnosci", ns),
    }
    # RachunekBankowy
    rachunek = _find(platnosc_el, "ksef:RachunekBankowy", ns)
    if rachunek is not None:
        platnosc["nr_rachunku"] = _text(rachunek, "ksef:NrRB", ns)
        platnosc["nazwa_banku"] = _text(rachunek, "ksef:NazwaBanku", ns)
    return {"platnosc": platnosc}


def _parse_additional_info(fa, root, ns: dict) -> dict:
    """Extract DodatkowyOpis, WarunkiTransakcji and Stopka fields."""
    data: dict = {}

    # DodatkowyOpis (may be multiple)
    dodatkowe_opisy = []
    for do_el in _findall(fa, "ksef:DodatkowyOpis", ns):
        klucz = _text(do_el, "ksef:Klucz", ns)
        wartosc = _text(do_el, "ksef:Wartosc", ns)
        if klucz and wartosc:
            dodatkowe_opisy.append({"klucz": klucz, "wartosc": wartosc})
    data["dodatkowy_opis"] = dodatkowe_opisy

    # WarunkiTransakcji
    warunki = _find(fa, "ksef:WarunkiTransakcji", ns)
    if warunki is not None:
        data["zamowienia"] = [
            {
                "data": _text(zam, "ksef:DataZamowienia", ns),
                "numer": _text(zam, "ksef:NrZamowienia", ns),
            }
            for zam in _findall(warunki, "ksef:Zamowienia", ns)
        ]
    else:
        data["zamowienia"] = []

    # Stopka (at root level, not inside Fa)
    stopka_data: dict = {}
    stopka = _find(root, "ksef:Stopka", ns)
    if stopka is not None:
        info = _find(stopka, "ksef:Informacje", ns)
        if info is not None:
            stopka_data["tekst"] = _text(info, "ksef:StopkaFaktury", ns)
        rejestry = _find(stopka, "ksef:Rejestry", ns)
        if rejestry is not None:
            stopka_data["krs"] = _text(rejestry, "ksef:KRS", ns)
            stopka_data["regon"] = _text(rejestry, "ksef:REGON", ns)
            stopka_data["bdo"] = _text(rejestry, "ksef:BDO", ns)
    data["stopka"] = stopka_data

    return data


def parse_ksef_xml(xml_path: Path) -> dict:
    """Parse a KSeF XML invoice and return a normalized dict.

    Handles FA(1), FA(2), FA(3) schemas - different namespaces, similar structure.

    Args:
        xml_path: Path to the KSeF XML invoice file.

    Returns:
        Normalized dictionary with invoice data.

    Raises:
        ValueError: If the XML namespace is not a known KSeF namespace.
    """
    tree = SafeET.parse(str(xml_path))
    root = tree.getroot()

    # Detect namespace
    root_tag = root.tag
    ns_uri = root_tag.split("}")[0].lstrip("{") if "}" in root_tag else ""

    if ns_uri not in KSEF_NAMESPACES:
        raise ValueError(f"Nieznany namespace KSeF: {ns_uri}")

    ns = {"ksef": ns_uri}

    data: dict = {"namespace": ns_uri}

    # --- Naglowek ---
    data.update(_parse_header(root, ns))

    # --- Podmiot1 (Sprzedawca) ---
    data["sprzedawca"] = _parse_podmiot(_find(root, "ksef:Podmiot1", ns), ns)

    # --- Podmiot2 (Nabywca) ---
    data["nabywca"] = _parse_podmiot(_find(root, "ksef:Podmiot2", ns), ns)

    # --- Podmiot3 (inne podmioty, 0..100) ---
    podmioty3 = root.findall("ksef:Podmiot3", ns)
    if podmioty3:
        data["podmioty3"] = [_parse_podmiot3(p, ns) for p in podmioty3]

    # --- PodmiotUpowazniony (opcjonalny) ---
    pu = _find(root, "ksef:PodmiotUpowazniony", ns)
    if pu is not None:
        data["podmiot_upowazniony"] = _parse_podmiot_upowazniony(pu, ns)

    # --- Fa ---
    fa = _find(root, "ksef:Fa", ns)
    if fa is not None:
        data.update(_parse_invoice_details(fa, ns))
        data.update(_parse_vat_summary(fa, ns))
        data.update(_parse_annotations(fa, ns))
        data.update(_parse_payment(fa, ns))
        data.update(_parse_additional_info(fa, root, ns))
    else:
        # Ensure keys expected by the renderer are always present
        data.setdefault("stopka", {})

    return data


# ---------------------------------------------------------------------------
# XML Parsing — UPO
# ---------------------------------------------------------------------------

def parse_upo_xml(xml_path: Path) -> dict:
    """Parse a KSeF UPO XML and return a normalized dict.

    Auto-detects UPO v4.2 and v4.3 namespaces.

    Args:
        xml_path: Path to the UPO XML file.

    Returns:
        Normalized dictionary with UPO data.

    Raises:
        ValueError: If the XML namespace is not a known UPO namespace.
    """
    tree = SafeET.parse(str(xml_path))
    root = tree.getroot()

    # Detect namespace
    root_tag = root.tag
    ns_uri = root_tag.split("}")[0].lstrip("{") if "}" in root_tag else ""

    if ns_uri not in UPO_NAMESPACES:
        raise ValueError(f"Nieznany namespace UPO: {ns_uri}")

    ns = {"upo": ns_uri}
    data = {"namespace": ns_uri}

    # Potwierdzenie — root is <Potwierdzenie>
    potw = root

    data["nazwa_podmiotu"] = _text(potw, "upo:NazwaPodmiotuPrzyjmujacego", ns)
    data["numer_sesji"] = _text(potw, "upo:NumerReferencyjnySesji", ns)
    data["nazwa_struktury"] = _text(potw, "upo:NazwaStrukturyLogicznej", ns)
    data["kod_formularza"] = _text(potw, "upo:KodFormularza", ns)

    # OpisPotwierdzenia
    opis = _find(potw, "upo:OpisPotwierdzenia", ns)
    if opis is not None:
        data["strona"] = _text(opis, "upo:Strona", ns)
        data["liczba_stron"] = _text(opis, "upo:LiczbaStron", ns)
        data["zakres_od"] = _text(opis, "upo:ZakresDokumentowOd", ns)
        data["zakres_do"] = _text(opis, "upo:ZakresDokumentowDo", ns)
        data["liczba_dokumentow"] = _text(
            opis, "upo:CalkowitaLiczbaDokumentow", ns
        )

    # Uwierzytelnienie
    uwierz = _find(potw, "upo:Uwierzytelnienie", ns)
    if uwierz is not None:
        id_kont = _find(uwierz, "upo:IdKontekstu", ns)
        if id_kont is not None:
            for field, label in [
                ("Nip", "NIP"),
                ("IdWewnetrzny", "ID wewnetrzny"),
                ("IdZlozonyVatUE", "ID zlozony VAT UE"),
                ("IdDostawcyUslugPeppol", "ID Peppol"),
            ]:
                val = _text(id_kont, f"upo:{field}", ns)
                if val:
                    data["typ_kontekstu"] = label
                    data["id_kontekstu"] = val
                    break
        data["skrot_uwierzytelniajacego"] = _text(
            uwierz, "upo:SkrotDokumentuUwierzytelniajacego", ns
        )

    # Dokumenty
    dokumenty = []
    for doc in _findall(potw, "upo:Dokument", ns):
        dokumenty.append(
            {
                "nip_sprzedawcy": _text(doc, "upo:NipSprzedawcy", ns),
                "numer_ksef": _text(doc, "upo:NumerKSeFDokumentu", ns),
                "numer_faktury": _text(doc, "upo:NumerFaktury", ns),
                "data_wystawienia": _text(doc, "upo:DataWystawieniaFaktury", ns),
                "data_przeslania": _text(doc, "upo:DataPrzeslaniaDokumentu", ns),
                "data_nadania_ksef": _text(doc, "upo:DataNadaniaNumeruKSeF", ns),
                "skrot_dokumentu": _text(doc, "upo:SkrotDokumentu", ns),
                "tryb_wysylki": _text(doc, "upo:TrybWysylki", ns),
            }
        )
    data["dokumenty"] = dokumenty

    return data


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _dec(value, default: str = "0.00") -> Decimal:
    """Safely convert value to Decimal for display."""
    if value is None:
        return Decimal(default)
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal(default)


def _fmt(value, decimals: int = 2) -> str:
    """Format a numeric value to string with given decimal places."""
    d = _dec(value)
    return f"{d:,.{decimals}f}".replace(",", " ")


# ---------------------------------------------------------------------------
# QR Code generation
# ---------------------------------------------------------------------------

def _compute_qr_url(xml_path: Path, nip: str, date_str: str) -> str:
    """Compute verification QR URL from XML file (QR Code I).

    Args:
        xml_path: Path to the XML invoice file.
        nip: NIP of the seller.
        date_str: Invoice issue date in YYYY-MM-DD format.

    Returns:
        URL in format https://qr.ksef.mf.gov.pl/invoice/{NIP}/{DD-MM-RRRR}/{hash}
    """
    raw_bytes = xml_path.read_bytes()
    sha256_hash = hashlib.sha256(raw_bytes).digest()
    hash_b64url = base64.urlsafe_b64encode(sha256_hash).rstrip(b"=").decode("ascii")

    # Convert date YYYY-MM-DD to DD-MM-RRRR
    parts = date_str.split("-")
    if len(parts) == 3:
        date_formatted = f"{parts[2]}-{parts[1]}-{parts[0]}"
    else:
        date_formatted = date_str

    return f"{QR_BASE_URL}/{nip}/{date_formatted}/{hash_b64url}"


def _generate_qr_image(url: str, size: int = 120) -> "Image | None":
    """Generate QR code as a reportlab Image.

    Args:
        url: The URL to encode.
        size: Image size in points.

    Returns:
        reportlab Image or None if qrcode library is unavailable.
    """
    if not HAS_QRCODE:
        return None

    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=10,
        border=1,
    )
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)

    return Image(buf, width=size, height=size)


# ---------------------------------------------------------------------------
# InvoicePDF — reportlab-based PDF generator for KSeF invoices
# ---------------------------------------------------------------------------

class InvoicePDF:
    """Generator PDF faktury KSeF oparty na reportlab."""

    def __init__(
        self,
        data: dict,
        xml_path: "Path | None" = None,
        ksef_nr: "str | None" = None,
    ):
        _register_fonts()
        self.data = data
        self.xml_path = xml_path
        self.ksef_nr = ksef_nr
        self.styles = _get_styles()
        self.page_width, self.page_height = A4
        self.margin = 15 * mm
        self.content_width = self.page_width - 2 * self.margin

    def build(self, output_path: Path) -> None:
        """Build and save the complete PDF invoice.

        Args:
            output_path: Destination path for the PDF file.
        """
        doc = SimpleDocTemplate(
            str(output_path),
            pagesize=A4,
            leftMargin=self.margin,
            rightMargin=self.margin,
            topMargin=self.margin,
            bottomMargin=self.margin,
        )
        story: list = []
        story.extend(self._render_header())
        story.extend(self._render_parties())
        story.extend(self._render_details())
        story.extend(self._render_korekta())
        story.extend(self._render_line_items())
        story.extend(self._render_vat_summary())
        story.extend(self._render_annotations())
        story.extend(self._render_additional_info())
        story.extend(self._render_payment())
        story.extend(self._render_orders())
        story.extend(self._render_footer_info())
        story.extend(self._render_qr_code())
        story.extend(self._render_generator_footer())
        doc.build(story)

    # --- Internal helpers ---

    def _line(self) -> Flowable:
        """Horizontal line separator as a Drawing flowable."""
        d = Drawing(self.content_width, 1)
        d.add(Line(0, 0, self.content_width, 0, strokeColor=COLOR_LINE, strokeWidth=0.5))
        return d

    def _section_header(self, text: str) -> Table:
        """Section header with light background."""
        t = Table(
            [[Paragraph(text, self.styles["section_header"])]],
            colWidths=[self.content_width],
            hAlign="LEFT",
        )
        t.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, -1), COLOR_SECTION_BG),
                    ("TOPPADDING", (0, 0), (-1, -1), 3),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                    ("LEFTPADDING", (0, 0), (-1, -1), 4),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                ]
            )
        )
        return t

    def _party_block(self, label: str, party: dict) -> list:
        """Build a list of Paragraphs for a party (seller/buyer) block."""
        parts: list = []
        parts.append(Paragraph(label, self.styles["label"]))
        nazwa = party.get("nazwa") or ""
        parts.append(Paragraph(nazwa, self.styles["bold"]))
        if party.get("nip"):
            parts.append(Paragraph(f"NIP: {party['nip']}", self.styles["normal"]))
        if party.get("adres_l1"):
            parts.append(Paragraph(party["adres_l1"], self.styles["normal"]))
        if party.get("adres_l2"):
            parts.append(Paragraph(party["adres_l2"], self.styles["normal"]))
        if party.get("email"):
            parts.append(Paragraph(f"Email: {party['email']}", self.styles["normal"]))
        if party.get("telefon"):
            parts.append(
                Paragraph(f"Tel: {party['telefon']}", self.styles["normal"])
            )
        if party.get("nr_klienta"):
            parts.append(
                Paragraph(
                    f"Nr klienta: {party['nr_klienta']}", self.styles["normal"]
                )
            )
        return parts

    # --- Render sections ---

    def _render_header(self) -> list:
        """Render invoice header: brand, type, number, optional KSeF number."""
        elements: list = []
        d = self.data

        # Invoice type label
        rodzaj = d.get("rodzaj_faktury", "VAT")
        typ_label = RODZAJ_FAKTURY_LABELS.get(rodzaj, "Faktura")
        elements.append(Paragraph(typ_label, self.styles["title"]))

        # Invoice number
        numer = d.get("numer_faktury") or ""
        elements.append(Paragraph(f"Nr {numer}", self.styles["header"]))

        # Optional KSeF reference number
        if self.ksef_nr:
            elements.append(
                Paragraph(
                    f"Numer KSeF: {self.ksef_nr}", self.styles["value_medium"]
                )
            )

        # Schema info (subtle)
        if d.get("kod_systemowy"):
            elements.append(
                Paragraph(
                    f"Schemat: {d['kod_systemowy']}",
                    ParagraphStyle(
                        "schema",
                        fontName="Lato",
                        fontSize=6,
                        leading=8,
                        textColor=COLOR_WATERMARK,
                    ),
                )
            )

        elements.append(Spacer(1, 3 * mm))
        elements.append(self._line())
        elements.append(Spacer(1, 2 * mm))
        return elements

    def _render_parties(self) -> list:
        """Render seller and buyer in two columns."""
        sprzedawca = self.data.get("sprzedawca", {})
        nabywca = self.data.get("nabywca", {})

        col_width = self.content_width / 2 - 5 * mm

        left = self._party_block("SPRZEDAWCA", sprzedawca)
        right = self._party_block("NABYWCA", nabywca)

        t = Table([[left, right]], colWidths=[col_width, col_width], hAlign="LEFT")
        t.setStyle(
            TableStyle(
                [
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ]
            )
        )

        result = [t, Spacer(1, 3 * mm)]

        # --- Podmiot3 (inne podmioty) ---
        podmioty3 = self.data.get("podmioty3", [])
        if podmioty3:
            result.append(self._render_podmioty3(podmioty3))
            result.append(Spacer(1, 2 * mm))

        # --- PodmiotUpowazniony ---
        pu = self.data.get("podmiot_upowazniony")
        if pu:
            result.append(self._render_podmiot_upowazniony(pu))
            result.append(Spacer(1, 2 * mm))

        result.extend([self._line(), Spacer(1, 2 * mm)])
        return result

    def _render_podmioty3(self, podmioty3: list) -> Table:
        """Render Podmiot3 entries (other parties) in a table layout."""
        col_width = self.content_width / 2 - 5 * mm
        rows = []

        for i in range(0, len(podmioty3), 2):
            left = self._party_block_with_role(podmioty3[i])
            right = (
                self._party_block_with_role(podmioty3[i + 1])
                if i + 1 < len(podmioty3)
                else []
            )
            rows.append([left, right])

        t = Table(rows, colWidths=[col_width, col_width], hAlign="LEFT")
        t.setStyle(
            TableStyle(
                [
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
                ]
            )
        )
        return t

    def _render_podmiot_upowazniony(self, pu: dict) -> Table:
        """Render PodmiotUpowazniony section."""
        col_width = self.content_width / 2 - 5 * mm
        left = self._party_block_with_role(pu, label_prefix="PODMIOT UPOWAZNIONY")
        t = Table([[left, []]], colWidths=[col_width, col_width], hAlign="LEFT")
        t.setStyle(
            TableStyle(
                [
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ]
            )
        )
        return t

    def _party_block_with_role(self, party: dict, label_prefix: str = "") -> list:
        """Build party block with role label (for Podmiot3 / PodmiotUpowazniony)."""
        rola = party.get("rola", "")
        if label_prefix:
            label = f"{label_prefix} — {rola}" if rola else label_prefix
        else:
            label = rola.upper() if rola else "PODMIOT"

        parts = self._party_block(label, party)

        if party.get("udzial"):
            parts.append(
                Paragraph(f"Udział: {party['udzial']}%", self.styles["normal"])
            )
        if party.get("nr_eori"):
            parts.append(
                Paragraph(f"EORI: {party['nr_eori']}", self.styles["normal"])
            )
        return parts

    def _render_details(self) -> list:
        """Render issue date, place, delivery date, currency."""
        d = self.data
        elements: list = [self._section_header("Szczegóły"), Spacer(1, 1 * mm)]

        fields = [
            ("Data wystawienia:", d.get("data_wystawienia")),
            ("Miejsce wystawienia:", d.get("miejsce_wystawienia")),
            ("Data dostawy/wykonania:", d.get("data_dostawy")),
        ]
        # Okres fakturowania (P_4A - P_4B)
        okres_od = d.get("okres_od")
        okres_do = d.get("okres_do")
        if okres_od and okres_do:
            fields.append(("Okres fakturowania:", f"{okres_od} — {okres_do}"))
        elif okres_od:
            fields.append(("Okres fakturowania od:", okres_od))

        if d.get("waluta") and d["waluta"] != "PLN":
            fields.append(("Waluta:", d["waluta"]))
            if d.get("kurs_waluty"):
                fields.append(("Kurs waluty:", d["kurs_waluty"]))

        for label, value in fields:
            if value:
                elements.append(
                    Paragraph(f"<b>{label}</b> {value}", self.styles["value"])
                )

        elements.append(Spacer(1, 2 * mm))
        return elements

    def _render_korekta(self) -> list:
        """Render corrected invoice details (for KOR/KOR_ZAL/KOR_ROZ)."""
        d = self.data
        rodzaj = d.get("rodzaj_faktury", "")
        if not rodzaj.startswith("KOR"):
            return []

        has_data = any(d.get(k) for k in [
            "korekta_nr", "korekta_data", "korekta_przyczyna", "korekta_nr_ksef"
        ])
        if not has_data:
            return []

        elements: list = [
            self._section_header("Dane faktury korygowanej"),
            Spacer(1, 1 * mm),
        ]

        fields = [
            ("Numer faktury korygowanej:", d.get("korekta_nr")),
            ("Data faktury korygowanej:", d.get("korekta_data")),
            ("Numer KSeF korygowanej:", d.get("korekta_nr_ksef")),
            ("Przyczyna korekty:", d.get("korekta_przyczyna")),
        ]
        for label, value in fields:
            if value:
                elements.append(
                    Paragraph(f"<b>{label}</b> {value}", self.styles["value"])
                )

        elements.append(Spacer(1, 2 * mm))
        return elements

    def _render_line_items(self) -> list:
        """Render the invoice line items table with flexible Paragraph rows."""
        wiersze = self.data.get("wiersze", [])
        if not wiersze:
            return []

        elements: list = [self._section_header("Pozycje faktury"), Spacer(1, 1 * mm)]

        # Check if any row has P_11A (foreign currency net value)
        has_p11a = any(row.get("wartosc_netto_waluta") for row in wiersze)
        # Check if any row uses brutto pricing (P_9B instead of P_9A)
        has_brutto = any(
            row.get("cena_jedn_brutto") and not row.get("cena_jedn")
            for row in wiersze
        )
        waluta = self.data.get("waluta", "")

        # Column headers and widths (in mm, None = flexible)
        cena_label = "Cena brutto" if has_brutto else "Cena netto"
        headers = [
            "Lp",
            "Nazwa towaru lub usługi",
            "Jedn.",
            "Ilość",
            cena_label,
            "Stawka VAT",
            "Wartość netto",
        ]
        if has_p11a:
            p11a_label = f"Netto {waluta}" if waluta and waluta != "PLN" else "Netto wal. obca"
            headers.append(p11a_label)
            col_widths_mm = list(ITEM_COL_WIDTHS_WALUTA)
        else:
            col_widths_mm = list(ITEM_COL_WIDTHS)

        # Compute flexible Nazwa column width
        fixed_total_mm = sum(w for w in col_widths_mm if w is not None)
        content_width_mm = self.content_width / mm
        nazwa_width_mm = content_width_mm - fixed_total_mm
        col_widths_mm[1] = nazwa_width_mm

        # Convert to points for reportlab
        col_widths_pt = [w * mm for w in col_widths_mm]

        header_row = [Paragraph(h, self.styles["table_header"]) for h in headers]
        data_rows: list = [header_row]

        for row in wiersze:
            stawka_str = row.get("stawka_vat") or ""
            if stawka_str and stawka_str not in ("zw", "zw.", "np", "oo"):
                stawka_str = f"{stawka_str}%"

            row_cells = [
                    Paragraph(row.get("nr") or "", self.styles["table_cell_center"]),
                    Paragraph(row.get("nazwa") or "", self.styles["table_cell"]),
                    Paragraph(
                        row.get("jednostka") or "", self.styles["table_cell_center"]
                    ),
                    Paragraph(
                        row.get("ilosc") or "", self.styles["table_cell_right"]
                    ),
                    Paragraph(
                        _fmt(row.get("cena_jedn") or row.get("cena_jedn_brutto")),
                        self.styles["table_cell_right"],
                    ),
                    Paragraph(stawka_str, self.styles["table_cell_center"]),
                    Paragraph(
                        _fmt(row.get("wartosc_netto")),
                        self.styles["table_cell_right"],
                    ),
            ]
            if has_p11a:
                row_cells.append(
                    Paragraph(
                        _fmt(row.get("wartosc_netto_waluta")),
                        self.styles["table_cell_right"],
                    )
                )
            data_rows.append(row_cells)

        # Build alternating row backgrounds
        row_styles = [
            # Header
            ("BACKGROUND", (0, 0), (-1, 0), COLOR_HEADER_BG),
            ("TEXTCOLOR", (0, 0), (-1, 0), white),
            # Grid
            ("GRID", (0, 0), (-1, -1), 0.5, COLOR_LINE),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 2),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ("LEFTPADDING", (0, 0), (-1, -1), 3),
            ("RIGHTPADDING", (0, 0), (-1, -1), 3),
        ]
        # Alternating background for even data rows (index 2, 4, 6…)
        for i in range(2, len(data_rows), 2):
            row_styles.append(("BACKGROUND", (0, i), (-1, i), COLOR_SECTION_BG))

        t = Table(
            data_rows,
            colWidths=col_widths_pt,
            repeatRows=1,
            hAlign="LEFT",
        )
        t.setStyle(TableStyle(row_styles))

        elements.append(t)
        elements.append(Spacer(1, 3 * mm))
        return elements

    def _render_vat_summary(self) -> list:
        """Render VAT summary table with RAZEM row and grand total."""
        vat_summary = self.data.get("vat_summary", [])
        if not vat_summary:
            return []

        elements: list = [
            self._section_header("Podsumowanie VAT"),
            Spacer(1, 1 * mm),
        ]

        headers = ["Stawka VAT", "Netto", "VAT", "Brutto"]
        col_widths_mm = [None, 50, 50, 55]
        content_width_mm = self.content_width / mm
        col_widths_mm[0] = content_width_mm - sum(w for w in col_widths_mm if w)
        col_widths_pt = [w * mm for w in col_widths_mm]

        header_row = [Paragraph(h, self.styles["table_header"]) for h in headers]
        data_rows: list = [header_row]

        total_netto = Decimal("0")
        total_vat = Decimal("0")
        total_brutto = Decimal("0")

        for row in vat_summary:
            netto = _dec(row.get("netto"))
            vat = _dec(row.get("vat"))
            brutto = netto + vat
            total_netto += netto
            total_vat += vat
            total_brutto += brutto

            data_rows.append(
                [
                    Paragraph(f"Stawka {row['stawka']}", self.styles["table_cell"]),
                    Paragraph(_fmt(netto), self.styles["table_cell_right"]),
                    Paragraph(_fmt(vat), self.styles["table_cell_right"]),
                    Paragraph(_fmt(brutto), self.styles["table_cell_right"]),
                ]
            )

        # RAZEM row
        data_rows.append(
            [
                Paragraph("<b>RAZEM</b>", self.styles["table_cell"]),
                Paragraph(
                    f"<b>{_fmt(total_netto)}</b>", self.styles["table_cell_right"]
                ),
                Paragraph(
                    f"<b>{_fmt(total_vat)}</b>", self.styles["table_cell_right"]
                ),
                Paragraph(
                    f"<b>{_fmt(total_brutto)}</b>",
                    self.styles["table_cell_right"],
                ),
            ]
        )

        t = Table(data_rows, colWidths=col_widths_pt, hAlign="LEFT")
        t.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, 0), COLOR_HEADER_BG),
                    ("BACKGROUND", (0, -1), (-1, -1), COLOR_SECTION_BG),
                    ("GRID", (0, 0), (-1, -1), 0.5, COLOR_LINE),
                    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                    ("TOPPADDING", (0, 0), (-1, -1), 2),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                    ("LEFTPADDING", (0, 0), (-1, -1), 3),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 3),
                ]
            )
        )
        elements.append(t)

        # Grand total from P_15
        brutto_p15 = self.data.get("brutto_total")
        if brutto_p15:
            waluta = self.data.get("waluta", "PLN")
            elements.append(Spacer(1, 2 * mm))
            elements.append(
                Paragraph(
                    f"Kwota należności ogółem: <b>{_fmt(brutto_p15)} {waluta}</b>",
                    self.styles["grand_total"],
                )
            )

        elements.append(Spacer(1, 3 * mm))
        return elements

    def _render_annotations(self) -> list:
        """Render invoice annotations (P_16–P_23, FP, TP)."""
        adnotacje = self.data.get("adnotacje", {})
        d = self.data
        items: list = []

        # Adnotacje z sekcji Adnotacje
        labels = {
            "P_16": "Odwrotne obciazenie",
            "P_17": "Mechanizm podzielonej platnosci",
            "P_18": "Samofakturowanie",
            "P_18A": "Faktura wystawiona na podstawie art. 106e ust. 5 pkt 3",
            "P_23": "Procedura szczegolna VAT-OSS",
        }
        for field, label in labels.items():
            val = adnotacje.get(field)
            if val and val == "1":
                items.append(f"* {label}")

        # Zwolnienie z VAT (P_19)
        if adnotacje.get("P_19") == "1":
            zwolnienie_parts = ["* Zwolnienie z VAT"]
            p19a = adnotacje.get("P_19A")
            p19b = adnotacje.get("P_19B")
            p19c = adnotacje.get("P_19C")
            if p19a:
                zwolnienie_parts.append(f"(art. {p19a} ustawy)")
            if p19b:
                zwolnienie_parts.append(f"(dyrektywa {p19b})")
            if p19c:
                zwolnienie_parts.append(f"({p19c})")
            items.append(" ".join(zwolnienie_parts))

        # FP — Faktura do paragonu fiskalnego
        if d.get("fp") == "1":
            items.append("* Faktura do paragonu fiskalnego")

        # TP — Transakcja miedzy podmiotami powiazanymi
        if d.get("tp") == "1":
            items.append("* Transakcja miedzy podmiotami powiazanymi")

        if not items:
            return []

        elements: list = [self._section_header("Adnotacje"), Spacer(1, 1 * mm)]
        for item in items:
            elements.append(Paragraph(item, self.styles["value"]))

        elements.append(Spacer(1, 2 * mm))
        return elements

    def _render_additional_info(self) -> list:
        """Render DodatkowyOpis entries."""
        dodatkowe = self.data.get("dodatkowy_opis", [])
        if not dodatkowe:
            return []

        elements: list = [
            self._section_header("Informacje dodatkowe"),
            Spacer(1, 1 * mm),
        ]
        for do in dodatkowe:
            elements.append(
                Paragraph(
                    f'<b>{do["klucz"]}:</b> {do["wartosc"]}', self.styles["value"]
                )
            )
        elements.append(Spacer(1, 2 * mm))
        return elements

    def _render_payment(self) -> list:
        """Render payment information."""
        platnosc = self.data.get("platnosc", {})
        if not platnosc:
            return []

        has_any = any(
            platnosc.get(k)
            for k in ["zaplacono", "forma", "data_zaplaty", "termin", "nr_rachunku"]
        )
        if not has_any:
            return []

        elements: list = [self._section_header("Płatność"), Spacer(1, 1 * mm)]

        forma_code = platnosc.get("forma") or ""
        forma_label = PAYMENT_METHODS.get(forma_code, forma_code)

        parts: list = []
        zaplacono = platnosc.get("zaplacono")
        if zaplacono == "1":
            parts.append("Zapłacono")
            if platnosc.get("data_zaplaty"):
                parts.append(f"dnia {platnosc['data_zaplaty']}")
        elif zaplacono == "2":
            parts.append("Nie zapłacono")

        if forma_label:
            parts.append(f"Forma: {forma_label}")
        if platnosc.get("termin"):
            parts.append(f"Termin: {platnosc['termin']}")

        if parts:
            elements.append(Paragraph(" | ".join(parts), self.styles["value"]))

        if platnosc.get("nr_rachunku"):
            elements.append(
                Paragraph(
                    f'<b>Nr rachunku:</b> {platnosc["nr_rachunku"]}',
                    self.styles["value"],
                )
            )
        if platnosc.get("nazwa_banku"):
            elements.append(
                Paragraph(
                    f'<b>Bank:</b> {platnosc["nazwa_banku"]}',
                    self.styles["value"],
                )
            )

        elements.append(Spacer(1, 2 * mm))
        return elements

    def _render_orders(self) -> list:
        """Render WarunkiTransakcji / Zamowienia section."""
        zamowienia = self.data.get("zamowienia", [])
        if not zamowienia:
            return []

        elements: list = [self._section_header("Zamowienia"), Spacer(1, 1 * mm)]
        for zam in zamowienia:
            parts: list = []
            if zam.get("numer"):
                parts.append(f"Nr: {zam['numer']}")
            if zam.get("data"):
                parts.append(f"Data: {zam['data']}")
            elements.append(Paragraph(" | ".join(parts), self.styles["value"]))

        elements.append(Spacer(1, 2 * mm))
        return elements

    def _render_footer_info(self) -> list:
        """Render KRS, REGON, BDO and footer text."""
        stopka = self.data.get("stopka", {})
        if not stopka:
            return []

        has_any = (
            stopka.get("krs")
            or stopka.get("regon")
            or stopka.get("bdo")
            or stopka.get("tekst")
        )
        if not has_any:
            return []

        elements: list = [self._line(), Spacer(1, 2 * mm)]

        parts: list = []
        if stopka.get("krs"):
            parts.append(f"KRS: {stopka['krs']}")
        if stopka.get("regon"):
            parts.append(f"REGON: {stopka['regon']}")
        if stopka.get("bdo"):
            parts.append(f"BDO: {stopka['bdo']}")
        if parts:
            elements.append(Paragraph(" | ".join(parts), self.styles["watermark"]))

        if stopka.get("tekst"):
            elements.append(
                Paragraph(stopka["tekst"], self.styles["watermark"])
            )

        return elements

    def _render_qr_code(self) -> list:
        """Render QR code with verification URL and clickable link."""
        if not self.xml_path:
            return []

        d = self.data
        nip = d.get("sprzedawca", {}).get("nip")
        date_str = d.get("data_wystawienia")
        if not nip or not date_str:
            return []

        qr_url = _compute_qr_url(self.xml_path, nip, date_str)
        qr_img = _generate_qr_image(qr_url, size=120)
        if not qr_img:
            return []

        elements: list = [
            Spacer(1, 3 * mm),
            self._line(),
            Spacer(1, 3 * mm),
            Paragraph(
                "<b>Sprawdź, czy Twoja faktura znajduje się w KSeF!</b>",
                self.styles["header"],
            ),
            Spacer(1, 2 * mm),
        ]

        # QR label (optional KSeF number)
        left_content: list = [qr_img]
        if self.ksef_nr:
            left_content.append(Spacer(1, 2 * mm))
            left_content.append(
                Paragraph(self.ksef_nr, self.styles["table_cell_center"])
            )

        right_content: list = [
            Spacer(1, 15 * mm),
            Paragraph(
                "Nie możesz zeskanować kodu z obrazka? Kliknij w link weryfikacyjny:",
                self.styles["qr_text"],
            ),
            Spacer(1, 2 * mm),
            Paragraph(
                f'<link href="{qr_url}">{qr_url}</link>',
                self.styles["link"],
            ),
        ]

        qr_col_width = 130 * mm
        text_col_width = self.content_width - qr_col_width

        t = Table(
            [[left_content, right_content]],
            colWidths=[qr_col_width, text_col_width],
            hAlign="LEFT",
        )
        t.setStyle(
            TableStyle(
                [
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ]
            )
        )
        elements.append(t)
        elements.append(Spacer(1, 3 * mm))
        return elements

    def _render_generator_footer(self) -> list:
        """Render generator attribution footer."""
        return [
            Spacer(1, 3 * mm),
            self._line(),
            Spacer(1, 2 * mm),
            Paragraph(GENERATOR_LINE_1, self.styles["watermark"]),
            Paragraph(GENERATOR_LINE_2, self.styles["watermark"]),
            Paragraph(GENERATOR_LINE_3, self.styles["watermark"]),
        ]


# ---------------------------------------------------------------------------
# UpoPDF — reportlab-based PDF generator for KSeF UPO (landscape A4)
# ---------------------------------------------------------------------------

class UpoPDF:
    """Generator PDF UPO (Urzędowe Poświadczenie Odbioru) oparty na reportlab."""

    def __init__(self, data: dict):
        _register_fonts()
        self.data = data
        self.styles = _get_styles()
        self.page_width, self.page_height = landscape(A4)
        self.margin = 15 * mm
        self.content_width = self.page_width - 2 * self.margin

    def build(self, output_path: Path) -> None:
        """Build and save the UPO PDF in landscape A4.

        Args:
            output_path: Destination path for the PDF file.
        """
        doc = SimpleDocTemplate(
            str(output_path),
            pagesize=landscape(A4),
            leftMargin=self.margin,
            rightMargin=self.margin,
            topMargin=self.margin,
            bottomMargin=self.margin,
        )
        story: list = []
        story.extend(self._render_header())
        story.extend(self._render_details())
        story.extend(self._render_documents())
        story.extend(self._render_generator_footer())
        doc.build(story)

    # --- Internal helpers ---

    def _line(self) -> Flowable:
        """Horizontal line separator."""
        d = Drawing(self.content_width, 1)
        d.add(Line(0, 0, self.content_width, 0, strokeColor=COLOR_LINE, strokeWidth=0.5))
        return d

    def _section_header(self, text: str) -> Table:
        """Section header with light background."""
        t = Table(
            [[Paragraph(text, self.styles["section_header"])]],
            colWidths=[self.content_width],
            hAlign="LEFT",
        )
        t.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, -1), COLOR_SECTION_BG),
                    ("TOPPADDING", (0, 0), (-1, -1), 3),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                    ("LEFTPADDING", (0, 0), (-1, -1), 4),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                ]
            )
        )
        return t

    # --- Render sections ---

    def _render_header(self) -> list:
        """Render UPO header: brand and document title."""
        elements: list = []

        elements.append(
            Paragraph(
                "Urzedowe poswiadczenie odbioru dokumentu elektronicznego KSeF",
                self.styles["title"],
            )
        )
        elements.append(Spacer(1, 4 * mm))

        if self.data.get("nazwa_podmiotu"):
            elements.append(
                Paragraph(
                    f'<b>Podmiot:</b> {self.data["nazwa_podmiotu"]}',
                    self.styles["value_medium"],
                )
            )

        elements.append(Spacer(1, 3 * mm))
        return elements

    def _render_details(self) -> list:
        """Render UPO details as key-value table."""
        d = self.data
        fields = [
            ("Numer referencyjny sesji:", d.get("numer_sesji")),
            ("Strona:", d.get("strona")),
            ("Liczba stron:", d.get("liczba_stron")),
            ("Zakres dokumentow od:", d.get("zakres_od")),
            ("Zakres dokumentow do:", d.get("zakres_do")),
            ("Calkowita liczba dokumentow:", d.get("liczba_dokumentow")),
            ("Typ kontekstu:", d.get("typ_kontekstu")),
            ("Identyfikator kontekstu:", d.get("id_kontekstu")),
            ("Skrot dokumentu uwierzytelniajacego:", d.get("skrot_uwierzytelniajacego")),
            ("Nazwa struktury logicznej:", d.get("nazwa_struktury")),
            ("Kod formularza:", d.get("kod_formularza")),
        ]

        data_rows: list = []
        for label, value in fields:
            if value:
                data_rows.append(
                    [
                        Paragraph(f"<b>{label}</b>", self.styles["table_cell"]),
                        Paragraph(value, self.styles["table_cell"]),
                    ]
                )

        if not data_rows:
            return []

        label_col = 80 * mm
        value_col = self.content_width - label_col

        t = Table(data_rows, colWidths=[label_col, value_col], hAlign="LEFT")
        t.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (0, -1), COLOR_SECTION_BG),
                    ("GRID", (0, 0), (-1, -1), 0.5, COLOR_LINE),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("TOPPADDING", (0, 0), (-1, -1), 2),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                    ("LEFTPADDING", (0, 0), (-1, -1), 3),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 3),
                ]
            )
        )
        return [t, Spacer(1, 4 * mm)]

    def _render_documents(self) -> list:
        """Render the documents table with repeatRows=1."""
        dokumenty = self.data.get("dokumenty", [])
        if not dokumenty:
            return []

        headers = [
            "Lp.",
            "Numer KSeF",
            "Numer faktury",
            "NIP Sprzedawcy",
            "Data wystawienia",
            "Data przeslania",
            "Data nadania KSeF",
            "Skrot dokumentu",
            "Tryb wysylki",
        ]
        header_row = [Paragraph(h, self.styles["table_header"]) for h in headers]

        data_rows: list = [header_row]
        for i, doc in enumerate(dokumenty, 1):
            data_rows.append(
                [
                    Paragraph(str(i), self.styles["table_cell_center"]),
                    Paragraph(
                        doc.get("numer_ksef") or "", self.styles["table_cell"]
                    ),
                    Paragraph(
                        doc.get("numer_faktury") or "", self.styles["table_cell"]
                    ),
                    Paragraph(
                        doc.get("nip_sprzedawcy") or "", self.styles["table_cell"]
                    ),
                    Paragraph(
                        doc.get("data_wystawienia") or "",
                        self.styles["table_cell_center"],
                    ),
                    Paragraph(
                        doc.get("data_przeslania") or "",
                        self.styles["table_cell_center"],
                    ),
                    Paragraph(
                        doc.get("data_nadania_ksef") or "",
                        self.styles["table_cell_center"],
                    ),
                    Paragraph(
                        doc.get("skrot_dokumentu") or "", self.styles["table_cell"]
                    ),
                    Paragraph(
                        doc.get("tryb_wysylki") or "",
                        self.styles["table_cell_center"],
                    ),
                ]
            )

        # Column widths for landscape A4
        content_mm = self.content_width / mm
        col_widths_mm = [10, None, 40, 25, 25, 25, 25, 55, 20]
        fixed_mm = sum(w for w in col_widths_mm if w is not None)
        col_widths_mm[1] = content_mm - fixed_mm
        col_widths_pt = [w * mm for w in col_widths_mm]

        row_styles = [
            ("BACKGROUND", (0, 0), (-1, 0), COLOR_HEADER_BG),
            ("TEXTCOLOR", (0, 0), (-1, 0), white),
            ("GRID", (0, 0), (-1, -1), 0.5, COLOR_LINE),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 2),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ("LEFTPADDING", (0, 0), (-1, -1), 3),
            ("RIGHTPADDING", (0, 0), (-1, -1), 3),
        ]
        for i in range(2, len(data_rows), 2):
            row_styles.append(("BACKGROUND", (0, i), (-1, i), COLOR_SECTION_BG))

        t = Table(
            data_rows,
            colWidths=col_widths_pt,
            repeatRows=1,
            hAlign="LEFT",
        )
        t.setStyle(TableStyle(row_styles))
        return [t, Spacer(1, 3 * mm)]

    def _render_generator_footer(self) -> list:
        """Render generator attribution footer."""
        ws = self.styles["watermark"]
        return [
            Spacer(1, 5 * mm),
            self._line(),
            Spacer(1, 2 * mm),
            Paragraph(GENERATOR_LINE_1, ws),
            Paragraph(GENERATOR_LINE_2, ws),
            Paragraph(GENERATOR_LINE_3, ws),
        ]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_invoice_pdf(
    data: dict,
    output_path: Path,
    xml_path: "Path | None" = None,
    ksef_nr: "str | None" = None,
) -> None:
    """Generate a PDF invoice from parsed KSeF data.

    Args:
        data: Parsed invoice data dict from parse_ksef_xml().
        output_path: Destination path for the PDF file.
        xml_path: Optional path to original XML (enables QR code generation).
        ksef_nr: Optional KSeF reference number to display.
    """
    pdf = InvoicePDF(data, xml_path=xml_path, ksef_nr=ksef_nr)
    pdf.build(output_path)


def generate_upo_pdf(data: dict, output_path: Path) -> None:
    """Generate a UPO PDF from parsed UPO data.

    Args:
        data: Parsed UPO data dict from parse_upo_xml().
        output_path: Destination path for the PDF file.
    """
    pdf = UpoPDF(data)
    pdf.build(output_path)


def generate_pdf(xml_path: Path, pdf_path: Path) -> None:
    """Drop-in replacement for backward compatibility.

    Same signature as the original function in app.py.

    Args:
        xml_path: Path to the KSeF XML invoice file.
        pdf_path: Destination path for the PDF file.
    """
    xml_path = Path(xml_path)
    pdf_path = Path(pdf_path)
    data = parse_ksef_xml(xml_path)
    generate_invoice_pdf(data, pdf_path, xml_path=xml_path)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _process_directory(
    dir_path: Path,
    skip_existing: bool,
    ksef_nr: "str | None",
) -> None:
    """Process all XML files in a directory.

    Auto-detects invoice vs UPO XML and generates corresponding PDFs.

    Args:
        dir_path: Directory containing XML files.
        skip_existing: If True, skip files that already have a PDF.
        ksef_nr: Optional KSeF reference number for invoices.
    """
    xml_files = sorted(dir_path.rglob("*.xml"))
    if not xml_files:
        print(f"Brak plikow XML w {dir_path}")
        return

    processed = 0
    skipped = 0
    errors = 0

    for xml_path in xml_files:
        pdf_path = xml_path.with_suffix(".pdf")

        if skip_existing and pdf_path.exists():
            skipped += 1
            continue

        try:
            # Try as invoice first, fall back to UPO
            try:
                data = parse_ksef_xml(xml_path)
                generate_invoice_pdf(
                    data, pdf_path, xml_path=xml_path, ksef_nr=ksef_nr
                )
            except ValueError as e:
                if "Nieznany" in str(e):
                    # Nie rozpoznano jako faktura KSeF — proba jako UPO
                    data = parse_upo_xml(xml_path)
                    generate_upo_pdf(data, pdf_path)
                else:
                    raise
            processed += 1
            print(f"OK: {xml_path.name} -> {pdf_path.name}")
        except Exception as exc:
            print(f"Blad: {xml_path.name}: {exc}")
            errors += 1

    print(f"Przetworzono: {processed}, pominięto: {skipped}, błędy: {errors}")


def _cli() -> None:
    """Entry point for the CLI."""
    # Backward compatibility: 2 args, first ends with .xml → old interface
    if (
        len(sys.argv) == 3
        and not sys.argv[1].startswith("-")
        and sys.argv[1] not in ("invoice", "upo")
    ):
        xml_path = Path(sys.argv[1])
        pdf_path = Path(sys.argv[2])
        generate_pdf(xml_path, pdf_path)
        return

    parser = argparse.ArgumentParser(
        prog="ksef_pdf",
        description="KSeF XML -> PDF converter",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # invoice subcommand
    inv = subparsers.add_parser("invoice", help="Generuj PDF faktury")
    inv.add_argument("xml", nargs="?", help="Plik XML faktury")
    inv.add_argument("pdf", nargs="?", help="Plik wyjsciowy PDF")
    inv.add_argument("--ksef-nr", help="Numer referencyjny KSeF")
    inv.add_argument("--dir", help="Przetworz caly folder XML-i")
    inv.add_argument(
        "--skip-existing",
        action="store_true",
        help="Pominij pliki z istniejacym PDF",
    )

    # upo subcommand
    upo_p = subparsers.add_parser("upo", help="Generuj PDF UPO")
    upo_p.add_argument("xml", help="Plik XML UPO")
    upo_p.add_argument("pdf", help="Plik wyjsciowy PDF")

    args = parser.parse_args()

    if args.command == "invoice":
        if args.dir:
            _process_directory(
                Path(args.dir), args.skip_existing, args.ksef_nr
            )
        elif args.xml and args.pdf:
            data = parse_ksef_xml(Path(args.xml))
            generate_invoice_pdf(
                data,
                Path(args.pdf),
                xml_path=Path(args.xml),
                ksef_nr=args.ksef_nr,
            )
        else:
            inv.print_help()
            sys.exit(1)

    elif args.command == "upo":
        data = parse_upo_xml(Path(args.xml))
        generate_upo_pdf(data, Path(args.pdf))


if __name__ == "__main__":
    _cli()
