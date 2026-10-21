r"""Shared Validation Library

Write validation rules ONCE in Python, use on BOTH:
- Django/FastAPI backend (Python)
- Browser frontend (compiled to JavaScript)

This eliminates the duplication of validation logic across frontend and backend.

Ported from sandbox/prescrypt/demos/validation-library/src/validators.py.
Two adjustments for the nanopython build of MicroPython:
  - `from __future__ import annotations` removed (not bundled).
  - `re` use replaced by small hand-rolled character checks — the nanopython
    port doesn't enable `MICROPY_PY_RE`. The original regexes were:
      EMAIL_PATTERN = r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    which is easier to express directly with `str` operations.
"""


# ============================================================================
# Core Validation Result
# ============================================================================


class ValidationResult:
    """Result of a validation check."""

    def __init__(self, is_valid: bool, errors: list = None):
        self.is_valid = is_valid
        self.errors = errors or []

    def __bool__(self):
        return self.is_valid

    @staticmethod
    def ok():
        return ValidationResult(True, [])

    @staticmethod
    def error(message: str):
        return ValidationResult(False, [message])

    @staticmethod
    def errors(messages: list):
        return ValidationResult(False, messages)

    def merge(self, other):
        """Merge two validation results."""
        return ValidationResult(
            self.is_valid and other.is_valid, self.errors + other.errors
        )


# ============================================================================
# String Validators
# ============================================================================


def validate_required(value: str, field_name: str = "Field") -> ValidationResult:
    """Check that a value is not empty."""
    if not value or not value.strip():
        return ValidationResult.error(f"{field_name} is required")
    return ValidationResult.ok()


def validate_min_length(
    value: str, min_len: int, field_name: str = "Field"
) -> ValidationResult:
    """Check minimum string length."""
    if len(value) < min_len:
        return ValidationResult.error(
            f"{field_name} must be at least {min_len} characters"
        )
    return ValidationResult.ok()


def validate_max_length(
    value: str, max_len: int, field_name: str = "Field"
) -> ValidationResult:
    """Check maximum string length."""
    if len(value) > max_len:
        return ValidationResult.error(
            f"{field_name} must be at most {max_len} characters"
        )
    return ValidationResult.ok()


# ============================================================================
# Email Validation
# ============================================================================

LOCAL_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-"
DOMAIN_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
TLD_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


def _all_in(value: str, allowed: str) -> bool:
    for c in value:
        if c not in allowed:
            return False
    return True


def validate_email(email: str) -> ValidationResult:
    """Validate email address format.

    Equivalent to: ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$
    """
    result = validate_required(email, "Email")
    if not result:
        return result

    if "@" not in email:
        return ValidationResult.error("Email must contain @")

    parts = email.split("@")
    if len(parts) != 2:
        return ValidationResult.error("Please enter a valid email address")
    local, domain_full = parts[0], parts[1]

    if not local or not _all_in(local, LOCAL_ALLOWED):
        return ValidationResult.error("Please enter a valid email address")

    if "." not in domain_full or not _all_in(domain_full, DOMAIN_ALLOWED):
        return ValidationResult.error("Please enter a valid email address")

    # TLD must be at least 2 alphabetic chars
    tld = domain_full.rsplit(".", 1)[-1]
    if len(tld) < 2 or not _all_in(tld, TLD_ALLOWED):
        return ValidationResult.error("Please enter a valid email address")

    # Check for common typos
    domain = domain_full.lower()
    typo_domains = {
        "gmial.com": "gmail.com",
        "gmal.com": "gmail.com",
        "gamil.com": "gmail.com",
        "hotmal.com": "hotmail.com",
        "yaho.com": "yahoo.com",
    }
    if domain in typo_domains:
        suggestion = typo_domains[domain]
        return ValidationResult.error(f"Did you mean @{suggestion}?")

    return ValidationResult.ok()


# ============================================================================
# Password Validation
# ============================================================================


def validate_password(password: str) -> ValidationResult:
    """Validate password strength."""
    errors = []

    if len(password) < 8:
        errors.append("Password must be at least 8 characters")

    if not any(c.isupper() for c in password):
        errors.append("Password must contain an uppercase letter")

    if not any(c.islower() for c in password):
        errors.append("Password must contain a lowercase letter")

    if not any(c.isdigit() for c in password):
        errors.append("Password must contain a number")

    special_chars = "!@#$%^&*()_+-=[]{}|;:,.<>?"
    if not any(c in special_chars for c in password):
        errors.append("Password must contain a special character")

    if errors:
        return ValidationResult.errors(errors)
    return ValidationResult.ok()


# ============================================================================
# Phone Number Validation
# ============================================================================


def validate_phone(phone: str) -> ValidationResult:
    """Validate phone number format."""
    cleaned = (
        phone.replace(" ", "")
        .replace("-", "")
        .replace("(", "")
        .replace(")", "")
        .replace("+", "")
    )

    if not cleaned.isdigit():
        return ValidationResult.error("Phone number must contain only digits")

    if len(cleaned) < 10:
        return ValidationResult.error("Phone number must be at least 10 digits")

    if len(cleaned) > 15:
        return ValidationResult.error("Phone number is too long")

    return ValidationResult.ok()


# ============================================================================
# Credit Card Validation
# ============================================================================


def validate_credit_card(card_number: str) -> ValidationResult:
    """Validate credit card number using Luhn algorithm."""
    cleaned = card_number.replace(" ", "").replace("-", "")

    if not cleaned.isdigit():
        return ValidationResult.error("Card number must contain only digits")

    if len(cleaned) < 13 or len(cleaned) > 19:
        return ValidationResult.error("Invalid card number length")

    # Luhn algorithm
    digits = [int(d) for d in cleaned]
    odd_digits = digits[-1::-2]
    even_digits = digits[-2::-2]

    checksum = sum(odd_digits)
    for d in even_digits:
        doubled = d * 2
        if doubled > 9:
            doubled -= 9
        checksum += doubled

    if checksum % 10 != 0:
        return ValidationResult.error("Invalid card number")

    return ValidationResult.ok()
