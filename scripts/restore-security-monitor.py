#!/usr/bin/env python3
"""Retrieve only our prior JSON report; never extract artifact paths."""
import io,json,os,subprocess,sys,zipfile
from pathlib import Path
repo=os.environ['GITHUB_REPOSITORY'];output=Path(sys.argv[1])
def api(path):return subprocess.check_output(['gh','api',path],timeout=60)
artifacts=json.loads(api(f'repos/{repo}/actions/artifacts?name=security-monitor-state&per_page=10'))['artifacts']
metadata=json.loads(api(f'repos/{repo}'))
items=[]
for artifact in artifacts:
 if artifact['expired']:continue
 run_id=artifact.get('workflow_run',{}).get('id')
 if not run_id or str(run_id)==os.environ.get('GITHUB_RUN_ID'):continue
 run=json.loads(api(f'repos/{repo}/actions/runs/{run_id}'))
 if (run.get('event') in ['schedule','workflow_dispatch']
     and run.get('head_branch')==metadata['default_branch']
     and run.get('head_repository',{}).get('id')==metadata['id']
     and run.get('path','').split('@')[0]=='.github/workflows/security-checks.yml'):
  items.append(artifact)
  break
if items:
 blob=api(f'repos/{repo}/actions/artifacts/{items[0]["id"]}/zip')
 with zipfile.ZipFile(io.BytesIO(blob)) as archive:
  member=archive.getinfo('security-report.json')
  if member.file_size>8*1024*1024:raise ValueError('Previous report too large')
  report=json.loads(archive.read(member))
 output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report))
else:print('No prior scheduled report; establishing a baseline.')
