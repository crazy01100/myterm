#!/usr/bin/env python3
"""Attach evidence-bound local assessment notes without granting gate exemptions."""
import hashlib
import json
from pathlib import Path


def annotate(report,root):
    path=root/'Config/Security/toolchain-assessments.json'
    document=json.loads(path.read_text())
    if document.get('schemaVersion')!=1 or document.get('grantsRiskException') is not False:
        raise ValueError('Invalid toolchain assessment policy')
    if report.get('observedEnvironment')!=document.get('environment'):
        return  # Local evidence never becomes CI evidence.
    valid=report.get('toolchainCoverage',{}).get('inventoryDigest')==document.get('inventoryDigest')
    for name,expected in document['inputFiles'].items():
        source=root/name
        if (Path(name).is_absolute() or '..' in Path(name).parts or source.is_symlink() or
                not source.resolve().is_relative_to(root.resolve()) or not source.is_file() or
                hashlib.sha256(source.read_bytes()).hexdigest()!=expected):valid=False
    for finding in report['findings']:
        matches=[r for r in document['assessments'] if all(r[k]==finding[k] for k in ('id','component','scope')) and
                 sorted(r['versions'])==sorted(v.strip() for v in finding['version'].split(','))]
        if len(matches)>1:raise ValueError('Duplicate toolchain impact assessment')
        if not matches:continue
        row=matches[0]
        if row.get('gateEffect')!='none' or row.get('status')!='needs-review':
            raise ValueError('Assessment notes cannot accept risk or lower gate status')
        finding['impact']={'status':'needs-review','usage':row['usage'],
                          'reason':row['reason'] if valid else '觀測環境或受審來源已改變，原靜態評估須重新確認。',
                          'evidence':row['evidence'] if valid else []}
