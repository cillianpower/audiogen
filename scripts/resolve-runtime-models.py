#!/usr/bin/env python3
"""Maintainer tool: resolve model checksums after fetching pinned runtime sources into .build/runtime-research/sources.json. Never invoked by the application."""
import urllib.request,urllib.parse,json,pathlib,hashlib,concurrent.futures
root=pathlib.Path('Sources/Audiogen/Resources/PythonRuntimes')
cache={}
def inventory(repo,rev=None):
 key=(repo,rev)
 if key not in cache:
  path='https://huggingface.co/api/models/'+repo+('/revision/'+rev if rev else '')+'?blobs=true'
  cache[key]=json.load(urllib.request.urlopen(path,timeout=45))
 return cache[key]
def artifact(repo,filename,prefix='',revision=None):
 data=inventory(repo,revision); rev=data['sha']; row=next(r for r in data['siblings'] if r['rfilename']==filename)
 url='https://huggingface.co/'+repo+'/resolve/'+rev+'/'+urllib.parse.quote(filename,safe='/')
 sha=row.get('lfs',{}).get('sha256');size=row.get('size',row.get('lfs',{}).get('size'))
 if not sha:
  raw=urllib.request.urlopen(url,timeout=45).read();sha=hashlib.sha256(raw).hexdigest();size=len(raw)
 return dict(name=prefix+filename,url=url,sha256=sha,bytes=size)
def model(id,name,memory,steps,files):return dict(id=id,name=name,minimumMemoryGB=memory,steps=steps,files=files)
sa=[]
for id,name in [('sm-music','Small Music'),('sm-sfx','Small Sound Effects'),('medium','Medium Music')]:
 codec='l' if id=='medium' else 's'
 files=['dit_'+id+'_f16.npz','same_'+codec+'_decoder_f32.npz','same_'+codec+'_encoder_f32.npz','t5gemma_f16.npz']
 sa.append(model(id,name,16 if id=='medium' else 8,8,[dict(artifact('stabilityai/stable-audio-3-optimized','MLX/'+f),name='stable/'+f) for f in files]+[artifact('stabilityai/stable-audio-3-optimized',f,'stable/') for f in ['LICENSE.md','LICENSE_GEMMA.md','NOTICE']]))
t5=[artifact('t5-base',f,'t5-base/') for f in ['config.json','model.safetensors','spiece.model','tokenizer.json']]
mg=[]
for variant,mem in [('small',8),('medium',16),('large',24),('stereo-small',8),('stereo-medium',16),('stereo-large',24)]:
 id='musicgen-'+variant;repo='facebook/'+id
 files=[artifact(repo,f,id+'/') for f in ['state_dict.bin','compression_state_dict.bin']]+t5
 if variant.startswith('stereo'):
  for f in ['config.json','model.safetensors','preprocessor_config.json']:
   files.append(artifact('facebook/encodec_32khz',f,'encodec_32khz/'))
 mg.append(model(id,variant.replace('-',' ').title(),mem,1,files))
yuefiles=[artifact('vanch007/mlx-Yue2-3B',r['rfilename'],'yue/') for r in inventory('vanch007/mlx-Yue2-3B')['siblings'] if r['rfilename'] not in ['.gitattributes','README.md']]
yuefiles += [artifact('m-a-p/YuE2-Vae',r['rfilename'],'yue-vae/',revision='95535e72a97bc0f09b8ada125d26b4009428c0e8') for r in inventory('m-a-p/YuE2-Vae','95535e72a97bc0f09b8ada125d26b4009428c0e8')['siblings'] if r['rfilename'] not in ['.gitattributes','README.md','modeling_vae.py']]
yue=[model('8bit','8-bit',24,8,yuefiles),model('bf16','BF16',24,32,yuefiles)]
ace=[]
for id,name,mem,steps in [('acestep-v15-sft','SFT',16,50),('acestep-v15-xl-turbo','XL Turbo',32,8),('acestep-v15-xl-sft','XL SFT',32,50)]:
 repo='ACE-Step/'+id
 files=[artifact(repo,r['rfilename'],id+'/') for r in inventory(repo)['siblings'] if r['rfilename'] not in ['.gitattributes','README.md']]
 ace.append(model(id,name,mem,steps,files))
sources=json.load(open('.build/runtime-research/sources.json'))
for source,models,working in zip(sources,[sa,mg,yue],['optimized/mlx','.','.']):
 source['models']=models;source['workingSubdirectory']=working
(root/'catalog.json').write_text(json.dumps(dict(runtimes=sources,aceModels=ace),indent=2)+'\n')
req=urllib.request.Request('https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/20261003',headers={'User-Agent':'Audiogen'})
assets=json.load(urllib.request.urlopen(req,timeout=45))['assets']
asset=next(a for a in assets if a['name'].startswith('cpython-3.12.') and 'aarch64-apple-darwin-install_only_stripped.tar.gz' in a['name'])
print('Python',asset['name'],asset.get('digest'))
raw=urllib.request.urlopen(asset['browser_download_url'],timeout=90).read()
python=dict(name='python312.tar.gz',url=asset['browser_download_url'],sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw))
pathlib.Path('.build/runtime-research/python312.tar.gz').write_bytes(raw)
(root/'python312.json').write_text(json.dumps(python,indent=2)+'\n')
print('catalog resolved',[(s['id'],len(s['models'])) for s in sources])
