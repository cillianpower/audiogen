#!/usr/bin/env python3
"""Maintainer tool: refresh upstream source revisions; inspect changes before shipping."""
import urllib.request,json,hashlib,pathlib,tarfile,concurrent.futures
root=pathlib.Path('.build/runtime-research')
def fetch(pair):
 name,repo=pair
 req=urllib.request.Request('https://api.github.com/repos/'+repo+'/commits/main',headers={'User-Agent':'Audiogen-maintainer'})
 data=json.load(urllib.request.urlopen(req));sha=data['sha']
 url='https://codeload.github.com/'+repo+'/tar.gz/'+sha
 raw=urllib.request.urlopen(url).read(); archive=root/(name+'.tar.gz');archive.write_bytes(raw)
 with tarfile.open(archive) as tar: tar.extractall(root/name,filter='data')
 return dict(id=name,revision=sha,repository=dict(name=name+'.tar.gz',url=url,sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw)),repositoryDirectory=repo.split('/')[1]+'-'+sha)
with concurrent.futures.ThreadPoolExecutor() as pool: records=list(pool.map(fetch,[('stableAudio','Stability-AI/stable-audio-3'),('musicGen','andrade0/musicgen-mlx'),('yue','vanch007/mlx-Yue')]))
(root/'sources.json').write_text(json.dumps(records,indent=2))
print(json.dumps(records,indent=2))
