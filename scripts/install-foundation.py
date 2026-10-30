#!/usr/bin/env python3
"""Package already-built upstream products as a separate, local Foundation app."""
import argparse
import datetime
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    products = args.bin_dir.resolve(strict=True)
    apps = Path.home() / "Applications"
    destination = apps / "FCG Foundation.app"
    if destination.exists():
        raise SystemExit("Foundation is already installed; preserve it before replacing this bundle.")
    apps.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".fcg-foundation-", dir=apps) as stage:
        bundle = Path(stage) / destination.name
        macos = bundle / "Contents/MacOS"
        resources = bundle / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        executables = ("Otto", "ottoctl", "otto-mcp", "otto-hermes-bridge",
                       "otto-openai-agent", "otto-hookd", "ottod")
        for name in executables:
            shutil.copy2(products / name, macos / name)
        for name in ("SwiftTerm_SwiftTerm.bundle", "Otto_OttoApp.bundle", "Otto_OttoServices.bundle"):
            shutil.copytree(products / name, resources / name)
        for name in ("LICENSE", "NOTICE"):
            shutil.copy2(repo / name, resources / name)
        shutil.copy2(repo / "packaging/THIRD_PARTY_NOTICES.md", resources)
        info = plistlib.loads((repo / "packaging/Info.dev.plist").read_bytes())
        info.update(CFBundleName="FCG Foundation", CFBundleDisplayName="FCG Foundation",
                    CFBundleIdentifier="com.freshcutgrass.foundation.dev",
                    CFBundleVersion=datetime.datetime.now().strftime("%Y%m%d%H%M%S"))
        # Omit the upstream icon and explicit relay/feedback bundle settings.
        # This does not disable defaults compiled into the upstream runtime.
        for key in ("CFBundleIconFile", "OttoPrivatePhoneURL", "OttoFeedbackURL"):
            info.pop(key, None)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        for name in executables:
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                            str(macos / name)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                        "--entitlements", str(repo / "packaging/Otto.entitlements"),
                        str(bundle)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
        os.rename(bundle, destination)
    print(destination)


if __name__ == "__main__":
    main()
