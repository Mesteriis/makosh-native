#!/usr/bin/env python3
"""Publish a verified staged app, preserving the previous app on failure."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid


def publish(stage: Path, destination: Path):
    if stage.is_symlink() or destination.is_symlink() or stage == destination:
        raise ValueError('App paths must be distinct owned directories')
    if stage.suffix != '.app' or destination.suffix != '.app' or not stage.is_dir():
        raise ValueError('Expected app bundles')
    if stage.stat().st_dev != destination.parent.stat().st_dev:
        raise ValueError('Stage and destination must share a filesystem')
    identity = plistlib.loads((stage / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
    if not identity:
        raise ValueError('Staged app has no bundle identity')
    if destination.exists():
        previous = plistlib.loads((destination / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
        if previous != identity:
            raise ValueError('Refusing to replace a different app')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage)], check=True, capture_output=True)
    backup = destination.with_name(destination.name + '.previous-' + uuid.uuid4().hex)
    had_previous = destination.exists()
    if had_previous:
        os.replace(destination, backup)
    try:
        os.replace(stage, destination)
    except BaseException:
        if had_previous:
            os.replace(backup, destination)
        raise
    if had_previous:
        shutil.rmtree(backup)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    publish(args.stage.absolute(), args.destination.absolute())
