#!/usr/bin/env python3
"""Select a test profile from actual Git changes, never labels or override flags."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
POLICY_FILES = {
    'Config/Security/conditional-acceptances.json',
    'scripts/security-conditional-risk.py', 'scripts/security-test-profile.py',
    'scripts/run-policy-tests.py', 'scripts/security-audit.py',
    'scripts/security-issue-format.py', 'scripts/sync-security-issues.py',
    'scripts/firebase-tools.sh', 'scripts/run-dev-app.sh', 'scripts/prepare-release-build.sh',
    'Tests/Security/test_conditional_risk.py', 'Tests/Security/test_security_test_profile.py',
    'Tests/Security/test_dev_launch_gate.py', 'Tests/Security/test_audit_policy.py',
    'Tests/Security/test_security_issues.py', 'Tests/Security/test_risk_context.py',
    '.github/workflows/security-gate.yml', '.github/workflows/security-checks.yml',
    '.github/workflows/deploy-update-site.yml',
}
for name in ('README','ARCHITECTURE','DEVELOPMENT','SECURITY','SECURITY_MAINTENANCE','FIREBASE_SETUP'):
    POLICY_FILES.update({name+'.md', name+'.en.md'})
POLICY_FILES.update({'update-site/README.md','update-site/README.en.md'})


def git(*args, root=ROOT):
    return subprocess.run(['git', *args], cwd=root, capture_output=True,
                          text=True, timeout=20, check=True).stdout.strip()


def profile(changes):
    # Mixed changes, deletion, rename and unknown entries never receive the
    # narrower profile. The original full suite remains available unchanged.
    return 'policy-only' if changes and all(status in ('A','M') and name in POLICY_FILES
                                          for status,name in changes) else 'full'


def refs(event, data, head, git_read=git):
    if event == 'pull_request':
        pr=data['pull_request'];base=pr['base']['sha'];target=pr['head']['sha']
    elif event == 'push':
        base=data['before'];target=data['after']
        if target != head:raise ValueError('Push checkout does not match event')
    elif event in ('schedule','workflow_dispatch'):
        target=head;base=git_read('rev-parse',head+'^1')
    else:raise ValueError('Unknown event; refusing test selection')
    if not all(isinstance(x,str) and re.fullmatch('[0-9a-f]{40}',x) and x!='0'*40 for x in (base,target)):
        raise ValueError('Missing or invalid comparison commits')
    return base,target


def select(root=ROOT,environ=None):
    env=os.environ if environ is None else environ
    data=json.loads(Path(env['GITHUB_EVENT_PATH']).read_text())
    read=lambda *args:git(*args,root=root)
    head=read('rev-parse','HEAD')
    base,target=refs(env.get('GITHUB_EVENT_NAME'),data,head,read)
    read('merge-base','--is-ancestor',base,target)
    if env.get('GITHUB_EVENT_NAME')=='pull_request':
        # Checkout may be the synthetic merge commit, but both exact event
        # commits must be ancestors. Unrelated checkouts cannot select a profile.
        read('merge-base','--is-ancestor',target,head)
        read('merge-base','--is-ancestor',base,head)
    raw=read('diff','--no-renames','--name-status',base,target)
    changes=[]
    for line in raw.splitlines():
        parts=line.split('\t')
        if len(parts)!=2:raise ValueError('Unrecognized change entry')
        changes.append(tuple(parts))
    return {'profile':profile(changes),'base':base,'head':target,'checkout':head,
            'changedFiles':[name for _,name in changes]}


def main():
    try:
        result=select()
        print(json.dumps(result,indent=2))
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'],'a') as out:out.write('profile='+result['profile']+'\n')
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as out:
                out.write('## Security test profile\n\n'+result['profile']+'\n\n')
                if result['profile']=='policy-only':
                    out.write('Policy/format/entry fixtures and read-only advisory scanning only. Full development-tool vulnerability regressions were not executed.\n')
        return 0
    except (ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError) as error:
        print('Cannot safely select security tests: '+str(error),file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
