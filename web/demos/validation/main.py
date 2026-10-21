"""Validation demo — Python-dominant, persistent-wasm + bridge callbacks.

J5b: One wasm instance per page load. main.py wires Python event handlers
into the DOM via `js.document.getElementById(...).addEventListener(...)`.
After main.py returns the wasm instance stays alive (the JS bridge holds
`wasmExports`) so the registered Python handlers keep firing on each
blur / click for the lifetime of the page.

The validators are still inlined (rather than imported from
validators.py) because `sys.path.insert + from X import` traps under the
browser's wasi-shim filesystem — same gotcha documented in the J4 commit
trail.
"""

import js

# ============================================================================
# Core Validation Result (inlined from validators.py)
# ============================================================================


class ValidationResult:
    """Result of a validation check."""

    def __init__(self, is_valid, errors=None):
        self.is_valid = is_valid
        self.errors = errors or []

    def __bool__(self):
        return self.is_valid

    @staticmethod
    def ok():
        return ValidationResult(True, [])

    @staticmethod
    def error(message):
        return ValidationResult(False, [message])

    @staticmethod
    def errors(messages):
        return ValidationResult(False, messages)


# ============================================================================
# String Validators
# ============================================================================


def validate_required(value, field_name="Field"):
    if not value or not value.strip():
        return ValidationResult.error(f"{field_name} is required")
    return ValidationResult.ok()


# ============================================================================
# Email Validation
# ============================================================================

LOCAL_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-"
DOMAIN_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
TLD_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


def _all_in(value, allowed):
    for c in value:
        if c not in allowed:
            return False
    return True


def validate_email(email):
    """Validate email address format."""
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

    tld = domain_full.rsplit(".", 1)[-1]
    if len(tld) < 2 or not _all_in(tld, TLD_ALLOWED):
        return ValidationResult.error("Please enter a valid email address")

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


def validate_password(password):
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


def validate_phone(phone):
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


def validate_credit_card(card_number):
    """Validate credit card number using Luhn algorithm."""
    cleaned = card_number.replace(" ", "").replace("-", "")

    if not cleaned.isdigit():
        return ValidationResult.error("Card number must contain only digits")

    if len(cleaned) < 13 or len(cleaned) > 19:
        return ValidationResult.error("Invalid card number length")

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


FIELDS = [
    ("email", validate_email),
    ("password", validate_password),
    ("phone", validate_phone),
    ("card", validate_credit_card),
]


# ============================================================================
# DOM helpers — bridged through `js`
# ============================================================================


def _has_class(el, name):
    """`name in el.classList`, expressed through the bridge.

    `in` is not wired on JsProxy (no __contains__), so we drive the DOM's
    DOMTokenList.contains() method directly and coerce the JS boolean to a
    Python int via `.to_int()`.
    """
    return el.classList.contains(name).to_int() != 0


def validate_field(field_id):
    el = js.document.getElementById(field_id)
    value = el.value.to_str()
    err_el = js.document.getElementById(field_id + "-error")

    fn = None
    for fid, f in FIELDS:
        if fid == field_id:
            fn = f
            break
    if fn is None:
        return

    if not value:
        el.classList.remove("ok")
        el.classList.remove("err")
        err_el.textContent = ""
        return

    result = fn(value)
    if result.is_valid:
        el.classList.add("ok")
        el.classList.remove("err")
        err_el.textContent = "OK"
    else:
        el.classList.add("err")
        el.classList.remove("ok")
        err_el.textContent = " / ".join(result.errors)


def make_blur_handler(fid):
    """Closure factory — the per-field `fid` is captured so the same handler
    body works for any field. Each closure is registered once on page load."""

    def handler(event=None):
        validate_field(fid)

    return handler


# Wire up on-blur validation for every field.
for field_id, _fn in FIELDS:
    el = js.document.getElementById(field_id)
    el.addEventListener("blur", make_blur_handler(field_id))


def validate_all_handler(event=None):
    invalid = 0
    empty = 0
    for fid, _fn in FIELDS:
        el = js.document.getElementById(fid)
        if not el.value.to_str():
            empty += 1
            continue
        validate_field(fid)
        if _has_class(el, "err"):
            invalid += 1

    status = js.document.getElementById("status")
    if invalid == 0 and empty == 0:
        status.textContent = "All fields valid"
        status.classList.add("ok")
        status.classList.remove("err")
    elif invalid > 0:
        status.textContent = str(invalid) + " field(s) need attention"
        status.classList.add("err")
        status.classList.remove("ok")
    else:
        status.textContent = "Fill in the form and click Validate"
        status.classList.remove("ok")
        status.classList.remove("err")


# Wire up the Validate button (now Python-driven, not JS-driven).
btn = js.document.getElementById("validate-btn")
btn.addEventListener("click", validate_all_handler)

# main.py finishes here. The wasm instance stays alive because the JS
# bridge holds `wasmExports`; the addEventListener-registered handlers
# remain callable for the lifetime of the page.
