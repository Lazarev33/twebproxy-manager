#!/usr/bin/env python3
"""Gate2 one-node controller; Paramiko loaded only by verified isolated launcher."""
import argparse,base64,ctypes,fcntl,getpass,hashlib,ipaddress,json,logging,os,resource,secrets,shlex,socket,subprocess,sys,tempfile,time,uuid
from pathlib import Path
import paramiko
import builtins
LANG=os.environ.get('TWEBPROXY_BRIDGE_LANG','en')
INTERACTIVE=os.environ.get('TWEBPROXY_BRIDGE_INTERACTIVE')=='1'
TEXT={
'Installation plan:':'План установки:',
'Entry OS / foreign OS:':'ОС входного / зарубежного узла:',
'Running foreign service count:':'Запущенных служб зарубежного узла:',
'Managed hostname / profile:':'Управляемое имя / профиль:',
'Automatic: WireGuard keys/private addresses, checked internal ports, private MTProxy and loopback forwarding. The existing client key/link is retained.':'Автоматически: ключи/внутренние адреса WireGuard, проверенные внутренние порты, закрытый MTProxy и перенаправление через loopback. Текущий клиентский ключ/ссылка сохраняются.',
'Affected: owned units/account/restricted SSH, WireGuard/routes/firewall and the selected relay. Connections may be interrupted; unrelated services are retained.':'Затронуты: собственные службы/учётная запись/ограниченный SSH, WireGuard/маршруты/firewall и выбранный relay. Соединения могут прерваться; сторонние службы сохраняются.',
'Security: foreign root can read the client key. Host-wide procfs protection affects process visibility/monitoring. Enroll only a trusted server.':'Безопасность: root зарубежного сервера может читать клиентский ключ. Защита procfs меняет видимость процессов/мониторинг на хосте. Добавляйте только доверенный сервер.',
'Recovery: partial setup is compensated; incomplete cleanup keeps its identity for Repair. Installed shared packages remain. No SSH password is saved.':'Восстановление: частичная установка компенсируется; незавершённая очистка сохраняет идентичность для восстановления. Общие установленные пакеты остаются. Пароль SSH не сохраняется.',
'Cancel / Back':'Отмена / Назад',
'Choose a managed hostname:':'Выберите управляемое имя:',
'SSH connection settings:':'Параметры подключения SSH:',
'Use root on port 22 (standard)':'root, порт 22 (стандартно)',
'Custom SSH user/port':'Другой пользователь/порт SSH',
'Authentication method:':'Способ аутентификации:',
'SSH password (memory only)':'Пароль SSH (только в памяти)',
'Existing SSH key':'Существующий ключ SSH',
'Invalid selection; enter a number.':'Неверный выбор; введите номер.',
'Empty SSH password refused':'Пустой пароль SSH не принимается',
'Foreign IPv4/hostname: ':'IP/имя зарубежного узла: ',
'SSH username [root]: ':'Пользователь SSH [root]: ',
'SSH port [22]: ':'Порт SSH [22]: ',
'Existing HTTPS hostname: ':'Управляемое имя HTTPS: ',
'Authentication [key/password]: ':'Способ SSH [key — ключ / password — пароль]: ',
'Existing private key path: ':'Путь к существующему приватному ключу: ',
'Initial SSH password (memory only): ':'Начальный пароль SSH (только в памяти): ',
'Key passphrase (memory only): ':'Парольная фраза ключа (только в памяти): ',
'Approve installation? [yes/NO]: ':'Одобрить установку? [да/НЕТ]: ',
'Compare through provider/trusted channel; enter full SHA256 fingerprint: ':'Сверьте с консолью провайдера и введите полный отпечаток SHA256: ',
'Restore local backend and remove owned foreign node? [yes/NO]: ':'Восстановить локальный сервер и удалить зарубежный узел? [да/НЕТ]: ',
'Initial SSH password for cleanup (memory only): ':'Начальный пароль SSH для очистки (только в памяти): ',
'Bridge profile provisioned. Transport verified; Telegram account/client test UNKNOWN.':'Мост настроен. Транспорт проверен; проверка приложения Telegram не выполнена.',
'Node removed; original local profile restored; shared packages retained.':'Узел удалён; локальный профиль восстановлен; общие пакеты оставлены.',
'Interrupted operation rolled back; run Add Foreign Node again.':'Прерванная операция откачена; повторите добавление зарубежного узла.',
'CANCELLED; no Bridge changes applied':'ОТМЕНЕНО; изменения моста не применялись',
'one node already exists or cleanup is pending; use status/repair/remove':'Зарубежный узел уже существует либо очистка ещё не завершена. Текущее состояние сохранено. Используйте «Статус», «Восстановить» или «Удалить» (foreign-node status|repair|remove).',
'another node operation is in progress':'Другая операция с узлом уже выполняется. Дождитесь её завершения.',
'no managed foreign node':'Управляемый зарубежный узел не найден.',
'unsupported/corrupt state; activation blocked':'Состояние повреждено или имеет неподдерживаемый формат; активация заблокирована.',
'root required':'Требуются права root.',
'invalid SSH port':'Недопустимый порт SSH: укажите число от 1 до 65535.',
'invalid foreign address':'Недопустимый адрес зарубежного узла.',
'invalid username':'Недопустимое имя пользователя SSH.',
'existing managed hostname required':'Укажите существующее управляемое имя HTTPS.',
'Gate2 MVP requires an instance with exactly one profile; other instances are preserved':'Для моста нужен инстанс ровно с одним профилем; остальные инстансы сохраняются.',
'normal instance setup did not complete':'Обычная настройка инстанса не завершена.',
'First configure the HTTPS/domain through the existing normal setup wizard. Bridge preparation follows after local setup succeeds.':'Сначала настройте домен и HTTPS через обычный мастер. Настройка моста продолжится после успешной локальной установки.',
'SSH host ED25519 fingerprint:':'Отпечаток ED25519 сервера SSH:',
'host identity not independently approved':'Подлинность сервера не подтверждена независимой проверкой.',
'HOST_IDENTITY_CHANGED; no authentication attempted':'Подлинность сервера изменилась; аутентификация не выполнялась.',
'AUTHENTICATION_FAILED':'Аутентификация SSH не удалась.',
'existing private key must be protected (0600 or stricter); permissions were not changed':'Приватный ключ должен иметь права 0600 или строже; права не изменялись.',
'unsupported authentication method; choose key or password':'Неподдерживаемый способ аутентификации: выберите key (ключ) или password (пароль).',
'Bridge credential handling requires no active swap in this MVP':'Работа с учётными данными моста требует отсутствия активного swap в этой версии.',
'password bootstrap requires no active swap in MVP':'Первичная настройка по паролю требует отсутствия активного swap в этой версии.',
'entry and foreign endpoints must differ':'Адреса входного и зарубежного узлов должны различаться.',
'entry and exit must be distinct installations':'Входной и зарубежный узлы должны быть разными системами.',
'credential-bearing provisioning refused: sudo input logging configured':'Передача учётных данных запрещена: настроено журналирование ввода sudo.',
'PARTIAL: cleanup pending; identity retained for retry':'ЧАСТИЧНО: очистка не завершена; данные узла сохранены для повторной попытки.',
'PARTIAL: interrupted operation cleanup pending; retry repair with initial --identity or --auth password':'ЧАСТИЧНО: очистка прерванной операции не завершена; повторите repair с исходным --identity или --auth password.',
'Cancelled; inspect status if an operation had started.':'Отменено; если операция уже началась, проверьте состояние узла.',
'provisioning job timeout; inspect operation receipt before retry':'Истекло время установки; перед повтором проверьте результат операции.',
'private path unavailable; no readiness claim':'Закрытый канал недоступен; готовность не подтверждена.',
'direct private TCP target unavailable':'Закрытый TCP-адрес назначения недоступен.',
'forwarder socket policy not enforced':'Сетевая политика сокета перенаправления не применяется.',
'restricted credential accepted forbidden verb':'Ограниченные учётные данные позволили запрещённую операцию.',
'remote output limit exceeded':'Превышен предел вывода удалённой команды.',
'REMOTE_TIMEOUT; operation outcome may be unknown':'Истекло время удалённой операции; её результат может быть неизвестен.'
}
def tr(s):return TEXT.get(s,s) if LANG=='ru' else s
def confirmed(s):return s.strip().lower() in ('y','yes','д','да')
def confirm_prompt(s):
 # Keep the delimiter so an unfinished affirmative followed by EOF cancels.
 builtins.print(tr(s),end='',flush=True)
 answer=sys.stdin.readline()
 if not answer.endswith('\n'):raise EOFError
 return confirmed(answer)
def select(s,options):
 builtins.print(tr(s))
 for n,label in enumerate(options,1):builtins.print(str(n)+') '+tr(label))
 builtins.print('0) '+tr('Cancel / Back'))
 while True:
  answer=ask('> ').strip()
  if answer=='0':raise KeyboardInterrupt
  if answer.isascii() and answer.isdigit() and 1<=int(answer)<=len(options):return int(answer)
  print('Invalid selection; enter a number.')
def ask(s):return builtins.input(tr(s))
def hidden_prompt(s):return getpass.getpass(tr(s))
def print(*args,**kwargs):return builtins.print(*(tr(x) if isinstance(x,str) else x for x in args),**kwargs)
from agent import atomic,Fault,layout,unit,iface,cfgpath,validate,private_lock
ROOT=Path('/etc/twebproxy/bridge');STATE=ROOT/'node.json';HERE=Path(__file__).resolve().parent
MANAGER=str(Path(os.environ.get('TWEBPROXY_MANAGER','/usr/local/sbin/twebproxy')).resolve())
logging.disable(logging.CRITICAL)

def secret_process():
 resource.setrlimit(resource.RLIMIT_CORE,(0,0));ctypes.CDLL(None).prctl(4,0,0,0,0);os.umask(0o077)
 if len(Path('/proc/swaps').read_text().splitlines())>1:raise Fault('Bridge credential handling requires no active swap in this MVP')

def config_safe(c):return {k:v for k,v in c.items() if k not in ('secret','private_key','password')}
def journal(s,phase=None):
 if phase:
  s['phase']=phase;s.setdefault('phase_history',[]).append({'phase':phase,'at':time.time()})
 s['updated_at']=time.time();atomic(STATE,json.dumps(s))
 if phase and os.getenv('TWEBPROXY_BRIDGE_CRASH_AFTER')==phase:os.kill(os.getpid(),9)
 if phase and os.getenv('TWEBPROXY_BRIDGE_FAIL_AFTER')==phase:raise Fault('injected phase failure: '+phase)

def local(a,input=None,timeout=120):
 p=subprocess.run(a,input=input,text=True,capture_output=True,timeout=timeout)
 if p.returncode:raise Fault('local command failed: '+Path(a[0]).name+' rc='+str(p.returncode))
 return p.stdout

def manager(verb,*args):return local([MANAGER,'bridge-internal',verb,*map(str,args)])
def agent(c,op,**kw):
 req={'op':op,'config':c,**kw};raw=local(['/usr/bin/python3',str(HERE/'agent.py')],json.dumps(req),timeout=900);r=json.loads(raw)
 if not r.get('ok'):raise Fault(r.get('error','local executor failed'))
 return r['result']
def fp(key):return 'SHA256:'+base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')

class SSH:
 def __init__(self,ip,port,expected=None,public=None):
  self.sock=socket.create_connection((ip,port),timeout=10)
  self.t=paramiko.Transport(self.sock);self.t.banner_timeout=10;self.t.auth_timeout=12
  opts=self.t.get_security_options();opts.key_types=('ssh-ed25519',);opts.kex=tuple(k for k in opts.kex if k in ('mlkem768x25519-sha256','curve25519-sha256@libssh.org','ecdh-sha2-nistp256','diffie-hellman-group16-sha512'));opts.ciphers=('aes256-ctr','aes128-ctr');opts.digests=('hmac-sha2-512','hmac-sha2-256')
  self.t.start_client(timeout=10);key=self.t.get_remote_server_key();self.fingerprint=fp(key);self.host_key=base64.b64encode(key.asbytes()).decode()
  if expected is not None and self.fingerprint!=expected:self.close();raise Fault('HOST_IDENTITY_CHANGED; no authentication attempted')
  if public is not None and self.host_key!=public:self.close();raise Fault('HOST_IDENTITY_CHANGED; no authentication attempted')
 def auth(self,user,password=None,identity=None,passphrase=None):
  if password is not None:
   if not password:raise Fault('Empty SSH password refused')
   self.t.auth_password(user,password,fallback=False)
  else:
   if Path(identity).stat().st_mode&0o077:raise Fault('existing private key must be protected (0600 or stricter); permissions were not changed')
   self.t.auth_publickey(user,paramiko.PKey.from_path(identity,password=passphrase))
  if not self.t.is_authenticated():raise Fault('AUTHENTICATION_FAILED')
 def command(self,command,request,timeout=40):
  ch=self.t.open_session(timeout=10);ch.settimeout(10);ch.exec_command(command);ch.sendall(json.dumps(request).encode());ch.shutdown_write();end=time.monotonic()+timeout;out=bytearray();err=bytearray()
  while True:
   if ch.recv_ready():out.extend(ch.recv(65536))
   if ch.recv_stderr_ready():err.extend(ch.recv_stderr(65536))
   if len(out)+len(err)>262144:ch.close();raise Fault('remote output limit exceeded')
   if ch.exit_status_ready() and not ch.recv_ready() and not ch.recv_stderr_ready():break
   if time.monotonic()>end:ch.close();raise Fault('REMOTE_TIMEOUT; operation outcome may be unknown')
   time.sleep(.02)
  rc=ch.recv_exit_status();ch.close()
  try:r=json.loads(out)
  except Exception:raise Fault('remote executor did not return valid JSON (rc='+str(rc)+')')
  if rc or not r.get('ok'):raise Fault(r.get('error','remote execution failed'))
  return r['result']
 def close(self):self.t.close();self.sock.close()

def managed(s):
 t=SSH(s['ip'],s['port'],s['fingerprint'],s['host_key']);t.auth(s['management_user'],identity=str(ROOT/'credentials/management-key'));return t

def rpc(s,op,t=None,**kw):
 own=t is None
 if own:t=managed(s)
 try:return t.command('bridge',{'op':op,'config':s['exit'],'generation':1,'digest':s['executor_digest'],**kw})
 finally:
  if own:t.close()

def apply(s,role,credential=None):
 c=s[role];operation=uuid.uuid4().hex;s[role+'_operation']=operation;journal(s)
 req={'operation':operation}
 if credential is not None:req['credential']=credential
 result=rpc(s,'deploy',**req) if role=='exit' else agent(c,'deploy',**req)
 print(role+': '+result['phase'],flush=True);last=result['phase']
 end=time.monotonic()+910
 while result['phase'] not in ('complete','failed'):
  if time.monotonic()>end:raise Fault('provisioning job timeout; inspect operation receipt before retry')
  time.sleep(1);result=rpc(s,'opstatus',operation=operation) if role=='exit' else agent(c,'opstatus',operation=operation)
  if result['phase']!=last:print(role+': '+result['phase'],flush=True);last=result['phase']
 if result['phase']!='complete':raise Fault('owned '+role+' job failed: '+result.get('error','unknown'))
 return result

def tcp(c):
 try:
  if not Path('/sys/class/net/'+iface(c)).exists():return False
  route=json.loads(local(['ip','-j','route','get',c['peer_ip']]))
  if not route or route[0].get('dev')!=iface(c):return False
  p=subprocess.run(['nft','list','table','inet','twb_'+c['id'][:12]],capture_output=True,timeout=5)
  if p.returncode:return False
  with socket.create_connection((c['peer_ip'],c['client_port']),timeout=5):return True
 except Exception:return False

def forward_units(s):
 c=s['entry'];root,lib,prefix,own,peer=layout(c);sock=prefix+'-forward.socket';svc=prefix+'-forward.service';deps=unit(c,'wg')+' '+unit(c,'guard')
 atomic(Path('/etc/systemd/system')/sock,f'[Unit]\nRequires={deps}\nAfter={deps}\nBindsTo={deps}\n[Socket]\nListenStream=127.0.0.1:{c["local_port"]}\nAccept=no\nIPAccounting=yes\nIPAddressDeny=any\nIPAddressAllow=localhost\n[Install]\nWantedBy=sockets.target\n',0o644)
 atomic(Path('/etc/systemd/system')/svc,f'[Unit]\nRequires={deps}\nAfter={deps}\nBindsTo={deps}\n[Service]\nType=exec\nDynamicUser=yes\nExecStartPre=+/usr/bin/python3 {lib}/agent.py gate %n\nExecStart=/usr/lib/systemd/systemd-socket-proxyd --connections-max=4160 {peer}:{c["client_port"]}\nRestart=on-failure\nRestartSec=3\nLimitNOFILE=65536\nNoNewPrivileges=yes\nPrivateTmp=yes\nPrivateDevices=yes\nProtectHome=yes\nProtectSystem=strict\nRestrictAddressFamilies=AF_INET AF_INET6\nIPAccounting=yes\nIPAddressDeny=any\nIPAddressAllow=localhost {peer}/32\n',0o644)
 local(['systemctl','daemon-reload']);local(['systemctl','enable','--now',sock])
 with socket.create_connection(('127.0.0.1',c['local_port']),timeout=3):pass
 # Assert both sides of socket activation carry real kernel enforcement.
 for u in [sock,svc]:
  deny=local(['systemctl','show',u,'-p','IPAddressDeny','--value']);count=local(['systemctl','show',u,'-p','IPIngressBytes','--value']).strip()
  if '0.0.0.0/0' not in deny or '::/0' not in deny or not count.isdigit():raise Fault('forwarder socket policy not enforced')

def stop_forward(s):
 prefix=layout(s['entry'])[2]
 subprocess.run(['systemctl','stop',prefix+'-watch.timer',prefix+'-watch.service'],capture_output=True,timeout=20)
 for ext in ['socket','service']:
  name=prefix+'-forward.'+ext;f=Path('/etc/systemd/system')/name
  if f.exists():
   local(['systemctl','disable','--now',name]);f.unlink()
 local(['systemctl','daemon-reload'])

def rollback(s,recovery=None,recovery_user="root"):
 errors=[]
 journal(s,'removing')
 # Compensate mapping first, only after old current-secret local backend is ready.
 side=Path('/etc/twebproxy/instances')/s['hostname']/'bridge.json'
 if side.exists() or side.with_name('bridge.owner').exists():
  try:manager('detach',s['hostname'],s['profile'],s['previous_port']);s['detached']=True;journal(s)
  except Exception:errors.append('local mapping restoration failed; denial and credentials retained')
 if not errors:
  try:stop_forward(s)
  except Exception:errors.append('forwarder cleanup pending')
  try:agent(s['entry'],'remove')
  except Exception:errors.append('entry cleanup pending')
 if errors:
  s['cleanup_debt']=errors;journal(s,'cleanup_pending');return False
 try:
  if not s.get('remote_removed'):
   s['remote_cleanup_receipt']=rpc(s,'remove')
  s['remote_removed']=True;journal(s)
 except Exception:
  if recovery is not None:
   try:
    command=('sudo -n ' if recovery_user!='root' else '')+'/usr/bin/python3 -c '+shlex.quote((HERE/'agent.py').read_text())
    recovery.command(command,{'op':'remove','config':s['exit']},timeout=90);s['remote_removed']=True;journal(s)
   except Exception:errors.append('remote cleanup pending; bootstrap retry required')
  else:errors.append('remote cleanup pending; dedicated identity retained for retry')
 if errors:
  s['cleanup_debt']=errors;journal(s,'cleanup_pending');return False
 s['cleanup_debt']=[];journal(s,'cleanup_complete')
 history=ROOT/'operations';history.mkdir(mode=0o700,exist_ok=True)
 receipt={k:s.get(k) for k in ['id','hostname','profile','phase','phase_history','updated_at','remote_cleanup_receipt']}
 atomic(history/(s['id']+'.json'),json.dumps(receipt))
 for old in sorted(history.glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)[20:]:old.unlink()
 import shutil
 shutil.rmtree(ROOT/'credentials',ignore_errors=True);STATE.unlink(missing_ok=True)
 return True

def choose_instance(a):
 hosts=[p.parent.name for p in Path('/etc/twebproxy/instances').glob('*/instance.env')]
 if not hosts:
  print('First configure the HTTPS/domain through the existing normal setup wizard. Bridge preparation follows after local setup succeeds.')
  args=[MANAGER,'bridge-internal','quick-setup'] if INTERACTIVE else [MANAGER,'add']
  if subprocess.run(args).returncode:raise Fault('normal instance setup did not complete')
  hosts=[p.parent.name for p in Path('/etc/twebproxy/instances').glob('*/instance.env')]
 hosts.sort()
 name=a.instance or (hosts[0] if len(hosts)==1 else hosts[select('Choose a managed hostname:',hosts)-1] if INTERACTIVE and hosts else ask('Existing HTTPS hostname: ').strip())
 if name not in hosts:raise Fault('existing managed hostname required')
 info=json.loads(manager('inspect',name))
 if len(info['profiles'])!=1:raise Fault('Gate2 MVP requires an instance with exactly one profile; other instances are preserved')
 return name,info

def stage_bootstrap(t,c,key,user,sudo=False):
 source=(HERE/'agent.py').read_bytes();digest=hashlib.sha256(source).hexdigest();staging='.twebproxy-stage-'+c['id'];sftp=paramiko.SFTPClient.from_transport(t.t)
 home=sftp.normalize('.');path=home+'/'+staging;sftp.mkdir(path,0o700)
 try:
  with sftp.file(path+'/agent.py','wb') as f:f.write(source)
  sftp.chmod(path+'/agent.py',0o600)
  # Root reads regular staged file once, hashes exact bytes, then executes bytes.
  code='import os,stat,hashlib,pwd; p='+repr(path+'/agent.py')+'; fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW); st=os.fstat(fd); assert stat.S_ISREG(st.st_mode) and st.st_size=='+str(len(source))+'; assert st.st_uid==pwd.getpwnam('+repr(user)+').pw_uid and st.st_mode & 0o077==0; b=os.read(fd,262144); os.close(fd); assert hashlib.sha256(b).hexdigest()=='+repr(digest)+'; exec(compile(b,p,"exec"),{"__name__":"__main__","__file__":p,"_VERIFIED_PAYLOAD_SHA256":'+repr(digest)+'})'
  command=('sudo -n ' if sudo else '')+'/usr/bin/python3 -c '+shlex.quote(code)
  return t.command(command,{'op':'bootstrap','config':c,'source':base64.b64encode(source).decode(),'public_key':key,'user':user},timeout=600)
 finally:
  try:sftp.remove(path+'/agent.py');sftp.rmdir(path)
  except Exception:pass
  sftp.close()

def show_plan(hostname,profile,localinfo,remote,digest):
 if INTERACTIVE:
  print('Installation plan:')
  print('Entry OS / foreign OS:',localinfo['version'],'/',remote['version'])
  print('Running foreign service count:',len(remote['services'].splitlines()))
  print('Managed hostname / profile:',hostname,'/',profile)
  print('Automatic: WireGuard keys/private addresses, checked internal ports, private MTProxy and loopback forwarding. The existing client key/link is retained.')
  print('Affected: owned units/account/restricted SSH, WireGuard/routes/firewall and the selected relay. Connections may be interrupted; unrelated services are retained.')
  print('Security: foreign root can read the client key. Host-wide procfs protection affects process visibility/monitoring. Enroll only a trusted server.')
  print('Recovery: partial setup is compensated; incomplete cleanup keeps its identity for Repair. Installed shared packages remain. No SSH password is saved.')
 else:
  print(json.dumps({'entry_os':localinfo['version'],'foreign_os':remote['version'],'existing_remote_services':remote['services'],'plan':{'hostname':hostname,'profile':profile,'topology':'one dedicated WireGuard peer, loopback proxyd, stock MTProxy','trust':'Foreign root receives the canonical profile secret; only enroll a trusted exit.','proc_policy':'Host-wide hidepid enforcement; monitoring impact must be accepted.','scoped_system_changes':'owned units/account/key/sudo/sshd Match; apt dependencies retained; host proc hardening; owned nft tables/route; affected relay restart','executor_sha256':digest}},indent=2))

def add(a):
 if STATE.exists():raise Fault('one node already exists or cleanup is pending; use status/repair/remove')
 hostname,info=choose_instance(a)
 if not a.host:
  a.host=ask('Foreign IPv4/hostname: ').strip()
  if not INTERACTIVE:a.port=int(ask('SSH port [22]: ').strip() or '22')
  if not 1<=a.port<=65535:raise Fault('invalid SSH port')
 if INTERACTIVE and not a.user and a.port==22:
  settings=select('SSH connection settings:',['Use root on port 22 (standard)','Custom SSH user/port'])
  if settings==1:a.user='root'
  else:a.user=ask('SSH username [root]: ').strip() or 'root';a.port=int(ask('SSH port [22]: ').strip() or '22')
  if not 1<=a.port<=65535:raise Fault('invalid SSH port')
 ip=socket.gethostbyname(a.host);addr=ipaddress.IPv4Address(ip)
 if addr.is_loopback or addr.is_unspecified or addr.is_multicast:raise Fault('invalid foreign address')
 user=a.user or ask('SSH username [root]: ').strip() or 'root'
 if not __import__('re').fullmatch('[a-z_][a-z0-9_-]*',user):raise Fault('invalid username')
 t=SSH(ip,a.port,a.fingerprint);bootstrap_available=True
 try:
  print('SSH host ED25519 fingerprint:',t.fingerprint)
  if not a.fingerprint:
   if ask('Compare through provider/trusted channel; enter full SHA256 fingerprint: ').strip()!=t.fingerprint:raise Fault('host identity not independently approved')
  password=None;passphrase=None;identity=a.identity
  mode=a.auth or ('key' if INTERACTIVE and identity else ('password','key')[select('Authentication method:',['SSH password (memory only)','Existing SSH key'])-1] if INTERACTIVE else ask('Authentication [key/password]: ').strip())
  if mode=='password':
   if len(Path('/proc/swaps').read_text().splitlines())>1:raise Fault('password bootstrap requires no active swap in MVP')
   password=hidden_prompt('Initial SSH password (memory only): ')
   if not password:raise Fault('Empty SSH password refused')
  elif mode=='key':
   identity=identity or ask('Existing private key path: ').strip()
   try:paramiko.PKey.from_path(identity)
   except paramiko.PasswordRequiredException:passphrase=hidden_prompt('Key passphrase (memory only): ')
  else:raise Fault('unsupported authentication method; choose key or password')
  t.auth(user,password=password,identity=identity,passphrase=passphrase);password=None;passphrase=None
  node=uuid.uuid4().hex
  # Allocate against authoritative local records; pending reservations are journaled below.
  port=int(manager('allocate'));profile=info['profiles'][0]['name'];previous=info['profiles'][0]['backend_port']
  route=json.loads(local(['ip','-j','route','get',ip]))[0];entry_ip=a.entry_endpoint or route.get('prefsrc') or route.get('src')
  if not entry_ip or entry_ip==ip:raise Fault('entry and foreign endpoints must differ')
  pair=secrets.randbelow(15000)+1;network=ipaddress.IPv4Network((int(ipaddress.IPv4Address('10.204.0.0'))+pair*4,30));own=str(network.network_address+1);peer=str(network.network_address+2)
  common={'schema':1,'id':node,'generation':1,'wg_port':51990,'client_port':24990,'stats_port':29990,'local_port':port,'backend_id':hostname+'--'+profile,'peer_key':'','public_key':''}
  entry={**common,'role':'entry','endpoint':entry_ip,'peer_endpoint':ip,'own_ip':own,'peer_ip':peer};exit={**common,'role':'exit','endpoint':ip,'peer_endpoint':entry_ip,'own_ip':peer,'peer_ip':own}
  code=(HERE/'agent.py').read_text();command=('sudo -n ' if user!='root' else '')+'/usr/bin/python3 -c '+shlex.quote(code)
  remote=t.command(command,{'op':'inspect','config':exit});localinfo=agent(entry,'inspect')
  if remote['machine_id_hash']==localinfo['machine_id_hash']:raise Fault('entry and exit must be distinct installations')
  # Do not transmit credentials through sudo sessions configured to log input.
  audit_code='import pathlib,json; fs=[pathlib.Path("/etc/sudoers")]+list(pathlib.Path("/etc/sudoers.d").glob("*")); print(json.dumps({"ok":True,"result":{"input_logging":any("log_input" in f.read_text(errors="ignore") for f in fs if f.is_file())}}))'
  auditing=t.command(('sudo -n ' if user!='root' else '')+'/usr/bin/python3 -c '+shlex.quote(audit_code),{})
  if auditing['input_logging']:raise Fault('credential-bearing provisioning refused: sudo input logging configured')
  digest=hashlib.sha256(code.encode()).hexdigest()
  show_plan(hostname,profile,localinfo,remote,digest)
  if not a.approve and not confirm_prompt('Approve installation? [yes/NO]: '):print('CANCELLED; no Bridge changes applied');return
  ROOT.mkdir(parents=True,exist_ok=True,mode=0o700);os.chmod(ROOT,0o700);creds=ROOT/'credentials';creds.mkdir(mode=0o700)
  keyfile=creds/'management-key';local(['ssh-keygen','-q','-t','ed25519','-N','','-C','twebproxy-managed-'+node,'-f',str(keyfile)])
  s={'schema':1,'id':node,'hostname':hostname,'profile':profile,'previous_port':previous,'ip':ip,'port':a.port,'fingerprint':t.fingerprint,'host_key':t.host_key,'executor_digest':digest,'entry':entry,'exit':exit,'phase':'plan_approved','bootstrap_user':user};journal(s)
  try:
   atomic(Path('/etc/twebproxy/instances')/hostname/'bridge.owner',node+'\n')
   manager('prepare-runtime')
   result=stage_bootstrap(t,exit,(keyfile.with_suffix('.pub')).read_text(),user,user!='root');s['exit']['public_key']=result['public_key'];s['management_user']=result['management_user'];journal(s,'management_enrolled')
   second=managed(s)
   try:
    rpc(s,'status',t=second)
    try:rpc(s,'forbidden',t=second)
    except Fault:pass
    else:raise Fault('restricted credential accepted forbidden verb')
   finally:second.close()
   t.close();bootstrap_available=False
   result=agent(entry,'bootstrap',source=base64.b64encode(code.encode()).decode(),public_key='',user='root');s['entry']['public_key']=result['public_key'];s['entry']['peer_key']=s['exit']['public_key'];s['exit']['peer_key']=result['public_key'];journal(s,'security_ready')
   credential=json.loads(manager('credential',hostname,profile))['secret'];credential=credential[2:] if credential.lower().startswith('dd') and len(credential)==34 else credential;credential=credential.lower()
   apply(s,'exit',credential);credential=None;journal(s,'backend_ready')
   apply(s,'entry');forward_units(s)
   if not tcp(s['entry']):raise Fault('direct private TCP target unavailable')
   journal(s,'entry_prepared')
   side=Path('/etc/twebproxy/instances')/hostname/'bridge.json';atomic(side.with_name('bridge.owner'),node+'\n');atomic(side,json.dumps({'schema':'twebproxy.bridge.instance.v1','id':node,'profile':profile,'generation':1,'local_port':port}))
   journal(s,'cutover_intent');manager('activate',hostname,profile,port);journal(s,'active');local(['systemctl','start',layout(s['entry'])[2]+'-watch.timer'])
   print('Bridge profile provisioned. Transport verified; Telegram account/client test UNKNOWN.');print(manager('show',hostname))
  except BaseException:
   try:rollback(s,recovery=t if bootstrap_available else None,recovery_user=user)
   except Exception:journal(s,'cleanup_pending')
   raise
 finally:t.close()

def load():
 if not STATE.exists():raise Fault('no managed foreign node')
 s=json.loads(STATE.read_text())
 if s.get('schema')!=1:raise Fault('unsupported/corrupt state; activation blocked')
 return s

def status(s):
 r=subprocess.run(['ip','-j','route','get',s['entry']['peer_ip']],capture_output=True,text=True)
 route=json.loads(r.stdout) if r.returncode==0 else []
 checks={'bridge.peer.route':'OK' if route and route[0].get('dev')==iface(s['entry']) else 'ERROR','bridge.exit.tcp':'OK' if tcp(s['entry']) else 'ERROR','bridge.exit.service':'UNKNOWN','bridge.mtproto.probe':'UNKNOWN','bridge.web.client':'UNKNOWN'}
 try:remote=rpc(s,'status');checks['bridge.exit.service']='OK' if all(v=='active' for v in remote['units'].values()) else 'ERROR';checks['bridge.security.boundary']=remote.get('security_boundary','UNKNOWN')
 except Exception as e:remote={'state':'UNREACHABLE_OR_IDENTITY_FAILURE','reason':str(e) if isinstance(e,Fault) else type(e).__name__}
 print(json.dumps({'schema':'twebproxy.bridge.status.v1','id':s['id'],'phase':s['phase'],'hostname':s['hostname'],'generation':1,'observed_at':time.time(),'checks':checks,'remote':remote,'cleanup_debt':s.get('cleanup_debt',[])},indent=2))

def main():
 secret_process();p=argparse.ArgumentParser();p.add_argument('verb',choices=['add','status','diagnose','repair','remove']);p.add_argument('--host');p.add_argument('--user');p.add_argument('--port',type=int,default=22);p.add_argument('--instance');p.add_argument('--identity');p.add_argument('--auth',choices=['key','password']);p.add_argument('--fingerprint');p.add_argument('--entry-endpoint');p.add_argument('--approve',action='store_true');a=p.parse_args()
 if os.geteuid()!=0:raise Fault('root required')
 if not 1<=a.port<=65535:raise Fault('invalid SSH port')
 with private_lock('controller.lock') as lock:
  try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:raise Fault('another node operation is in progress')
  if a.verb=='add':add(a);return
  if not STATE.exists() and a.verb in ('status','diagnose','remove'):
   print(json.dumps({'schema':'twebproxy.bridge.status.v1','state':'NO_NODE','checks':{'bridge.web.client':'UNKNOWN'}}));return
  s=load()
  if a.verb in ('status','diagnose'):status(s)
  elif a.verb=='remove':
   if not a.approve and not confirm_prompt('Restore local backend and remove owned foreign node? [yes/NO]: '):return
   if not rollback(s):raise Fault('PARTIAL: cleanup pending; identity retained for retry')
   print('Node removed; original local profile restored; shared packages retained.');print(json.dumps({'retained_policy':s.get('remote_cleanup_receipt',{}).get('warnings',[])},ensure_ascii=False))
  elif a.verb=='repair':
   if s['phase']!='active':
    recovery=None;user=a.user or s.get('bootstrap_user','root')
    if a.identity or a.auth=='password':
     recovery=SSH(s['ip'],s['port'],s['fingerprint'],s['host_key'])
     password=hidden_prompt('Initial SSH password for cleanup (memory only): ') if a.auth=='password' else None
     recovery.auth(user,password=password,identity=a.identity);password=None
    try:complete=rollback(s,recovery=recovery,recovery_user=user)
    finally:
     if recovery:recovery.close()
    if not complete:raise Fault('PARTIAL: interrupted operation cleanup pending; retry repair with initial --identity or --auth password')
    print('Interrupted operation rolled back; run Add Foreign Node again.');return
   subprocess.run(['systemctl','stop',layout(s['entry'])[2]+'-watch.timer',layout(s['entry'])[2]+'-watch.service'],capture_output=True,timeout=20)
   try:
    apply(s,'exit');apply(s,'entry');forward_units(s)
    if not tcp(s['entry']):raise Fault('private path unavailable; no readiness claim')
    side=Path('/etc/twebproxy/instances')/s['hostname']/'bridge.json';atomic(side,json.dumps({'schema':'twebproxy.bridge.instance.v1','id':s['id'],'generation':1,'profile':s['profile'],'local_port':s['entry']['local_port']}));manager('refresh',s['hostname']);journal(s,'active');local(['systemctl','start',layout(s['entry'])[2]+'-watch.timer']);status(s)
   finally:
    timer=layout(s['entry'])[2]+'-watch.timer'
    if Path('/etc/systemd/system/'+timer).exists():subprocess.run(['systemctl','start',timer],capture_output=True,timeout=20)
if __name__=='__main__':
 try:main()
 except (KeyboardInterrupt,EOFError):print('Cancelled; inspect status if an operation had started.',file=sys.stderr);sys.exit(1)
 except Exception as e:print(str(e) if isinstance(e,Fault) else type(e).__name__,file=sys.stderr);sys.exit(1)
