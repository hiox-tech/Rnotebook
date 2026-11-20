#!/usr/bin/env python3
"""Sync only current application sources/resources; Legacy is never a target."""
import hashlib
import json
import pathlib
import subprocess

project = pathlib.Path('Rnotebook.xcodeproj/project.pbxproj')
data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))
objects = data['objects']

# Tests must not share the shipping app's Launch Services/process identity.
# Default builds preserve the production identifiers; test.sh overrides only
# these two target-specific settings, not the test bundle or document UTIs.
for item in objects.values():
    if item.get('isa') == 'XCBuildConfiguration':
        settings = item.get('buildSettings', {})
        if settings.get('INFOPLIST_FILE') == 'Config/Info.plist':
            settings['RNOTEBOOK_APP_ID'] = 'org.hiox.Rnotebook'
            settings['RNOTEBOOK_DISPLAY_NAME'] = 'Rnotebook'
            settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(RNOTEBOOK_APP_ID)'

def uid(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

# Drop missing sources/resources and the retired UI test target and packaging phases.
removed = {key for key, item in objects.items()
           if item.get('isa') == 'PBXFileReference'
           and item.get('sourceTree') == 'SOURCE_ROOT'
           and not pathlib.Path(item['path']).exists()}
removed.update(key for key, item in objects.items()
               if item.get('isa') == 'PBXShellScriptBuildPhase'
               or item.get('name') == 'RnotebookUITests'
               or item.get('path') == 'RnotebookUITests.xctest')
removed.update(key for key, item in objects.items()
               if item.get('isa') == 'PBXBuildFile' and item.get('fileRef') in removed)
for item in objects.values():
    for field in ['files', 'children', 'targets', 'buildPhases', 'dependencies']:
        if field in item:
            item[field] = [key for key in item[field] if key not in removed]
    if item.get('isa') == 'PBXProject':
        for key in removed:
            item.get('attributes', {}).get('TargetAttributes', {}).pop(key, None)
for key in removed:
    del objects[key]

def group(path):
    key = uid('group:' + path)
    if key not in objects:
        objects[key] = {'isa': 'PBXGroup', 'name': pathlib.Path(path).name,
                        'sourceTree': '<group>', 'children': []}
        objects[group(str(pathlib.Path(path).parent))]['children'].append(key)
    return key

for root, target, phase, override in [
    ('DesktopApp', 'Rnotebook', 'F54FD5BA6E9DA9AA50E2F216', None),
    ('Tests/Unit', 'RnotebookTests', '7710A906293C46BAF854C265', None)
]:
    source_ids = []
    for file in sorted(pathlib.Path(root).rglob('*.swift')):
        key = uid('file:' + str(file))
        if key not in objects:
            objects[key] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'sourcecode.swift',
                            'name': file.name, 'path': str(file), 'sourceTree': 'SOURCE_ROOT'}
            objects[override or group(str(file.parent))]['children'].append(key)
        build = uid('build:' + target + ':sources:' + str(file))
        objects[build] = {'isa': 'PBXBuildFile', 'fileRef': key}
        source_ids.append(build)
    objects[phase]['files'] = source_ids

# Fixed Tree-sitter C runtime and grammar sources; internal .c files are included by lib.c.
for path in ['DesktopApp/LanguageServices/TreeSitterBridge.c',
 'ThirdParty/LanguageTools/TreeSitter/lib/src/lib.c',
 'ThirdParty/LanguageTools/TreeSitter/r/src/parser.c', 'ThirdParty/LanguageTools/TreeSitter/r/src/scanner.c',
 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown/src/parser.c', 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown/src/scanner.c',
 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown-inline/src/parser.c', 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown-inline/src/scanner.c']:
 key=uid('file:'+path)
 objects[key]={'isa':'PBXFileReference','lastKnownFileType':'sourcecode.c.c','name':pathlib.Path(path).name,'path':path,'sourceTree':'SOURCE_ROOT'}
 parent=objects[group(str(pathlib.Path(path).parent))]['children']
 if key not in parent: parent.append(key)
 build=uid('build:Rnotebook:sources:'+path)
 objects[build]={'isa':'PBXBuildFile','fileRef':key}
 objects['F54FD5BA6E9DA9AA50E2F216']['files'].append(build)
resource='DesktopApp/Resources/Quarto'
key=uid('file:'+resource)
objects[key]={'isa':'PBXFileReference','lastKnownFileType':'folder','name':'Quarto','path':resource,'sourceTree':'SOURCE_ROOT'}
parent=objects[group('DesktopApp/Resources')]['children']
if key not in parent: parent.append(key)
build=uid('build:Rnotebook:resources:'+resource)
objects[build]={'isa':'PBXBuildFile','fileRef':key}
phase=objects['EF66B8862723A4FF27E52624']['files']
if build not in phase:phase.append(build)

resource='DesktopApp/Resources/LanguageTools'
key=uid('file:'+resource)
objects[key]={'isa':'PBXFileReference','lastKnownFileType':'folder','name':'LanguageTools','path':resource,'sourceTree':'SOURCE_ROOT'}
parent=objects[group('DesktopApp/Resources')]['children']
if key not in parent:parent.append(key)
build=uid('build:Rnotebook:resources:'+resource)
objects[build]={'isa':'PBXBuildFile','fileRef':key}
phase=objects['EF66B8862723A4FF27E52624']['files']
if build not in phase:phase.append(build)

# Notebook runtime resources are a dedicated, reviewed extraction, never Legacy.
resource = 'DesktopApp/Resources/NotebookRuntime'
key = uid('file:' + resource)
if key not in objects:
    objects[key] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'folder', 'name': 'NotebookRuntime', 'path': resource, 'sourceTree': 'SOURCE_ROOT'}
    objects[group('DesktopApp/Resources')]['children'].append(key)
build = uid('build:Rnotebook:resources:' + resource)
objects[build] = {'isa': 'PBXBuildFile', 'fileRef': key}
phase = objects['EF66B8862723A4FF27E52624']['files']
if build not in phase:
    phase.append(build)

icon = 'DesktopApp/Resources/Rnotebook.icns'
if pathlib.Path(icon).exists():
    key = uid('file:' + icon)
    if key not in objects:
        objects[key] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'image.icns', 'name': 'Rnotebook.icns', 'path': icon, 'sourceTree': 'SOURCE_ROOT'}
        objects[group('DesktopApp/Resources')]['children'].append(key)
    build = uid('build:Rnotebook:resources:' + icon)
    objects[build] = {'isa': 'PBXBuildFile', 'fileRef': key}
    if build not in phase:
        phase.append(build)

# Native Apple Help book plus Markdown for the two native educational windows.
for resource in ['DesktopApp/Resources/Help', 'DesktopApp/Resources/Rnotebook.help', 'DesktopApp/Resources/ThirdPartyNotices']:
    key = uid('file:' + resource)
    objects[key] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'folder', 'name': pathlib.Path(resource).name, 'path': resource, 'sourceTree': 'SOURCE_ROOT'}
    parent = objects[group('DesktopApp/Resources')]['children']
    if key not in parent: parent.append(key)
    build = uid('build:Rnotebook:resources:' + resource)
    objects[build] = {'isa': 'PBXBuildFile', 'fileRef': key}
    if build not in phase: phase.append(build)

# Complete official CRAN mirror snapshot, usable before an online refresh.
resource = 'DesktopApp/Resources/CRANMirrors.json'
key = uid('file:' + resource)
objects[key] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'text.json', 'name': 'CRANMirrors.json', 'path': resource, 'sourceTree': 'SOURCE_ROOT'}
parent = objects[group('DesktopApp/Resources')]['children']
if key not in parent: parent.append(key)
build = uid('build:Rnotebook:resources:' + resource)
objects[build] = {'isa': 'PBXBuildFile', 'fileRef': key}
if build not in phase: phase.append(build)

# Localizable source-key resources are a native Xcode variant group.
resource = 'DesktopApp/Resources/Localizable.strings'
key = uid('variant:' + resource)
children = []
for locale in ['zh-Hans', 'en']:
    path = 'DesktopApp/Resources/' + locale + '.lproj/Localizable.strings'
    child = uid('file:' + path)
    objects[child] = {'isa': 'PBXFileReference', 'lastKnownFileType': 'text.plist.strings',
                      'name': locale, 'path': path, 'sourceTree': 'SOURCE_ROOT'}
    children.append(child)
objects[key] = {'isa': 'PBXVariantGroup', 'name': 'Localizable.strings', 'sourceTree': '<group>', 'children': children}
parent = objects[group('DesktopApp/Resources')]['children']
if key not in parent: parent.append(key)
build = uid('build:Rnotebook:resources:' + resource)
objects[build] = {'isa': 'PBXBuildFile', 'fileRef': key}
if build not in phase: phase.append(build)
for item in objects.values():
    if item.get('isa') == 'PBXProject': item['knownRegions'] = ['zh-Hans', 'en', 'Base']

# Finder Quick Look is an embedded sandboxed extension, with no runtime/export hosts.
preview_target = uid('target:RnotebookPreview')
preview_sources = uid('phase:RnotebookPreview:sources')
preview_frameworks = uid('phase:RnotebookPreview:frameworks')
preview_resources = uid('phase:RnotebookPreview:resources')
preview_queries = uid('phase:RnotebookPreview:queries')
preview_product = uid('product:RnotebookPreview')
preview_configs = uid('configs:RnotebookPreview')
preview_package = uid('package-product:RnotebookPreview:EdmundCore')
objects[preview_product] = {'isa':'PBXFileReference','explicitFileType':'wrapper.app-extension','path':'RnotebookPreview.appex','sourceTree':'BUILT_PRODUCTS_DIR'}
products = objects['FBDC4F23F93125BBEEAE800C']['children']
if preview_product not in products: products.append(preview_product)
objects[preview_package] = {'isa':'XCSwiftPackageProductDependency','package':'C5A44007D0090CF975AB66C6','productName':'EdmundCore'}
package_build = uid('build:RnotebookPreview:EdmundCore')
objects[package_build] = {'isa':'PBXBuildFile','productRef':preview_package}
objects[preview_frameworks] = {'isa':'PBXFrameworksBuildPhase','buildActionMask':2147483647,'files':[package_build],'runOnlyForDeploymentPostprocessing':0}
objects[preview_resources] = {'isa':'PBXResourcesBuildPhase','buildActionMask':2147483647,'files':[],'runOnlyForDeploymentPostprocessing':0}
objects[preview_sources] = {'isa':'PBXSourcesBuildPhase','buildActionMask':2147483647,'files':[],'runOnlyForDeploymentPostprocessing':0}
shared_preview_sources = [
 'DesktopApp/Preview/NotebookPreviewContent.swift',
 'DesktopApp/Preview/NotebookPreviewViewController.swift',
 'DesktopApp/Editor/SourceTypography.swift',
 'DesktopApp/Editor/RecordSyntaxPalette.swift',
 'DesktopApp/AppShell/RecordRSyntaxAdapter.swift',
 'DesktopApp/AppShell/RecordFencePresentationCache.swift',
 'DesktopApp/LanguageServices/TreeSitterHighlight.swift',
 'DesktopApp/LanguageServices/TreeSitterBridge.c',
 'ThirdParty/LanguageTools/TreeSitter/lib/src/lib.c',
 'ThirdParty/LanguageTools/TreeSitter/r/src/parser.c',
 'ThirdParty/LanguageTools/TreeSitter/r/src/scanner.c',
 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown/src/parser.c',
 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown/src/scanner.c',
 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown-inline/src/parser.c',
 'ThirdParty/LanguageTools/TreeSitter/tree-sitter-markdown-inline/src/scanner.c']
for path in shared_preview_sources:
 build = uid('build:RnotebookPreview:sources:'+path)
 objects[build] = {'isa':'PBXBuildFile','fileRef':uid('file:'+path)}
 objects[preview_sources]['files'].append(build)
# Only the three small Tree-sitter queries belong in the extension, never Raven/Air/R.
objects[preview_queries] = {'isa':'PBXCopyFilesBuildPhase','name':'Copy Preview Queries','buildActionMask':2147483647,'dstPath':'LanguageTools','dstSubfolderSpec':7,'files':[],'runOnlyForDeploymentPostprocessing':0}
for name in ['r','markdown','markdown_inline']:
 path = 'DesktopApp/Resources/LanguageTools/'+name+'.scm'
 key = uid('file:'+path)
 objects[key] = {'isa':'PBXFileReference','lastKnownFileType':'text','name':pathlib.Path(path).name,'path':path,'sourceTree':'SOURCE_ROOT'}
 parent = objects[group('QuickLook')]['children']
 if key not in parent: parent.append(key)
 build = uid('build:RnotebookPreview:query:'+name)
 objects[build] = {'isa':'PBXBuildFile','fileRef':key}
 objects[preview_queries]['files'].append(build)
# The two preview labels have their own localization; the app bundles the same keys.
variant = uid('variant:QuickLook/Localizable.strings')
objects[variant] = {'isa':'PBXVariantGroup','name':'Localizable.strings','sourceTree':'<group>','children':[]}
for lang in ['zh-Hans','en']:
 path = 'QuickLook/'+lang+'.lproj/Localizable.strings'
 key = uid('file:'+path)
 objects[key] = {'isa':'PBXFileReference','lastKnownFileType':'text.plist.strings','name':lang,'path':path,'sourceTree':'SOURCE_ROOT'}
 objects[variant]['children'].append(key)
parent = objects[group('QuickLook')]['children']
if variant not in parent: parent.append(variant)
build = uid('build:RnotebookPreview:localization')
objects[build] = {'isa':'PBXBuildFile','fileRef':variant}
objects[preview_resources]['files'].append(build)
config_ids = []
for name, base in [('Debug','7326A50204128321A8234000'),('Release','513804B2957FB72C4F7A17B1')]:
 key = uid('config:RnotebookPreview:'+name); config_ids.append(key)
 objects[key] = {'isa':'XCBuildConfiguration','name':name,'baseConfigurationReference':base,'buildSettings':{
  'APPLICATION_EXTENSION_API_ONLY':'YES','CODE_SIGN_ENTITLEMENTS':'QuickLook/Preview.entitlements','ENABLE_APP_SANDBOX':'YES',
  'GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'QuickLook/Info.plist','PRODUCT_NAME':'RnotebookPreview',
  'RNOTEBOOK_PREVIEW_ID':'org.hiox.Rnotebook.Preview',
  'PRODUCT_BUNDLE_IDENTIFIER':'$(RNOTEBOOK_PREVIEW_ID)','SKIP_INSTALL':'YES',
  'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks',
  'SWIFT_EMIT_LOC_STRINGS':'NO'}}
objects[preview_configs] = {'isa':'XCConfigurationList','buildConfigurations':config_ids,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'}
objects[preview_target] = {'isa':'PBXNativeTarget','name':'RnotebookPreview','productName':'RnotebookPreview','productType':'com.apple.product-type.app-extension','productReference':preview_product,'buildConfigurationList':preview_configs,'buildPhases':[preview_sources,preview_frameworks,preview_resources,preview_queries],'buildRules':[],'dependencies':[],'packageProductDependencies':[preview_package]}
project_object = objects[data['rootObject']]
if preview_target not in project_object['targets']: project_object['targets'].append(preview_target)
project_object['attributes']['TargetAttributes'][preview_target] = {'CreatedOnToolsVersion':'27.1'}
proxy = uid('proxy:RnotebookPreview')
objects[proxy] = {'isa':'PBXContainerItemProxy','containerPortal':data['rootObject'],'proxyType':1,'remoteGlobalIDString':preview_target,'remoteInfo':'RnotebookPreview'}
dependency = uid('dependency:RnotebookPreview')
objects[dependency] = {'isa':'PBXTargetDependency','target':preview_target,'targetProxy':proxy}
app = objects['C3A8B4F09490507F86FB422E']
if dependency not in app['dependencies']: app['dependencies'].append(dependency)
embed_build = uid('build:Rnotebook:embed-preview')
objects[embed_build] = {'isa':'PBXBuildFile','fileRef':preview_product,'settings':{'ATTRIBUTES':['RemoveHeadersOnCopy']}}
embed = uid('phase:Rnotebook:embed-preview')
objects[embed] = {'isa':'PBXCopyFilesBuildPhase','name':'Embed App Extensions','buildActionMask':2147483647,'dstPath':'','dstSubfolderSpec':13,'files':[embed_build],'runOnlyForDeploymentPostprocessing':0}
if embed not in app['buildPhases']: app['buildPhases'].append(embed)

# Remove emptied groups and any now-unreachable objects/configurations/proxies.
while True:
    empty = {key for key, item in objects.items()
             if item.get('isa') == 'PBXGroup' and not item.get('children')}
    if not empty:
        break
    for item in objects.values():
        if 'children' in item:
            item['children'] = [key for key in item['children'] if key not in empty]
    for key in empty:
        del objects[key]

def references(value):
    if isinstance(value, dict):
        for entry in value.values():
            yield from references(entry)
    elif isinstance(value, list):
        for entry in value:
            yield from references(entry)
    elif isinstance(value, str) and value in objects:
        yield value

reachable = set()
pending = [data['rootObject']]
while pending:
    key = pending.pop()
    if key in reachable:
        continue
    reachable.add(key)
    pending.extend(references(objects[key]))
data['objects'] = {key: value for key, value in objects.items() if key in reachable}

for phase in objects.values():
    if phase.get('isa') == 'PBXResourcesBuildPhase':
        seen = set(); unique = []
        for key in phase.get('files', []):
            ref = objects.get(objects.get(key, {}).get('fileRef'), {})
            identity = (ref.get('sourceTree'), ref.get('path'))
            if identity not in seen: unique.append(key); seen.add(identity)
        phase['files'] = unique

def fmt(value, indent=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (indent + 1) + json.dumps(key) + ' = ' + fmt(entry, indent + 1) + ';\n'
                               for key, entry in sorted(value.items())) + '\t' * indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join('\t' * (indent + 1) + fmt(entry, indent + 1) + ',\n' for entry in value) + '\t' * indent + ')'
    return json.dumps(value, ensure_ascii=False)

project.write_text('// !$*UTF8*$!\n' + fmt(data) + '\n')
print('Synced app, unit tests and embedded Quick Look; authorized Notebook resources only; no Legacy sources or retired UI target.')
