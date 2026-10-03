"""Read-only Syncthing checks before merging any synchronized project."""
from pathlib import Path
import xml.etree.ElementTree as ET
import httpx


async def stable(project):
    try:
        paths=[Path.home()/'Library/Application Support/Syncthing/config.xml',Path.home()/'.config/syncthing/config.xml']
        config=next(p for p in paths if p.is_file())
        root=ET.parse(config).getroot()
        key=root.findtext('gui/apikey')
        address=root.findtext('gui/address') or '127.0.0.1:8384'
        scheme='https' if root.find('gui').get('tls')=='true' else 'http'
        folders=[f for f in root.findall('folder') if project.is_relative_to(Path(f.get('path')).expanduser().resolve())]
        if not folders or not key:
            return False
        folder=max(folders,key=lambda f:len(f.get('path')))
        async with httpx.AsyncClient(base_url=scheme+'://'+address,headers={'X-API-Key':key},trust_env=False,timeout=10) as client:
            identity=(await client.get('/rest/system/status')).json().get('myID')
            connections=(await client.get('/rest/system/connections')).json().get('connections',{})
            status=(await client.get('/rest/db/status',params={'folder':folder.get('id')})).json()
            if status.get('state')!='idle' or status.get('needTotalItems',1)!=0 or status.get('pullErrors',0):
                return False
            for device in folder.findall('device'):
                if device.get('id')==identity:continue
                if not connections.get(device.get('id'),{}).get('connected'):return False
                completion=(await client.get('/rest/db/completion',params={'folder':folder.get('id'),'device':device.get('id')})).json()
                if completion.get('completion',0)<100:
                    return False
        return True
    except (OSError,ValueError,StopIteration,ET.ParseError,httpx.HTTPError,AttributeError):
        return False
