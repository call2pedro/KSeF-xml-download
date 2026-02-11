"""
KSeF XML to PDF converter using fpdf2.

Parses KSeF invoice XML (FA(1), FA(2), FA(3) schemas) and generates
a readable A4 PDF invoice document.

Author: IT TASK FORCE Piotr Mierzenski <biuro@ittf.pl> — https://ittf.pl
Source: https://github.com/call2pedro/KSeF-xml-download

Inspired by ksef-pdf-generator (TypeScript/pdfmake):
  Original: https://github.com/CIRFMF/ksef-pdf-generator
  Fork:     https://github.com/aiv/ksef-pdf-generator
This file is a clean-room Python reimplementation using fpdf2.
"""

from pathlib import Path
from decimal import Decimal, InvalidOperation

from defusedxml import ElementTree as SafeET
from fpdf import FPDF

# Known KSeF namespace URIs
KSEF_NAMESPACES = {
    "http://crd.gov.pl/wzor/2021/11/29/11089/",   # FA(1)
    "http://crd.gov.pl/wzor/2023/06/29/12648/",   # FA(2)
    "http://crd.gov.pl/wzor/2025/06/25/13775/",   # FA(3)
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
]

# Font directory relative to this file
FONTS_DIR = Path(__file__).parent / "fonts"


# ---------------------------------------------------------------------------
# XML Parsing
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


def parse_ksef_xml(xml_path: Path) -> dict:
    """Parse a KSeF XML invoice and return a normalized dict.

    Handles FA(1), FA(2), FA(3) schemas - different namespaces, similar structure.
    """
    tree = SafeET.parse(str(xml_path))
    root = tree.getroot()

    # Detect namespace
    root_tag = root.tag
    ns_uri = root_tag.split("}")[0].lstrip("{") if "}" in root_tag else ""

    if ns_uri not in KSEF_NAMESPACES:
        raise ValueError(f"Nieznany namespace KSeF: {ns_uri}")

    ns = {"ksef": ns_uri}

    data = {"namespace": ns_uri}

    # --- Naglowek ---
    naglowek = _find(root, "ksef:Naglowek", ns)
    if naglowek is not None:
        kod_form = _find(naglowek, "ksef:KodFormularza", ns)
        data["kod_formularza"] = kod_form.text if kod_form is not None else None
        data["kod_systemowy"] = kod_form.get("kodSystemowy") if kod_form is not None else None
        data["wersja_schemy"] = kod_form.get("wersjaSchemy") if kod_form is not None else None
        data["wariant"] = _text(naglowek, "ksef:WariantFormularza", ns)
        data["data_wytworzenia"] = _text(naglowek, "ksef:DataWytworzeniaFa", ns)
        data["system_info"] = _text(naglowek, "ksef:SystemInfo", ns)

    # --- Podmiot1 (Sprzedawca) ---
    data["sprzedawca"] = _parse_podmiot(_find(root, "ksef:Podmiot1", ns), ns)

    # --- Podmiot2 (Nabywca) ---
    data["nabywca"] = _parse_podmiot(_find(root, "ksef:Podmiot2", ns), ns)

    # --- Fa ---
    fa = _find(root, "ksef:Fa", ns)
    if fa is not None:
        data["waluta"] = _text(fa, "ksef:KodWaluty", ns, "PLN")
        data["data_wystawienia"] = _text(fa, "ksef:P_1", ns)       # P_1
        data["miejsce_wystawienia"] = _text(fa, "ksef:P_1M", ns)   # P_1M
        data["numer_faktury"] = _text(fa, "ksef:P_2", ns)          # P_2
        data["data_dostawy"] = _text(fa, "ksef:P_6", ns)           # P_6
        data["brutto_total"] = _text(fa, "ksef:P_15", ns)          # P_15
        data["rodzaj_faktury"] = _text(fa, "ksef:RodzajFaktury", ns)
        data["fp"] = _text(fa, "ksef:FP", ns)

        # VAT summary fields P_13_x (netto) and P_14_x (VAT) per rate
        vat_summary = []
        for net_suffix, vat_suffix, rate_label in VAT_RATE_FIELDS:
            netto = _text(fa, f"ksef:P_13_{net_suffix}", ns)
            vat = _text(fa, f"ksef:P_14_{vat_suffix}", ns)
            if netto is not None:
                vat_summary.append({
                    "stawka": rate_label,
                    "netto": netto,
                    "vat": vat or "0.00",
                })
        data["vat_summary"] = vat_summary

        # Adnotacje
        adnotacje = _find(fa, "ksef:Adnotacje", ns)
        data["adnotacje"] = {}
        if adnotacje is not None:
            for field in ["P_16", "P_17", "P_18", "P_18A", "P_23"]:
                val = _text(adnotacje, f"ksef:{field}", ns)
                if val:
                    data["adnotacje"][field] = val

        # DodatkowyOpis (may be multiple)
        dodatkowe_opisy = []
        for do_el in _findall(fa, "ksef:DodatkowyOpis", ns):
            klucz = _text(do_el, "ksef:Klucz", ns)
            wartosc = _text(do_el, "ksef:Wartosc", ns)
            if klucz and wartosc:
                dodatkowe_opisy.append({"klucz": klucz, "wartosc": wartosc})
        data["dodatkowy_opis"] = dodatkowe_opisy

        # FaWiersz (line items)
        wiersze = []
        for w in _findall(fa, "ksef:FaWiersz", ns):
            wiersze.append(_parse_wiersz(w, ns))
        data["wiersze"] = wiersze

        # Platnosc
        platnosc = _find(fa, "ksef:Platnosc", ns)
        if platnosc is not None:
            data["platnosc"] = {
                "zaplacono": _text(platnosc, "ksef:Zaplacono", ns),
                "data_zaplaty": _text(platnosc, "ksef:DataZaplaty", ns),
                "forma": _text(platnosc, "ksef:FormaPlatnosci", ns),
                "termin": _text(platnosc, "ksef:TerminPlatnosci", ns),
            }
            # RachunekBankowy
            rachunek = _find(platnosc, "ksef:RachunekBankowy", ns)
            if rachunek is not None:
                data["platnosc"]["nr_rachunku"] = _text(rachunek, "ksef:NrRB", ns)
                data["platnosc"]["nazwa_banku"] = _text(rachunek, "ksef:NazwaBanku", ns)
        else:
            data["platnosc"] = {}

        # WarunkiTransakcji
        warunki = _find(fa, "ksef:WarunkiTransakcji", ns)
        if warunki is not None:
            zamowienia = []
            for zam in _findall(warunki, "ksef:Zamowienia", ns):
                zamowienia.append({
                    "data": _text(zam, "ksef:DataZamowienia", ns),
                    "numer": _text(zam, "ksef:NrZamowienia", ns),
                })
            data["zamowienia"] = zamowienia
        else:
            data["zamowienia"] = []

    # --- Stopka ---
    stopka = _find(root, "ksef:Stopka", ns)
    data["stopka"] = {}
    if stopka is not None:
        info = _find(stopka, "ksef:Informacje", ns)
        if info is not None:
            data["stopka"]["tekst"] = _text(info, "ksef:StopkaFaktury", ns)
        rejestry = _find(stopka, "ksef:Rejestry", ns)
        if rejestry is not None:
            data["stopka"]["krs"] = _text(rejestry, "ksef:KRS", ns)
            data["stopka"]["regon"] = _text(rejestry, "ksef:REGON", ns)
            data["stopka"]["bdo"] = _text(rejestry, "ksef:BDO", ns)

    return data


# ---------------------------------------------------------------------------
# PDF Generation
# ---------------------------------------------------------------------------

def _dec(value, default="0.00"):
    """Safely convert value to Decimal for display."""
    if value is None:
        return Decimal(default)
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal(default)


def _fmt(value, decimals=2):
    """Format a numeric value to string with given decimal places."""
    d = _dec(value)
    return f"{d:,.{decimals}f}".replace(",", " ")


class InvoicePDF(FPDF):
    """Custom FPDF class for KSeF invoice rendering."""

    def __init__(self, data: dict):
        super().__init__(orientation="P", unit="mm", format="A4")
        self.data = data
        self.set_auto_page_break(auto=True, margin=15)
        self._register_fonts()

    def _register_fonts(self):
        """Register Inter fonts for Unicode support."""
        regular = str(FONTS_DIR / "Inter-Regular.ttf")
        bold = str(FONTS_DIR / "Inter-Bold.ttf")
        self.add_font("Inter", "", regular, uni=True)
        self.add_font("Inter", "B", bold, uni=True)

    def _set_font_regular(self, size=9):
        self.set_font("Inter", "", size)

    def _set_font_bold(self, size=9):
        self.set_font("Inter", "B", size)

    def _draw_line(self, y=None):
        """Draw a horizontal line at current or given Y position."""
        if y is None:
            y = self.get_y()
        self.set_draw_color(200, 200, 200)
        self.line(10, y, 200, y)
        self.set_draw_color(0, 0, 0)

    def _section_header(self, text, size=10):
        """Render a section header with background."""
        self.ln(3)
        self.set_fill_color(240, 240, 240)
        self._set_font_bold(size)
        self.cell(0, 7, text, new_x="LMARGIN", new_y="NEXT", fill=True)
        self.ln(2)

    def build(self):
        """Build the complete PDF document."""
        self.add_page()
        self._render_header()
        self._render_parties()
        self._render_line_items()
        self._render_vat_summary()
        self._render_payment()
        self._render_additional_info()
        self._render_footer_info()

    def _render_header(self):
        """Render invoice header: type, number, dates."""
        d = self.data

        # Invoice type + number
        rodzaj = d.get("rodzaj_faktury", "VAT")
        typ_label = f"FAKTURA {rodzaj}" if rodzaj else "FAKTURA"
        self._set_font_bold(14)
        self.cell(0, 8, typ_label, new_x="LMARGIN", new_y="NEXT")

        self._set_font_bold(11)
        numer = d.get("numer_faktury", "")
        self.cell(0, 6, f"Nr {numer}", new_x="LMARGIN", new_y="NEXT")
        self.ln(2)

        # Date fields
        self._set_font_regular(9)
        fields = []
        if d.get("data_wystawienia"):
            fields.append(f"Data wystawienia: {d['data_wystawienia']}")
        if d.get("miejsce_wystawienia"):
            fields.append(f"Miejsce: {d['miejsce_wystawienia']}")
        if d.get("data_dostawy"):
            fields.append(f"Data dostawy/wykonania: {d['data_dostawy']}")
        if d.get("waluta") and d["waluta"] != "PLN":
            fields.append(f"Waluta: {d['waluta']}")

        if fields:
            self.cell(0, 5, "   |   ".join(fields), new_x="LMARGIN", new_y="NEXT")
            self.ln(1)

        # Schema info (subtle)
        if d.get("kod_systemowy"):
            self.set_text_color(150, 150, 150)
            self._set_font_regular(7)
            self.cell(0, 4, f"Schemat: {d['kod_systemowy']}", new_x="LMARGIN", new_y="NEXT")
            self.set_text_color(0, 0, 0)

        self._draw_line()
        self.ln(2)

    def _render_party_block(self, x, w, label, party):
        """Render a single party (seller/buyer) block."""
        self.set_x(x)
        self._set_font_bold(9)
        self.cell(w, 5, label, new_x="LEFT", new_y="NEXT")

        self.set_x(x)
        self._set_font_bold(9)
        nazwa = party.get("nazwa", "")
        self.multi_cell(w, 5, nazwa, new_x="LEFT", new_y="NEXT")

        self._set_font_regular(8)
        if party.get("nip"):
            self.set_x(x)
            self.cell(w, 4, f"NIP: {party['nip']}", new_x="LEFT", new_y="NEXT")

        if party.get("adres_l1"):
            self.set_x(x)
            self.cell(w, 4, party["adres_l1"], new_x="LEFT", new_y="NEXT")
        if party.get("adres_l2"):
            self.set_x(x)
            self.cell(w, 4, party["adres_l2"], new_x="LEFT", new_y="NEXT")

        if party.get("email"):
            self.set_x(x)
            self.cell(w, 4, f"Email: {party['email']}", new_x="LEFT", new_y="NEXT")
        if party.get("telefon"):
            self.set_x(x)
            self.cell(w, 4, f"Tel: {party['telefon']}", new_x="LEFT", new_y="NEXT")
        if party.get("nr_klienta"):
            self.set_x(x)
            self.cell(w, 4, f"Nr klienta: {party['nr_klienta']}", new_x="LEFT", new_y="NEXT")

    def _render_parties(self):
        """Render seller and buyer side by side."""
        sprzedawca = self.data.get("sprzedawca", {})
        nabywca = self.data.get("nabywca", {})

        y_start = self.get_y()

        # Left column: Sprzedawca
        self._render_party_block(10, 90, "SPRZEDAWCA", sprzedawca)
        y_after_left = self.get_y()

        # Right column: Nabywca
        self.set_y(y_start)
        self._render_party_block(105, 90, "NABYWCA", nabywca)
        y_after_right = self.get_y()

        self.set_y(max(y_after_left, y_after_right) + 3)
        self._draw_line()
        self.ln(2)

    def _render_line_items(self):
        """Render the invoice line items table."""
        wiersze = self.data.get("wiersze", [])
        if not wiersze:
            return

        self._section_header("POZYCJE FAKTURY")

        # Table header
        col_widths = [10, 70, 15, 15, 23, 15, 27]  # Lp, Nazwa, Jedn, Ilosc, Cena n., VAT%, Wart.n.
        headers = ["Lp", "Nazwa towaru / uslugi", "Jedn.", "Ilosc", "Cena netto", "VAT%", "Wart. netto"]

        self.set_fill_color(50, 50, 50)
        self.set_text_color(255, 255, 255)
        self._set_font_bold(7)
        for i, (w, h_text) in enumerate(zip(col_widths, headers)):
            align = "C" if i != 1 else "L"
            self.cell(w, 6, h_text, border=1, align=align, fill=True)
        self.ln()
        self.set_text_color(0, 0, 0)

        # Table rows
        self._set_font_regular(7.5)
        fill = False
        for row in wiersze:
            # Check if we need a new page
            if self.get_y() > 260:
                self.add_page()
                # Re-render header row on new page
                self.set_fill_color(50, 50, 50)
                self.set_text_color(255, 255, 255)
                self._set_font_bold(7)
                for i, (w, h_text) in enumerate(zip(col_widths, headers)):
                    align = "C" if i != 1 else "L"
                    self.cell(w, 6, h_text, border=1, align=align, fill=True)
                self.ln()
                self.set_text_color(0, 0, 0)
                self._set_font_regular(7.5)
                fill = False

            if fill:
                self.set_fill_color(248, 248, 248)
            else:
                self.set_fill_color(255, 255, 255)

            stawka_str = row.get("stawka_vat", "")
            if stawka_str and stawka_str not in ("zw", "zw.", "np", "oo"):
                stawka_str = f"{stawka_str}%"

            nazwa = row.get("nazwa", "")
            # Truncate long names to fit
            max_name_len = 55
            if len(nazwa) > max_name_len:
                nazwa = nazwa[:max_name_len - 3] + "..."

            vals = [
                row.get("nr", ""),
                nazwa,
                row.get("jednostka", ""),
                row.get("ilosc", ""),
                _fmt(row.get("cena_jedn")),
                stawka_str,
                _fmt(row.get("wartosc_netto")),
            ]
            for i, (w, v) in enumerate(zip(col_widths, vals)):
                align = "R" if i >= 3 else ("C" if i != 1 else "L")
                self.cell(w, 5.5, v, border=1, align=align, fill=True)
            self.ln()
            fill = not fill

        self.ln(2)

    def _render_vat_summary(self):
        """Render VAT summary table."""
        vat_summary = self.data.get("vat_summary", [])
        if not vat_summary:
            return

        self._section_header("PODSUMOWANIE VAT")

        col_widths = [60, 35, 35, 45]
        headers = ["Stawka VAT", "Netto", "VAT", "Brutto"]

        self.set_fill_color(50, 50, 50)
        self.set_text_color(255, 255, 255)
        self._set_font_bold(8)
        for w, h_text in zip(col_widths, headers):
            self.cell(w, 6, h_text, border=1, align="C", fill=True)
        self.ln()
        self.set_text_color(0, 0, 0)

        # Rows per VAT rate
        self._set_font_regular(8)
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

            self.cell(col_widths[0], 5.5, f"Stawka {row['stawka']}", border=1, align="L")
            self.cell(col_widths[1], 5.5, _fmt(netto), border=1, align="R")
            self.cell(col_widths[2], 5.5, _fmt(vat), border=1, align="R")
            self.cell(col_widths[3], 5.5, _fmt(brutto), border=1, align="R")
            self.ln()

        # Totals row
        self._set_font_bold(8)
        self.set_fill_color(240, 240, 240)
        self.cell(col_widths[0], 6, "RAZEM", border=1, align="L", fill=True)
        self.cell(col_widths[1], 6, _fmt(total_netto), border=1, align="R", fill=True)
        self.cell(col_widths[2], 6, _fmt(total_vat), border=1, align="R", fill=True)
        self.cell(col_widths[3], 6, _fmt(total_brutto), border=1, align="R", fill=True)
        self.ln()

        # Grand total from P_15
        brutto_p15 = self.data.get("brutto_total")
        if brutto_p15:
            self.ln(1)
            self._set_font_bold(10)
            waluta = self.data.get("waluta", "PLN")
            self.cell(0, 7, f"DO ZAPLATY: {_fmt(brutto_p15)} {waluta}",
                      new_x="LMARGIN", new_y="NEXT")

        self.ln(2)

    def _render_payment(self):
        """Render payment information."""
        platnosc = self.data.get("platnosc", {})
        if not platnosc:
            return

        has_any = any(platnosc.get(k) for k in
                      ["zaplacono", "forma", "data_zaplaty", "termin", "nr_rachunku"])
        if not has_any:
            return

        self._section_header("PLATNOSC")
        self._set_font_regular(9)

        forma_code = platnosc.get("forma", "")
        forma_label = PAYMENT_METHODS.get(forma_code, forma_code)

        parts = []
        zaplacono = platnosc.get("zaplacono")
        if zaplacono == "1":
            parts.append("Zaplacono")
            if platnosc.get("data_zaplaty"):
                parts.append(f"dnia {platnosc['data_zaplaty']}")
        elif zaplacono == "2":
            parts.append("Nie zaplacono")

        if forma_label:
            parts.append(f"Forma: {forma_label}")

        if platnosc.get("termin"):
            parts.append(f"Termin: {platnosc['termin']}")

        if parts:
            self.cell(0, 5, "   |   ".join(parts), new_x="LMARGIN", new_y="NEXT")

        if platnosc.get("nr_rachunku"):
            self._set_font_regular(9)
            self.cell(0, 5, f"Nr rachunku: {platnosc['nr_rachunku']}",
                      new_x="LMARGIN", new_y="NEXT")
        if platnosc.get("nazwa_banku"):
            self.cell(0, 5, f"Bank: {platnosc['nazwa_banku']}",
                      new_x="LMARGIN", new_y="NEXT")

        self.ln(2)

    def _render_additional_info(self):
        """Render additional descriptions, order references, annotations."""
        d = self.data

        # DodatkowyOpis
        if d.get("dodatkowy_opis"):
            self._section_header("INFORMACJE DODATKOWE")
            self._set_font_regular(8)
            for do in d["dodatkowy_opis"]:
                self.cell(0, 5, f"{do['klucz']}: {do['wartosc']}",
                          new_x="LMARGIN", new_y="NEXT")
            self.ln(1)

        # Zamowienia
        if d.get("zamowienia"):
            self._section_header("ZAMOWIENIA")
            self._set_font_regular(8)
            for zam in d["zamowienia"]:
                parts = []
                if zam.get("numer"):
                    parts.append(f"Nr: {zam['numer']}")
                if zam.get("data"):
                    parts.append(f"Data: {zam['data']}")
                self.cell(0, 5, "   ".join(parts), new_x="LMARGIN", new_y="NEXT")
            self.ln(1)

    def _render_footer_info(self):
        """Render registry info and footer text."""
        stopka = self.data.get("stopka", {})
        if not stopka:
            return

        has_any = stopka.get("krs") or stopka.get("regon") or stopka.get("bdo") or stopka.get("tekst")
        if not has_any:
            return

        self._draw_line()
        self.ln(2)
        self._set_font_regular(7.5)
        self.set_text_color(100, 100, 100)

        parts = []
        if stopka.get("krs"):
            parts.append(f"KRS: {stopka['krs']}")
        if stopka.get("regon"):
            parts.append(f"REGON: {stopka['regon']}")
        if stopka.get("bdo"):
            parts.append(f"BDO: {stopka['bdo']}")

        if parts:
            self.cell(0, 4, "   |   ".join(parts), new_x="LMARGIN", new_y="NEXT")

        if stopka.get("tekst"):
            self.cell(0, 4, stopka["tekst"], new_x="LMARGIN", new_y="NEXT")

        self.set_text_color(0, 0, 0)

        # Watermark: generated by
        self.ln(3)
        self.set_text_color(180, 180, 180)
        self._set_font_regular(6)
        self.cell(0, 3, "Wygenerowano przez ITTF KSeF Wizualizator | ittf.pl",
                  new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)


def generate_invoice_pdf(data: dict, output_path: Path):
    """Generate a PDF invoice from parsed KSeF data."""
    pdf = InvoicePDF(data)
    pdf.build()
    pdf.output(str(output_path))


def generate_pdf(xml_path: Path, pdf_path: Path):
    """Drop-in replacement for the old subprocess-based generate_pdf().

    Same signature as the original function in app.py.
    """
    data = parse_ksef_xml(xml_path)
    generate_invoice_pdf(data, pdf_path)


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 3:
        print("Uzycie: ksef_pdf.py input.xml output.pdf")
        sys.exit(1)
    generate_pdf(Path(sys.argv[1]), Path(sys.argv[2]))
