import asyncio,json,sys,time
import httpx
from main import prepare_request
from config import load_config
from pathlib import Path
async def main():
 cfg=load_config(Path('/config/backend_ocr.toml'))
 async with httpx.AsyncClient(timeout=cfg.timeout_seconds,trust_env=False) as client:
  slots=asyncio.Semaphore(2)
  async def guarded(c):
   async with slots: await run(c)
  async def run(c):
   p=prepare_request(c['body'],cfg)['messages'][0]['content'][0]['image_url']['url']
   b={'model':cfg.engine.model,'messages':[{'role':'user','content':[{'type':'text','text':'<image>document parsing.'},{'type':'image_url','image_url':{'url':p}}]}],'temperature':0,'max_tokens':8192,'skip_special_tokens':False,'vllm_xargs':{'ngram_size':35,'window_size':128}}
   async def call(engine,port,path,body):
    t=time.monotonic()
    try:
     r=await client.post(f'http://127.0.0.1:{port}{path}',json=body)
     return {'engine':engine,'status':r.status_code,'body':r.json(),'seconds':time.monotonic()-t}
    except httpx.HTTPError as e:
     return {'engine':engine,'error_type':type(e).__name__,'error':str(e),'seconds':time.monotonic()-t}
   results=await asyncio.gather(call('unlimited',8002,'/v1/chat/completions',b),call('paddle',8003,'/recognize',{'image':p}))
   print(json.dumps({'id':c['id'],'results':results}),flush=True)
  await asyncio.gather(*(guarded(c) for c in json.load(sys.stdin)))
asyncio.run(main())
