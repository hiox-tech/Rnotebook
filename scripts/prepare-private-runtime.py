#!/usr/bin/env python3
"""Extract and relocate the official macOS R framework into Rnotebook's prefix.

The CRAN framework hard-codes /Library/Frameworks/R.framework in load commands
and compiled R_HOME strings. This script rewrites both to --prefix, ad-hoc
re-signs the touched Mach-O files, and verifies the result. It does not install
anything into /Library or modify the machine's existing R.
"""
import argparse, hashlib, os, plistlib, shutil, subprocess, tempfile
from pathlib import Path

OLD_ROOT = '/Library/Frameworks/R.framework'

def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, **kwargs)

def is_macho(p: Path) -> bool:
    if not p.is_file() or p.is_symlink():
        return False
    try:
        magic = p.read_bytes()[:4]
    except OSError:
        return False
    return magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

def patch_framework(framework: Path, new_root: str) -> int:
    assert len(new_root) <= len(OLD_ROOT), (new_root, OLD_ROOT)
    for p in framework.rglob('*.dSYM'):
        shutil.rmtree(p, ignore_errors=True)
    machos = [p for p in framework.rglob('*') if is_macho(p)]
    # 1. Shell scripts, Makeconf, pkg-config files and other text references.
    for p in framework.rglob('*'):
        if not p.is_file() or p.is_symlink() or is_macho(p):
            continue
        if p.suffix in ('.dylib', '.so', '.rdb', '.rdx', '.rds', '.RData'):
            continue
        try:
            text = p.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        if OLD_ROOT in text:
            p.write_text(text.replace(OLD_ROOT, new_root))
    # 2. Load commands while the original absolute paths are still present.
    for p in machos:
        try:
            out = subprocess.check_output(['otool', '-L', str(p)], stderr=subprocess.DEVNULL, text=True)
        except subprocess.CalledProcessError:
            continue
        deps = [line.strip().split(' (')[0] for line in out.splitlines()[1:]]
        try:
            dout = subprocess.check_output(['otool', '-D', str(p)], stderr=subprocess.DEVNULL, text=True)
            ids = [line.strip() for line in dout.splitlines()[1:] if line.strip()]
        except subprocess.CalledProcessError:
            ids = []
        changed = False
        for ident in ids:
            if ident.startswith(OLD_ROOT + '/'):
                run('install_name_tool', '-id', new_root + ident[len(OLD_ROOT):], str(p))
                changed = True
        for dep in deps:
            if dep in ids or not dep.startswith(OLD_ROOT + '/'):
                continue
            run('install_name_tool', '-change', dep, new_root + dep[len(OLD_ROOT):], str(p))
            changed = True
        if changed:
            run('codesign', '--force', '--sign', '-', str(p))
    # 3. Remaining NUL-terminated strings (notably compiled R_HOME).
    old_b, new_b = OLD_ROOT.encode(), new_root.encode()
    for p in framework.rglob('*'):
        if not p.is_file() or p.is_symlink() or p.suffix in ('.rdb', '.rdx', '.rds', '.RData'):
            continue
        data = p.read_bytes()
        if old_b not in data:
            continue
        out, i, changed = bytearray(), 0, False
        while i < len(data):
            if data[i] == 0:
                out.append(data[i]); i += 1; continue
            j = data.find(b'\0', i)
            if j < 0: j = len(data)
            segment = data[i:j]
            if old_b in segment:
                replaced = segment.replace(old_b, new_b)
                if len(replaced) <= len(segment):
                    segment = replaced + b'\0' * (len(segment) - len(replaced))
                    changed = True
            out.extend(segment); i = j
        if changed:
            p.write_bytes(bytes(out))
            if is_macho(p):
                run('codesign', '--force', '--sign', '-', str(p))
    return len(machos)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pkg', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prefix', default='/Library/Rnotebook')
    parser.add_argument('--verify-native', action='store_true')
    args = parser.parse_args()
    pkg = args.pkg.resolve()
    output = args.output.resolve()
    prefix = args.prefix.rstrip('/')
    new_root = prefix + '/R.framework'
    assert len(new_root) <= len(OLD_ROOT), f'prefix too long for in-place relocation: {new_root}'
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='rnotebook-r-') as temp:
        expanded = Path(temp) / 'expanded'
        run('pkgutil', '--expand-full', str(pkg), str(expanded))
        candidates = list(expanded.rglob('R.framework'))
        candidates = [p for p in candidates if (p / 'Versions').is_dir()]
        if len(candidates) != 1:
            raise SystemExit(f'expected one R.framework payload, found {candidates}')
        framework = output / 'R.framework'
        shutil.copytree(candidates[0], framework, symlinks=True)
    machos = patch_framework(framework, new_root)
    leftovers = subprocess.run(['grep', '-R', '-a', '-l', OLD_ROOT, str(framework)],
                               stdout=subprocess.PIPE, text=True).stdout.splitlines()
    if leftovers:
        raise SystemExit('old framework path remains: ' + ', '.join(leftovers[:5]))
    info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    result = {
        'source': str(pkg),
        'sourceSHA256': hashlib.sha256(pkg.read_bytes()).hexdigest(),
        'prefix': new_root,
        'rVersion': info.get('CFBundleShortVersionString'),
        'architectures': subprocess.check_output(['lipo', '-archs', str(framework / 'Resources/bin/exec/R')], text=True).strip(),
        'machOFiles': machos,
    }
    (output / 'runtime.json').write_text(__import__('json').dumps(result, indent=2) + '\n')
    if args.verify_native:
        rscript = framework / 'Resources/bin/Rscript'
        home = subprocess.check_output([str(rscript), '--vanilla', '--slave', '-e', 'cat(R.home())'], text=True).strip()
        if Path(home).resolve() != (framework / 'Resources').resolve():
            raise SystemExit(f'R.home() was {home}, expected {framework}')
        result['verifiedRHome'] = home
    print(__import__('json').dumps(result, indent=2))

if __name__ == '__main__':
    main()
