#!/usr/bin/env python3
"""Check immutable upstream, inherited v14 patches and explicit Rnotebook pruning."""
import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parent.parent/'ThirdParty/EdmundCore'
base=json.loads((root/'SOURCE-HASHES.json').read_text())
prior=json.loads((root/'LOCAL-PATCHES.json').read_text())
pruning=json.loads((root/'RNOTEBOOK-PRUNING.json').read_text())
host=json.loads((root/'RNOTEBOOK-HOST-PATCHES.json').read_text())
removed=pruning['removed'];modified=pruning['modified'];patches=prior['files']
assert patches.keys() <= base.keys()
assert removed.keys() <= base.keys() and modified.keys() <= base.keys()
assert not (removed.keys() & modified.keys())
for name,upstream in base.items():
 patch=patches.get(name)
 if patch: assert patch['upstreamSHA256']==upstream,name
 expected=patch['patchedSHA256'] if patch else upstream
 path=root/'Sources/EdmundCore'/name
 if name in removed:
  assert removed[name]['beforeSHA256']==expected,name
  assert not path.exists(),f'Removed source reintroduced: {name}'
  continue
 if name in modified:
  assert modified[name]['beforeSHA256']==expected,name
  expected=modified[name]['prunedSHA256']
 if name in host['modified']:
  assert host['modified'][name]['beforeSHA256']==expected,name
  expected=host['modified'][name]['patchedSHA256']
 assert path.is_file(),f'Missing retained source: {name}'
 assert hashlib.sha256(path.read_bytes()).hexdigest()==expected,f'Unrecorded change: {name}'
actual={str(p.relative_to(root/'Sources/EdmundCore')) for p in (root/'Sources/EdmundCore').rglob('*') if p.is_file()}
assert actual==base.keys()-removed.keys(),f'Unexpected source inventory: {actual ^ (base.keys()-removed.keys())}'
assert host['modified'].keys() <= base.keys()-removed.keys()
for patch in [prior['patch'],pruning['patch'],host['patch']]:assert (root/patch).is_file(),patch
for p in (root/'Sources/EdmundCore').rglob('*.swift'):
 for line in p.read_text().splitlines():
  assert not line.strip().startswith(('import WebKit','import MetricKit')),str(p)
  assert 'WKWebView(' not in line,str(p)
print(f'PASS {len(actual)} retained files; {len(removed)} reviewed removals; {len(modified)} pruning edits; original baseline and v14 preserved')
