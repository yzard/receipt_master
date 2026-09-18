"""Real image-to-store regression; owns and removes all its receipts and aliases."""
import argparse
import json
from pathlib import Path
import time
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', required=True)
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--photo', type=Path, required=True)
    args = parser.parse_args()
    key = args.key_file.read_text().strip()
    base = args.url.rstrip('/')
    name = 'LOGO PROBE ' + uuid.uuid4().hex
    owned, sample = [], None

    def call(component, operation, value):
        req = urllib.request.Request(f'{base}/api/v1/{component}/{operation}',
            data=json.dumps({'request_key':str(uuid.uuid4()),'input':value}).encode(),
            headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=300) as result:
            return json.load(result)

    def create():
        now = int(time.time()*1000)
        receipt = call('receipts','save',{'receipt':{'id':str(uuid.uuid4()),'store':'',
            'branch':'','address':'','country':'US','currency':'USD','timeSource':'estimated_instant',
            'rawTime':'','totalSource':'user_entered','occurredAt':now,'createdAt':now,'revision':0,
            'totalMinor':0,'posted':False,'lines':[]}})['data']
        owned.append(receipt['id'])
        boundary = uuid.uuid4().hex
        metadata = json.dumps({'request_key':str(uuid.uuid4()),'input':{'receipt_id':receipt['id'],
            'expected_version':receipt['revision'],'captured_at_utc_ms':now}})
        body = (f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\n\r\n{metadata}\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="photo"; filename="probe.jpg"\r\nContent-Type: image/jpeg\r\n\r\n').encode()+args.photo.read_bytes()+f'\r\n--{boundary}--\r\n'.encode()
        req = urllib.request.Request(base+'/api/v1/images/upload',data=body,headers={
            'Authorization':'Bearer '+key,'Content-Type':'multipart/form-data; boundary='+boundary})
        with urllib.request.urlopen(req,timeout=30) as result:
            return json.load(result)['data']['receipt']

    try:
        template = create()
        reply = call('logos','extract',{'receipt_id':template['id']})
        sample = reply['data'][0]['logo_id']
        call('logos','save',{'id':sample,'name':name,'expected_version':reply['catalog_version']})
        print('Confirmed probe image alias',flush=True)
        query = create()
        job = call('recognition','start',{'receipt_id':query['id'],'expected_version':query['revision'],
            'zone':'America/New_York'})['data']['job_id']
        deadline = time.monotonic()+600
        while time.monotonic()<deadline:
            status = call('recognition','get',{'id':job})['data']['status']
            assert status not in ['failed','cancelled','unknown'],status
            if status=='applied': break
            time.sleep(2)
        else: raise AssertionError('Job timed out')
        result = call('receipts','get',{'id':query['id']})['data']
        assert result['store']==name, result['store']
        assert not result['recognizedStore'],result['recognizedStore']
        assert result['lines']
        print('PASS: new receipt uses confirmed image alias, never OCR store text; items still recognized',flush=True)
    finally:
        if sample:
            reply=call('logos','list',{})
            call('logos','delete',{'id':sample,'expected_version':reply['catalog_version']})
        for rid in owned:
            receipt=call('receipts','get',{'id':rid})['data']
            call('receipts','purge',{'id':rid,'expected_version':receipt['revision']})


if __name__=='__main__': main()
