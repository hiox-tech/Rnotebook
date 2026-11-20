#!/usr/bin/env python3
"""Launch a separate debug bundle against generated fixtures only."""
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
evidence = root / '.local/validation/feature-completion-2026-11-07/ui'
app = evidence / 'Rnotebook-Acceptance.app'
source = root / '.build/Rnotebook/Build/Products/Debug/Rnotebook.app'
if app.exists():
    archived = evidence / ('Rnotebook-Acceptance-previous-' + str(len(list(evidence.glob('Rnotebook-Acceptance-previous-*')))) + '.app')
    app.rename(archived)
shutil.copytree(source, app, symlinks=True)
info = app / 'Contents/Info.plist'
with info.open('rb') as stream:
    data = plistlib.load(stream)
data['CFBundleIdentifier'] = 'org.hiox.Rnotebook.Acceptance'
data['CFBundleDisplayName'] = 'Rnotebook Acceptance'
with info.open('wb') as stream:
    plistlib.dump(data, stream)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['/usr/bin/open', '-n', '--env', 'RNOTEBOOK_VALIDATION_ROOT=' + str(evidence / 'support'),
                '-a', str(app), str(evidence / 'Acceptance-A.qmd'), str(evidence / 'Acceptance-B.qmd')], check=True)
print('Launched isolated acceptance bundle:', app)
