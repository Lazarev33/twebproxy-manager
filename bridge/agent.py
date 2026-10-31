#!/usr/bin/env python3
"""Owned-resource bridge agent. RPC is stdin JSON, never shell command input."""
import base64,ctypes,fcntl,stat,signal,hashlib,json,os,pwd,re,shutil,socket,subprocess,sys,tempfile,threading,time
from pathlib import Path
BASE=Path('/var/lib/twebproxy-bridge'); LIB=Path('/usr/local/libexec/twebproxy-bridge')
DCS='91.108.56.0/22 91.108.4.0/22 91.108.8.0/22 91.108.16.0/22 91.108.12.0/22 149.154.160.0/20 91.105.192.0/23 91.108.20.0/22 185.76.151.0/24 2001:b28:f23d::/48 2001:b28:f23f::/48 2001:67c:4e8::/48 2001:b28:f23c::/48 2a0a:f280::/32'
COMMIT='f36d8af769ffaeac36978d38c2c0f6d1104c2137'
class Fault(Exception):pass
def private_lock(name,directory=Path('/run/twebproxy-bridge')):
 if not re.fullmatch(r'[a-z-]+\.lock',name):raise Fault('invalid lock identity')
 directory=Path(directory)
 try:directory.mkdir(mode=0o700)
 except FileExistsError:pass
 st=directory.lstat()
 if not stat.S_ISDIR(st.st_mode) or st.st_uid!=0 or st.st_mode&0o077:raise Fault('unsafe Bridge lock directory')
 try:fd=os.open(directory/name,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
 except OSError:raise Fault('unsafe Bridge lock file')
 st=os.fstat(fd)
 if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_nlink!=1:
  os.close(fd);raise Fault('unsafe Bridge lock ownership')
 return os.fdopen(fd,'r+')

def run(a,check=True,timeout=180,input=None):
 try:p=subprocess.run(a,input=input,text=True,capture_output=True,timeout=timeout)
 except FileNotFoundError:
  if check:raise Fault('required command missing: '+Path(a[0]).name)
  return subprocess.CompletedProcess(a,127,'','missing')
 if check and p.returncode:
  detail=''
  if Path(a[0]).name=='wg':
   if 'Key is not' in p.stderr:detail=' invalid-key-format'
   elif 'Unable to' in p.stderr:detail=' interface-or-permission'
   else:detail=' argument-or-device-error'
   if 'private-key' in a:
    keyfile=Path(a[a.index('private-key')+1]);detail+=' private_file='+str(keyfile.exists())
    if keyfile.exists():
     private=keyfile.read_text().strip();safe=p.stderr.replace(private,'<private-key>')
     safe=re.sub(r'[A-Za-z0-9+/]{43}=', '<key>',safe);detail+=' diagnostic='+safe[:240].replace('\n',' ')
     try:detail+=' private_valid='+str(len(base64.b64decode(keyfile.read_text().strip(),validate=True))==32)
     except Exception:detail+=' private_valid=False'
  elif Path(a[0]).name=='systemctl':detail=' '+str(a[1])+' '+str(a[-1])
  raise Fault('command failed: '+Path(a[0]).name+detail+' (rc '+str(p.returncode)+')')
 return p

def atomic(p,data,mode=0o600):
 p=Path(p);p.parent.mkdir(parents=True,exist_ok=True)
 if p.is_symlink():raise Fault('symlink destination refused')
 fd,tmp=tempfile.mkstemp(prefix='.bridge-',dir=p.parent)
 try:
  os.fchmod(fd,mode)
  with os.fdopen(fd,'w') as f:f.write(data);f.flush();os.fsync(f.fileno())
  os.replace(tmp,p);d=os.open(p.parent,os.O_DIRECTORY);os.fsync(d);os.close(d)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)

FIELDS={'schema','id','role','endpoint','peer_endpoint','wg_port','client_port','stats_port','local_port','backend_id','own_ip','peer_ip','peer_key','public_key','generation','management_user','phase','proc_changed','prior_hidden','material_updated','operation','executor_sha256'}
def validate(c):
 import ipaddress
 if set(c)-FIELDS or c.get('schema')!=1:raise Fault('unknown configuration field/schema')
 if not re.fullmatch('[0-9a-f]{32}',c['id']):raise Fault('invalid owner')
 if c['role'] not in ('entry','exit'):raise Fault('invalid role')
 for k in ['endpoint','peer_endpoint','own_ip','peer_ip']:
  ip=ipaddress.IPv4Address(c[k])
  if ip.is_loopback or ip.is_unspecified or ip.is_multicast:raise Fault('invalid endpoint')
 for k in ['own_ip','peer_ip']:
  if not ipaddress.IPv4Address(c[k]).is_private:raise Fault('private inner addresses required')
 for k in ['wg_port','client_port','stats_port','local_port']:
  if type(c[k]) is not int or not 1024<=c[k]<=65535:raise Fault('invalid port')
 for k in ['public_key','peer_key']:
  if c.get(k):
   try:assert len(base64.b64decode(c[k],validate=True))==32
   except Exception:raise Fault('invalid WG public key')
 if c['own_ip']==c['peer_ip'] or c['endpoint']==c['peer_endpoint']:raise Fault('distinct entry/exit identities required')
 if type(c['generation']) is not int or c['generation']<1:raise Fault('invalid generation')
 if not re.fullmatch('[a-z0-9.-]+--[a-z0-9_-]+',c['backend_id']):raise Fault('invalid profile identity')

def layout(c):
 validate(c);i=c['id'];return BASE/i,LIB/i,'twb-'+i[:12],c['own_ip'],c['peer_ip']
def unit(c,s):return layout(c)[2]+'-'+s+'.service'
def iface(c):return 'twb'+c['id'][:8]
def table(c):return 'twb_'+c['id'][:12]
def cfgpath(c):return layout(c)[0]/'config.json'
def keypath(c):return Path('/etc/wireguard')/('twb-'+c['id']+'.key')
def save(c):atomic(cfgpath(c),json.dumps(c))
def hidden():
 p=run(['setpriv','--reuid=nobody','--regid=nogroup','--clear-groups','cat','/proc/1/cmdline'],False)
 return p.returncode!=0

def inspect(c):
 release=dict(l.split('=',1) for l in Path('/etc/os-release').read_text().splitlines() if '=' in l)
 return {'os':release.get('ID','').strip('"'),'version':release.get('VERSION_ID','').strip('"'),'root':os.geteuid()==0,'pid1':Path('/proc/1/comm').read_text().strip(),'listeners':run(['ss','-lntu']).stdout,'services':run(['systemctl','list-units','--state=running','--no-legend'],False).stdout,'nft_tables':run(['nft','list','tables'],False).stdout,'proc_hidden':hidden(),'machine_id_hash':hashlib.sha256(Path('/etc/machine-id').read_bytes()).hexdigest()}

def preflight(c):
 x=inspect(c)
 if not x['root'] or x['pid1']!='systemd':raise Fault('root privileges and systemd required')
 if x['os']!='ubuntu' or x['version'] not in ('24.04','26.04'):raise Fault('MVP supports only Ubuntu 24.04/26.04; other platforms untested')
 run(['capsh','--has-p=cap_net_admin']);run(['capsh','--has-p=cap_sys_admin'])
 root,lib,prefix,own,peer=layout(c)
 if root.is_symlink() or lib.is_symlink():raise Fault('owned directory symlink refused')
 if not root.exists() and lib.exists():raise Fault('unowned component directory collision')
 if not root.exists():
  if run(['id','-u','twb'+c['id'][:10]],False).returncode==0:raise Fault('management account collision')
  for d in BASE.glob('*') if BASE.exists() else []:
   if d.is_dir():raise Fault('another managed Bridge node exists')
  if Path('/sys/class/net/'+iface(c)).exists() or keypath(c).exists():raise Fault('interface/key allocation occupied')
  for suffix in ['wg','guard','mt','stats']:
   if Path('/etc/systemd/system/'+unit(c,suffix)).exists():raise Fault('unit occupied')
  ports=[c['wg_port']]+([c['client_port'],c['stats_port']] if c['role']=='exit' else [c['local_port']])
  for p in ports:
   if re.search(r':'+str(p)+r'\s',x['listeners']):raise Fault('required port occupied: '+str(p))
   import ipaddress
  for r in json.loads(run(['ip','-j','route','show']).stdout):
   dst=r.get('dst','default')
   if dst!='default' and any(ipaddress.IPv4Address(c[k]) in ipaddress.IPv4Network(dst,strict=False) for k in ['own_ip','peer_ip']):raise Fault('inner allocation overlaps an existing route')
  # Other local instances are independent resources, not a role conflict.
  # Reserve their authoritative ports even when their processes are stopped.
  if c['role']=='exit':
   for f in Path('/etc/twebproxy/backends').glob('*.env'):
    reserved=[int(v) for v in re.findall(r'^(?:MTPROXY_CLIENT_PORT|MTPROXY_STATS_PORT)=[\"\']?(\d+)',f.read_text(),re.M)]
    if set(reserved)&set(ports):raise Fault('required port reserved by an existing local backend')
 return x

def management(c,key):
 root,lib,*_=layout(c)
 parts=key.strip().split()
 if len(parts) not in (2,3) or parts[0]!='ssh-ed25519' or '\n' in key.strip() or '\r' in key:raise Fault('invalid management public key')
 try:
  raw=base64.b64decode(parts[1],validate=True)
  if len(raw)!=51 or raw[:19]!=b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00 ':raise ValueError()
 except Exception:raise Fault('invalid management public key encoding')
 user='twb'+c['id'][:10];c['management_user']=user;save(c)
 if run(['id','-u',user],False).returncode:run(['useradd','--system','--no-create-home','--home-dir','/nonexistent','--shell','/bin/sh','--password','*',user])
 keydir=Path('/etc/ssh/twebproxy-bridge');keydir.mkdir(mode=0o755,exist_ok=True);os.chmod(keydir,0o755)
 cmd='/usr/bin/sudo -n /usr/bin/python3 '+str(lib/'agent.py')+' rpc '+c['id']
 line='restrict,from="'+c['peer_endpoint']+'",command="'+cmd+'" '+key.strip()+'\n'
 atomic(keydir/c['id'],line,0o644)
 sudo=Path('/etc/sudoers.d')/('twb-'+c['id']);atomic(sudo,user+' ALL=(root) NOPASSWD: /usr/bin/python3 '+str(lib/'agent.py')+' rpc '+c['id']+'\n',0o440)
 run(['visudo','-cf',str(sudo)])
 sshconf=Path('/etc/ssh/sshd_config.d')/('90-twb-'+c['id']+'.conf')
 atomic(sshconf,'Match User '+user+'\n    AuthorizedKeysFile /etc/ssh/twebproxy-bridge/'+c['id']+'\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    AllowAgentForwarding no\n    AllowTcpForwarding no\n    X11Forwarding no\n    PermitTTY no\n    PermitUserRC no\nMatch all\n',0o644)
 run(['/usr/sbin/sshd','-t'])
 effective=run(['/usr/sbin/sshd','-T','-C','user='+user+',host=localhost,addr='+c['peer_endpoint']]).stdout
 if 'authorizedkeysfile /etc/ssh/twebproxy-bridge/'+c['id'] not in effective or 'passwordauthentication no' not in effective or 'allowtcpforwarding no' not in effective:raise Fault('effective management SSH restrictions differ from approved policy')
 run(['systemctl','reload','ssh'])

def bootstrap(c,source,key,user):
 preflight(c);root,lib,*_=layout(c)
 expected=globals().get('_VERIFIED_PAYLOAD_SHA256')
 if expected is None:expected=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
 if hashlib.sha256(source.encode()).hexdigest()!=expected:raise Fault('bootstrap payload digest mismatch')
 if not root.exists():root.mkdir(parents=True,mode=0o700)
 c['executor_sha256']=hashlib.sha256(source.encode()).hexdigest();save(c)
 LIB.mkdir(parents=True,exist_ok=True,mode=0o755);os.chmod(LIB,0o755);lib.mkdir(parents=True,exist_ok=True,mode=0o755);os.chmod(lib,0o755);atomic(lib/'agent.py',source,0o755)
 dependencies(c,['wireguard-tools','nftables','sudo'])
 keypath(c).parent.mkdir(mode=0o700,exist_ok=True)
 st=keypath(c).parent.lstat()
 if not stat.S_ISDIR(st.st_mode) or st.st_uid!=0 or st.st_mode&0o022:raise Fault('unsafe WireGuard key directory')
 if not keypath(c).exists():atomic(keypath(c),run(['wg','genkey']).stdout)
 c['public_key']=run(['wg','pubkey'],input=keypath(c).read_text()).stdout.strip();save(c)
 if c['role']=='exit':management(c,key)
 return {'bootstrapped':True,'public_key':c['public_key'],'management_user':c.get('management_user')}

def service(c,s,body):
 atomic(Path('/etc/systemd/system')/unit(c,s),body,0o644)

def runtime(c,up):
 root,lib,prefix,own,peer=layout(c);dev=iface(c)
 if not up:
  run(['ip','link','del',dev],False);return
 if not Path('/sys/class/net/'+dev).exists():run(['ip','link','add',dev,'type','wireguard'])
 run(['wg','set',dev,'listen-port',str(c['wg_port']),'private-key',str(keypath(c)),'peer',c['peer_key'],'allowed-ips',peer+'/32','endpoint',c['peer_endpoint']+':'+str(c['wg_port']),'persistent-keepalive','25'])
 run(['ip','addr','replace',own+'/32','dev',dev]);run(['ip','link','set',dev,'mtu','1280'])
 run(['ip','route','replace','blackhole',peer+'/32','metric','32760']);run(['ip','link','set',dev,'up']);run(['ip','route','replace',peer+'/32','dev',dev,'metric','100'])

def guard(c):
 _,_,_,own,peer=layout(c);t=table(c);dev=iface(c);rules=f'add table inet {t} {{ flags owner; }}\nadd chain inet {t} input {{ type filter hook input priority -7; policy accept; }}\n'
 rules+=f'add rule inet {t} input ip saddr {c["peer_endpoint"]} udp dport {c["wg_port"]} accept\nadd rule inet {t} input udp dport {c["wg_port"]} drop\n'
 rules+=f'add rule inet {t} input iifname "{dev}" ip saddr {peer} ip daddr {own} ct state established,related accept\n'
 if c['role']=='exit':
  ports=f'{{ {c["client_port"]}, {c["stats_port"]} }}'
  rules+=f'add rule inet {t} input iifname "lo" tcp dport {ports} accept\nadd rule inet {t} input iifname "{dev}" ip saddr {peer} ip daddr {own} tcp dport {c["client_port"]} accept\nadd rule inet {t} input tcp dport {ports} drop\n'
 rules+=f'add rule inet {t} input iifname "{dev}" drop\n'
 rules+=f'add chain inet {t} output {{ type filter hook output priority -7; policy accept; }}\nadd rule inet {t} output oifname != \"{dev}\" ip daddr {peer} drop\n'
 if c['role']=='entry':rules+=f'add rule inet {t} output oifname "{dev}" ip saddr {own} ip daddr {peer} tcp dport {c["client_port"]} accept\n'
 else:rules+=f'add rule inet {t} output oifname "{dev}" ip saddr {own} ip daddr {peer} ct state established,related accept\n'
 rules+=f'add rule inet {t} output oifname "{dev}" drop\n'
 p=subprocess.Popen(['nft','-i'],stdin=subprocess.PIPE,text=True);p.stdin.write(rules);p.stdin.flush()
 import signal
 signal.signal(signal.SIGTERM,lambda *_:p.terminate());p.wait();raise SystemExit(1)

def forward(config):
 c=json.loads(Path(config).read_text());threads=[]
 def pipe(a,b):
  try:
   while True:
    d=a.recv(65536)
    if not d:break
    b.sendall(d)
  except OSError:pass
  finally:
   try:b.shutdown(socket.SHUT_WR)
   except OSError:pass
 def serve(bind,port,target,tport):
  def connection(a):
   try:
    with a,socket.create_connection((target,tport),timeout=5) as b:
     b.settimeout(None);t=threading.Thread(target=pipe,args=(a,b),daemon=True);t.start();pipe(b,a);t.join(timeout=30)
   except OSError:pass
  s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((bind,port));s.listen(128)
  while True:
   a,_=s.accept();threading.Thread(target=connection,args=(a,),daemon=True).start()
 for v in c['forwards']:
  t=threading.Thread(target=serve,args=v);t.start();threads.append(t)
 for t in threads:t.join()

def gate(name):
 deny=run(['systemctl','show',name,'-p','IPAddressDeny','--value']).stdout
 count=run(['systemctl','show',name,'-p','IPIngressBytes','--value']).stdout.strip()
 if '0.0.0.0/0' not in deny or '::/0' not in deny or not count.isdigit() or not hidden():raise Fault('backend start refused: socket filter/procfs protection missing')

def dependencies(c,names):
 root=layout(c)[0];record=root/'packages.json';old=json.loads(record.read_text()) if record.exists() else {}
 missing=[]
 for n in names:
  r=run(['dpkg-query','-W','-f=${Status} ${Version}',n],False)
  if n not in old:old[n]={'before':r.stdout.strip() if r.returncode==0 else 'absent'}
  if r.returncode or not r.stdout.startswith('install ok installed'):missing.append(n)
 atomic(record,json.dumps(old))
 if missing:
  run(['apt-get','-o','DPkg::Lock::Timeout=30','update'],timeout=300)
  run(['apt-get','-o','DPkg::Lock::Timeout=30','install','--no-upgrade','-y','--no-install-recommends',*missing],timeout=600)
 for n in names:old[n]['after']=run(['dpkg-query','-W','-f=${Version}',n],False).stdout.strip()
 atomic(record,json.dumps(old))

def material_download(url,path):
 if url not in ('https://core.telegram.org/getProxySecret','https://core.telegram.org/getProxyConfig'):raise Fault('unapproved material origin')
 run(['curl','-4','-fLsS','--proto','=https','--proto-redir','=https','--tlsv1.2','--connect-timeout','8','--max-time','20','--retry','3','--retry-all-errors','--retry-delay','2','--retry-max-time','75','--max-filesize','65536',url,'-o',str(path)],timeout=110)
 data=Path(path).read_bytes()
 if not 100<=len(data)<=65536:raise Fault('invalid official material size')
 if url.endswith('getProxyConfig') and (b'proxy_for ' not in data or b'default ' not in data):raise Fault('invalid official routing material')

def stock(c):
 root,lib,*_=layout(c)
 b=root/'mtproto-proxy'
 if b.exists():return
 dependencies(c,['wireguard-tools','nftables','git','build-essential','libssl-dev','zlib1g-dev','curl','ca-certificates'])
 source=root/'stock-source'
 if not source.exists():run(['git','clone','https://github.com/TelegramMessenger/MTProxy.git',str(source)],timeout=180)
 run(['git','-C',str(source),'checkout','--detach',COMMIT]);run(['make','-C',str(source),'-j2'],timeout=300)
 shutil.copy2(source/'objs/bin/mtproto-proxy',b);os.chmod(b,0o755)
 for name,url in [('proxy-secret','https://core.telegram.org/getProxySecret'),('proxy-multi.conf','https://core.telegram.org/getProxyConfig')]:
  material_download(url,str(root/name));os.chmod(root/name,0o600)
 c['material_updated']=time.time();save(c)

def deploy(c):
 validate(c);root,lib,prefix,own,peer=layout(c)
 if not root.exists():raise Fault('ownership bootstrap required')
 old=json.loads(cfgpath(c).read_text())
 for k in ['management_user','proc_changed','prior_hidden','public_key','material_updated']:
  if k in old:c[k]=old[k]
 save(c)
 if not shutil.which('wg'):
  run(['apt-get','update'],timeout=600);run(['apt-get','install','-y','--no-install-recommends','wireguard-tools','nftables'],timeout=600)
 if not c.get('peer_key'):raise Fault('peer identity not configured')
 agent=str(lib/'agent.py');cfg=str(cfgpath(c))
 if c['role']=='exit':
  # A failed repair must not leave the old secret-bearing process alive.
  oldunit=Path('/etc/systemd/system')/unit(c,'mt')
  if oldunit.exists():
   run(['systemctl','stop',unit(c,'mt')])
   if run(['systemctl','is-active',unit(c,'mt')],False).stdout.strip() not in ('inactive','failed'):raise Fault('owned backend stop not proven')
  stock(c)
  if 'prior_hidden' not in c:c['prior_hidden']=hidden();c['proc_changed']=not c['prior_hidden'];save(c)
  if not hidden():run(['mount','-o','remount,hidepid=2','/proc'])
  if not hidden():raise Fault('procfs hardening failed; backend remains stopped')
 service(c,'wg',f'[Unit]\nAfter=network-online.target {unit(c,"guard")}\nWants=network-online.target\nRequires={unit(c,"guard")}\nBindsTo={unit(c,"guard")}\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart={sys.executable} {agent} up {c["id"]}\nExecStop={sys.executable} {agent} down {c["id"]}\n[Install]\nWantedBy=multi-user.target\n')
 service(c,'guard',f'[Unit]\nAfter=network-online.target\n[Service]\nExecStart={sys.executable} {agent} guard {c["id"]}\nExecStartPost=/bin/sh -c "for n in 1 2 3 4 5; do nft list table inet {table(c)} >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"\nRestart=on-failure\nRestartSec=2\n[Install]\nWantedBy=multi-user.target\n')
 if c['role']=='exit':
  if not (root/'client-secret').is_file():raise Fault('client credential missing')
  runner='#!/usr/bin/env python3\nimport os\nfrom pathlib import Path\np=Path(os.environ["CREDENTIALS_DIRECTORY"])\ns=(p/"client-secret").read_text().strip()\nos.execv('+repr(str(root/'mtproto-proxy'))+',['+repr(str(root/'mtproto-proxy'))+',"-H",'+repr(str(c['client_port']))+',"-p",'+repr(str(c['stats_port']))+',"-S",s,"--http-stats","--aes-pwd",str(p/"proxy-secret"),str(p/"proxy-multi.conf"),"-M","1","-C","4096"])\n'
  atomic(lib/'run-mt.py',runner,0o755)
  # Binary must be accessible to DynamicUser; secrets stay in root-only state.
  target=lib/'mtproto-proxy'
  if not target.exists() or hashlib.sha256(target.read_bytes()).digest()!=hashlib.sha256((root/'mtproto-proxy').read_bytes()).digest():
   fd,tmp=tempfile.mkstemp(prefix='.stock-',dir=lib);os.close(fd)
   try:shutil.copy2(root/'mtproto-proxy',tmp);os.chmod(tmp,0o755);os.replace(tmp,target)
   finally:
    if os.path.exists(tmp):os.unlink(tmp)
  runner=runner.replace(str(root/'mtproto-proxy'),str(lib/'mtproto-proxy'));atomic(lib/'run-mt.py',runner,0o755)
  dependencies=f'Requires={unit(c,"wg")} {unit(c,"guard")}\nAfter={unit(c,"wg")} {unit(c,"guard")}\nBindsTo={unit(c,"guard")}\n'
  service(c,'mt',f'[Unit]\n{dependencies}[Service]\nDynamicUser=yes\nLimitCORE=0\nLoadCredential=client-secret:{root}/client-secret\nLoadCredential=proxy-secret:{root}/proxy-secret\nLoadCredential=proxy-multi.conf:{root}/proxy-multi.conf\nExecStartPre=+{sys.executable} {agent} gate %n\nExecStart={sys.executable} {lib}/run-mt.py\nRestart=on-failure\nRestartSec=3\nNoNewPrivileges=yes\nProtectSystem=strict\nPrivateTmp=yes\nPrivateDevices=yes\nProtectHome=yes\nProtectProc=invisible\nProcSubset=pid\nRestrictNamespaces=yes\nRestrictRealtime=yes\nRestrictSUIDSGID=yes\nLockPersonality=yes\nLimitNOFILE=65536\nRestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK\nIPAccounting=yes\nIPAddressDeny=any\nIPAddressAllow=localhost {DCS} {peer}/32\n[Install]\nWantedBy=multi-user.target\n')
  # Proc mount protection is reapplied before backend on boot; no reboot tested.
  atomic(lib/'ensure-proc.py','import subprocess\nsubprocess.run(["mount","-o","remount,hidepid=2","/proc"],check=True)\n',0o755)
  procunit=unit(c,'proc');service(c,'proc',f'[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart={sys.executable} {lib}/ensure-proc.py\n[Install]\nWantedBy=multi-user.target\n')
  drop=Path('/etc/systemd/system')/(unit(c,'mt')+'.d')/'proc.conf';atomic(drop,f'[Unit]\nRequires={procunit}\nAfter={procunit}\n',0o644)
 if c['role']=='entry':
  service(c,'watch',f'[Unit]\nAfter={unit(c,"wg")}\n[Service]\nType=oneshot\nTimeoutStartSec=8\nExecStart={sys.executable} {agent} watch {c["id"]}\nLimitCORE=0\n')
  timer=Path('/etc/systemd/system')/unit(c,'watch').replace('.service','.timer')
  atomic(timer,'[Timer]\nOnBootSec=10\nOnUnitActiveSec=10\nAccuracySec=1\n[Install]\nWantedBy=timers.target\n',0o644)
 else:
  service(c,'refresh',f'[Service]\nType=oneshot\nTimeoutStartSec=150\nExecStart={sys.executable} {agent} refresh {c["id"]}\nLimitCORE=0\n')
  timer=Path('/etc/systemd/system')/unit(c,'refresh').replace('.service','.timer')
  atomic(timer,'[Timer]\nOnActiveSec=7h\nOnUnitActiveSec=7h\nAccuracySec=5m\n[Install]\nWantedBy=timers.target\n',0o644)
 run(['systemctl','daemon-reload'])
 for suffix in ['guard','wg']+(['proc','mt'] if c['role']=='exit' else []):run(['systemctl','enable','--now',unit(c,suffix)])
 timer=unit(c,'watch' if c['role']=='entry' else 'refresh').replace('.service','.timer')
 run(['systemctl','enable',timer])
 if c['role']=='exit':run(['systemctl','start',timer])
 if c['role']=='exit':
  run(['systemctl','restart',unit(c,'mt')])
  for _ in range(15):
   if owned_listener(c):break
   time.sleep(.2)
  else:raise Fault('owned MTProxy listener not verified')
 # enable --now does not repair an already-active unit with a lost interface.
 runtime(c,True)
 return status(c)

def owned_listener(c):
 u=unit(c,'mt');group=run(['systemctl','show',u,'-p','ControlGroup','--value']).stdout.strip()
 if not group.startswith('/') or '..' in Path(group).parts:return False
 try:pids=set((Path('/sys/fs/cgroup')/group.lstrip('/')/'cgroup.procs').read_text().split())
 except OSError:return False
 listeners=run(['ss','-H','-lntp','sport = :'+str(c['client_port'])]).stdout
 owners=set(re.findall(r'pid=(\d+)',listeners))
 return bool(owners) and owners<=pids

def status(c):
 root,lib,*_=layout(c);units={s:run(['systemctl','is-active',unit(c,s)],False).stdout.strip() for s in ['wg','guard']+(['mt'] if c['role']=='exit' else [])}
 policy=True
 if c['role']=='exit':
  deny=run(['systemctl','show',unit(c,'mt'),'-p','IPAddressDeny','--value'],False).stdout
  count=run(['systemctl','show',unit(c,'mt'),'-p','IPIngressBytes','--value'],False).stdout.strip()
  policy='0.0.0.0/0' in deny and '::/0' in deny and count.isdigit()
 proc=hidden();table_present=run(['nft','list','table','inet',table(c)],False).returncode==0
 return {'id':c['id'],'role':c['role'],'units':units,'interface_present':Path('/sys/class/net/'+iface(c)).exists(),'proc_hidden':proc,'socket_filter_enforced':policy,'guard_table_present':table_present,'security_boundary':'OK' if proc and policy and table_present else 'ERROR','wireguard':run(['wg','show',iface(c)],False).stdout,'material_updated':c.get('material_updated'),'packages_retained':json.loads((root/'packages.json').read_text()) if (root/'packages.json').exists() else {}}

def remove(c):
 root,lib,prefix,own,peer=layout(c)
 if not root.exists():
  residual=lib.exists() or keypath(c).exists() or Path('/sys/class/net/'+iface(c)).exists()
  residual=residual or bool(list(Path('/etc/systemd/system').glob(prefix+'-*')))
  if residual:raise Fault('ownership record missing with residual resources; cleanup UNKNOWN')
  return {'removed':True}
 old=json.loads(cfgpath(c).read_text())
 if old['id']!=c['id']:raise Fault('ownership mismatch')
 c=old
 if c.get('operation'):
  jobname=layout(c)[2]+'-apply-'+c['operation'][:8]+'.service'
  if run(['systemctl','is-active',jobname],False).stdout.strip() in ('active','activating'):raise Fault('provisioning job still running; query receipt before removal')
 for s in ['watch','refresh']:
  timer=Path('/etc/systemd/system')/unit(c,s).replace('.service','.timer')
  if timer.exists():run(['systemctl','disable','--now',timer.name]);timer.unlink()
 for s in ['watch','refresh','mt','stats','guard','wg','proc']:
  f=Path('/etc/systemd/system')/unit(c,s)
  if f.exists():
   run(['systemctl','disable','--now',unit(c,s)])
   if run(['systemctl','is-active',unit(c,s)],False).stdout.strip() not in ('inactive','failed','unknown',''):raise Fault('unit not proven stopped')
   f.unlink();shutil.rmtree(str(f)+'.d',ignore_errors=True)
 runtime(c,False);run(['ip','route','del','blackhole',peer+'/32','metric','32760'],False);run(['systemctl','daemon-reload'])
 if Path('/sys/class/net/'+iface(c)).exists():raise Fault('interface cleanup failed')
 if run(['nft','list','table','inet',table(c)],False).returncode==0:raise Fault('owned guard still present')
 warnings=[]
 if c.get('proc_changed'):
  if run(['pgrep','-x','mtproto-proxy'],False).returncode==0:warnings.append('procfs retained: other MTProxy processes exist')
  else:run(['mount','-o','remount,hidepid=0','/proc'])
 if c.get('management_user'):
  (Path('/etc/ssh/twebproxy-bridge')/c['id']).unlink(missing_ok=True)
  (Path('/etc/sudoers.d')/('twb-'+c['id'])).unlink(missing_ok=True)
  (Path('/etc/ssh/sshd_config.d')/('90-twb-'+c['id']+'.conf')).unlink(missing_ok=True)
  run(['/usr/sbin/sshd','-t']);run(['systemctl','reload','ssh'])
  if run(['id','-u',c['management_user']],False).returncode==0:run(['userdel','--force',c['management_user']])
 retained=json.loads((root/'packages.json').read_text()) if (root/'packages.json').exists() else {}
 keypath(c).unlink(missing_ok=True)
 run(['systemctl','reset-failed',layout(c)[2]+'-*'],False)
 shutil.rmtree(root);shutil.rmtree(lib,ignore_errors=True)
 return {'removed':True,'warnings':warnings,'packages_retained':retained}

def restore_owned_peer_route(c):
 # Link-down flushes an explicitly added route. Restore only our lost route,
 # never an administrator's competing route, and only after the link is up.
 dev=iface(c);peer=c['peer_ip'];routes=run(['ip','-j','route','show','exact',peer+'/32'],False)
 if routes.returncode:return False
 current=json.loads(routes.stdout)
 if any(r.get('dev')==dev for r in current):return True
 if not current or any(r.get('type')!='blackhole' or r.get('metric')!=32760 for r in current):return False
 if run(['nft','list','table','inet',table(c)],False).returncode:return False
 link=run(['ip','-j','link','show',dev],False)
 if link.returncode:return False
 links=json.loads(link.stdout)
 if not links or 'UP' not in links[0].get('flags',[]):return False
 key=run(['wg','show',dev,'public-key'],False)
 if key.returncode or key.stdout.strip()!=c['public_key']:return False
 run(['ip','route','replace',peer+'/32','dev',dev,'metric','100']);return True

def watch(c):
 root,lib,prefix,own,peer=layout(c);sfile=root/'watch.json'
 try:
  state=json.loads(Path('/etc/twebproxy/bridge/node.json').read_text())
  side=Path('/etc/twebproxy/instances')/state['hostname']/'bridge.json'
  active=state['id']==c['id'] and state['phase']=='active' and json.loads(side.read_text())['id']==c['id']
 except Exception:active=False
 socket_unit=prefix+'-forward.socket';service_unit=prefix+'-forward.service'
 if not active:
  run(['systemctl','stop',socket_unit,service_unit],False);atomic(sfile,json.dumps({'failures':0,'successes':0}));return
 counters=json.loads(sfile.read_text()) if sfile.exists() else {'failures':0,'successes':0}
 try:
  restore_owned_peer_route(c)
  route=json.loads(run(['ip','-j','route','get',peer]).stdout)
  if not route or route[0].get('dev')!=iface(c) or run(['nft','list','table','inet',table(c)],False).returncode:raise OSError('private route/security boundary unavailable')
  with socket.create_connection((peer,c['client_port']),timeout=5):good=True
 except (OSError,Fault):good=False
 counters={'failures':0 if good else counters['failures']+1,'successes':counters['successes']+1 if good else 0,'observed_at':time.time()}
 atomic(sfile,json.dumps(counters))
 if counters['failures']>=3:
  run(['systemctl','stop',socket_unit]);run(['systemctl','stop',service_unit])
 elif counters['successes']>=2 and hidden():
  if run(['systemctl','is-active',unit(c,'guard')],False).stdout.strip()=='active':run(['systemctl','start',socket_unit])

def refresh(c):
 root=layout(c)[0];pending=[]
 try:
  for name,url in [('proxy-secret','https://core.telegram.org/getProxySecret'),('proxy-multi.conf','https://core.telegram.org/getProxyConfig')]:
   fd,path=tempfile.mkstemp(prefix='.material-',dir=root);os.close(fd);pending.append((path,root/name))
   material_download(url,path)
   if not Path(path).stat().st_size:raise Fault('empty Telegram material refused')
  for path,dest in pending:os.chmod(path,0o600);os.replace(path,dest)
  c['material_updated']=time.time();save(c);run(['systemctl','restart',unit(c,'mt')])
 finally:
  for path,_ in pending:Path(path).unlink(missing_ok=True)

def read_request():
 signal.signal(signal.SIGALRM,lambda *_:(_ for _ in ()).throw(Fault('request input deadline exceeded')))
 signal.alarm(20)
 raw=sys.stdin.buffer.read(262145);signal.alarm(0)
 if len(raw)>262144:raise Fault('request too large')
 def depth(x,n=0):
  if n>12:raise Fault('request nesting limit')
  if isinstance(x,dict):
   for v in x.values():depth(v,n+1)
  elif isinstance(x,list):
   for v in x:depth(v,n+1)
 x=json.loads(raw);depth(x)
 if not isinstance(x,dict) or set(x)-{'op','config','source','public_key','user','credential','operation','digest','generation'}:raise Fault('unknown request fields')
 return x

def receipt(c,operation,data):
 data['observed_at']=time.time();atomic(layout(c)[0]/('op-'+operation+'.json'),json.dumps(data))

def job(c,operation):
 with private_lock('apply.lock') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  if not cfgpath(c).exists():raise Fault('owned apply canceled; configuration absent')
  c=json.loads(cfgpath(c).read_text());c['operation']=operation;save(c)
  try:
   receipt(c,operation,{'phase':'applying','generation':c['generation']})
   result=deploy(c);receipt(c,operation,{'phase':'complete','generation':c['generation'],'result':result})
  except Exception as e:
   if cfgpath(c).exists():receipt(c,operation,{'phase':'failed','error':str(e) if isinstance(e,Fault) else type(e).__name__})
   raise

def main():
 import resource
 resource.setrlimit(resource.RLIMIT_CORE,(0,0));ctypes.CDLL(None).prctl(4,0,0,0,0)
 os.umask(0o077);os.environ['PATH']='/usr/sbin:/usr/bin:/sbin:/bin';os.environ['DEBIAN_FRONTEND']='noninteractive';os.environ['NEEDRESTART_MODE']='l'
 if len(sys.argv)>1 and sys.argv[1]=='gate':gate(sys.argv[2]);return
 if len(sys.argv)>2 and sys.argv[1] in ('up','down','guard','job','watch','refresh'):
  owner=sys.argv[2]
  if not re.fullmatch('[0-9a-f]{32}',owner):raise Fault('invalid owner')
  c=json.loads((BASE/owner/'config.json').read_text())
  if sys.argv[1]=='guard':guard(c)
  elif sys.argv[1]=='job':job(c,sys.argv[3])
  elif sys.argv[1]=='watch':watch(c)
  elif sys.argv[1]=='refresh':
   with private_lock('apply.lock') as lock:
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:raise Fault('owned apply/refresh already running')
    refresh(c)
  else:runtime(c,sys.argv[1]=='up')
  return
 req=read_request();op=req['op'];c=req['config'];validate(c)
 public={'schema','id','role','endpoint','peer_endpoint','wg_port','client_port','stats_port','local_port','backend_id','own_ip','peer_ip','peer_key','public_key','generation'}
 if set(c)-public:raise Fault('internal configuration fields not permitted in requests')
 common={'op','config','generation','digest'}
 extras={'inspect':set(),'bootstrap':{'source','public_key','user'},'deploy':{'operation','credential'},'opstatus':{'operation'},'status':set(),'remove':set()}
 if op not in extras or set(req)-(common|extras[op]):raise Fault('unknown verb/request fields')
 if op in ('deploy','opstatus') and not re.fullmatch('[0-9a-f]{32}',req.get('operation','')):raise Fault('invalid operation')
 if op=='deploy' and not c.get('peer_key'):raise Fault('peer identity must be prepared before apply')
 if 'credential' in req and (c['role']!='exit' or not isinstance(req['credential'],str) or not re.fullmatch('[0-9a-f]{32}',req['credential'])):raise Fault('invalid credential input')
 restricted=len(sys.argv)>1 and sys.argv[1]=='rpc'
 if restricted:
  if c['id']!=sys.argv[2] or c['role']!='exit' or op not in ('deploy','status','remove','opstatus'):raise Fault('managed key request refused')
  existing=json.loads(cfgpath(c).read_text())
  if hashlib.sha256(Path(__file__).read_bytes()).hexdigest()!=existing['executor_sha256']:raise Fault('installed executor digest mismatch')
  if type(req.get('generation')) is not int or req.get('generation')!=existing['generation']:raise Fault('stale generation')
  if req.get('digest')!=existing['executor_sha256']:raise Fault('executor digest mismatch')
  for k in ['id','role','endpoint','peer_endpoint','own_ip','peer_ip','client_port','stats_port','local_port','backend_id','wg_port','public_key']:
   if c[k]!=existing[k]:raise Fault('manifest identity mismatch')
  if op=='deploy' and not existing.get('peer_key'):
   candidate=dict(existing);candidate['peer_key']=c.get('peer_key');validate(candidate);save(candidate);existing=candidate
  elif c.get('peer_key')!=existing.get('peer_key'):raise Fault('peer identity change requires re-enrollment')
  c=existing
 if os.geteuid()!=0:raise Fault('root required')
 if op in ('inspect','status','opstatus'):
  if op=='inspect':result=preflight(c)
  elif op=='status':result=status(c)
  else:
   operation=req['operation']
   if not re.fullmatch('[0-9a-f]{32}',operation):raise Fault('invalid operation')
   result=json.loads((layout(c)[0]/('op-'+operation+'.json')).read_text())
  print(json.dumps({'ok':True,'result':result}));return
 with private_lock('agent.lock') as lock:
  try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:raise Fault('node operation busy')
  if op=='inspect':result=preflight(c)
  elif op=='bootstrap':result=bootstrap(c,base64.b64decode(req['source']).decode(),req['public_key'],req.get('user','root'))
  elif op=='deploy':
   root,lib,*_=layout(c);existing=json.loads(cfgpath(c).read_text())
   pending=existing.get('operation')
   if pending and pending!=req.get('operation'):
    active=run(['systemctl','is-active',layout(c)[2]+'-apply-'+pending[:8]+'.service'],False)
    if active.stdout.strip() in ('active','activating'):raise Fault('existing apply job in progress; query its receipt')
    if active.returncode not in (0,3,4):raise Fault('apply job state unknown')
   if existing.get('peer_key') and existing['peer_key']!=c.get('peer_key'):raise Fault('peer mismatch')
   c.update({k:existing[k] for k in ['management_user','public_key','executor_sha256'] if k in existing});save(c)
   if req.get('credential'):
    value=req['credential']
    if not re.fullmatch('[0-9a-f]{32}',value):raise Fault('invalid client credential')
    if (root/'client-secret').exists() and (root/'client-secret').read_text().strip()!=value:raise Fault('credential replacement requires remove/re-enroll')
    atomic(root/'client-secret',value+'\n')
   operation=req['operation']
   if not re.fullmatch('[0-9a-f]{32}',operation):raise Fault('invalid operation')
   f=root/('op-'+operation+'.json')
   if f.exists():result=json.loads(f.read_text())
   else:
    c['operation']=operation;save(c)
    receipt(c,operation,{'phase':'prepared','generation':c['generation']})
    run(['systemd-run','--unit='+layout(c)[2]+'-apply-'+operation[:8],'--property=Type=exec','--property=RuntimeMaxSec=900','/usr/bin/python3',str(lib/'agent.py'),'job',c['id'],operation])
    result={'phase':'prepared','operation':operation}
  elif op=='opstatus':
   operation=req['operation']
   if not re.fullmatch('[0-9a-f]{32}',operation):raise Fault('invalid operation')
   result=json.loads((layout(c)[0]/('op-'+operation+'.json')).read_text())
  elif op=='status':result=status(c)
  elif op=='remove':
   active=run(['systemctl','list-units','--state=active,activating','--no-legend',layout(c)[2]+'-apply-*.service']).stdout.strip()
   if active:raise Fault('owned apply job still running; inspect receipt before removal')
   with private_lock('apply.lock') as applying:
    try:fcntl.flock(applying,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:raise Fault('owned apply/refresh in progress; cleanup pending')
    result=remove(c)
  else:raise Fault('unknown operation')
 print(json.dumps({'ok':True,'result':result}))
if __name__=='__main__':
 try:main()
 except Exception as e:
  print(json.dumps({'ok':False,'error':str(e) if isinstance(e,Fault) else type(e).__name__}));sys.exit(1)
