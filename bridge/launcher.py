#!/usr/bin/env python3
"""Hash-verified offline dependency environment. No system-wide pip changes."""
import hashlib,json,os,platform,runpy,shutil,stat,sys,tempfile,zipfile
from pathlib import Path

def verify(root,expected):
 manifest=root/'MANIFEST.json';raw=manifest.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=expected:raise RuntimeError('Bridge release manifest mismatch')
 records=json.loads(raw)
 actual=set()
 for p in root.rglob('*'):
  if p.is_symlink():raise RuntimeError('bundle symlink refused')
  if p.is_file():actual.add(str(p.relative_to(root)))
 if actual!=set(records)|{'MANIFEST.json'}:raise RuntimeError('unmanifested Bridge component refused')
 for name,digest in records.items():
  parts=Path(name).parts
  if Path(name).is_absolute() or '..' in parts:raise RuntimeError('unsafe bundle path')
  p=root/name
  if p.is_symlink() or not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest:raise RuntimeError('Bridge component digest mismatch: '+name)
 return records

def main():
 sys.dont_write_bytecode=True
 root=Path(__file__).resolve().parent;expected=sys.argv[1];records=verify(root,expected)
 if sys.argv[2]=='--install':
  target=Path(sys.argv[3]);
  if target.resolve()==root.resolve():return
  target.mkdir(parents=True,exist_ok=True,mode=0o700)
  for name in [*records,'MANIFEST.json']:
   dst=target/name;dst.parent.mkdir(parents=True,exist_ok=True)
   if dst.is_symlink():raise RuntimeError('symlink install destination')
   shutil.copyfile(root/name,dst);os.chmod(dst,0o644)
  return
 version=str(sys.version_info.major)+str(sys.version_info.minor)
 if version not in ('312','314') or platform.machine()!='x86_64':raise RuntimeError('Bridge dependency bundle supports tested x86_64 Python3.12/3.14 only')
 cache=Path('/opt/twebproxy-manager/bridge-python')/(expected+'-cp'+version)
 if (cache/'.complete').exists():
  expected_files={'.complete'}
  for name in records:
   if not name.endswith('.whl') or ('cffi-' in Path(name).name and '-cp'+version+'-' not in name):continue
   with zipfile.ZipFile(root/name) as z:
    for entry in z.infolist():
     if entry.is_dir():continue
     expected_files.add(entry.filename);target=cache/entry.filename
     if target.is_symlink() or not target.is_file() or hashlib.sha256(target.read_bytes()).digest()!=hashlib.sha256(z.read(entry)).digest():raise RuntimeError('Bridge dependency cache integrity mismatch; reinstall verified bundle')
  actual_files={str(f.relative_to(cache)) for f in cache.rglob('*') if f.is_file() or f.is_symlink()}
  if actual_files!=expected_files:raise RuntimeError('Unexpected component in Bridge dependency cache')
 if not (cache/'.complete').exists():
  cache.parent.mkdir(parents=True,exist_ok=True,mode=0o700);tmp=Path(tempfile.mkdtemp(prefix='.bridge-',dir=cache.parent))
  try:
   for name in records:
    if not name.endswith('.whl'):continue
    if 'cffi-' in Path(name).name and '-cp'+version+'-' not in name:continue
    with zipfile.ZipFile(root/name) as z:
     for zi in z.infolist():
      if zi.filename.startswith('/') or '..' in Path(zi.filename).parts or stat.S_ISLNK(zi.external_attr>>16):raise RuntimeError('unsafe wheel entry')
     z.extractall(tmp)
   (tmp/'.complete').write_text(expected)
   if cache.exists():shutil.rmtree(cache)
   os.replace(tmp,cache)
  finally:
   if tmp.exists():shutil.rmtree(tmp)
 sys.path[:]=[str(root),str(cache)]+[x for x in sys.path if x and 'site-packages' not in x and 'dist-packages' not in x]
 sys.argv=[str(root/'controller.py'),*sys.argv[2:]];runpy.run_path(str(root/'controller.py'),run_name='__main__')
if __name__=='__main__':
 try:main()
 except Exception as e:print('Bridge launcher: '+str(e),file=sys.stderr);sys.exit(1)
