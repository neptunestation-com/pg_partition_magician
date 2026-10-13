#!/usr/bin/env python3
"""unit.py <tree> <file> <schema.name> [maxlines]: print a function/procedure body with line numbers (create line to the closing $$;)."""
import re,sys
tree,f,name=sys.argv[1:4]; mx=int(sys.argv[4]) if len(sys.argv)>4 else 400
lines=open(f"{tree}/{f}").read().split("\n")
rx=re.compile(r'^\s*create\s+(?:or\s+replace\s+)?(?:function|procedure)\s+'+re.escape(name)+r'\s*\(',re.I)
for i,l in enumerate(lines):
    if rx.match(l):
        j=i
        while j<len(lines) and not re.match(r'^\$[a-z_]*\$;',lines[j]): j+=1
        for k in range(i,min(j+1,i+mx)): print(f"{k+1}:{lines[k]}")
        print(f"[{name}: lines {i+1}-{j+1}]"); print()
