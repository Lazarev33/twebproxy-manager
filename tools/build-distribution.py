#!/usr/bin/env python3
"""Build the deterministic, complete runtime artifact. No network or credentials."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import stat
import tarfile


def encoded(obj):
    return (json.dumps(obj, sort_keys=True, indent=2) + '\n').encode()


def build(root, output=None):
    names = ['VERSION', 'updater/engine.py', 'tools/default-site-bundle.py']
    for directory in ['bridge', 'sites/podmoskovye']:
        names += [p.relative_to(root).as_posix() for p in (root / directory).rglob('*') if p.is_file()]
    records = {}
    for name in sorted(names):
        p = root / name
        if p.is_symlink() or '__pycache__' in p.parts or p.suffix == '.pyc':
            raise ValueError('unsafe/untracked runtime input: ' + name)
        raw = p.read_bytes()
        mode = stat.S_IMODE(p.stat().st_mode)
        if mode not in (0o644, 0o755):
            raise ValueError('unexpected runtime mode: ' + name)
        records[name] = {'sha256': hashlib.sha256(raw).hexdigest(), 'size': len(raw), 'mode': mode}
    components = encoded(records)
    pin = hashlib.sha256(components).hexdigest()
    (root / 'COMPONENTS.json').write_bytes(components)
    manager = root / 'twebproxy-manager.sh'
    text = manager.read_text()
    for key, value in [('COMPONENTS_MANIFEST_SHA256', pin), ('DISTRIBUTION_ENGINE_SHA256', records['updater/engine.py']['sha256'])]:
        text, n = re.subn(r'^' + key + r'="[^"]*"$', key + '="' + value + '"', text, flags=re.M)
        if n != 1:
            raise ValueError('missing/duplicate manager pin: ' + key)
    manager.write_text(text)
    version = re.search(r'^MANAGER_VERSION="([^"]+)"$', text, re.M).group(1)
    release = re.search(r'^MANAGER_RELEASE_VERSION="([^"]+)"$', text, re.M).group(1)
    metadata = {'format': 'twebproxy.distribution.v1', 'version': version, 'release_version': release,
                'manager_sha256': hashlib.sha256(manager.read_bytes()).hexdigest(),
                'components_sha256': pin, 'bridge_state_schema': 1}
    (root / 'DISTRIBUTION.json').write_bytes(encoded(metadata))
    if output:
        with output.open('wb') as f, gzip.GzipFile(fileobj=f, mode='wb', filename='', mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name in sorted([*records, 'COMPONENTS.json', 'DISTRIBUTION.json', 'twebproxy-manager.sh']):
                    raw = (root / name).read_bytes()
                    entry = tarfile.TarInfo(name)
                    entry.size = len(raw)
                    entry.mode = 0o755 if name == 'twebproxy-manager.sh' else records.get(name, {'mode': 0o644})['mode']
                    entry.uid = entry.gid = entry.mtime = 0
                    archive.addfile(entry, io.BytesIO(raw))
        print(hashlib.sha256(output.read_bytes()).hexdigest() + '  ' + output.name)
    return metadata


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument('--output', type=Path)
    a = p.parse_args()
    build(a.root, a.output)
