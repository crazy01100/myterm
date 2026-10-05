#!/usr/bin/env python3
"""Limit the repository Firebase wrapper to its documented Firestore workflow.

This is not a sandbox against a local owner invoking firebase-tools directly.
It prevents accidentally reaching unsupported import/hosting paths.
"""
import json
import os
from pathlib import Path
import re
import sys

ROOT=Path(__file__).resolve().parents[1]

def validate_rules_watch_paths(config, root):
    # Chokidar 3 expands braces in its watch path. A Rules filename is a
    # literal path, so reject brace syntax before Firebase loads the watcher.
    # Include the project directory and symlink target, not just the basename.
    entries = config.get('firestore', {})
    if isinstance(entries, dict):
        entries = [entries]
    if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
        raise ValueError('Invalid Firestore configuration')
    for entry in entries:
        value = entry.get('rules')
        if value is None:
            continue
        if not isinstance(value, str) or not value or '\x00' in value:
            raise ValueError('Firestore rules must name a local file')
        # Firebase Config.path uses normalize(join(projectDir, rules)), where
        # an initial slash in rules does not discard the project directory.
        path = Path(os.path.normpath(str(root.absolute()) + '/' + value))
        for candidate in [str(root.absolute()), value, str(path), str(path.resolve())]:
            if '{' in candidate or '}' in candidate:
                raise ValueError('Firestore Emulator rules paths and project directories must not contain braces')

def validate(args,root=ROOT):
    if args in [['--version'],['--help'],['help'],['login'],['login','--no-localhost'],['logout'],['login:list'],['projects:list']]:
        return
    if not args or args[0] not in ['deploy','emulators:start','emulators:exec']:
        raise ValueError('This wrapper permits Firestore deployment, local emulators, and basic account setup only')
    command=args[0];options={};positionals=[];i=1
    while i<len(args):
        arg=args[i]
        if arg=='--non-interactive':
            i+=1;continue
        if arg in ['--project','--only']:
            if arg in options or i+1>=len(args):raise ValueError('Missing or repeated option')
            options[arg]=args[i+1];i+=2
        elif arg.startswith('-'):
            raise ValueError('Unsupported Firebase option')
        else:
            positionals.append(arg);i+=1
    if set(options)!= {'--project','--only'}:
        raise ValueError('An explicit --project and --only are required')
    targets=options['--only'].split(',')
    if command=='deploy':
        if not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]',options['--project']):raise ValueError('Invalid project')
        if positionals or not targets or any(t not in ['firestore','firestore:rules','firestore:indexes'] for t in targets):
            raise ValueError('Only Firestore rules/indexes deployment is supported')
    else:
        if options['--project']!='demo-myterm' or any(t not in ['auth','firestore'] for t in targets):
            raise ValueError('Only local auth/firestore emulators with project demo-myterm are supported')
        expected=['node --test Tests/FirebaseRules/firestore.rules.test.mjs'] if command=='emulators:exec' else []
        if positionals!=expected:raise ValueError('Only the repository Firestore Rules test command is supported')
        config=json.loads((root/'firebase.json').read_text())
        for target in targets:
            if config.get('emulators',{}).get(target,{}).get('host','127.0.0.1') not in ['127.0.0.1','localhost','::1']:
                raise ValueError('Emulators must remain bound to loopback')
        if 'firestore' in targets:
            validate_rules_watch_paths(config, root)

if __name__=='__main__':
    try:validate(sys.argv[1:])
    except (ValueError,OSError) as error:
        print('Firebase command rejected: '+str(error),file=sys.stderr);sys.exit(64)
