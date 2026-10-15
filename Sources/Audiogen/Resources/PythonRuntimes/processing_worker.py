"""Offline SAM/AFTER adapters. All model files are installed and verified by Audiogen."""
import json,sys,time,math
from pathlib import Path
from urllib.parse import urlparse,unquote

def path(value):
    return Path(unquote(urlparse(value).path)) if value.startswith('file:') else Path(value)

def progress(config, status, fraction=None):
    destination=Path(config['outputRoot'])/'progress.json'
    temporary=destination.with_suffix('.tmp')
    temporary.write_text(json.dumps({'status':status,'fraction':fraction}))
    temporary.replace(destination)
    print(status,flush=True)

def split_channels(audio, stereo):
    # Both channels of a stereo source when requested, otherwise a mono mixdown.
    if stereo and audio.shape[1]>=2:return [audio[:,0].copy(),audio[:,1].copy()]
    return [audio.mean(axis=1)]

def combine_channels(parts, length):
    # Each processed channel is trimmed or padded to the source length, then
    # stacked as frames x channels; a single channel stays one-dimensional.
    import numpy as np
    parts=[np.asarray(part,dtype='float32').reshape(-1) for part in parts]
    parts=[np.pad(part[:length],(0,max(0,length-len(part)))) for part in parts]
    return parts[0] if len(parts)==1 else np.stack(parts,axis=1)

def read_channels(filename, rate, maximum=None, stereo=False):
    import soundfile as sf
    import numpy as np
    from scipy.signal import resample_poly
    audio,sr=sf.read(str(filename),always_2d=True,dtype='float32')
    if not len(audio) or not np.isfinite(audio).all():raise ValueError('Source audio is empty or contains invalid samples')
    if maximum is not None and len(audio)/sr > maximum:raise ValueError('This input must be no longer than '+str(maximum)+' seconds')
    parts=split_channels(audio,stereo)
    if sr!=rate:
        divisor=math.gcd(sr,rate);parts=[resample_poly(part,rate//divisor,sr//divisor).astype('float32') for part in parts]
    return parts

def read_audio(filename, rate, maximum=None):
    return read_channels(filename,rate,maximum)[0]

def sam(config):
    import numpy as np
    import soundfile as sf
    import mlx.core as mx
    import huggingface_hub
    import transformers
    sys.path.insert(0,config['sourceRoot'])
    root=Path(config['modelRoot']);request=config['request'];out=Path(config['outputRoot'])
    # Upstream's native MLX T5 loader expects Hub IDs. Resolve only the pinned
    # local shared T5 files, and prohibit every other download in inference.
    def local_hub(repo_id,filename,*args,**kwargs):
        if repo_id not in ['t5-base','google-t5/t5-base']:raise ValueError('Unmanaged model requested: '+repo_id)
        candidate=root/'t5-base'/filename
        if not candidate.is_file():raise FileNotFoundError(candidate)
        return str(candidate)
    huggingface_hub.hf_hub_download=local_hub
    original_tokenizer=transformers.AutoTokenizer.from_pretrained
    def tokenizer(cls,name,*args,**kwargs):
        if name not in ['t5-base','google-t5/t5-base']:raise ValueError('Unmanaged tokenizer requested')
        kwargs['local_files_only']=True
        return original_tokenizer(str(root/'t5-base'),*args,**kwargs)
    transformers.AutoTokenizer.from_pretrained=classmethod(tokenizer)
    from mlx_audio.sts.models.sam_audio import SAMAudio,SAMAudioConfig
    from mlx_audio.sts.models.sam_audio.model import _load_weights
    progress(config,'Loading SAM model',0.05)
    folder=root/request['model']
    model=SAMAudio(SAMAudioConfig.from_dict(json.loads((folder/'config.json').read_text())))
    model=model.post_load_hook(folder)
    weights={}
    for file in sorted(folder.glob('*.safetensors')):weights.update(mx.load(str(file)))
    if not weights:raise ValueError('No SAM weights installed')
    model=_load_weights(model,weights,strict=True);model.eval()
    rate=model.sample_rate;parts=read_channels(path(request['source']),rate,stereo=bool(request.get('stereo')))
    length=len(parts[0])
    anchors=[('+' if anchor['present'] else '-',anchor['region']['start'],anchor['region']['end']) for anchor in request.get('anchors',[])]
    if len(anchors)>3:raise ValueError('SAM supports up to three sound examples')
    if anchors and length/rate>30:raise ValueError('Sound examples require a source of 30 seconds or less')
    options={'method':'midpoint','step_size':1.0/request['steps']}
    targets=[];residuals=[];peak_memory=0.0
    # Stereo sources are separated one channel at a time with the same prompt and seed.
    for index,source in enumerate(parts):
        mx.random.seed(request['seed'])
        prepared=out/('sam-input-'+str(index)+'.wav');sf.write(str(prepared),source,rate,subtype='FLOAT')
        progress(config,'Extracting sound'+(' · channel '+str(index+1)+' of '+str(len(parts)) if len(parts)>1 else ''),0.2+0.75*index/len(parts))
        if length/rate>30:
            result=model.separate_long(audios=[str(prepared)],descriptions=[request['description']],chunk_seconds=10,overlap_seconds=3,ode_opt=options,ode_decode_chunk_size=50,seed=request['seed'],verbose=True)
        else:
            result=model.separate(audios=[str(prepared)],descriptions=[request['description']],anchors=[anchors] if anchors else None,ode_opt=options,ode_decode_chunk_size=50)
        targets.append(np.asarray(result.target[0]));residuals.append(np.asarray(result.residual[0]))
        peak_memory=max(peak_memory,float(result.peak_memory));prepared.unlink()
    progress(config,'Saving extracted sound and remaining audio',0.95)
    # Codec padding is trimmed to the resampled source's exact frame count.
    outputs=[];arrays=[combine_channels(targets,length),combine_channels(residuals,length)]
    if any(not np.isfinite(a).all() for a in arrays):raise ValueError('SAM returned invalid samples')
    peak=max(float(np.max(np.abs(a))) for a in arrays);gain=min(1.0,0.999/max(peak,1e-8))
    for role,name,audio in zip(['Extracted sound','Remaining audio'],['extracted.wav','remaining.wav'],arrays):
        sf.write(str(out/name),audio*gain,rate,subtype='PCM_24');outputs.append({'role':role,'filename':name})
    return outputs,{'backend':'MLX','sample_rate':str(rate),'channels':str(len(parts)),'output_gain':str(gain),'peak_memory_gb':str(peak_memory)}

def after(config):
    import numpy as np
    import torch
    import soundfile as sf
    request=config['request'];root=Path(config['modelRoot']);out=Path(config['outputRoot'])
    progress(config,'Loading AFTER model',0.05)
    model_file=root/('afterv2.audio.'+request['model']+'.ts')
    # The publisher's TorchScript exports contain codec, structure/timbre
    # encoders and diffusion network. Training dependencies are unnecessary.
    model=torch.jit.load(str(model_file),map_location='cpu').eval()
    rate=int(model.sr);parts=read_channels(path(request['source']),rate,stereo=bool(request.get('stereo')))
    reference=read_audio(path(request['reference']),rate,maximum=30)
    ratio=int(model.ae_ratio);chunk=int(model.chunk_size)*ratio
    if chunk<=0 or rate<=0:raise ValueError('Invalid AFTER model geometry')
    def execute(device,source,index):
        torch.manual_seed(request['seed'])
        runtime=torch.jit.load(str(model_file),map_location='cpu').eval().to(device)
        runtime.set_nb_steps(request['steps']);runtime.set_guidance_structure(request['guidance'])
        ref=np.pad(reference,(0,(-len(reference))%chunk))
        with torch.inference_mode():
            progress(config,'Reading timbre reference',0.1)
            latent=runtime.emb_model_structure.encode(torch.from_numpy(ref).reshape(1,1,-1).to(device))
            embedding=runtime.encoder.forward_stream(latent)
            if hasattr(runtime,'post_encoder'):embedding=runtime.post_encoder.forward_stream(embedding)
            embedding=embedding.reshape(1,-1)/float(runtime.latent_range)
            if embedding.shape[1]!=int(runtime.zt_channels):raise ValueError('Invalid timbre embedding dimensions')
            # Reload to reset the streaming codec/encoder state after reference
            # analysis; the selected timbre embedding survives independently.
            runtime=torch.jit.load(str(model_file),map_location='cpu').eval().to(device)
            runtime.set_nb_steps(request['steps']);runtime.set_guidance_structure(request['guidance'])
            padded=np.pad(source,(0,(-len(source))%chunk));chunks=[]
            for start in range(0,len(padded),chunk):
                label='Transforming audio'+(' · channel '+str(index+1)+' of '+str(len(parts)) if len(parts)>1 else '')
                progress(config,label,0.2+0.7*(index+start/max(1,len(padded)))/len(parts))
                audio=torch.from_numpy(padded[start:start+chunk]).reshape(1,1,-1).to(device)
                timbre=embedding.unsqueeze(-1).expand(1,-1,chunk)
                result=runtime.generate_timbre(torch.cat([audio,timbre],dim=1))
                chunks.append(result.detach().cpu().numpy().reshape(-1))
            return np.concatenate(chunks)[:len(source)]
    device='mps' if torch.backends.mps.is_available() else 'cpu'
    # Stereo sources are transformed one channel at a time with the same timbre.
    def run(device):return [execute(device,source,index) for index,source in enumerate(parts)]
    try:results=run(device)
    except RuntimeError as error:
        if device!='mps':raise
        print('MPS unavailable for this exported operation; using CPU:',error,flush=True)
        torch.mps.empty_cache();device='cpu';results=run(device)
    if any(len(result)!=len(parts[0]) for result in results):raise ValueError('AFTER returned invalid audio')
    audio=combine_channels(results,len(parts[0]))
    if not np.isfinite(audio).all():raise ValueError('AFTER returned invalid audio')
    gain=min(1.0,0.999/max(float(np.max(np.abs(audio))),1e-8))
    progress(config,'Saving transformed audio',0.95)
    sf.write(str(out/'transformed.wav'),audio*gain,rate,subtype='PCM_24')
    return [{'role':'Transformed audio','filename':'transformed.wav'}],{'backend':device.upper(),'sample_rate':str(rate),'channels':str(len(parts)),'output_gain':str(gain),'stream_chunk_frames':str(chunk)}

def main(filename):
    config=json.loads(Path(filename).read_text());start=time.monotonic()
    outputs,details={'sam':sam,'after':after}[config['request']['engine']](config)
    details['elapsed_seconds']=str(time.monotonic()-start)
    result={'outputs':outputs,'details':details}
    (Path(config['outputRoot'])/'result.json').write_text(json.dumps(result,indent=2))
    progress(config,'Complete',1.0)
if __name__=='__main__':main(sys.argv[1])
