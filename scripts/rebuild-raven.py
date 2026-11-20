#!/usr/bin/env python3
"""Rebuild the pinned Raven fork. Requires Rust >=1.96 and Cargo registry access/cache."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cargo', default='cargo')
parser.add_argument('--work', type=Path, required=True, help='New disposable build directory')
parser.add_argument('--prepare-only', action='store_true')
args = parser.parse_args()
archive = ROOT / 'ThirdParty/LanguageTools/raven-0.21.1-source.tar.gz'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == '97cdfa9d19cfba51b46cd76ee793f566313a29bb275f81a2b911dbdde6270330'
work = args.work.resolve()
work.mkdir(parents=True, exist_ok=False)
with tarfile.open(archive) as source:
    for member in source.getmembers():
        assert (work / member.name).resolve().is_relative_to(work)
        if member.issym() or member.islnk():
            assert not Path(member.linkname).is_absolute()
    source.extractall(work)
source = work / 'raven-0.21.1'
with (ROOT / 'ThirdParty/LanguageTools/Raven-0.21.1.patch').open('rb') as patch:
    subprocess.run(['patch', '-p1', '--batch'], cwd=source, stdin=patch, check=True)
if args.prepare_only:
    print(source)
else:
    env = dict(os.environ, CARGO_PROFILE_RELEASE_STRIP='none',
               CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP='none', MACOSX_DEPLOYMENT_TARGET='14.0')
    subprocess.run([args.cargo, 'build', '--locked', '--release', '-j', '2', '-p', 'raven'], cwd=source, env=env, check=True)
    arch = os.uname().machine
    assert arch in ('arm64', 'x86_64')
    output = ROOT / ('DesktopApp/Resources/LanguageTools/raven-' + arch)
    shutil.copy2(source / 'target/release/raven', output)
    subprocess.run(['codesign', '--force', '--sign', '-', str(output)], check=True)
    print('Rebuilt', output, '; review/update manifest.sha256 before accepting.')
