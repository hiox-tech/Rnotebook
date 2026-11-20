#!/usr/bin/env python3
"""Build/check the local Apple Help book from the app's reviewed Markdown help.

No Quarto/R/network/Python packages required. The renderer intentionally supports
only the Markdown constructs used in these bundled articles, escaping all HTML.
Apple's hiutil creates both native search indices; normal unchanged builds only
check the source and generated-file hashes.
"""
from pathlib import Path
import argparse, hashlib, html, json, plistlib, re, shutil, subprocess
from urllib.parse import urlparse

SOURCE = Path('DesktopApp/Resources/Help')
BOOK = Path('DesktopApp/Resources/Rnotebook.help')
BOOK_ID = 'org.hiox.Rnotebook.help'
TOPICS = {
 'overview': ('认识 Rnotebook', 'Meet Rnotebook'),
 'components': ('组件与环境', 'Components and Environment'),
 'interface': ('界面导览', 'Interface Tour'),
 'r-basics': ('R 基础', 'R Basics'),
 'quarto-basics': ('Quarto 与 QMD 基础', 'Quarto and QMD Basics'),
 'quick-start': ('快速开始', 'Quick Start'),
 'syntax': ('Quarto语法', 'Quarto Syntax'),
 'editing': ('编辑与资源', 'Editing and Resources'),
 'r-export': ('R 运行与报告导出', 'Running R and Rendering'),
 'files': ('保存、恢复与设置', 'Saving, Recovery and Settings'),
 'shortcuts': ('快捷键速查', 'Keyboard Shortcuts'),
}
CSS = '''
:root{color-scheme:light dark;--bg:#fff;--fg:#242426;--sub:#66666b;--panel:#f4f4f6;--line:#dedee3;--link:#006bd6}
@media(prefers-color-scheme:dark){:root{--bg:#1f2022;--fg:#eeeeef;--sub:#b0b0b5;--panel:#2c2d30;--line:#45464b;--link:#7eb8ff}}
figure{margin:22px 0}figure img{display:block;width:100%;height:auto;border:1px solid var(--line);border-radius:8px}figcaption{font-size:12px;color:var(--sub);margin-top:8px}*{box-sizing:border-box}html{scroll-padding-top:22px}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.75 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:900px;margin:auto;padding:28px 38px 48px}h1{font-size:30px;line-height:1.25;letter-spacing:-.025em;margin:18px 0 22px}h2{font-size:20px;line-height:1.4;margin:32px 0 12px}h3{font-size:17px}p,ul,ol{margin:12px 0}li+li{margin-top:5px}a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}a:focus-visible{outline:3px solid var(--link);outline-offset:3px}
nav{font-size:13px;color:var(--sub);border-bottom:1px solid var(--line);padding-bottom:14px}nav ol{columns:2;padding-left:24px}nav li{break-inside:avoid}code{font:12.5px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--panel);padding:2px 5px;border-radius:4px}pre{overflow:auto;background:var(--panel);padding:16px 18px;border:1px solid var(--line);border-radius:8px;tab-size:2}pre code{padding:0;white-space:pre;background:transparent}blockquote{margin:16px 0;padding:2px 18px;border-left:3px solid var(--line);color:var(--sub)}.table-scroll{overflow-x:auto;margin:18px 0}table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top;text-align:left}th{background:var(--panel)}td code{white-space:normal;overflow-wrap:anywhere}hr{border:0;border-top:1px solid var(--line);margin:24px 0}footer{border-top:1px solid var(--line);margin-top:36px;padding-top:16px;font-size:13px}.book-icon{width:64px;height:64px;float:left;margin:0 18px 12px 0}.topics{list-style:none;padding:0}.topics li{padding:14px 0;border-bottom:1px solid var(--line)}.topics a{font-size:18px;font-weight:600}
@media(max-width:600px){main{padding:20px 22px 36px}nav ol{columns:1}h1{font-size:26px}}
'''


def sha(path):
 return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
 # Repository-relative: the generated Source.json is also shipped in public
 # builds and must not embed the builder's absolute checkout path.
 paths = [Path('scripts/generate-help-book.py'), Path('DesktopApp/Resources/Rnotebook.icns')]
 paths += sorted(SOURCE.rglob('*.md')) + sorted((SOURCE/'images').glob('*.png'))
 return {str(p):sha(p) for p in paths}


def target_url(raw):
 parsed=urlparse(raw)
 if parsed.scheme=='rnotebook-help':
  slug=parsed.path.lstrip('/')
  if parsed.netloc!='article' or slug not in TOPICS or parsed.query:
   raise ValueError('Unknown local help link: '+raw)
  return slug+'.html'+('#'+parsed.fragment if parsed.fragment else '')
 if parsed.scheme=='https' and parsed.netloc and not parsed.username and not parsed.password:
  return raw
 if raw.startswith('#'):
  return raw
 raise ValueError('Unexpected help link: '+raw)


def inline(text):
 # Protect literal code/link fragments before processing surrounding emphasis.
 values=[]
 def token(value):
  values.append(value);return '\x00'+str(len(values)-1)+'\x00'
 def code(match):return token('<code>'+html.escape(match.group(2))+'</code>')
 text=re.sub(r'(`+)(.+?)\1',code,text)
 def link(match):
  url=target_url(match.group(2))
  external=' target="_blank" rel="noopener"' if url.startswith('https:') else ''
  return token('<a href="'+html.escape(url,quote=True)+'"'+external+'>'+html.escape(match.group(1))+'</a>')
 text=re.sub(r'\[([^\]]+)\]\(([^)]+)\)',link,text)
 text=html.escape(text)
 text=re.sub(r'\*\*(.+?)\*\*',r'<strong>\1</strong>',text)
 text=re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)',r'<em>\1</em>',text)
 return re.sub('\x00([0-9]+)\x00',lambda m:values[int(m.group(1))],text)


def render(markdown):
 lines=markdown.splitlines();out=[];sections=[];i=0
 def special(line):return bool(not line.strip() or re.match(r'^(#{1,6}) |^`{3,}|^[-*] |^\d+\. |^> |^\||^!\[',line))
 while i<len(lines):
  line=lines[i]
  if not line.strip():i+=1;continue
  fence=re.match(r'^(`{3,})',line)
  if fence:
   delimiter=fence.group(1);i+=1;code=[]
   while i<len(lines) and not re.fullmatch(r'`{'+str(len(delimiter))+r',}\s*',lines[i]):code.append(lines[i]);i+=1
   if i==len(lines):raise ValueError('Unclosed help fence')
   out.append('<pre><code>'+html.escape('\n'.join(code)+'\n')+'</code></pre>');i+=1;continue
  picture=re.fullmatch(r'!\[([^\]]+)\]\((images/[A-Za-z0-9_-]+\.png)\)',line)
  if picture:
   alt,path=picture.groups()
   if not (SOURCE/path).is_file():raise ValueError('Missing help image: '+path)
   out.append('<figure><img src="../'+path+'" alt="'+html.escape(alt,quote=True)+'"><figcaption>'+html.escape(alt)+'</figcaption></figure>');i+=1;continue
  heading=re.match(r'^(#{1,6}) (.+)',line)
  if heading:
   level=len(heading.group(1));title=heading.group(2);anchor='title' if level==1 else 'section-'+str(len(sections))
   if level>1:sections.append((anchor,title))
   out.append(f'<h{level} id="{anchor}">'+inline(title)+f'</h{level}>');i+=1;continue
  if line.startswith('|') and i+1<len(lines) and re.fullmatch(r'[| :\-]+',lines[i+1]):
   rows=[]
   def cells(row):return [part.strip() for part in row.strip().strip('|').split('|')]
   headers=cells(line);i+=2
   while i<len(lines) and lines[i].startswith('|'):rows.append(cells(lines[i]));i+=1
   out.append('<div class="table-scroll"><table><thead><tr>'+''.join('<th>'+inline(c)+'</th>' for c in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+inline(c)+'</td>' for c in row)+'</tr>' for row in rows)+'</tbody></table></div>');continue
  ordered=bool(re.match(r'^\d+\. ',line))
  if ordered or re.match(r'^[-*] ',line):
   tag='ol' if ordered else 'ul';pattern=r'^\d+\. ' if ordered else r'^[-*] ';items=[]
   while i<len(lines) and re.match(pattern,lines[i]):items.append(re.sub(pattern,'',lines[i]));i+=1
   out.append('<'+tag+'>'+''.join('<li>'+inline(x)+'</li>' for x in items)+'</'+tag+'>');continue
  if line.startswith('> '):
   quote=[]
   while i<len(lines) and lines[i].startswith('> '):quote.append(lines[i][2:]);i+=1
   out.append('<blockquote><p>'+inline(' '.join(quote))+'</p></blockquote>');continue
  if line.strip()=='---':out.append('<hr>');i+=1;continue
  paragraph=[line];i+=1
  while i<len(lines) and not special(lines[i]):paragraph.append(lines[i]);i+=1
  out.append('<p>'+inline(' '.join(paragraph))+'</p>')
 return '\n'.join(out),sections


def page(title,body,language,description,anchor,toc=None):
 position=0 if language=='zh-Hans' else 1
 book_title='Rnotebook 帮助' if language=='zh-Hans' else 'Rnotebook Help'
 toc_title='本页内容' if language=='zh-Hans' else 'On this page'
 home='使用手册' if language=='zh-Hans' else 'User Guide'
 current=anchor.removeprefix('rnotebook-')
 navigation='<nav><a href="index.html">'+home+'</a></nav>'
 return '<!doctype html>\n<html lang="'+language+'"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="AppleTitle" content="'+book_title+'"><meta name="description" content="'+html.escape(description,quote=True)+'"><meta name="keywords" content="Rnotebook,Markdown,QMD,RMD"><title>'+html.escape(title)+'</title><link rel="stylesheet" href="../help.css"></head><body>'+navigation+'<main><a name="'+anchor+'" id="'+anchor+'"></a>'+body+'</main></body></html>\n'


def generate():
 resources=BOOK/'Contents/Resources';resources.mkdir(parents=True,exist_ok=True)
 info={'CFBundleIdentifier':BOOK_ID,'CFBundleDevelopmentRegion':'en','CFBundleName':'Rnotebook Help','CFBundlePackageType':'BNDL','CFBundleSignature':'hbwr','CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':'1.0','CFBundleVersion':'4','HPDBookAccessPath':'index.html','HPDBookIndexPath':'search.helpindex','HPDBookCSIndexPath':'search.cshelpindex','HPDBookIconPath':'Rnotebook.icns','HPDBookTitle':'Rnotebook Help','HPDBookType':'3'}
 (BOOK/'Contents/Info.plist').write_bytes(plistlib.dumps(info,sort_keys=True))
 shutil.copyfile('DesktopApp/Resources/Rnotebook.icns',resources/'Rnotebook.icns')
 (resources/'help.css').write_text(CSS)
 shutil.copytree(SOURCE/'images',resources/'images',dirs_exist_ok=True)
 subprocess.run(['/usr/bin/sips','-s','format','png','DesktopApp/Resources/Rnotebook.icns','--out',str(resources/'AppIcon.png')],check=True,stdout=subprocess.DEVNULL)
 for language in ['zh-Hans','en']:
  position=0 if language=='zh-Hans' else 1
  folder=resources/(language+'.lproj');folder.mkdir(exist_ok=True)
  title='Rnotebook 帮助' if language=='zh-Hans' else 'Rnotebook Help'
  (folder/'InfoPlist.strings').write_text('"HPDBookTitle" = '+json.dumps(title,ensure_ascii=False)+';\n"CFBundleName" = '+json.dumps(title,ensure_ascii=False)+';\n')
  for slug,titles in TOPICS.items():
   source=(SOURCE/language/(slug+'.md')).read_text();body,toc=render(source)
   (folder/(slug+'.html')).write_text(page(titles[position],body,language,titles[position],'rnotebook-'+slug,toc))
  heading='Rnotebook 使用手册' if language=='zh-Hans' else 'Rnotebook User Guide'
  lead='在 Mac 上编写 QMD、RMD 笔记，交互运行 R，并使用 Quarto 导出报告。' if language=='zh-Hans' else 'Write QMD and RMD notebooks on your Mac, run R interactively and render reports with Quarto.'
  introduction='Rnotebook 将文字、代码、公式和图形放在一份 Markdown 文档中。每份笔记在独立窗口中编辑，并拥有独立的 R 会话。' if language=='zh-Hans' else 'Rnotebook keeps text, code, formulas and figures in one Markdown document. Each notebook has its own editing window and R session.'
  start='开始使用' if language=='zh-Hans' else 'Get started'
  learn='查阅帮助' if language=='zh-Hans' else 'Explore the guide'
  start_text='按照简易指引完成第一份笔记，或查看语法示例。' if language=='zh-Hans' else 'Follow the quick start to create your first notebook, or explore the syntax examples.'
  learn_text='从左侧目录选择主题。你可以了解编辑操作、运行 R、导出报告，以及保存与恢复。顶部搜索框可查找帮助内容。' if language=='zh-Hans' else 'Choose a topic in the sidebar to learn about editing, running R, rendering reports, saving and recovery. Use the search field above to find help.'
  body='<img class="book-icon" alt="" src="../AppIcon.png"><h1>'+heading+'</h1><p>'+lead+'</p><p>'+introduction+'</p><h2>'+start+'</h2><p>'+start_text+'</p><p><a href="quick-start.html">'+TOPICS['quick-start'][position]+'</a> · <a href="syntax.html">'+TOPICS['syntax'][position]+'</a></p><h2>'+learn+'</h2><p>'+learn_text+'</p>'
  body+='<footer><ul>'+''.join('<li><a href="'+slug+'.html">'+titles[position]+'</a></li>' for slug,titles in TOPICS.items())+'</ul></footer>'
  (folder/'index.html').write_text(page(title,body,language,lead,'rnotebook-home'))
  for fmt,filename in [('lsm','search.helpindex'),('corespotlight','search.cshelpindex')]:
   subprocess.run(['/usr/bin/hiutil','-I',fmt,'-C','-a','-l',language,'-f',str(folder/filename),str(folder)],check=True)
 output={str(p.relative_to(BOOK)):sha(p) for p in sorted(BOOK.rglob('*')) if p.is_file() and p.name!='Source.json'}
 (resources/'Source.json').write_text(json.dumps({'sources':sources(),'files':output},ensure_ascii=False,indent=2)+'\n')
 print(f'Generated Apple Help book:2 languages,{2*len(TOPICS)} articles,2 contents pages,4 native search indices')


def verify():
 manifest=BOOK/'Contents/Resources/Source.json'
 if not manifest.exists():return False
 try:
  data=json.loads(manifest.read_text())
  return data['sources']==sources() and all((BOOK/p).is_file() and sha(BOOK/p)==digest for p,digest in data['files'].items())
 except (KeyError,ValueError,OSError):return False


if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
 if verify():print('Verified Apple Help book sources and generated resources')
 elif args.check:raise SystemExit('Apple Help book is missing/stale;run python3 scripts/generate-help-book.py')
 else:generate()
