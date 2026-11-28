# Medians per module from bench JSON lines. "1st" = the module touched first
# in that launch (pays process-wide first-use costs), "rest" = the others.
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
mods = ['swift', 'cpp', 'mixed', 'wide']
def med(xs): return f"{statistics.median(xs):8.1f}" if xs else "       -"
for mode, keys in [('plain', ['ctor_us', 'sync1_us', 'struct1_us', 'async1_us', 'sync_warm_ns', 'async_warm_us']),
                   ('breakdown', ['open_us', 'provides2_us', 'init_dl_us', 'abi_us', 'checksum_us', 'lookup_create_us', 'create_call_us', 'lookup_all_us', 'lookup_all_n'])]:
    rs = [r for r in rows if r['mode'] == mode]
    if not rs: continue
    print(f"\n== {mode} ({len(rs)} launches, {rs[0]['platform']}) ==")
    print(f"{'module':12}" + "".join(f"{k:>16}" for k in keys))
    for m in mods:
        for tag, sel in [('1st', lambda r: r['first'] == m), ('rest', lambda r: r['first'] != m)]:
            print(f"{m + ' ' + tag:12}" + "".join(f"{med([r[m][k] for r in rs if sel(r)]):>16}" for k in keys))
