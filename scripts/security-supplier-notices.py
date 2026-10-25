#!/usr/bin/env python3
"""Bounded supplier-notice monitoring, never a subdependency safety claim.

Actual tool identities and official queries remain separate from candidate evidence.
Operating-system and runner-image updates are excluded. Existing package findings are
independent; successful notice coverage cannot waive or close them.
"""
import datetime as dt
import hashlib
from html.parser import HTMLParser
import importlib.util
import json
import re
from pathlib import Path
import urllib.request
import urllib.parse

ROOT=Path(__file__).resolve().parents[1]
CONFIG='Config/Security/supplier-notices.json'
CURSOR='Config/Security/supplier-notice-cursor.json'
SOURCES={
 'workers':('github','repos/cloudflare/workers-sdk/security-advisories?per_page=100'),
 'workerd':('github','repos/cloudflare/workerd/security-advisories?per_page=100'),
 'jdk':('web','https://openjdk.org/groups/vulnerability/advisories/'),
}
NOTICE_SOURCES={'jdk-security':('https://openjdk.org/groups/vulnerability/advisories/','openjdk.org')}


def load(name):
 s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m


def digest(value):return hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()


class Text(HTMLParser):
 def __init__(self):super().__init__();self.skip=0;self.parts=[];self.rows=[];self.row=None
 def handle_starttag(self,tag,attrs):
  if tag in ('script','style'):self.skip+=1
  if tag=='tr':self.row=[]
 def handle_endtag(self,tag):
  if tag in ('script','style'):self.skip=max(0,self.skip-1)
  if tag=='tr' and self.row is not None:self.rows.append(' '.join(self.row));self.row=None
 def handle_data(self,value):
  if not self.skip:
   text=' '.join(value.split())
   if text:
    self.parts.append(text)
    if self.row is not None:self.row.append(text)


def page(target):
 trust=load('python-toolchain')
 req=urllib.request.Request(target,headers={'User-Agent':'MyTerm-project-supplier-notices'})
 with urllib.request.urlopen(req,context=trust.https_context(ROOT),timeout=30) as response:
  end=urllib.parse.urlsplit(response.url);start=urllib.parse.urlsplit(target)
  if end.scheme!='https' or end.hostname!=start.hostname or end.username or end.password or end.port not in (None,443):raise ValueError('Supplier redirect differs')
  raw=response.read(4*1024*1024+1)
 if len(raw)>4*1024*1024:raise ValueError('Oversized supplier page')
 parser=Text();parser.feed(raw.decode('utf-8'));return parser


def fetch(identifier):
 kind,target=SOURCES[identifier]
 if kind=='github':
  gh=load('security-source-review')
  if '/security-advisories?' in target:
   pages=gh.gh_read(ROOT,target,pages=True)
   if not isinstance(pages,list) or any(not isinstance(p,list) for p in pages):raise ValueError('Invalid advisory pages')
   rows=[row for page in pages for row in page]
   if len(rows)>1000:raise ValueError('Oversized supplier advisories')
   selected=[{k:r.get(k) for k in ('ghsa_id','summary','description','severity','published_at','updated_at','withdrawn_at','vulnerabilities')} for r in rows]
   return {'advisories':sorted(selected,key=lambda r:r['ghsa_id'])}
  row=gh.gh_read(ROOT,target)
  if row.get('draft') is not False or row.get('prerelease') is not False or not row.get('tag_name'):raise ValueError('Missing stable supplier release')
  return {k:row.get(k) for k in ('tag_name','html_url','body','published_at')}
 parser=page(target)
 text=' '.join(parser.parts)
 if len(text)<100 or (identifier=='jdk' and 'Advisories' not in text and 'advisories' not in text):raise ValueError('Missing vendor notice content')
 if identifier=='jdk':
  dates=list(dict.fromkeys(re.findall(r'\b20\d\d/\d\d/\d\d\b',text)))[:3]
  if not dates:raise ValueError('Missing JDK advisory dates')
  details={d:' '.join(page(target+d.replace('/','-')).parts) for d in dates}
  if any('CVE-' not in value or 'affected versions' not in value for value in details.values()):raise ValueError('Missing JDK advisory details')
  return {'index':text,'recentAdvisories':details}
 return {'text':text}


def scan(inventory,root=ROOT,fetcher=fetch,global_fetcher=None):
 policy=json.loads((root/CONFIG).read_text())
 cursor=json.loads((root/CURSOR).read_text())
 if policy.get('schemaVersion')!=2 or policy.get('grantsRiskException') is not False:raise ValueError('Invalid project supplier policy')
 domains={r['id']:r for r in inventory['coverage']}
 receipts=[];findings=[];notices=[];errors=[];observed={};now=dt.datetime.now(dt.timezone.utc).isoformat()
 audit=load('security-audit')
 for collector,source,queries in [('deployment','Cloudflare security notices',('workers','workerd')),('emulator','JDK vendor security notices',('jdk',))]:
  domain=domains.get(collector,{})
  if domain.get('status')=='not-applicable':continue
  row={'collector':collector,'source':source,'checkedAt':now,'coverageDigest':digest(domain),
       'status':'needs-review','allDependenciesScanned':False,'closureEligible':False,
       'limitation':'Actual selected tool and official notices; not exhaustive native child coverage'}
  try:
   if domain.get('status') not in ('inventoried','supplier-managed-limited'):raise ValueError('Actual tool inventory missing')
   if collector=='deployment':
    for q in queries:observed[q]=fetcher(q)
   if collector=='deployment':
    components=[c for c in inventory['components'] if c.get('collector')==collector]
    for q in queries:
     for advisory in observed[q]['advisories']:
      if advisory.get('withdrawn_at'):continue
      vulnerabilities=advisory.get('vulnerabilities',[])
      if any(c['name']==v.get('package',{}).get('name') and
             audit.affected(c['version'],v.get('vulnerable_version_range','')) is None
             for c in components for v in vulnerabilities):
       identifier=advisory['ghsa_id']
       if not re.fullmatch(r'GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}',identifier):raise ValueError('Invalid advisory identity')
       canonical=(global_fetcher(identifier) if global_fetcher else
                  load('security-source-review').gh_read(root,'advisories/'+identifier))
       if (canonical.get('ghsa_id')!=identifier or 'withdrawn_at' not in canonical or
               not isinstance(canonical.get('vulnerabilities'),list) or not canonical['vulnerabilities']):
        raise ValueError('Incomplete canonical advisory')
       observed['canonical:'+identifier]=canonical
       if canonical['withdrawn_at']:continue
       vulnerabilities=canonical['vulnerabilities']
       original_names={v.get('package',{}).get('name') for v in advisory.get('vulnerabilities',[])}
       if not original_names.issubset({v.get('package',{}).get('name') for v in vulnerabilities}):
        raise ValueError('Canonical advisory package differs')
      for vulnerability in vulnerabilities:
       for component in components:
        if component['name']!=vulnerability.get('package',{}).get('name'):continue
        match=audit.affected(component['version'],vulnerability.get('vulnerable_version_range',''))
        if match is False:continue
        findings.append({'id':advisory['ghsa_id'],'component':component['name'],'version':component['version'],
          'scope':'development','severity':'moderate' if advisory['severity']=='medium' else advisory['severity'],
          'status':'needs-review','queryComplete':True,'url':'https://github.com/advisories/'+advisory['ghsa_id'],
          'fixedVersion':vulnerability.get('first_patched_version') or vulnerability.get('patched_versions',''),'dependencyPaths':[component['origin']],
          'environmentObservations':[{'environment':inventory['environment'],'origin':component['origin'],'versions':[component['version']]}]})
   else:
    tools=[t for t in domain.get('tools',[]) if t.get('component')=='java']
    if len(tools)!=1:raise ValueError('Rules Java identity missing')
    java=tools[0]
    if not any(java.get('vendor')==r['vendor'] and java.get('runtimeVersion')==r['runtimeVersion'] for r in policy.get('reviewedJDKs',[])):
     raise ValueError('Selected Rules JDK requires tool-version review')
    for fact in policy['jdkFindings']:
     if fact.get('status')!='needs-review' or fact.get('acceptedRisk'):raise ValueError('No supplier risk waivers')
     if java['runtimeVersion'].split('-')[0]==fact['version']:
      findings.append({**fact,'queryComplete':False,'dependencyPaths':['emulator/java'],
       'environmentObservations':[{'environment':inventory['environment'],'origin':'emulator/java','versions':[java['runtimeVersion']]}]})
    observed['jdk']=fetcher('jdk')
    for fact in findings:
     if fact.get('dependencyPaths')==['emulator/java']:fact['queryComplete']=True
    current=observed['jdk'];url=NOTICE_SOURCES['jdk-security'][0]
    if digest(current)!=cursor.get('jdkNoticeCursor'):
     notices.append({'source':'jdk-security','id':hashlib.sha256(url.encode()).hexdigest(),
       'contentSHA256':digest(current),'title':'OpenJDK security advisory update','url':url,'publishedAt':now})
   row.update(status='complete',reason='Actual project tool identities and official advisory responses collected')
  except Exception as error:
   row['reason']=type(error).__name__;errors.append(collector+': '+type(error).__name__)
  receipts.append(row)
 return {'checkedAt':now,'receipts':receipts,'findings':findings,'errors':errors,'notices':notices,
         'candidateFindings':policy.get('candidateFindings',[]),'observed':observed,
         'allDependenciesScanned':False,'grantsRiskException':False}
