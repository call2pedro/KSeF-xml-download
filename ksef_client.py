"""
Klient KSeF (Krajowy System e-Faktur) — uwierzytelnianie tokenem i certyfikatem.

Obsługuje:
- Uwierzytelnianie tokenem KSeF (RSA-OAEP)
- Uwierzytelnianie certyfikatem X.509 (XAdES-BES)
- Wyszukiwanie faktur (query metadata)
- Pobieranie XML faktur

Źródła:
- aiv/ksef-cli (GPL-3.0) — flow tokenowy: challenge, szyfrowanie RSA-OAEP,
  polling statusu autoryzacji, pobieranie faktur z paginacją
- sstybel/ksef-xml-download (MIT) — flow XAdES: budowa AuthTokenRequest XML,
  podpis XAdES-BES (enveloped), kanonizacja C14N, struktura ds:Signature
  z QualifyingProperties/SignedProperties

Autor: IT TASK FORCE Piotr Mierzenski — https://ittf.pl
"""

import base64
import datetime
import hashlib
import json
import logging
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Optional

import requests
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding
from cryptography.hazmat.primitives.asymmetric import rsa as rsa_module

try:
    from lxml import etree
except ImportError:
    etree = None  # Opcjonalne — wymagane tylko dla auth certyfikatem

# ---------------------------------------------------------------------------
# Stałe
# ---------------------------------------------------------------------------

KSEF_URLS = {
    "test": "https://api-test.ksef.mf.gov.pl/v2",
    "demo": "https://api-demo.ksef.mf.gov.pl/v2",
    "prod": "https://api.ksef.mf.gov.pl/v2",
}

AUTH_TOKEN_NS = "http://ksef.mf.gov.pl/auth/token/2.0"
XMLDSIG_NS = "http://www.w3.org/2000/09/xmldsig#"
XADES_NS = "http://uri.etsi.org/01903/v1.3.2#"

MAX_AUTH_POLL_ATTEMPTS = 30
AUTH_POLL_INTERVAL_S = 1.0
REQUEST_TIMEOUT_S = 30


# ---------------------------------------------------------------------------
# Wyjątki
# ---------------------------------------------------------------------------

class KSeFError(Exception):
    """Błąd komunikacji z KSeF API."""

    def __init__(self, message: str, status_code: int = 0, response_data: dict = None):
        super().__init__(message)
        self.status_code = status_code
        self.response_data = response_data or {}


# ---------------------------------------------------------------------------
# Klient KSeF
# ---------------------------------------------------------------------------

class KSeFClient:
    """Klient systemu KSeF obsługujący token i certyfikat."""

    def __init__(
        self,
        nip: str,
        environment: str = "prod",
        timeout: int = REQUEST_TIMEOUT_S,
        logger: logging.Logger = None,
    ):
        if environment not in KSEF_URLS:
            raise ValueError(f"Nieznane środowisko: {environment}. Dostępne: {list(KSEF_URLS.keys())}")

        self.nip = nip
        self.environment = environment
        self.base_url = KSEF_URLS[environment]
        self.timeout = timeout
        self.logger = logger or logging.getLogger(__name__)

        self.authentication_token: Optional[str] = None
        self.access_token: Optional[str] = None
        self.refresh_token: Optional[str] = None
        self.reference_number: Optional[str] = None

        self._session = requests.Session()
        self._session.headers.update({"Accept": "application/json"})

    # ------------------------------------------------------------------
    # Żądania HTTP
    # ------------------------------------------------------------------

    def _request(
        self,
        method: str,
        endpoint: str,
        json_data: dict = None,
        xml_data: str = None,
        with_auth: bool = True,
    ) -> dict:
        url = f"{self.base_url}{endpoint}"
        headers = {}

        if xml_data:
            headers["Content-Type"] = "application/xml; charset=utf-8"
        else:
            headers["Content-Type"] = "application/json"

        if with_auth:
            token = self.access_token or self.authentication_token
            if token:
                headers["Authorization"] = f"Bearer {token}"

        self.logger.debug("KSeF %s %s", method, url)

        try:
            if method == "GET":
                resp = self._session.get(url, headers=headers, timeout=self.timeout)
            elif method == "POST":
                if xml_data:
                    resp = self._session.post(url, headers=headers, data=xml_data.encode("utf-8"), timeout=self.timeout)
                else:
                    resp = self._session.post(url, headers=headers, json=json_data, timeout=self.timeout)
            elif method == "DELETE":
                resp = self._session.delete(url, headers=headers, timeout=self.timeout)
            else:
                raise ValueError(f"Nieobsługiwana metoda HTTP: {method}")
        except requests.RequestException as exc:
            raise KSeFError(f"Błąd połączenia z KSeF: {exc}")

        if resp.status_code >= 400:
            msg = f"KSeF API HTTP {resp.status_code}"
            data = {}
            try:
                data = resp.json()
                exc_info = data.get("exception", {})
                detail_list = exc_info.get("exceptionDetailList", [])
                if detail_list:
                    msg = detail_list[0].get("exceptionDescription", msg)
            except (ValueError, KeyError):
                data = {"raw": resp.text[:500]}
            raise KSeFError(msg, resp.status_code, data)

        if not resp.text:
            return {}

        ct = resp.headers.get("Content-Type", "")
        if "application/json" in ct:
            return resp.json()
        return {"raw_content": resp.text}

    # ------------------------------------------------------------------
    # Challenge (wspólny dla obu metod)
    # ------------------------------------------------------------------

    def _get_challenge(self) -> dict:
        return self._request(
            "POST",
            "/auth/challenge",
            json_data={
                "contextIdentifier": {
                    "type": "onip",
                    "identifier": self.nip,
                }
            },
            with_auth=False,
        )

    # ------------------------------------------------------------------
    # Polling + redeem (wspólne)
    # ------------------------------------------------------------------

    def _poll_auth_status(self) -> None:
        for attempt in range(MAX_AUTH_POLL_ATTEMPTS):
            resp = self._request("GET", f"/auth/{self.reference_number}")
            status = resp.get("status", {})
            code = status.get("code") or resp.get("processingCode")

            if code == 200:
                self.logger.info("Autoryzacja zakończona pomyślnie")
                return
            if code == 100:
                self.logger.info("Autoryzacja w toku (%d/%d)...", attempt + 1, MAX_AUTH_POLL_ATTEMPTS)
                time.sleep(AUTH_POLL_INTERVAL_S)
                continue

            desc = status.get("description", "Nieznany błąd")
            raise KSeFError(f"Błąd autoryzacji: kod {code} — {desc}", response_data=resp)

        raise KSeFError("Timeout oczekiwania na autoryzację")

    def _redeem_token(self) -> None:
        resp = self._request("POST", "/auth/token/redeem")
        at = resp.get("accessToken")
        rt = resp.get("refreshToken")
        self.access_token = at.get("token") if isinstance(at, dict) else at
        self.refresh_token = rt.get("token") if isinstance(rt, dict) else rt

    # ------------------------------------------------------------------
    # Auth: Token KSeF
    # ------------------------------------------------------------------

    def authenticate_token(self, ksef_token: str) -> None:
        """Uwierzytelnianie tokenem KSeF (RSA-OAEP SHA-256)."""
        self.logger.info("Uwierzytelnianie tokenem KSeF dla NIP %s...", self.nip)

        challenge_resp = self._get_challenge()
        challenge = challenge_resp.get("challenge")
        timestamp_ms = challenge_resp.get("timestampMs")

        if not challenge or timestamp_ms is None:
            raise KSeFError("Brak challenge/timestamp z KSeF", response_data=challenge_resp)

        # Pobierz klucz publiczny KSeF do szyfrowania tokenu
        public_key = self._fetch_token_encryption_key()

        # Szyfrowanie: {token}|{timestampMs} -> RSA-OAEP SHA-256 -> Base64
        plaintext = f"{ksef_token}|{timestamp_ms}".encode("utf-8")
        encrypted = public_key.encrypt(
            plaintext,
            padding.OAEP(
                mgf=padding.MGF1(algorithm=hashes.SHA256()),
                algorithm=hashes.SHA256(),
                label=None,
            ),
        )
        encrypted_b64 = base64.b64encode(encrypted).decode("utf-8")

        # Wysłanie
        resp = self._request(
            "POST",
            "/auth/ksef-token",
            json_data={
                "challenge": challenge,
                "contextIdentifier": {"type": "Nip", "value": self.nip},
                "encryptedToken": encrypted_b64,
            },
            with_auth=False,
        )

        self.authentication_token = resp.get("authenticationToken", {}).get("token")
        self.reference_number = resp.get("referenceNumber")

        if not self.authentication_token:
            raise KSeFError("Brak authenticationToken w odpowiedzi", response_data=resp)

        self._poll_auth_status()
        self._redeem_token()
        self.logger.info("Uwierzytelnianie tokenem zakończone — accessToken uzyskany")

    def _fetch_token_encryption_key(self):
        """Pobierz klucz publiczny KSeF do szyfrowania tokenów."""
        resp = self._request("GET", "/security/public-key-certificates", with_auth=False)

        certs = resp if isinstance(resp, list) else resp.get("certificates", [])
        if not certs:
            raise KSeFError("Brak certyfikatów publicznych KSeF")

        for cert_info in certs:
            usage = cert_info.get("usage", [])
            if "KsefTokenEncryption" in usage:
                cert_b64 = cert_info["certificate"]
                cert_der = base64.b64decode(cert_b64)
                cert = x509.load_der_x509_certificate(cert_der, default_backend())
                return cert.public_key()

        # Fallback — pierwszy aktywny certyfikat
        cert_b64 = certs[0].get("certificate") or certs[0].get("publicKey")
        if not cert_b64:
            raise KSeFError("Nie można wyodrębnić klucza publicznego KSeF")

        cert_der = base64.b64decode(cert_b64)
        cert = x509.load_der_x509_certificate(cert_der, default_backend())
        return cert.public_key()

    # ------------------------------------------------------------------
    # Auth: Certyfikat X.509 (XAdES-BES)
    # ------------------------------------------------------------------

    def authenticate_certificate(
        self,
        cert_path: str,
        key_path: str,
        key_password: str = None,
    ) -> None:
        """Uwierzytelnianie certyfikatem X.509 z podpisem XAdES-BES."""
        if etree is None:
            raise KSeFError(
                "Brak biblioteki lxml — wymagana do podpisu XAdES. "
                "Zainstaluj: pip install lxml>=4.9"
            )

        self.logger.info("Uwierzytelnianie certyfikatem dla NIP %s...", self.nip)

        # Wczytaj certyfikat i klucz prywatny
        certificate = self._load_certificate(cert_path)
        private_key = self._load_private_key(key_path, key_password)

        # Challenge
        challenge_resp = self._get_challenge()
        challenge = challenge_resp.get("challenge")
        timestamp = challenge_resp.get("timestamp")

        if not challenge:
            raise KSeFError("Brak challenge z KSeF", response_data=challenge_resp)

        # Buduj i podpisz XML
        xml_content = self._build_auth_token_request_xml(challenge, timestamp)
        signed_xml = self._sign_xml_xades(xml_content, certificate, private_key)

        # Wyślij podpisany XML
        resp = self._request(
            "POST",
            "/auth/xades-signature",
            xml_data=signed_xml,
            with_auth=False,
        )

        self.authentication_token = resp.get("authenticationToken", {}).get("token")
        self.reference_number = resp.get("referenceNumber")

        if not self.authentication_token:
            raise KSeFError("Brak authenticationToken w odpowiedzi", response_data=resp)

        self._poll_auth_status()
        self._redeem_token()
        self.logger.info("Uwierzytelnianie certyfikatem zakończone — accessToken uzyskany")

    def _load_certificate(self, cert_path: str) -> x509.Certificate:
        path = Path(cert_path)
        if not path.exists():
            raise KSeFError(f"Certyfikat nie znaleziony: {cert_path}")

        data = path.read_bytes()
        try:
            return x509.load_pem_x509_certificate(data, default_backend())
        except Exception:
            return x509.load_der_x509_certificate(data, default_backend())

    def _load_private_key(self, key_path: str, password: str = None):
        path = Path(key_path)
        if not path.exists():
            raise KSeFError(f"Klucz prywatny nie znaleziony: {key_path}")

        data = path.read_bytes()
        pwd = password.encode("utf-8") if password else None

        try:
            return serialization.load_pem_private_key(data, password=pwd, backend=default_backend())
        except Exception as exc:
            raise KSeFError(f"Błąd ładowania klucza prywatnego: {exc}")

    def _build_auth_token_request_xml(self, challenge: str, timestamp: str = None) -> str:
        root = etree.Element("AuthTokenRequest", nsmap={None: AUTH_TOKEN_NS})

        ch = etree.SubElement(root, "Challenge")
        ch.text = challenge

        ctx = etree.SubElement(root, "ContextIdentifier")
        nip_el = etree.SubElement(ctx, "Nip")
        nip_el.text = self.nip

        sub = etree.SubElement(root, "SubjectIdentifierType")
        sub.text = "certificateSubject"

        return '<?xml version="1.0" encoding="utf-8"?>' + etree.tostring(root, encoding="unicode")

    def _sign_xml_xades(
        self,
        xml_content: str,
        certificate: x509.Certificate,
        private_key,
    ) -> str:
        """Podpis XAdES-BES — enveloped signature."""
        doc = etree.fromstring(xml_content.encode("utf-8"))

        sig_id = f"Signature-{uuid.uuid4()}"
        signed_props_id = f"SignedProperties-{uuid.uuid4()}"

        # Dane certyfikatu
        cert_der = certificate.public_bytes(serialization.Encoding.DER)
        cert_b64 = base64.b64encode(cert_der).decode()
        cert_digest = base64.b64encode(hashlib.sha256(cert_der).digest()).decode()
        signing_time = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Algorytm podpisu
        if isinstance(private_key, rsa_module.RSAPrivateKey):
            sig_algorithm = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
        else:
            sig_algorithm = "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"

        ns_ds = XMLDSIG_NS
        ns_xa = XADES_NS

        # --- Budowa struktury podpisu ---
        signature = etree.Element(f"{{{ns_ds}}}Signature", nsmap={"ds": ns_ds}, Id=sig_id)

        # SignedInfo
        signed_info = etree.SubElement(signature, f"{{{ns_ds}}}SignedInfo")
        etree.SubElement(signed_info, f"{{{ns_ds}}}CanonicalizationMethod",
                         Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#")
        etree.SubElement(signed_info, f"{{{ns_ds}}}SignatureMethod", Algorithm=sig_algorithm)

        # Reference #1 — dokument
        ref1 = etree.SubElement(signed_info, f"{{{ns_ds}}}Reference", URI="")
        transforms1 = etree.SubElement(ref1, f"{{{ns_ds}}}Transforms")
        etree.SubElement(transforms1, f"{{{ns_ds}}}Transform",
                         Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature")
        etree.SubElement(transforms1, f"{{{ns_ds}}}Transform",
                         Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#")
        etree.SubElement(ref1, f"{{{ns_ds}}}DigestMethod",
                         Algorithm="http://www.w3.org/2001/04/xmlenc#sha256")
        digest_val1 = etree.SubElement(ref1, f"{{{ns_ds}}}DigestValue")

        # Reference #2 — SignedProperties
        ref2 = etree.SubElement(
            signed_info, f"{{{ns_ds}}}Reference",
            URI=f"#{signed_props_id}",
            Type="http://uri.etsi.org/01903#SignedProperties",
        )
        transforms2 = etree.SubElement(ref2, f"{{{ns_ds}}}Transforms")
        etree.SubElement(transforms2, f"{{{ns_ds}}}Transform",
                         Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#")
        etree.SubElement(ref2, f"{{{ns_ds}}}DigestMethod",
                         Algorithm="http://www.w3.org/2001/04/xmlenc#sha256")
        digest_val2 = etree.SubElement(ref2, f"{{{ns_ds}}}DigestValue")

        # SignatureValue (puste — wypełnione po obliczeniu)
        sig_value = etree.SubElement(signature, f"{{{ns_ds}}}SignatureValue")

        # KeyInfo z certyfikatem X.509
        key_info = etree.SubElement(signature, f"{{{ns_ds}}}KeyInfo")
        x509_data = etree.SubElement(key_info, f"{{{ns_ds}}}X509Data")
        x509_cert = etree.SubElement(x509_data, f"{{{ns_ds}}}X509Certificate")
        x509_cert.text = cert_b64

        # Object > QualifyingProperties > SignedProperties
        obj = etree.SubElement(signature, f"{{{ns_ds}}}Object")
        qp = etree.SubElement(obj, f"{{{ns_xa}}}QualifyingProperties",
                              nsmap={"xades": ns_xa}, Target=f"#{sig_id}")
        sp = etree.SubElement(qp, f"{{{ns_xa}}}SignedProperties", Id=signed_props_id)
        ssp = etree.SubElement(sp, f"{{{ns_xa}}}SignedSignatureProperties")

        st_el = etree.SubElement(ssp, f"{{{ns_xa}}}SigningTime")
        st_el.text = signing_time

        sc = etree.SubElement(ssp, f"{{{ns_xa}}}SigningCertificate")
        cert_el = etree.SubElement(sc, f"{{{ns_xa}}}Cert")
        cd = etree.SubElement(cert_el, f"{{{ns_xa}}}CertDigest")
        etree.SubElement(cd, f"{{{ns_ds}}}DigestMethod",
                         Algorithm="http://www.w3.org/2001/04/xmlenc#sha256")
        cd_val = etree.SubElement(cd, f"{{{ns_ds}}}DigestValue")
        cd_val.text = cert_digest

        iss = etree.SubElement(cert_el, f"{{{ns_xa}}}IssuerSerial")
        iss_name = etree.SubElement(iss, f"{{{ns_ds}}}X509IssuerName")
        iss_name.text = certificate.issuer.rfc4514_string()
        iss_serial = etree.SubElement(iss, f"{{{ns_ds}}}X509SerialNumber")
        iss_serial.text = str(certificate.serial_number)

        # --- Obliczenie digestów ---

        # Digest SignedProperties (C14N)
        sp_c14n = etree.tostring(sp, method="c14n", exclusive=True)
        digest_val2.text = base64.b64encode(hashlib.sha256(sp_c14n).digest()).decode()

        # Digest dokumentu (C14N, bez podpisu)
        doc_c14n = etree.tostring(doc, method="c14n", exclusive=True)
        digest_val1.text = base64.b64encode(hashlib.sha256(doc_c14n).digest()).decode()

        # Dodaj podpis do dokumentu
        doc.append(signature)

        # --- Obliczenie wartości podpisu ---
        signed_info_c14n = etree.tostring(signed_info, method="c14n", exclusive=True)

        if isinstance(private_key, rsa_module.RSAPrivateKey):
            raw_sig = private_key.sign(signed_info_c14n, padding.PKCS1v15(), hashes.SHA256())
        else:
            der_sig = private_key.sign(signed_info_c14n, ec.ECDSA(hashes.SHA256()))
            raw_sig = self._der_to_raw_ecdsa(der_sig, private_key.key_size)

        sig_value.text = base64.b64encode(raw_sig).decode()

        return '<?xml version="1.0" encoding="utf-8"?>' + etree.tostring(doc, encoding="unicode")

    @staticmethod
    def _der_to_raw_ecdsa(der_signature: bytes, key_size: int) -> bytes:
        """Konwersja ECDSA DER → raw (r || s)."""
        from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

        r, s = decode_dss_signature(der_signature)
        component_size = (key_size + 7) // 8
        return r.to_bytes(component_size, "big") + s.to_bytes(component_size, "big")

    # ------------------------------------------------------------------
    # Operacje na fakturach
    # ------------------------------------------------------------------

    def query_invoices(
        self,
        subject_type: str = "Subject2",
        date_from: datetime.date = None,
        date_to: datetime.date = None,
        date_type: str = "Invoicing",
        page_size: int = 100,
        page_offset: int = 0,
    ) -> dict:
        """Wyszukiwanie faktur w KSeF.

        Args:
            subject_type: 'Subject1' (wystawione), 'Subject2' (otrzymane)
            date_from: Data od (domyślnie: 30 dni wstecz)
            date_to: Data do (domyślnie: dziś)
            date_type: 'Invoicing' lub 'Issue'
            page_size: Wyników na stronę (max 250)
            page_offset: Offset strony
        """
        if not self.access_token:
            raise KSeFError("Brak aktywnej sesji — najpierw uwierzytelnij się")

        if date_to is None:
            date_to = datetime.date.today()
        if date_from is None:
            date_from = date_to - datetime.timedelta(days=30)

        # KSeF limit: max 90 dni
        max_range = datetime.timedelta(days=90)
        if (date_to - date_from) > max_range:
            self.logger.warning("Zakres dat przekracza 90 dni — ograniczam")
            date_from = date_to - max_range

        data = {
            "subjectType": subject_type,
            "dateRange": {
                "dateType": date_type,
                "from": f"{date_from.isoformat()}T00:00:00",
                "to": f"{date_to.isoformat()}T23:59:59",
            },
        }

        qs = f"?pageSize={min(page_size, 250)}&pageOffset={page_offset}"
        return self._request("POST", f"/invoices/query/metadata{qs}", json_data=data)

    def download_invoice_xml(self, ksef_number: str) -> bytes:
        """Pobierz XML faktury z KSeF.

        Args:
            ksef_number: Numer KSeF faktury

        Returns:
            Surowe bajty XML (zachowuje oryginalne kodowanie dla hash QR)
        """
        if not self.access_token:
            raise KSeFError("Brak aktywnej sesji — najpierw uwierzytelnij się")

        url = f"{self.base_url}/invoices/ksef/{ksef_number}"
        headers = {
            "Authorization": f"Bearer {self.access_token}",
            "Accept": "application/octet-stream",
        }

        resp = self._session.get(url, headers=headers, timeout=self.timeout)
        if resp.status_code >= 400:
            raise KSeFError(f"Błąd pobierania faktury: HTTP {resp.status_code}", resp.status_code)

        return resp.content

    def terminate_session(self) -> None:
        """Zakończ sesję KSeF."""
        if self.access_token:
            try:
                self._request("DELETE", "/auth/sessions/current")
            except KSeFError:
                pass
            self.access_token = None
            self.authentication_token = None
            self.refresh_token = None
            self.reference_number = None


# ---------------------------------------------------------------------------
# CLI — samodzielne użycie
# ---------------------------------------------------------------------------

def _cli() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Klient KSeF — pobieranie faktur XML",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--nip", required=True, help="NIP firmy")
    parser.add_argument("--env", choices=["test", "demo", "prod"], default="prod", help="Środowisko KSeF")
    parser.add_argument("--output-dir", default="faktury", help="Katalog na pliki XML")
    parser.add_argument("--subject", choices=["Subject1", "Subject2"], default="Subject2",
                        help="Subject1=wystawione, Subject2=otrzymane")
    parser.add_argument("--days", type=int, default=30, help="Ile dni wstecz")
    parser.add_argument("-v", "--verbose", action="store_true")

    auth_group = parser.add_mutually_exclusive_group(required=True)
    auth_group.add_argument("--token", help="Token KSeF")
    auth_group.add_argument("--token-file", help="Plik z tokenem KSeF")
    auth_group.add_argument("--cert", help="Ścieżka do certyfikatu PEM")

    parser.add_argument("--key", help="Ścieżka do klucza prywatnego PEM (dla --cert)")
    parser.add_argument("--password", help="Hasło klucza prywatnego (dla --cert)")
    parser.add_argument("--password-file", help="Plik z hasłem klucza prywatnego")

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    logger = logging.getLogger("ksef_client")

    client = KSeFClient(nip=args.nip, environment=args.env, logger=logger)

    # Uwierzytelnianie
    if args.cert:
        if not args.key:
            print("BŁĄD: --key jest wymagany razem z --cert", file=sys.stderr)
            sys.exit(1)

        password = None
        if args.password:
            password = args.password
        elif args.password_file:
            password = Path(args.password_file).read_text(encoding="utf-8").strip()

        client.authenticate_certificate(args.cert, args.key, password)
    else:
        token = args.token
        if args.token_file:
            token = Path(args.token_file).read_text(encoding="utf-8").strip()
        if not token:
            print("BŁĄD: Podaj --token lub --token-file", file=sys.stderr)
            sys.exit(1)

        client.authenticate_token(token)

    # Pobieranie faktur
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    date_to = datetime.date.today()
    date_from = date_to - datetime.timedelta(days=args.days)

    logger.info("Wyszukiwanie faktur od %s do %s...", date_from, date_to)

    total_downloaded = 0
    total_skipped = 0
    page_offset = 0

    while True:
        result = client.query_invoices(
            subject_type=args.subject,
            date_from=date_from,
            date_to=date_to,
            page_offset=page_offset,
        )

        invoices = result.get("invoiceHeaderList", [])
        if not invoices:
            if page_offset == 0:
                logger.info("Brak faktur w podanym zakresie dat.")
            break

        for inv in invoices:
            ksef_nr = inv.get("ksefReferenceNumber", "")
            if not ksef_nr:
                continue

            # Nazwa pliku: numer KSeF (bezpieczna nazwa)
            safe_name = ksef_nr.replace("/", "_").replace("\\", "_")
            xml_path = output_dir / f"{safe_name}.xml"

            if xml_path.exists():
                total_skipped += 1
                continue

            try:
                xml_bytes = client.download_invoice_xml(ksef_nr)
                xml_path.write_bytes(xml_bytes)
                total_downloaded += 1
                logger.info("Pobrano: %s", ksef_nr)
            except KSeFError as exc:
                logger.error("Błąd pobierania %s: %s", ksef_nr, exc)

        # Paginacja
        total_count = result.get("numberOfElements", 0)
        page_offset += len(invoices)
        if page_offset >= total_count:
            break

    logger.info("Zakończono. Pobrano: %d, pominięto: %d", total_downloaded, total_skipped)

    # Zamknij sesję
    client.terminate_session()


if __name__ == "__main__":
    _cli()
