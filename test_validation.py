"""Testy walidacji: NIP, sanityzacja nazw plikow, szyfrowanie AES-256-GCM."""
import base64
import re

import pytest
from pathlib import Path

from ksef_client import KSeFClient, generate_aes_key, encrypt_password, decrypt_password


# ---------------------------------------------------------------------------
# Pomocnicza funkcja sanityzacji — skopiowana z _download_all_invoices
# ---------------------------------------------------------------------------

def _sanitize_ksef_name(ksef_nr: str) -> str:
    """Sanitize KSeF invoice number for use as a filename.

    Replicates the inline logic from KSeFClient._download_all_invoices.
    """
    safe_name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', ksef_nr)
    safe_name = safe_name.replace('..', '__')
    if len(safe_name) > 200:
        safe_name = safe_name[:200]
    return safe_name


# ---------------------------------------------------------------------------
# Walidacja NIP
# ---------------------------------------------------------------------------

class TestNIPValidation:
    """Tests for NIP validation in KSeFClient.__init__."""

    def test_nip_valid(self):
        """Valid NIP 5261040828 should not raise."""
        # checksum: 6*5+5*2+7*6+2*1+3*0+4*4+5*0+6*8+7*2 = 30+10+42+2+0+16+0+48+14 = 162, 162%11 = 8 ✓
        with KSeFClient(nip="5261040828", environment="test"):
            pass

    def test_nip_too_short(self):
        """NIP shorter than 10 digits should raise ValueError."""
        with pytest.raises(ValueError, match="NIP"):
            KSeFClient(nip="123", environment="test")

    def test_nip_too_long(self):
        """NIP longer than 10 digits should raise ValueError."""
        with pytest.raises(ValueError, match="NIP"):
            KSeFClient(nip="12345678901", environment="test")

    def test_nip_non_digits(self):
        """NIP containing non-digit characters should raise ValueError."""
        with pytest.raises(ValueError, match="NIP"):
            KSeFClient(nip="123abc7890", environment="test")

    def test_nip_bad_checksum(self):
        """NIP with incorrect checksum digit should raise ValueError."""
        # 1234567891 — digit sequence 123456789 gives checksum != 1
        with pytest.raises(ValueError, match="NIP"):
            KSeFClient(nip="1234567891", environment="test")

    def test_nip_all_zeros(self):
        """NIP 0000000000 satisfies checksum (0 % 11 == 0) and should not raise."""
        with KSeFClient(nip="0000000000", environment="test"):
            pass


# ---------------------------------------------------------------------------
# Sanityzacja nazw plikow
# ---------------------------------------------------------------------------

class TestFilenameSanitization:
    """Tests for filename sanitization logic (replicated from _download_all_invoices)."""

    def test_sanitize_normal(self):
        """Alphanumeric KSeF number with dashes passes through unchanged."""
        result = _sanitize_ksef_name("1234567890-20260315-ABC")
        assert result == "1234567890-20260315-ABC"

    def test_sanitize_slashes(self):
        """Forward and backward slashes are replaced with underscores."""
        result = _sanitize_ksef_name("NIP/2026/INV")
        assert result == "NIP_2026_INV"

    def test_sanitize_windows_chars(self):
        """All Windows-forbidden characters are replaced with underscores."""
        result = _sanitize_ksef_name('<>:"|?*')
        assert result == "_______"

    def test_sanitize_path_traversal(self):
        """Double dots used for path traversal are replaced with double underscores."""
        result = _sanitize_ksef_name("../../etc/passwd")
        # Step 1: re.sub replaces '/' with '_' → '.._.._etc_passwd'
        # Step 2: str.replace('..', '__') left-to-right:
        #   '..' at 0-1 → '__', then '_' at 2, then '..' at 3-4 → '__', then '_etc_passwd'
        #   result: '__' + '_' + '__' + '_' + 'etc' + '_passwd' = '______etc_passwd'
        assert result == "______etc_passwd"

    def test_sanitize_long_name(self):
        """Names longer than 200 characters are truncated to 200."""
        long_name = "A" * 300
        result = _sanitize_ksef_name(long_name)
        assert len(result) == 200
        assert result == "A" * 200

    def test_sanitize_null_bytes(self):
        """Null bytes and other control characters are replaced with underscores."""
        result = _sanitize_ksef_name("\x00\x01")
        assert result == "__"


# ---------------------------------------------------------------------------
# Szyfrowanie AES-256-GCM
# ---------------------------------------------------------------------------

class TestAESEncryption:
    """Tests for AES-256-GCM encrypt/decrypt roundtrip."""

    def test_aes_roundtrip(self, tmp_path):
        """Encrypt then decrypt returns the original plaintext."""
        key_file = str(tmp_path / ".aes_key")
        generate_aes_key(key_file)

        original = "tajnehaslo123"
        encrypted = encrypt_password(original, key_file)
        decrypted = decrypt_password(encrypted, key_file)

        assert decrypted == original

    def test_aes_roundtrip_unicode(self, tmp_path):
        """Encrypt/decrypt correctly handles Polish Unicode characters."""
        key_file = str(tmp_path / ".aes_key")
        generate_aes_key(key_file)

        original = "Zażółć gęślą jaźń"
        encrypted = encrypt_password(original, key_file)
        decrypted = decrypt_password(encrypted, key_file)

        assert decrypted == original

    def test_aes_roundtrip_special(self, tmp_path):
        """Encrypt/decrypt correctly handles special ASCII characters."""
        key_file = str(tmp_path / ".aes_key")
        generate_aes_key(key_file)

        original = "p@$$w0rd!#%^&*()"
        encrypted = encrypt_password(original, key_file)
        decrypted = decrypt_password(encrypted, key_file)

        assert decrypted == original

    def test_aes_wrong_key(self, tmp_path):
        """Decrypting with a different key raises an exception."""
        key_file_a = str(tmp_path / ".aes_key_a")
        key_file_b = str(tmp_path / ".aes_key_b")
        generate_aes_key(key_file_a)
        generate_aes_key(key_file_b)

        encrypted = encrypt_password("sekret", key_file_a)

        with pytest.raises(Exception):
            decrypt_password(encrypted, key_file_b)

    def test_aes_invalid_key_size(self, tmp_path):
        """A key file with fewer than 32 bytes raises ValueError."""
        key_file = str(tmp_path / ".aes_key_short")
        Path(key_file).write_bytes(b"\x00" * 16)  # 16 bytes instead of 32

        with pytest.raises(ValueError, match="32"):
            encrypt_password("haslo", key_file)

    def test_aes_tampered_ciphertext(self, tmp_path):
        """Decrypting a tampered ciphertext raises an exception (GCM tag mismatch)."""
        key_file = str(tmp_path / ".aes_key")
        generate_aes_key(key_file)

        encrypted = encrypt_password("haslo", key_file)

        # Decode, flip a byte in the ciphertext region (after 12-byte nonce), re-encode
        raw = bytearray(base64.b64decode(encrypted))
        raw[12] ^= 0xFF  # flip first byte of ciphertext
        tampered = base64.b64encode(bytes(raw)).decode("ascii")

        with pytest.raises(Exception):
            decrypt_password(tampered, key_file)
