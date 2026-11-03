"""Reject inconsistent tracking declarations before signing an iOS app."""

from pathlib import Path
import plistlib
import re
import sys


def validate(path):
    data = plistlib.loads(Path(path).read_bytes())
    tracking = data.get("NSPrivacyTracking", False)
    domains = data.get("NSPrivacyTrackingDomains", [])
    if type(tracking) is not bool:
        raise ValueError(f"{path}: NSPrivacyTracking must be a Boolean")
    if not isinstance(domains, list) or any(not isinstance(item, str) for item in domains):
        raise ValueError(f"{path}: NSPrivacyTrackingDomains must be an array of domain strings")
    if tracking != bool(domains):
        raise ValueError(f"{path}: tracking must be true exactly when tracking domains are nonempty (ITMS-91064)")
    for domain in domains:
        if not re.fullmatch(r"(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}", domain):
            raise ValueError(f"{path}: invalid tracking domain {domain!r}; use a hostname without a URL scheme or path")
    return {"path": str(path), "tracking": tracking, "domains": domains}


def validate_bundle(path):
    root = Path(path)
    manifests = [root] if root.is_file() else sorted(root.rglob("PrivacyInfo.xcprivacy"))
    if not manifests:
        raise ValueError(f"{root}: no privacy manifests found")
    return [validate(manifest) for manifest in manifests]


if __name__ == "__main__":
    try:
        results = validate_bundle(sys.argv[1])
    except (ValueError, OSError, IndexError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"error: {error}")
    print(f"Validated tracking declarations in {len(results)} privacy manifests")
