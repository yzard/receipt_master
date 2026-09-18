"""Apply Docker-secret defaults to the assembled Flutter project, not canonical source."""
import json
import shutil
import sys
from pathlib import Path
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

source = Path(sys.argv[1])
config = json.loads(source.read_text())
shutil.copyfile(source, 'resources/backend_defaults.json')
root = ET.Element('network-security-config')
ET.SubElement(root, 'base-config', cleartextTrafficPermitted='false')
url = urlparse(config.get('endpoint', ''))
if url.scheme == 'http':
    domain_config = ET.SubElement(root, 'domain-config', cleartextTrafficPermitted='true')
    ET.SubElement(domain_config, 'domain', includeSubdomains='false').text = url.hostname
ET.ElementTree(root).write('android/app/src/main/res/xml/network_security_config.xml', encoding='utf-8', xml_declaration=True)
