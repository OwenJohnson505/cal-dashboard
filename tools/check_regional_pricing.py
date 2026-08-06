"""Work out which column of the Special Price (region) matrix is the customer charge.

The grid exposes no column headers to UI Automation, so the meaning of the two
money columns is inferred from evidence rather than assumed: each real job on a
Regional tariff is mapped to its (from_region, to_region) lane and compared
against both candidates. The column that predicts actual revenue is the charge.
"""
import csv, json, statistics as st, sys
from collections import defaultdict

AREA_REGION = {}
def _add(region, areas):
    for a in areas.split():
        AREA_REGION[a] = region

_add('Scotland',   'AB DD DG EH FK G HS IV KA KW KY ML PA PH TD ZE')
_add('Wales',      'CF LD LL NP SA')
_add('North East', 'DH DL NE SR TS')
_add('North West', 'BB BL CA CH CW FY L LA M OL PR SK WA WN')
_add('Yorkshire and the Humber', 'BD DN HD HG HU HX LS S WF YO')
_add('Midlands',   'B CV DE DY LE LN NG NN ST TF WR WS WV')
_add('East of England', 'AL CB CM CO IP LU NR PE SG SS')
_add('Greater London', 'BR CR DA E EC EN HA IG KT N NW RM SE SM SW TW UB W WC WD')
_add('South East',  'BN CT GU HP ME MK OX PO RG RH SL SO')
_add('South West',  'BA BH BS DT EX GL PL SN SP TA TQ TR')


def area(pc):
    """Postcode area = leading letters of the outward code."""
    if not pc:
        return None
    pc = str(pc).split('\r')[0].split('\n')[0].strip().upper()
    letters = ''
    for ch in pc:
        if ch.isalpha():
            letters += ch
        else:
            break
    return letters or None


def region(pc):
    return AREA_REGION.get(area(pc))


def money(x):
    try:
        return float(str(x).replace(',', '').replace('£', '').strip())
    except Exception:
        return None


def main(matrix_csv, jobs_json):
    rows = list(csv.DictReader(open(matrix_csv, encoding='utf-8-sig')))
    lane = {}
    for r in rows:
        lane[(r['tariff'], r['from_region'], r['to_region'])] = (
            money(r['price']), money(r['cost']))

    jobs = json.load(open(jobs_json, encoding='utf-8'))
    print(f'matrix lanes: {len(lane)}   jobs: {len(jobs)}')

    rec = []
    unmapped = 0
    for j in jobs:
        fr, to = region(j['collection_postcode']), region(j['delivery_postcode'])
        if not fr or not to:
            unmapped += 1
            continue
        hit = lane.get((j['vehicle'], fr, to))
        if not hit:
            continue
        c4, c5 = hit
        rev = money(j['revenue'])
        cost = money(j['cost'])
        if rev is None or not rev:
            continue
        rec.append(dict(job=j['job_no'], tariff=j['vehicle'], fr=fr, to=to,
                        rev=rev, cost=cost, c4=c4, c5=c5))

    print(f'matched to a lane: {len(rec)}   unmapped postcode: {unmapped}')
    if not rec:
        return

    for name, key in (('col4', 'c4'), ('col5', 'c5')):
        exact = sum(1 for r in rec if r[key] and abs(r['rev'] - r[key]) < 0.01)
        w10 = sum(1 for r in rec if r[key] and abs(r['rev'] - r[key]) <= 0.10 * r[key])
        ratios = [r['rev'] / r[key] for r in rec if r[key]]
        print(f'\n  revenue vs {name}:')
        print(f'    exact match      {exact:5d}  ({exact/len(rec)*100:.1f}%)')
        print(f'    within 10%       {w10:5d}  ({w10/len(rec)*100:.1f}%)')
        if ratios:
            print(f'    median rev/{name}  {st.median(ratios):.2f}')

    # does either column predict COST instead?
    for name, key in (('col4', 'c4'), ('col5', 'c5')):
        have = [r for r in rec if r[key] and r['cost']]
        if have:
            exact = sum(1 for r in have if abs(r['cost'] - r[key]) < 0.01)
            print(f'  cost vs {name}: exact {exact}/{len(have)}')

    print('\n  sample lanes:')
    print(f"    {'job':<10}{'tariff':<24}{'lane':<38}{'rev':>8}{'cost':>8}{'col4':>8}{'col5':>8}")
    for r in rec[:15]:
        ln = f"{r['fr']} -> {r['to']}"
        print(f"    {r['job']:<10}{r['tariff']:<24}{ln:<38}{r['rev']:>8.0f}"
              f"{(r['cost'] or 0):>8.0f}{(r['c4'] or 0):>8.0f}{(r['c5'] or 0):>8.0f}")


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
