"""Build management-preview.html — the management view with data embedded.

For review only: no login, no Supabase, the full dataset baked in. The output
goes OUTSIDE the public repo (cal-dashboard is on GitHub Pages) because it
contains company data with no auth in front of it.

Usage: python build_preview.py <jobs1> <jobs2> <jobs3> <conv> <rest> <out>
where the first five args are execute_sql tool-result files.
"""
import json, re, sys


def extract(path):
    """Tool-result file -> the JSON payload between the untrusted-data markers."""
    outer = json.load(open(path, encoding='utf-8'))
    s = outer['result']
    # the marker string also appears in the prose sentence before the payload,
    # so anchor on the closing tag and walk back to the nearest opening one
    b = s.rindex('</untrusted-data')
    a = s.index('>', s.rindex('<untrusted-data', 0, b)) + 1
    return json.loads(s[a:b].strip())


def main(jobs_files, conv_file, rest_file, src, out):
    jobs = []
    for f in jobs_files:
        jobs += extract(f)[0]['json_agg']
    conv = extract(conv_file)[0]['json_agg']
    rest = extract(rest_file)[0]['json_build_object']
    print(f'jobs {len(jobs)}  conv {len(conv)}  nonconv {len(rest["nonconv"])}'
          f'  canc {len(rest["canc"])}  rep {len(rest["rep"])}  cust {len(rest["cust"])}')

    payload = json.dumps({'jobs': jobs, 'conv': conv, 'nonconv': rest['nonconv'],
                          'canc': rest['canc'], 'rep': rest['rep'], 'cust': rest['cust']},
                         separators=(',', ':'), ensure_ascii=False)
    # keep </script> from terminating the inline block early
    payload = payload.replace('</', '<\\/')

    html = open(src, encoding='utf-8').read()

    # 1. no Supabase CDN — stub the one call the page makes at load
    html = html.replace(
        '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>',
        '<script>window.supabase={createClient:()=>({auth:{getSession:async()=>({data:{}}),'
        'signInWithPassword:async()=>({error:{message:"preview build — no login"}}),'
        'signOut:async()=>{}}})};</script>')

    # 2. login stays hidden, app starts visible
    html = html.replace('<div id="login" class="wrap login">',
                        '<div id="login" class="wrap login" hidden>')
    html = html.replace('<div id="app" class="wrap" hidden>',
                        '<div id="app" class="wrap">')

    # 3. banner + title so nobody mistakes it for the live page
    html = html.replace('<title>Cal — Management Review</title>',
                        '<title>Cal — Management Review (preview)</title>')
    html = html.replace('<div class="sub" id="period">—</div>',
                        '<div class="sub" id="period">—</div>'
                        '<div class="sub" style="color:var(--warning)">Preview build — data embedded '
                        + json.dumps(__import__('datetime').date.today().isoformat())
                        + ', not live. Do not share this file.</div>')

    # 4. feed RAW and render. Top-level `let RAW` lives in the global lexical
    #    scope, so a later classic <script> can assign it directly.
    columns = {
        'jobs': ['week_label', 'depot', 'customer_name', 'sales_name', 'revenue', 'cost', 'profit', 'vehicle', 'call_sign'],
        'conv': ['week_label', 'depot', 'customer_name', 'quote_issued_by', 'income', 'tariff', 'our_ref'],
        'nonconv': ['week_label', 'depot', 'customer_name', 'quote_issued_by', 'income', 'tariff', 'quote_no'],
        'canc': ['week_label', 'depot', 'customer_name', 'value', 'reason_code', 'our_ref'],
    }
    boot = f"""
<script>
const PREVIEW_DATA = {payload};
const PREVIEW_COLS = {json.dumps(columns)};
(function(){{
  const expand = (rows, cols) => rows.map(r => Object.fromEntries(cols.map((c,i)=>[c,r[i]])));
  RAW = {{
    jobs:    expand(PREVIEW_DATA.jobs,    PREVIEW_COLS.jobs),
    conv:    expand(PREVIEW_DATA.conv,    PREVIEW_COLS.conv),
    nonconv: expand(PREVIEW_DATA.nonconv, PREVIEW_COLS.nonconv),
    canc:    expand(PREVIEW_DATA.canc,    PREVIEW_COLS.canc),
    rep:  Object.fromEntries(PREVIEW_DATA.rep),
    cust: Object.fromEntries(PREVIEW_DATA.cust)
  }};
  render();
}})();
</script>"""
    html = html.replace('</body>', boot + '\n</body>')

    open(out, 'w', encoding='utf-8').write(html)
    print(f'wrote {out}  ({len(html)/1e6:.1f} MB)')


if __name__ == '__main__':
    a = sys.argv[1:]
    main(a[0:3], a[3], a[4], a[5], a[6])
