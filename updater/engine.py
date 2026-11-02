#!/usr/bin/python3 -I
"""Authenticated distribution update; immutable components + bounded two-copy undo.

No proxy configuration, credentials, units, routes or live websites are targets.
The fixed-path CLI is also the standalone offline recovery helper. Paths/health
injection is a Python test API only, never an environment/CLI privilege bypass.
"""
import argparse
import base64
from contextlib import contextmanager
from dataclasses import dataclass
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import selectors
import secrets
import shutil
import signal
import ssl
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
MAX_ARCHIVE = 32 * 1024 * 1024
MAX_EXPANDED = 96 * 1024 * 1024
MAX_FILES = 256
HEX = re.compile(r'[0-9a-f]{64}')
VERSION = re.compile(r'[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}')
IDENT = re.compile(r'dist-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}')
SNAPSHOT_METADATA = object()
REPOSITORY = 'Lazarev33/twebproxy-manager'
ARTIFACT = 'twebproxy-manager-distribution.tar.gz'
MESSAGES = {
    'root': ('Root is required.', 'Требуются права root.'),
    'digest': ('Distribution checksum mismatch; installed files were not changed.', 'SHA-256 дистрибутива не совпадает; установленные файлы не изменены.'),
    'archive': ('Invalid or incompatible distribution; installed files were not changed.', 'Дистрибутив повреждён или несовместим; установленные файлы не изменены.'),
    'download': ('Verified distribution download failed; installed files were not changed.', 'Не удалось скачать проверяемый дистрибутив; установленные файлы не изменены.'),
    'trust': ('Supply an independent distribution SHA-256 or a pinned signing key.', 'Укажите SHA-256 полного дистрибутива из независимого источника или закреплённый ключ подписи.'),
    'signature': ('Release signature or manifest is invalid.', 'Подпись или манифест релиза не подтверждены.'),
    'busy': ('Another update or Bridge operation is running; retry later.', 'Выполняется обновление или операция Bridge; повторите позже.'),
    'bridge': ('Bridge cleanup/pending state or incompatible agent; repair/remove before update or rollback.', 'Очистка Bridge не завершена, операция прервана либо агент несовместим; выполните repair/remove перед обновлением или откатом.'),
    'current': ('Installed copies are inconsistent or unhealthy; use the offline recovery helper.', 'Установленные копии не согласованы либо не прошли проверку; используйте автономный модуль восстановления.'),
    'components': ('Complete verified distribution required. Use the documented distribution bootstrap; no auxiliary code is downloaded by help/status.', 'Нужен полный проверенный дистрибутив. Используйте описанный bootstrap дистрибутива; help/status не скачивают вспомогательный код.'),
    'backup': ('Backup or interrupted update record is unsafe; preserve it for inspection.', 'Резервная копия или запись прерванного обновления небезопасна; сохраните её для проверки.'),
    'metadata': ('Version metadata could not be committed; update is rolled back.', 'Не удалось записать версию; обновление откатывается.'),
    'health': ('Distribution health failed; update is rolled back.', 'Дистрибутив не прошёл проверку; обновление откатывается.'),
    'version': ('Candidate is not newer; use --force for an intentional reinstall.', 'Версия не новее установленной; для намеренной переустановки используйте --force.'),
}


class Fault(Exception):
    def __init__(self, code, detail=''):
        super().__init__(code)
        self.code, self.detail = code, detail


def message(code):
    ru = os.environ.get('TWEBPROXY_UI_LANGUAGE', 'ru') == 'ru'
    return MESSAGES.get(code, (code, code))[int(ru)]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(obj):
    return (json.dumps(obj, sort_keys=True, indent=2) + '\n').encode()


def strict_json(data):
    def pairs(items):
        result = {}
        for k, v in items:
            if k in result:
                raise Fault('archive', 'duplicate JSON key')
            result[k] = v
        return result
    return json.loads(data, object_pairs_hook=pairs)


def no_links(path):
    path = Path(path)
    if not path.is_absolute():
        raise Fault('current', 'relative system path')
    for p in [*reversed(path.parents), path]:
        if p.is_symlink():
            raise Fault('current', 'symlink system path')


def safe_file(path, mode=None):
    path = Path(path)
    no_links(path)
    st = path.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid or st.st_gid or st.st_nlink != 1 or st.st_mode & 0o022:
        raise Fault('current', 'unsafe file ownership/mode')
    if mode is not None and stat.S_IMODE(st.st_mode) != mode:
        raise Fault('current', 'unexpected file mode')


def directory(path, mode=0o700):
    path = Path(path)
    no_links(path)
    path.mkdir(parents=True, exist_ok=True, mode=mode)
    st = path.stat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid or st.st_gid or st.st_mode & 0o022:
        raise Fault('current', 'unsafe directory')


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, data, mode=0o600):
    path = Path(path)
    no_links(path)
    if path.exists():
        safe_file(path)
    fd, tmp = tempfile.mkstemp(prefix='.distribution-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def embedded(text, key, pattern=HEX):
    values = re.findall(r'^' + re.escape(key) + r'="([^"\n]+)"$', text, re.M)
    if len(values) != 1 or not pattern.fullmatch(values[0]):
        raise Fault('archive', 'embedded identity: ' + key)
    return values[0]


def manager_info(data):
    text = data.decode('utf-8')
    version = embedded(text, 'MANAGER_VERSION', VERSION)
    label = embedded(text, 'MANAGER_RELEASE_VERSION', re.compile(r'[0-9A-Za-z.+-]{1,64}'))
    if label != version and not label.startswith(version + '-'):
        raise Fault('archive', 'release label')
    return {'version': version, 'label': label, 'sha256': sha(data), 'text': text}


def version_metadata(raw, version):
    if raw is None:
        return None
    return re.sub(br'(?m)^MANAGER_VERSION=[^\n]*$', b'MANAGER_VERSION=' + version.encode(), raw)


def verify_components(root, expected, ownership=False, exact=True):
    root = Path(root).absolute()
    if root.is_symlink() or not HEX.fullmatch(expected):
        raise Fault('components')
    raw = (root / 'COMPONENTS.json').read_bytes()
    if ownership:
        safe_file(root / 'COMPONENTS.json', 0o644)
    if sha(raw) != expected:
        raise Fault('components', 'manifest digest')
    records = strict_json(raw)
    if not isinstance(records, dict) or not 1 <= len(records) <= MAX_FILES:
        raise Fault('components', 'manifest records')
    actual = set()
    for p in root.rglob('*') if exact else []:
        if p.is_symlink() or not (p.is_dir() or p.is_file()):
            raise Fault('components', 'non-regular component')
        if p.is_file():
            actual.add(p.relative_to(root).as_posix())
    if exact and actual != set(records) | {'COMPONENTS.json'}:
        raise Fault('components', 'component file set')
    total = 0
    for name, record in records.items():
        parts = PurePosixPath(name).parts
        if not parts or name != '/'.join(parts) or '\\' in name or any(x in ('.', '..') for x in parts) or name.startswith('/'):
            raise Fault('components', 'component path')
        if not isinstance(record, dict) or set(record) != {'sha256', 'size', 'mode'} or not HEX.fullmatch(str(record['sha256'])):
            raise Fault('components', 'component record')
        if type(record['size']) is not int or record['size'] < 0 or record['mode'] not in (0o644, 0o755):
            raise Fault('components', 'component size/mode')
        p = root / name
        if ownership:
            safe_file(p, record['mode'])
        data = p.read_bytes()
        if len(data) != record['size'] or sha(data) != record['sha256']:
            raise Fault('components', 'component digest: ' + name)
        total += len(data)
    if total > MAX_EXPANDED or 'updater/engine.py' not in records or 'bridge/MANIFEST.json' not in records:
        raise Fault('components', 'incomplete component distribution')
    for relative in ['bridge', 'sites/podmoskovye']:
        base = root / relative
        nested = strict_json((base / 'MANIFEST.json').read_bytes())
        if not isinstance(nested, dict):
            raise Fault('components', 'nested manifest schema')
        actual = {p.relative_to(base).as_posix() for p in base.rglob('*') if p.is_file()}
        if actual != set(nested) | {'MANIFEST.json'}:
            raise Fault('components', 'nested component file set')
        for name, expected_sha in nested.items():
            parts = PurePosixPath(name).parts
            if not parts or name.startswith('/') or '\\' in name or '..' in parts or name != '/'.join(parts):
                raise Fault('components', 'nested component path')
            if not isinstance(expected_sha, str) or not HEX.fullmatch(expected_sha) or sha((base / name).read_bytes()) != expected_sha:
                raise Fault('components', 'nested component digest')
    return records


def extract_distribution(archive, expected, target):
    archive = Path(archive).absolute()
    safe_file(archive)
    if not HEX.fullmatch(expected) or archive.stat().st_size > MAX_ARCHIVE or sha(archive.read_bytes()) != expected:
        raise Fault('digest')
    members = {}
    total = 0
    try:
        with tarfile.open(archive, 'r:gz') as t:
            for m in t:
                path = PurePosixPath(m.name)
                if (not m.isfile() or m.issparse() or m.pax_headers or m.name in members or path.is_absolute() or
                    not path.parts or any(x in ('.', '..') for x in path.parts) or
                    '\\' in m.name or path.as_posix() != m.name or m.mode not in (0o644, 0o755)):
                    raise Fault('archive', 'unsafe/duplicate archive member')
                total += m.size
                if m.size < 0 or total > MAX_EXPANDED or len(members) >= MAX_FILES:
                    raise Fault('archive', 'expansion limit')
                p = target / m.name
                p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with p.open('xb') as f:
                    shutil.copyfileobj(t.extractfile(m), f)
                p.chmod(m.mode)
                members[m.name] = m.size
        meta = strict_json((target / 'DISTRIBUTION.json').read_bytes())
        if set(meta) != {'format', 'version', 'release_version', 'manager_sha256', 'components_sha256', 'bridge_state_schema'} or meta['format'] != 'twebproxy.distribution.v1' or meta['bridge_state_schema'] != 1:
            raise Fault('archive', 'distribution descriptor')
        info = manager_info((target / 'twebproxy-manager.sh').read_bytes())
        if info['version'] != meta['version'] or info['label'] != meta['release_version'] or info['sha256'] != meta['manager_sha256']:
            raise Fault('archive', 'manager identity')
        if (target / 'VERSION').read_text().strip() != info['version']:
            raise Fault('archive', 'VERSION identity')
        pin = embedded(info['text'], 'COMPONENTS_MANIFEST_SHA256')
        records = verify_components(target_components(target), pin)
        if meta['components_sha256'] != pin or set(members) != set(records) | {'COMPONENTS.json', 'DISTRIBUTION.json', 'twebproxy-manager.sh'}:
            raise Fault('archive', 'distribution file set')
        if records['updater/engine.py']['sha256'] != embedded(info['text'], 'DISTRIBUTION_ENGINE_SHA256'):
            raise Fault('archive', 'engine pin')
        # Existing Bridge/site integrity contracts remain separate and pinned.
        for name, key in [('bridge/MANIFEST.json', 'BRIDGE_MANIFEST_SHA256'), ('sites/podmoskovye/MANIFEST.json', 'DEFAULT_SITE_MANIFEST_SHA256')]:
            if sha((target / name).read_bytes()) != embedded(info['text'], key):
                raise Fault('archive', 'nested component manifest')
        return info, records
    except Fault:
        raise
    except (OSError, ValueError, KeyError, UnicodeError, tarfile.TarError) as e:
        raise Fault('archive', type(e).__name__) from e


def target_components(root):
    """Verify a full archive's component subset without weakening file-set checks."""
    # The full root also has exactly two explicitly verified manager/descriptor files.
    # A separate component view is prepared by the caller, never through symlinks.
    view = root / '.component-view'
    view.mkdir(mode=0o700)
    for p in list(root.iterdir()):
        if p.name in ('DISTRIBUTION.json', 'twebproxy-manager.sh', '.component-view'):
            continue
        dst = view / p.name
        if p.is_dir():
            shutil.copytree(p, dst)
        else:
            shutil.copyfile(p, dst)
            dst.chmod(stat.S_IMODE(p.stat().st_mode))
    return view


@dataclass
class Paths:
    root: Path = Path('/')

    def at(self, name):
        return self.root / name.lstrip('/')

    @property
    def project(self): return self.at('/opt/twebproxy-manager')
    @property
    def primary(self): return self.at('/usr/local/sbin/twebproxy')
    @property
    def secondary(self): return self.project / 'twebproxy-manager.sh'
    @property
    def state(self): return self.at('/var/lib/twebproxy/distribution-update')
    @property
    def backups(self): return self.at('/var/lib/twebproxy/distribution-backups')
    @property
    def lock(self): return self.at('/run/lock/twebproxy-manager-update.lock')
    @property
    def global_env(self): return self.at('/etc/twebproxy/global.env')
    @property
    def node(self): return self.at('/etc/twebproxy/bridge/node.json')
    @property
    def helper(self): return self.at('/usr/local/libexec/twebproxy/restore-distribution-backup')


class Engine:
    def __init__(self, paths=None, health=None, event=None):
        self.p = paths or Paths()
        self.health_override = health
        self.event = event or (lambda phase: None)

    @contextmanager
    def locked(self, bridge=True):
        if os.geteuid() != 0:
            raise Fault('root')
        no_links(self.p.lock)
        fd = os.open(self.p.lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        locks = [fd]
        try:
            safe_file(self.p.lock, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as e:
                raise Fault('busy') from e
            if bridge:
                d = self.p.at('/run/twebproxy-bridge')
                directory(d)
                bfd = os.open(d / 'controller.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                locks.append(bfd)
                safe_file(d / 'controller.lock', 0o600)
                try:
                    fcntl.flock(bfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as e:
                    raise Fault('busy') from e
            directory(self.p.state)
            yield
        finally:
            for item in reversed(locks):
                os.close(item)

    def current(self):
        safe_file(self.p.primary, 0o755)
        safe_file(self.p.secondary, 0o755)
        data = self.p.primary.read_bytes()
        if data != self.p.secondary.read_bytes():
            raise Fault('current')
        info = manager_info(data)
        if self.p.global_env.exists():
            safe_file(self.p.global_env, 0o600)
            values = re.findall(br'(?m)^MANAGER_VERSION=(?:"([0-9.]+)"|\x27([0-9.]+)\x27|([0-9.]+))$', self.p.global_env.read_bytes())
            if len(values) != 1 or b''.join(values[0]).decode() != info['version']:
                raise Fault('current', 'version metadata mismatch')
        return data, info

    def bridge_guard(self, candidate_text, component_root=None):
        if not self.p.node.exists():
            return
        safe_file(self.p.node, 0o600)
        s = strict_json(self.p.node.read_bytes())
        if (s.get('schema') != 1 or s.get('phase') != 'active' or s.get('cleanup_debt') or
            not HEX.fullmatch(str(s.get('executor_digest', '')))):
            raise Fault('bridge')
        if 'COMPONENTS_MANIFEST_SHA256=' in candidate_text:
            component_id = embedded(candidate_text, 'COMPONENTS_MANIFEST_SHA256')
            component_root = component_root or self.p.project / 'distributions' / component_id
            records = verify_components(component_root, component_id, True)
            agent_hash = records['bridge/agent.py']['sha256']
        else:
            # Legacy rollback resolves the exact old immutable bundle, never a
            # relabelled new controller/agent. Existing remote executor stays put.
            pin = embedded(candidate_text, 'BRIDGE_MANIFEST_SHA256')
            bundle = self.p.project / ('bridge-' + pin)
            safe_file(bundle / 'MANIFEST.json', 0o644)
            raw = (bundle / 'MANIFEST.json').read_bytes()
            if sha(raw) != pin:
                raise Fault('bridge')
            records = strict_json(raw)
            actual = {p.relative_to(bundle).as_posix() for p in bundle.rglob('*') if p.is_file()}
            if actual != set(records) | {'MANIFEST.json'}:
                raise Fault('bridge')
            for name, expected in records.items():
                p = bundle / name
                if PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts:
                    raise Fault('bridge')
                safe_file(p, 0o644)
                if sha(p.read_bytes()) != expected:
                    raise Fault('bridge')
            agent_hash = records['agent.py']
        if agent_hash != s['executor_digest']:
            raise Fault('bridge')

    def publish(self, source, pin, source_tree=False):
        records = verify_components(source, pin, exact=not source_tree)
        directory(self.p.project)
        store = self.p.project / 'distributions'
        directory(store)
        target = store / pin
        if target.exists():
            try:
                verify_components(target, pin, True)
                return target
            except (Fault, OSError):
                # Only a proven owned component directory can be quarantined;
                # an unrelated directory/symlink is never replaced or deleted.
                no_links(target)
                safe_file(target / 'COMPONENTS.json', 0o644)
                if target.stat().st_uid or stat.S_IMODE(target.stat().st_mode) != 0o700 or sha((target / 'COMPONENTS.json').read_bytes()) != pin:
                    raise Fault('components')
                os.rename(target, store / ('.rejected-' + pin + '-' + secrets.token_hex(6)))
                sync_dir(store)
        tmp = Path(tempfile.mkdtemp(prefix='.components-', dir=store))
        try:
            for name in ['COMPONENTS.json', *records]:
                dst = tmp / name
                dst.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                atomic(dst, (source / name).read_bytes(), records.get(name, {'mode': 0o644})['mode'])
            verify_components(tmp, pin, True)
            for d in sorted((p for p in tmp.rglob('*') if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
                sync_dir(d)
            sync_dir(tmp)
            os.rename(tmp, target)
            sync_dir(store)
        finally:
            if tmp.exists():
                shutil.rmtree(tmp)
        return target

    def helper_install(self, engine):
        directory(self.p.helper.parent, 0o755)
        atomic(self.p.helper, engine.read_bytes(), 0o755)

    def probe(self, args, timeout=25):
        env = {**os.environ, 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1',
               'TWEBPROXY_DISTRIBUTION_HEALTH': '1', 'PYTHONDONTWRITEBYTECODE': '1'}
        # Limit this channel, not RLIMIT_FSIZE: verified offline wheels contain
        # legitimate libraries larger than 4MiB. A pipe-holding descendant must
        # neither extend the deadline nor hold the update lock.
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, env=env, close_fds=True,
                             start_new_session=True)
        output = bytearray()
        deadline = time.monotonic() + timeout
        os.set_blocking(p.stdout.fileno(), False)
        try:
            with selectors.DefaultSelector() as select:
                select.register(p.stdout, selectors.EVENT_READ)
                while True:
                    if time.monotonic() >= deadline:
                        return None
                    for key, _ in select.select(min(0.05, max(0, deadline - time.monotonic()))):
                        block = os.read(key.fd, 65536)
                        if block:
                            output.extend(block)
                            if len(output) > 4 * 1024 * 1024:
                                return None
                        else:
                            select.unregister(key.fileobj)
                    rc = p.poll()
                    if rc is not None:
                        # Stop descendants now; drain only buffered output, not
                        # an inherited writer's lifetime or an unbounded stream.
                        try:os.killpg(p.pid, signal.SIGKILL)
                        except ProcessLookupError:pass
                        while True:
                            try:block = os.read(p.stdout.fileno(), 65536)
                            except BlockingIOError:break
                            if not block:break
                            output.extend(block)
                            if len(output) > 4 * 1024 * 1024:return None
                        return bytes(output) if rc == 0 else None
        finally:
            try:os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:pass
            p.wait(timeout=5)
            p.stdout.close()

    def health(self, data):
        if self.health_override:
            return self.health_override(data)
        info = manager_info(data)
        for target in [self.p.primary, self.p.secondary]:
            if target.read_bytes() != data:
                return False
            help_text = self.probe([str(target), '--help'])
            overview = self.probe([str(target), '--json', 'overview'])
            if help_text is None or b'TWebProxy Manager v' + info['version'].encode() not in help_text or overview is None:
                return False
            try:
                obj = strict_json(overview)
                if obj['schema_version'] != 'twebproxy.output.v1' or obj['data']['manager_version'] != info['version']:
                    return False
            except (ValueError, KeyError):
                return False
        if 'COMPONENTS_MANIFEST_SHA256=' in info['text']:
            pin = embedded(info['text'], 'COMPONENTS_MANIFEST_SHA256')
            verify_components(self.p.project / 'distributions' / pin, pin, True)
            if platform.machine() == 'x86_64' and sys.version_info[:2] in ((3, 12), (3, 14)):
                # --help exits argparse before controller.lock; the updater holds
                # that lock to exclude provisioning while switching local code.
                if self.probe([str(self.p.primary), 'foreign-node', '--help']) is None:
                    return False
        return True

    def backup(self, data, info):
        directory(self.p.backups)
        ident = 'dist-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(6)
        tmp = Path(tempfile.mkdtemp(prefix='.incomplete-', dir=self.p.backups))
        try:
            global_data = None
            if self.p.global_env.exists():
                safe_file(self.p.global_env, 0o600)
                global_data = self.p.global_env.read_bytes()
                atomic(tmp / 'global.env', global_data)
            atomic(tmp / 'manager.sh', data)
            metadata = {'format': 'twebproxy.distribution-backup.v1', 'id': ident, 'version': info['version'],
                        'manager_sha256': sha(data), 'global_sha256': sha(global_data) if global_data is not None else None}
            atomic(tmp / 'metadata.json', json_bytes(metadata))
            atomic(tmp / 'SHA256SUMS', ''.join(sha(p.read_bytes()) + '  ' + p.name + '\n' for p in sorted(tmp.iterdir())).encode())
            target = self.p.backups / ident
            os.rename(tmp, target)
            sync_dir(self.p.backups)
            self.verify_backup(ident)
            return ident
        finally:
            if tmp.exists():
                shutil.rmtree(tmp)

    def verify_backup(self, ident):
        if not IDENT.fullmatch(ident):
            raise Fault('backup')
        d = self.p.backups / ident
        no_links(d)
        if not d.is_dir() or d.stat().st_uid or stat.S_IMODE(d.stat().st_mode) != 0o700:
            raise Fault('backup')
        for p in d.iterdir():
            safe_file(p, 0o600)
        meta = strict_json((d / 'metadata.json').read_bytes())
        if set(meta) != {'format', 'id', 'version', 'manager_sha256', 'global_sha256'} or meta['format'] != 'twebproxy.distribution-backup.v1' or meta['id'] != ident:
            raise Fault('backup')
        sums = {}
        for line in (d / 'SHA256SUMS').read_text().splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  (manager.sh|metadata.json|global.env)', line)
            if not match or match[2] in sums:
                raise Fault('backup')
            sums[match[2]] = match[1]
        names = {'metadata.json', 'manager.sh'} | ({'global.env'} if meta['global_sha256'] is not None else set())
        if set(sums) != names or {p.name for p in d.iterdir()} != names | {'SHA256SUMS'}:
            raise Fault('backup')
        if any(sha((d / n).read_bytes()) != h for n, h in sums.items()):
            raise Fault('backup')
        data = (d / 'manager.sh').read_bytes()
        if sha(data) != meta['manager_sha256'] or manager_info(data)['version'] != meta['version']:
            raise Fault('backup')
        if meta['global_sha256'] is not None and sha((d / 'global.env').read_bytes()) != meta['global_sha256']:
            raise Fault('backup')
        return d, meta, data

    def staged_paths(self, ident):
        if not IDENT.fullmatch(ident):
            raise Fault('backup')
        return [(self.p.primary, 'primary', 0o755), (self.p.secondary, 'secondary', 0o755),
                (self.p.global_env, 'metadata', 0o600)]

    def stage_backup(self, ident, include_global=True):
        d, meta, data = self.verify_backup(ident)
        for target, kind, mode in self.staged_paths(ident):
            if kind == 'metadata' and (not include_global or meta['global_sha256'] is None):
                continue
            raw = (d / 'global.env').read_bytes() if kind == 'metadata' else data
            # Reserve undo data on each target filesystem BEFORE mutation. A
            # later ENOSPC can restore by rename without allocating payloads.
            atomic(target.parent / ('.twebproxy-undo-' + ident + '-' + kind), raw, mode)

    def clean_stages(self, identifiers):
        for ident in identifiers:
            d, meta, data = self.verify_backup(ident)
            for target, kind, mode in self.staged_paths(ident):
                p = target.parent / ('.twebproxy-undo-' + ident + '-' + kind)
                if p.exists():
                    safe_file(p, mode)
                    expected = meta['global_sha256'] if kind == 'metadata' else meta['manager_sha256']
                    if sha(p.read_bytes()) != expected:
                        raise Fault('backup', 'unexpected staged undo')
                    p.unlink()
                    sync_dir(p.parent)

    def restore_file(self, target, raw, mode, ident, kind):
        if target.exists() and target.read_bytes() == raw:
            return
        no_links(target)
        staged = target.parent / ('.twebproxy-undo-' + ident + '-' + kind)
        if staged.exists():
            safe_file(staged, mode)
            if sha(staged.read_bytes()) != sha(raw):
                raise Fault('backup')
            os.replace(staged, target)
            sync_dir(target.parent)
        else:
            atomic(target, raw, mode)

    def rollback_metadata(self, undo, target):
        d, meta, _ = self.verify_backup(undo)
        _, target_meta, _ = self.verify_backup(target)
        current = (d / 'global.env').read_bytes() if meta['global_sha256'] is not None else None
        return version_metadata(current, target_meta['version'])

    def clean_target_metadata(self, undo, target):
        p = self.p.global_env.parent / ('.twebproxy-undo-' + undo + '-target-metadata')
        if p.exists():
            safe_file(p, 0o600)
            expected = self.rollback_metadata(undo, target)
            if expected is None or p.read_bytes() != expected:
                raise Fault('backup')
            p.unlink()
            sync_dir(p.parent)

    def restore_locked(self, ident, metadata=SNAPSHOT_METADATA, stage_ident=None):
        d, meta, data = self.verify_backup(ident)
        self.bridge_guard(manager_info(data)['text'])
        # Refuse an immutable/read-only differing metadata file before touching
        # either executable. An update undo normally finds the original bytes.
        if metadata is not SNAPSHOT_METADATA:
            if metadata is not None:
                self.restore_file(self.p.global_env, metadata, 0o600, stage_ident, 'target-metadata')
        elif meta['global_sha256'] is not None:
            raw = (d / 'global.env').read_bytes()
            if not self.p.global_env.exists() or self.p.global_env.read_bytes() != raw:
                self.restore_file(self.p.global_env, raw, 0o600, ident, 'metadata')
        elif self.p.global_env.exists():
            raise Fault('metadata', 'unexpected metadata created outside transaction')
        for target, kind in [(self.p.primary, 'primary'), (self.p.secondary, 'secondary')]:
            self.restore_file(target, data, 0o755, ident, kind)
        if not self.health(data):
            raise Fault('health')
        return meta

    def recover_locked(self):
        pending = self.p.state / 'pending.json'
        if not pending.exists():
            return False
        safe_file(pending, 0o600)
        record = strict_json(pending.read_bytes())
        allowed = {'format', 'backup_id', 'candidate_sha256', 'staging_ids'}
        if (set(record) not in (allowed, allowed | {'restore_target'}) or
            record['format'] != 'twebproxy.distribution-pending.v1' or not HEX.fullmatch(record['candidate_sha256']) or
            not isinstance(record['staging_ids'], list) or not 1 <= len(record['staging_ids']) <= 2 or
            len(set(record['staging_ids'])) != len(record['staging_ids']) or
            any(not IDENT.fullmatch(i) for i in record['staging_ids']) or record['backup_id'] not in record['staging_ids']):
            raise Fault('backup')
        if record.get('restore_target') is not None and record['restore_target'] not in record['staging_ids']:
            raise Fault('backup')
        self.restore_locked(record['backup_id'])
        pending.unlink()
        sync_dir(self.p.state)
        self.clean_stages(record['staging_ids'])
        if record.get('restore_target'):
            self.clean_target_metadata(record['backup_id'], record['restore_target'])
        return True

    def install(self, archive, expected, force=False):
        with self.locked():
            self.recover_locked()
            self.clean_stages([m['id'] for m in self.backups()])
            with tempfile.TemporaryDirectory(prefix='.unpack-', dir=self.p.state) as td:
                source = Path(td)
                candidate, records = extract_distribution(Path(archive), expected, source)
                old, old_info = self.current()
                self.bridge_guard(candidate['text'], source / '.component-view')
                if not self.health(old):
                    raise Fault('current')
                if not force and candidate['sha256'] == old_info['sha256']:
                    print('UPDATE_CURRENT version=' + candidate['version'], flush=True)
                    return None
                if not force and tuple(map(int, candidate['version'].split('.'))) <= tuple(map(int, old_info['version'].split('.'))):
                    raise Fault('version')
                pin = embedded(candidate['text'], 'COMPONENTS_MANIFEST_SHA256')
                self.publish(source / '.component-view', pin)
                self.bridge_guard(candidate['text'])
                ident = self.backup(old, old_info)
                pending = self.p.state / 'pending.json'
                try:
                    self.stage_backup(ident)
                    self.helper_install(source / 'updater/engine.py')
                    self.event('prepared')
                    atomic(pending, json_bytes({'format': 'twebproxy.distribution-pending.v1', 'backup_id': ident,
                                               'candidate_sha256': candidate['sha256'], 'staging_ids': [ident]}))
                except BaseException:
                    self.clean_stages([ident])
                    raise
                try:
                    atomic(self.p.primary, (source / 'twebproxy-manager.sh').read_bytes(), 0o755)
                    self.event('primary-replaced')
                    atomic(self.p.secondary, (source / 'twebproxy-manager.sh').read_bytes(), 0o755)
                    self.event('copies-replaced')
                    if not self.health((source / 'twebproxy-manager.sh').read_bytes()):
                        raise Fault('health')
                    if self.p.root == Path('/'):
                        # Preserve the old helper's v1 protocol and verified
                        # backup functions, adding only v2 delegation. This also
                        # leaves offline recovery usable after legacy rollback.
                        if self.probe(['bash', '-c', 'source "$1"; stage4_install_restore_helper refresh', '_', str(self.p.primary)]) is None:
                            raise Fault('health')
                    if self.p.global_env.exists():
                        raw = self.p.global_env.read_bytes()
                        new = version_metadata(raw, candidate['version'])
                        if new == raw and not re.search(br'(?m)^MANAGER_VERSION=', raw):
                            new += b'\nMANAGER_VERSION=' + candidate['version'].encode() + b'\n'
                        atomic(self.p.global_env, new)
                    self.event('metadata-written')
                    if self.p.primary.read_bytes() != self.p.secondary.read_bytes() or sha(self.p.primary.read_bytes()) != candidate['sha256']:
                        raise Fault('health')
                except BaseException as failure:
                    try:
                        self.restore_locked(ident)
                        pending.unlink()
                        sync_dir(self.p.state)
                        self.clean_stages([ident])
                    except BaseException:
                        failure.distribution_outcome = 'rollback-failed'
                        print('UPDATE_FAILED_ROLLBACK_FAILED backup_id=' + ident, flush=True)
                        raise
                    failure.distribution_outcome = 'rolled-back'
                    print('UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=' + ident, flush=True)
                    raise
                pending.unlink()
                sync_dir(self.p.state)
                self.clean_stages([ident])
                print('UPDATE_SUCCESS backup_id=' + ident, flush=True)
                return ident

    def backups(self):
        if not self.p.backups.exists():
            return []
        result = []
        for p in sorted(self.p.backups.iterdir(), reverse=True):
            if not IDENT.fullmatch(p.name):
                continue
            try:
                _, meta, _ = self.verify_backup(p.name)
                result.append(meta)
            except (Fault, OSError, ValueError):
                continue
        return result

    def rollback(self, selector):
        with self.locked():
            self.recover_locked()
            backups = self.backups()
            if selector == 'latest':
                if not backups:
                    raise Fault('backup')
                selector = backups[0]['id']
            _, meta, target_data = self.verify_backup(selector)
            self.bridge_guard(manager_info(target_data)['text'])
            current_data, current_info = self.current()
            undo = self.backup(current_data, current_info)
            pending = self.p.state / 'pending.json'
            stages = list(dict.fromkeys([undo, selector]))
            desired_metadata = self.rollback_metadata(undo, selector)
            try:
                for ident in stages:
                    self.stage_backup(ident, include_global=ident == undo)
                if desired_metadata is not None:
                    atomic(self.p.global_env.parent / ('.twebproxy-undo-' + undo + '-target-metadata'), desired_metadata)
            except BaseException:
                self.clean_stages(stages)
                raise
            atomic(pending, json_bytes({'format': 'twebproxy.distribution-pending.v1',
                                       'backup_id': undo, 'candidate_sha256': sha(target_data), 'staging_ids': stages,
                                       'restore_target': selector}))
            try:
                self.restore_locked(selector, metadata=desired_metadata, stage_ident=undo)
            except BaseException as failure:
                try:
                    self.restore_locked(undo)
                    pending.unlink()
                    sync_dir(self.p.state)
                    self.clean_stages(stages)
                    self.clean_target_metadata(undo, selector)
                except BaseException:
                    print('RESTORE_FAILED_ROLLBACK_FAILED backup_id=' + undo, flush=True)
                    raise
                failure.distribution_outcome = 'rolled-back'
                print('RESTORE_FAILED_ROLLBACK_SUCCESS backup_id=' + undo, flush=True)
                raise
            pending.unlink()
            sync_dir(self.p.state)
            self.clean_stages(stages)
            self.clean_target_metadata(undo, selector)
            print('RESTORE_SUCCESS backup_id=' + selector + ' manager_version=' + meta['version'], flush=True)


class Redirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, origin):
        self.origin = origin
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        origin = urllib.parse.urlsplit(self.origin)
        if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.fragment:
            raise Fault('download')
        if parsed.netloc != origin.netloc and parsed.hostname not in ('github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'):
            raise Fault('download')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url, target, maximum):
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or not p.hostname or p.username or p.password or p.fragment:
        raise Fault('download')
    ctx = ssl.create_default_context(cafile=os.environ.get('CURL_CA_BUNDLE') or None)
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), Redirects(url))
    try:
        with opener.open(urllib.request.Request(url, headers={'User-Agent': 'TWebProxy-distribution-updater', 'Accept': 'application/json'}), timeout=15) as r, target.open('xb') as f:
            total = 0
            deadline = time.monotonic() + 90
            while True:
                if time.monotonic() > deadline:
                    raise Fault('download')
                block = r.read1(min(65536, maximum + 1 - total))
                if not block:
                    break
                total += len(block)
                if total > maximum:
                    raise Fault('download')
                f.write(block)
            length = r.headers.get('Content-Length')
            if length is not None and int(length) != total:
                raise Fault('download')
    except (OSError, ValueError, urllib.error.URLError) as e:
        raise Fault('download') from e


def release_archive(args, work):
    api = work / 'release.json'
    download(args.api_url.rstrip('/') + '/releases/latest', api, 1024 * 1024)
    obj = strict_json(api.read_bytes())
    tag = obj.get('tag_name', '')
    if obj.get('draft') is not False or obj.get('prerelease') is not False or not tag.startswith('v') or not VERSION.fullmatch(tag[1:]):
        raise Fault('signature', 'not a stable release')
    base = args.release_url.rstrip('/') + '/releases/download/' + tag + '/'
    expected, size, release_label = args.sha256, None, None
    if args.trusted_key:
        manifest, signature = work / 'release-manifest.json', work / 'release-manifest.sig'
        download(base + 'twebproxy-manager-release.json', manifest, 65536)
        download(base + 'twebproxy-manager-release.json.sig', signature, 4096)
        try:
            sig = base64.b64decode(signature.read_bytes().strip(), validate=True)
            if len(sig) != 64:
                raise ValueError()
            (work / 'signature.bin').write_bytes(sig)
            verified = False
            for key in args.trusted_key:
                der = base64.b64decode(key, validate=True)
                if len(der) != 44 or not der.startswith(bytes.fromhex('302a300506032b6570032100')):
                    raise ValueError('Ed25519 SPKI required')
                (work / 'key.der').write_bytes(der)
                p = subprocess.run(['openssl', 'pkey', '-pubin', '-inform', 'DER', '-in', str(work / 'key.der'), '-out', str(work / 'key.pem')], capture_output=True, timeout=5)
                if p.returncode == 0:
                    p = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(work / 'key.pem'), '-rawin', '-in', str(manifest), '-sigfile', str(work / 'signature.bin')], capture_output=True, timeout=5)
                    verified |= p.returncode == 0
            m = strict_json(manifest.read_bytes())
            if not verified or set(m) != {'format', 'repository', 'channel', 'version', 'release_version', 'tag', 'commit', 'artifact'} or m['format'] != 'twebproxy.manager-distribution-release.v1' or m['repository'] != REPOSITORY or m['channel'] != 'stable' or m['tag'] != tag or m['version'] != tag[1:] or not re.fullmatch('[0-9a-f]{40}', m['commit']):
                raise ValueError()
            a = m['artifact']
            if set(a) != {'name', 'sha256', 'size'} or a['name'] != ARTIFACT or not HEX.fullmatch(a['sha256']) or type(a['size']) is not int or not 0 < a['size'] <= MAX_ARCHIVE:
                raise ValueError()
            if expected and expected != a['sha256']:
                raise Fault('digest')
            expected, size = a['sha256'], a['size']
            release_label = m['release_version']
            if not isinstance(release_label, str) or not (release_label == tag[1:] or release_label.startswith(tag[1:] + '-')):
                raise ValueError()
        except (ValueError, KeyError, TypeError) as e:
            raise Fault('signature') from e
    elif not expected:
        raise Fault('trust')
    target = work / ARTIFACT
    download(base + ARTIFACT, target, MAX_ARCHIVE)
    if size is not None and target.stat().st_size != size:
        raise Fault('digest')
    return target, expected, tag[1:], release_label


def main(argv=None):
    p = argparse.ArgumentParser(description='Verified full-distribution updater and offline recovery')
    sub = p.add_subparsers(dest='command', required=True)
    for name in ['install', 'update']:
        q = sub.add_parser(name)
        q.add_argument('--archive', type=Path)
        q.add_argument('--sha256', default='')
        q.add_argument('--force', action='store_true')
        q.add_argument('--api-url', default='https://api.github.com/repos/' + REPOSITORY)
        q.add_argument('--release-url', default='https://github.com/' + REPOSITORY)
        q.add_argument('--trusted-key', action='append', default=[])
    q = sub.add_parser('verify');q.add_argument('root', type=Path);q.add_argument('pin');q.add_argument('--source', action='store_true')
    q = sub.add_parser('publish');q.add_argument('root', type=Path);q.add_argument('pin');q.add_argument('--source', action='store_true')
    q = sub.add_parser('restore');q.add_argument('selector', nargs='?', default='latest')
    sub.add_parser('list');sub.add_parser('recover')
    args = p.parse_args(argv)
    engine = Engine()
    if args.command == 'verify':
        verify_components(args.root, args.pin, True, exact=not args.source)
        return 0
    if os.geteuid() != 0:
        raise Fault('root')
    if args.command == 'publish':
        engine.publish(args.root, args.pin, args.source)
        engine.helper_install(args.root / 'updater/engine.py')
    elif args.command == 'list':
        print('format=twebproxy.distribution-backup.v1')
        backups = engine.backups()
        for m in backups:print('backup_id=' + m['id'] + ' source_version=' + m['version'])
        entries = len(list(engine.p.backups.iterdir())) if engine.p.backups.exists() else 0
        print('valid=' + str(len(backups)) + ' invalid=' + str(entries - len(backups)))
    elif args.command == 'restore':
        engine.rollback(args.selector)
    elif args.command == 'recover':
        with engine.locked():
            engine.recover_locked()
    else:
        args.sha256 = args.sha256.lower()
        if args.sha256 and not HEX.fullmatch(args.sha256):
            raise Fault('digest')
        if args.archive:
            if not args.sha256:
                raise Fault('trust')
            engine.install(args.archive, args.sha256, args.force)
        else:
            if args.command == 'install':
                p.error('install requires --archive and independent --sha256')
            # Refuse pending/incompatible Bridge before the first network request;
            # candidate-agent compatibility is checked again under the install lock.
            if engine.p.node.exists():
                node = strict_json(engine.p.node.read_bytes())
                if node.get('phase') != 'active' or node.get('cleanup_debt'):
                    raise Fault('bridge')
            with tempfile.TemporaryDirectory(prefix='twebproxy-distribution-download-') as td:
                archive, expected, version, label = release_archive(args, Path(td))
                # Bind the authenticated artifact's identity to the selected release.
                with tempfile.TemporaryDirectory(prefix='twebproxy-distribution-identity-') as check:
                    info, _ = extract_distribution(archive, expected, Path(check))
                    if info['version'] != version or label is not None and info['label'] != label:
                        raise Fault('archive')
                engine.install(archive, expected, args.force)
    return 0


def interrupted(signum, frame):
    raise KeyboardInterrupt(signum)


if __name__ == '__main__':
    os.umask(0o077)
    for sig in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
        signal.signal(sig, interrupted)
    try:
        raise SystemExit(main())
    except KeyboardInterrupt as e:
        raise SystemExit(128 + (e.args[0] if e.args else signal.SIGINT))
    except (Fault, OSError, ValueError, TypeError, KeyError) as e:
        code = e.code if isinstance(e, Fault) else 'archive'
        if not getattr(e, 'distribution_outcome', None):
            print('UPDATE_REFUSED reason=' + code, file=sys.stderr)
        print(message(code), file=sys.stderr)
        raise SystemExit(75 if code == 'busy' else 1)
