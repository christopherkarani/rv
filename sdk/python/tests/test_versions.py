"""Semver-major port, skew checks, and product floors (``sdk/VERSIONING.md``)."""

from __future__ import annotations

import pytest

from rv import versions
from rv.errors import MajorVersionSkew, RuntimeTooOld


def test_major_of_valid():
    assert versions.major_of("1.0.0") == 1
    assert versions.major_of("1") == 1
    assert versions.major_of("007.2") == 7
    assert versions.major_of("2147483647.0.0") == 2147483647
    assert versions.major_of("1.0.0-rc1") == 1


def test_major_of_misses():
    assert versions.major_of("") is None
    assert versions.major_of(".1.2") is None
    assert versions.major_of("+1") is None
    assert versions.major_of("-0") is None
    assert versions.major_of("x.y") is None
    assert versions.major_of("1" * 16) is None
    assert versions.major_of("2147483648") is None
    # Non-ASCII digits are not digits.
    assert versions.major_of("١٢٣") is None
    assert versions.major_of("1٢") is None


def test_fifteen_digit_overflow_is_none():
    assert versions.major_of("9" * 15) is None
    assert versions.major_of("2147483647") == 2147483647


def test_is_major_skew_only_on_parsed_mismatch():
    assert versions.is_major_skew("1.0.0", "1.2.3") is False
    assert versions.is_major_skew("1.0.0", "2.0.0") is True
    # Unparseable input is not skew (fail-open helper; fail-closed callers
    # check major_of for None separately).
    assert versions.is_major_skew("garbage", "1.0.0") is False
    assert versions.is_major_skew("1.0.0", "garbage") is False
    assert versions.is_major_skew("", "") is False


def test_check_compatible_accepts_equal_majors():
    versions.check_compatible("1.0.0", "1.9.9")
    versions.check_compatible("1.0.0", "1")


def test_check_compatible_rejects_skew_and_garbage():
    for client, service in [
        ("1.0.0", "2.0.0"),
        ("2.0.0", "1.0.0"),
        ("1.0.0", None),
        ("1.0.0", ""),
        ("1.0.0", "garbage"),
        ("garbage", "1.0.0"),
        ("", ""),
    ]:
        with pytest.raises(MajorVersionSkew) as info:
            versions.check_compatible(client, service)
        assert info.value.client_semver == client
        assert info.value.service_semver == service


def test_product_floor():
    assert versions.product_at_least("0.1.5") is True
    assert versions.product_at_least("0.1.6") is True
    assert versions.product_at_least("0.2.0") is True
    assert versions.product_at_least("1.0.0") is True
    assert versions.product_at_least("0.1.4") is False
    assert versions.product_at_least("0.0.9") is False
    assert versions.product_at_least("garbage") is False
    assert versions.product_at_least("") is False
    assert versions.product_at_least("1.2") is False
    assert versions.product_at_least("1.0.0-rc1", "1.0.0") is True
    versions.check_product_floor("0.1.5")
    with pytest.raises(RuntimeTooOld) as info:
        versions.check_product_floor("0.1.4")
    assert info.value.minimum == "0.1.5"
    assert info.value.found == "0.1.4"
