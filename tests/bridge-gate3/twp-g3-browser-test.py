import json,time,hashlib
from pathlib import Path
from playwright.sync_api import sync_playwright
out=Path('/root/projects/twebproxy/gate3-evidence');results=[]
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True,args=['--disable-dev-shm-usage'])
 for name,width,height in [('desktop',1440,1000),('mobile',390,844)]:
  context=browser.new_context(viewport={'width':width,'height':height});page=context.new_page();requests=[];errors=[]
  page.on('request',lambda r:requests.append(r.url));page.on('pageerror',lambda e:errors.append(str(e)))
  response=page.goto('https://martins.ortositi.ru/',wait_until='networkidle',timeout=30000);page.screenshot(path=str(out/('website-'+name+'.png')),full_page=True)
  check=page.evaluate('''() => ({title:document.title,heading:document.querySelector('h1').innerText,scroll:document.documentElement.scrollWidth,viewport:innerWidth,images:[...document.images].every(i=>i.complete&&i.naturalWidth>0),links:[...document.querySelectorAll('a[href]')].map(a=>a.getAttribute('href'))})''')
  results.append({'viewport':name,'width':width,'height':height,'status':response.status,'tls':response.security_details(),'observed':check,'runtime_requests':requests,'page_errors':errors,'no_external_runtime':all(u.startswith('https://martins.ortositi.ru/') for u in requests),'no_horizontal_overflow':check['scroll']<=check['viewport']});context.close()
 browser.close()
(out/'website-browser-results.json').write_text(json.dumps({'at':time.time(),'engine':'Playwright Chromium headless; real public TLS validation enabled','results':results,'status':'PASS' if all(x['status']==200 and x['no_external_runtime'] and x['no_horizontal_overflow'] and x['observed']['images'] and not x['page_errors'] for x in results) else 'FAIL'},indent=2));print(json.dumps(results,indent=2))
