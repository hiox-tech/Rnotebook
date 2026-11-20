#!/usr/bin/env python3
"""Package the exact retained upstream notices; never rewrite license text."""
from pathlib import Path
import hashlib, json, shutil, argparse
ROOT = Path('DesktopApp/Resources/ThirdPartyNotices')
ENTRIES = [
 ('edmund','Edmund','Apache-2.0','Native Markdown editor','ThirdParty/EdmundCore/LICENSE'),
 ('swift-markdown','swift-markdown','Apache-2.0','Markdown parsing','ThirdParty/Dependencies/swift-markdown/LICENSE.txt'),
 ('swift-markdown-notice','swift-markdown — attribution','Upstream NOTICE','Copyright and attribution','ThirdParty/Dependencies/swift-markdown/NOTICE.txt'),
 ('cmark','cmark','BSD and MIT notices','CommonMark parser','ThirdParty/Dependencies/cmark/COPYING'),
 ('swiftmath','SwiftMath','MIT','Mathematical typesetting','ThirdParty/Dependencies/SwiftMath/LICENSE'),
 ('mathfonts','Math font bundle / MathChat','MIT','Bundled math font resources','ThirdParty/Dependencies/SwiftMath/Sources/SwiftMath/mathFonts.bundle/LICENSE'),
 ('stix','STIX font notice','SIL OFL 1.1','Math font license supplied with SwiftMath','ThirdParty/Dependencies/SwiftMath/Sources/SwiftMath/mathFonts.bundle/OFL.txt'),
 ('gust','GUST math fonts','GUST Font License','Latin Modern and TeX Gyre fonts','ThirdParty/Dependencies/SwiftMath/Sources/SwiftMath/mathFonts.bundle/GUST-FONT-LICENSE.txt'),
 ('tree-sitter','Tree-sitter 0.25.10','MIT','Incremental syntax parsing','ThirdParty/LanguageTools/TreeSitter/LICENSE'),
 ('tree-sitter-r','tree-sitter-r','MIT','R syntax grammar','ThirdParty/LanguageTools/TreeSitter/r/LICENSE'),
 ('tree-sitter-markdown','tree-sitter-markdown 0.5.3','MIT','Markdown syntax grammar','ThirdParty/LanguageTools/TreeSitter/MARKDOWN-LICENSE'),
 ('unicode','Unicode data (Tree-sitter)','Unicode license','Character classification','ThirdParty/LanguageTools/TreeSitter/lib/src/unicode/LICENSE'),
 ('air','Air 0.13.0','MIT','R code formatting','DesktopApp/Resources/LanguageTools/AIR-LICENSE'),
 ('raven','Raven 0.21.1 (locally patched)','GPL-3.0','R completion language server','DesktopApp/Resources/LanguageTools/RAVEN-LICENSE'),
 ('beautiful-mermaid','beautiful-mermaid 1.1.3','MIT','Native diagram rendering assets','DesktopApp/Resources/RecordPreviewAssets/Mermaid/licenses/LICENSE-beautiful-mermaid'),
 ('elkjs','elkjs','EPL-2.0','Diagram layout','DesktopApp/Resources/RecordPreviewAssets/Mermaid/licenses/LICENSE-elkjs'),
 ('entities','entities','BSD-2-Clause','Diagram text decoding','DesktopApp/Resources/RecordPreviewAssets/Mermaid/licenses/LICENSE-entities'),
]
def manifest():
 return [dict(id=i,name=n,license=l,purpose=p,file=i+'.txt',source=s,sha256=hashlib.sha256(Path(s).read_bytes()).hexdigest()) for i,n,l,p,s in ENTRIES]
def verify():
 try:
  entries=manifest()
  return json.loads((ROOT/'index.json').read_text())==entries and all((ROOT/e['file']).read_bytes()==Path(e['source']).read_bytes() for e in entries)
 except (OSError,ValueError): return False
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
 if args.check:
  if not verify():raise SystemExit('Third-party notices stale; run scripts/generate-third-party-notices.py')
 else:
  ROOT.mkdir(parents=True,exist_ok=True)
  for e in manifest():shutil.copyfile(e['source'],ROOT/e['file'])
  (ROOT/'index.json').write_text(json.dumps(manifest(),ensure_ascii=False,indent=2)+'\n')
 if not verify():raise SystemExit('Third-party notice verification failed')
 print(f'Verified {len(ENTRIES)} exact upstream third-party notices')
