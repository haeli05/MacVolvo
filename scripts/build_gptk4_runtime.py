#!/usr/bin/env python3
"""Derive a local D3DMetal evaluation runtime from an owned Apple GPTK 4 DMG.

The base runtime and Apple binaries remain unchanged. Apple framework symlinks
and signatures are preserved; the new runtime has a separate manifest/archive.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

from derive_runtime import tree, write_archive


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


@contextmanager
def mounted(dmg):
    run('/usr/bin/hdiutil', 'verify', dmg, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix='macvolvo-gptk4-image-') as folder:
        mount = Path(folder) / 'image'
        mount.mkdir()
        run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
            '-mountpoint', mount, dmg, stdout=subprocess.DEVNULL)
        try:
            yield mount
        finally:
            run('/usr/bin/hdiutil', 'detach', mount, stdout=subprocess.DEVNULL)


def derive(base, image, output, version, package_sha256):
    base, image, output = map(Path, (base, image, output))
    if not re.fullmatch(r'macvolvo-gptk4-[A-Za-z0-9._-]+', version):
        raise ValueError('Use a separate macvolvo-gptk4-* runtime version')
    if output.exists() or Path(str(output) + '.tar.gz').exists():
        raise ValueError('Output exists; choose a new evaluation artifact')
    manifest = json.loads((base / 'runtime.json').read_text())
    before = tree(base)
    if before.keys() - manifest['files'].keys() - {'runtime.json'}:
        raise ValueError('Base runtime contains files outside its manifest')
    for name, spec in manifest['files'].items():
        expected = ('link', spec['symlink']) if 'symlink' in spec else ('file', spec['sha256'])
        if before.get(name) != expected:
            raise ValueError('Base runtime differs from its manifest: ' + name)
    redist = image / 'redist/lib'
    framework = redist / 'external/D3DMetal.framework'
    info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    apple_version = info['CFBundleShortVersionString']
    if not apple_version.startswith('4.'):
        raise ValueError('The supplied image does not contain D3DMetal 4')
    if info.get('CFBundleIdentifier') != 'com.apple.D3DMetal':
        raise ValueError('Unexpected framework identity')
    for path in (framework, redist / 'external/libd3dshared.dylib'):
        run('/usr/bin/codesign', '--verify', '--strict', '-R=anchor apple', path)
    for name in ('Read Me.rtf', 'License.rtf', 'Acknowledgements.rtf'):
        if not (image / name).is_file():
            raise ValueError('Apple package documentation missing: ' + name)
    for name in ('wine/x86_64-windows/d3d11.dll', 'wine/x86_64-windows/dxgi.dll',
                 'wine/x86_64-unix/d3d11.so', 'wine/x86_64-unix/dxgi.so',
                 'external/libd3dshared.dylib'):
        if not (redist / name).is_file():
            raise ValueError('Apple graphics module missing: ' + name)
    for path in redist.rglob('*'):
        if path.is_symlink():
            if not path.resolve().is_relative_to(redist.resolve()):
                raise ValueError('Apple redist contains an escaping symlink')
        elif path.is_file() and path.read_bytes()[:4] == b'\xcf\xfa\xed\xfe':
            run('/usr/bin/codesign', '--verify', '--strict', '-R=anchor apple', path)
    output.parent.mkdir(parents=True, exist_ok=True)
    run('/bin/cp', '-Rc', base, output)
    removed = ['lib/wine/x86_64-unix/winemetal.so',
               'lib/wine/x86_64-windows/winemetal.dll',
               'lib/wine/x86_64-windows/d3d10core.dll',
               'lib/wine/x86_64-windows/nvngx.dll']
    for name in removed:
        (output / name).unlink(missing_ok=True)
    shutil.copytree(redist, output / 'lib', symlinks=True, dirs_exist_ok=True)
    for name in ('Read Me.rtf', 'License.rtf', 'Acknowledgements.rtf'):
        target = output / 'licenses/apple-gptk4' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(image / name, target)
    files = {}
    for name, (kind, value) in tree(output).items():
        if name == 'runtime.json':
            continue
        files[name] = {'symlink': value} if kind == 'link' else {
            'sha256': value, 'bytes': (output / name).stat().st_size}
    base_version = manifest['version']
    manifest.update(version=version, files=files, graphics_backend='d3dmetal',
                    gptk_version=apple_version,
                    gptk_derivation={'base_version': base_version,
                                     'base_manifest_sha256': sha(base / 'runtime.json'),
                                     'apple_dmg_sha256': package_sha256})
    (output / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    after = tree(output)
    for name, entry in tree(redist).items():
        if after.get('lib/' + name) != entry:
            raise ValueError('Imported Apple file differs from package: ' + name)
    allowed = {'runtime.json', *removed}
    allowed.update('lib/' + str(p.relative_to(redist)) for p in redist.rglob('*')
                   if p.is_file() or p.is_symlink())
    allowed.update('licenses/apple-gptk4/' + n for n in ('Read Me.rtf', 'License.rtf', 'Acknowledgements.rtf'))
    changed = {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)}
    if changed - allowed:
        raise ValueError('Unexpected changes outside graphics overlay: ' + str(sorted(changed - allowed)))
    archive = write_archive(output)
    proof = {'version': version, 'graphics_backend': 'd3dmetal', 'gptk_version': apple_version,
             'apple_dmg_sha256': package_sha256, 'archive_sha256': sha(archive),
             'changed_files': sorted(changed), 'apple_binaries_modified': False}
    Path(str(output) + '.proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, indent=2), flush=True)
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--dmg', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', default='macvolvo-gptk4-4.0b3.1')
    args = parser.parse_args()
    with mounted(args.dmg.resolve()) as image:
        derive(args.base.resolve(), image, args.output.resolve(), args.version, sha(args.dmg))
