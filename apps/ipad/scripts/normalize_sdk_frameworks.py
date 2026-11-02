#!/usr/bin/env python3
"""Align Xcode's empty static-SDK resource stubs with the app deployment target."""

import os
from pathlib import Path
import plistlib
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True)


def version(value):
    return tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))


def build_version(binary):
    output = run("xcrun", "vtool", "-show-build", str(binary))
    minimum = re.search(r"^\s+minos (\S+)$", output, re.MULTILINE)
    sdk = re.search(r"^\s+sdk (\S+)$", output, re.MULTILINE)
    if not minimum or not sdk or "platform IOS\n" not in output:
        raise RuntimeError(f"Expected an iOS LC_BUILD_VERSION: {binary}")
    return minimum[1], sdk[1]


def main():
    if not os.environ["SDK_NAME"].startswith("iphoneos"):
        return
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    target = os.environ["IPHONEOS_DEPLOYMENT_TARGET"]
    # These SDKs are statically linked. Their embedded frameworks retain resources
    # and privacy manifests; Xcode injects empty dylibs for App Store packaging.
    for name in ("onnxruntime", "FirebaseAnalytics", "GoogleAppMeasurement", "UserMessagingPlatform"):
        framework = app / "Frameworks" / f"{name}.framework"
        plist_path = framework / "Info.plist"
        original_plist = plist_path.read_bytes()
        info = plistlib.loads(original_plist)
        binary = framework / info["CFBundleExecutable"]
        minimum, sdk = build_version(binary)
        if version(minimum) == version(info["MinimumOSVersion"]) and version(minimum) <= version(target):
            continue

        # Never lower the requirement of actual SDK code. Only empty generated
        # stubs (zero symbols and no nonempty sections) can be repaired here.
        commands = run("xcrun", "otool", "-l", str(binary))
        sections = re.findall(r"Section\n(.*?)(?=Load command|Section|\Z)", commands, re.DOTALL)
        if not re.search(r"\bnsyms 0\b", commands) or not sections:
            raise RuntimeError(f"Refusing to modify nonempty SDK binary: {binary}")
        if any(int(re.search(r"^\s+size (0x[0-9a-fA-F]+)$", section, re.MULTILINE)[1], 16) for section in sections):
            raise RuntimeError(f"Refusing to modify SDK sections: {binary}")

        if version(minimum) != version(target):
            output = binary.with_name(binary.name + ".deployment-fixed")
            subprocess.run(["xcrun", "vtool", "-set-build-version", "ios", target, sdk,
                            "-replace", "-output", str(output), str(binary)], check=True)
            output.chmod(binary.stat().st_mode)
            output.replace(binary)
        info["MinimumOSVersion"] = target
        plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY if original_plist.startswith(b"bplist") else plistlib.FMT_XML))
        if os.environ.get("CODE_SIGNING_ALLOWED") == "YES":
            identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY")
            if not identity:
                raise RuntimeError("Missing framework signing identity")
            subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(framework)], check=True)
        print(f"Aligned empty {name} resource stub and MinimumOSVersion to iOS {target}", flush=True)


if __name__ == "__main__":
    main()
