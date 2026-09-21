#!/usr/bin/env python3
"""Bind public release metadata before the final feed signing step."""
import argparse
import importlib.util
import json
import xml.etree.ElementTree as ET
from pathlib import Path
spec=importlib.util.spec_from_file_location('inventory',Path(__file__).with_name('dependency-inventory.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
SP='http://www.andymatuschak.org/xml-namespaces/sparkle'
MT='urn:myterm:release:v1'
ET.register_namespace('sparkle',SP);ET.register_namespace('myterm',MT)
p=argparse.ArgumentParser();p.add_argument('--feed',type=Path,required=True);p.add_argument('--notes',type=Path,required=True)
p.add_argument('--signature',required=True);p.add_argument('--base-url',required=True);p.add_argument('--version',required=True);p.add_argument('--commit',required=True)
a=p.parse_args();tree=ET.parse(a.feed);item=tree.getroot().find('./channel/item')
assert item is not None
for name in [f'{{{SP}}}releaseNotesLink',f'{{{MT}}}sourceCommit',f'{{{MT}}}dependencies']:
 for old in item.findall(name):item.remove(old)
# 2.10 reads sparkle:length; retain the legacy attribute for older updaters.
notes_size=str(a.notes.stat().st_size)
notes=ET.SubElement(item,f'{{{SP}}}releaseNotesLink',{'length':notes_size,f'{{{SP}}}length':notes_size,f'{{{SP}}}edSignature':a.signature})
notes.text=a.base_url.rstrip('/')+f'/releases/{a.version}.html'
ET.SubElement(item,f'{{{MT}}}sourceCommit').text=a.commit
ET.SubElement(item,f'{{{MT}}}dependencies').text=json.dumps(module.inventory(),sort_keys=True)
tree.write(a.feed,encoding='utf-8',xml_declaration=True)
