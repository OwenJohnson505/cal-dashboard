"""Test whether the Special Price (postcode) table predicts a job's actual revenue.

Unlike the region matrix, this table has unambiguous semantics: one money column
holding a fixed charge for a (customer, tariff, collection postcode, delivery
postcode) combination. If it is the charge, jobs on those exact lanes should hit
it exactly. Anything that does not is either a hand-priced job or carries extras.
"""
import csv, json, statistics as st, sys
from collections import defaultdict


def money(x):
    try:
        return float(str(x).replace(',', '').replace('£', '').strip())
    except Exception:
        return None


def norm_pc(pc):
    if not pc:
        return None
    pc = str(pc).split('\r')[0].split('\n')[0].strip().upper()
    return pc.replace(' ', '') or None


def norm_cust(c):
    if not c:
        return ''
    c = str(c).strip().upper()
    for junk in ('@', "''", '..', '.', 'ï¿½'):
        c = c.replace(junk, '')
    return ' '.join(c.split())


def main(pc_csv, jobs_json):
    rows = list(csv.DictReader(open(pc_csv, encoding='utf-8-sig')))

    # (tariff, from, to) -> {customer_key: price}
    table = defaultdict(dict)
    for r in rows:
        p = money(r['v4'])
        if p is None:
            continue
        key = (r['tariff'].strip().upper(), norm_pc(r['from']), norm_pc(r['to']))
        table[key][norm_cust(r['customer'])] = p

    jobs = json.load(open(jobs_json, encoding='utf-8'))
    print(f'postcode lanes: {len(table)}   jobs: {len(jobs)}')

    matched, exact, within10 = [], 0, 0
    above, below = [], []
    for j in jobs:
        rev = money(j['revenue'])
        if not rev:
            continue
        key = (str(j['vehicle']).strip().upper(),
               norm_pc(j['collection_postcode']), norm_pc(j['delivery_postcode']))
        cands = table.get(key)
        if not cands:
            continue
        cust = norm_cust(j['customer_name'])
        price = cands.get(cust)
        if price is None:
            # fall back to the All Customers rate
            price = cands.get('ALL CUSTOMERS')
        if price is None:
            continue
        matched.append((j, price, rev))
        if abs(rev - price) < 0.01:
            exact += 1
        elif rev > price:
            above.append((j, price, rev))
        else:
            below.append((j, price, rev))
        if price and abs(rev - price) <= 0.10 * price:
            within10 += 1

    if not matched:
        print('no jobs matched a postcode lane')
        return

    n = len(matched)
    print(f'\n  jobs matching a lane exactly: {n}')
    print(f'    revenue == table price   {exact:5d}  ({exact/n*100:.1f}%)')
    print(f'    within 10%               {within10:5d}  ({within10/n*100:.1f}%)')
    print(f'    charged ABOVE the table  {len(above):5d}  ({len(above)/n*100:.1f}%)')
    print(f'    charged BELOW the table  {len(below):5d}  ({len(below)/n*100:.1f}%)')

    if above:
        d = [r - p for _, p, r in above]
        print(f'    median uplift when above  +{st.median(d):.2f}')
    if below:
        d = [p - r for _, p, r in below]
        print(f'    median shortfall when below -{st.median(d):.2f}')

    print('\n  sample:')
    print(f"    {'job':<10}{'tariff':<20}{'lane':<22}{'table':>9}{'actual':>9}{'diff':>9}")
    for j, p, r in matched[:18]:
        ln = f"{norm_pc(j['collection_postcode'])}>{norm_pc(j['delivery_postcode'])}"
        print(f"    {j['job_no']:<10}{str(j['vehicle'])[:19]:<20}{ln:<22}"
              f"{p:>9.0f}{r:>9.0f}{r-p:>+9.0f}")


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
