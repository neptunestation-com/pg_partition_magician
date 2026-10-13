import json,sys
for p in sys.argv[1:]:
    last=None
    with open(p) as f:
        for line in f:
            line=line.strip()
            if not line: continue
            try: o=json.loads(line)
            except Exception: continue
            m=o.get('message') if isinstance(o,dict) else None
            if o.get('type')=='assistant' and m:
                c=m.get('content')
                if isinstance(c,list):
                    t=''.join(x.get('text','') for x in c if isinstance(x,dict) and x.get('type')=='text')
                    if t.strip(): last=t
                elif isinstance(c,str) and c.strip(): last=c
    print('=====',p.split('/')[-1]); print((last or '(no text)')[-3500:])
