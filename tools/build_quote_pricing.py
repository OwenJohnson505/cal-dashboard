"""Precompute the quote-pricing snapshot embedded in management.html.

Prices every open quote in the scraped grid against the tariff data scraped from
System Setup, using the customer-first matching rule (match on the customer's
assigned tariffs, by exact name then vehicle then prefix — never by bare name
across all 500 cards, which biases +10%).

Zero-rate tariffs (no distance rate) are priced from the Special Price postcode
table where a lane exists. The Regional tariffs' region matrix has unreadable
column headers (vendor question outstanding), so those quotes are counted as
UNPRICEABLE rather than half-guessed — per Owen's instruction to go with what
we can actually get and leave the rest off.

Output: quote_pricing_snapshot.json, embedded verbatim in management.html.
"""
import csv, json, re, statistics as st
from collections import defaultdict

TOL = 0.02          # within 2% of the card = "at tariff"
TOL_ABS = 2.0       # or within £2, for small jobs


def money(x):
    try:
        v = float(str(x).replace(',', '').replace('£', '').strip())
        return v
    except Exception:
        return None


def norm(s):
    return ' '.join(str(s or '').strip().upper().split())


def clean_cust(s):
    c = norm(s)
    for junk in ('@', "''", '..', 'ï¿½', '�'):
        c = c.replace(junk, '')
    return c.strip(' .')


PC_RE = re.compile(r'([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})\s*$')
def postcode(s):
    m = PC_RE.search(norm(s))
    return m.group(1).replace(' ', '') if m else None


def load_tariffs(path):
    rows = list(csv.DictReader(open(path, encoding='utf-8-sig')))
    cards = []
    by_customer = defaultdict(list)
    for r in rows:
        card = dict(
            name=norm(r['tariff_name']), vehicle=norm(r['vehicle']),
            base=money(r['base_price']) or 0, inc=money(r['included_miles']) or 0,
            rate=money(r['rate_per_mile']) or 0)
        card['zero'] = card['base'] == 0 and card['rate'] == 0
        cards.append(card)
        for c in str(r.get('customers') or '').split(','):
            c = clean_cust(c)
            if c:
                by_customer[c].append(card)
    return cards, by_customer


def match_card(cust, tariff, by_customer):
    """Customer-first: exact name, then vehicle==tariff, then prefixes."""
    mine = by_customer.get(cust, [])
    for tier, ok in (
        ('exact', lambda k: k['name'] == tariff),
        ('vehicle', lambda k: k['vehicle'] == tariff),
        ('name-prefix', lambda k: k['name'].startswith(tariff) or tariff.startswith(k['name'])),
        ('vehicle-prefix', lambda k: k['vehicle'].startswith(tariff) or tariff.startswith(k['vehicle'])),
    ):
        hits = [k for k in mine if ok(k)]
        if hits:
            # prefer a priced card over a zero-rate one
            hits.sort(key=lambda k: k['zero'])
            return hits[0], tier
    return None, None


def main():
    cards, by_customer = load_tariffs('tariffs_CalNorth_20260806-114019.csv')
    zero_names = {c['name'] for c in cards if c['zero']}

    # Special Price postcode lanes: customer-specific first, then All Customers
    lanes = {}
    for r in csv.DictReader(open('special_prices_postcode_CalNorth.csv', encoding='utf-8-sig')):
        p = money(r['v4'])
        if p is None:
            continue
        lanes[(clean_cust(r['customer']), norm(r['tariff']),
               norm(r['from']).replace(' ', ''), norm(r['to']).replace(' ', ''))] = p

    quotes = list(csv.DictReader(open('quotes_CalNorth_20260806-125050.csv', encoding='utf-8-sig')))

    out = dict(scraped='2026-08-06', profile='Cal North', n=len(quotes),
               unpriced_yet=0,
               at=0, above=0, below=0,
               at_v=0.0, above_v=0.0, below_v=0.0,
               above_dev=[], below_dev=[],
               unpriceable=dict(regional=0, regional_v=0.0, other=0, other_v=0.0,
                                no_match=0, no_match_v=0.0),
               samples=dict(above=[], below=[]))

    for q in quotes:
        cust = clean_cust(q['customer'])
        tariff = norm(q['tariff']).rstrip('.')
        rev = money(q['revenue']) or 0
        miles = money(q['miles'])
        if rev <= 0:
            # a £0 quote has not been priced yet — it is not a discount
            out['unpriced_yet'] += 1
            continue

        expected = None
        via = None

        card, tier = match_card(cust, tariff, by_customer)
        if card and not card['zero'] and miles is not None:
            expected = card['base'] + max(0, miles - card['inc']) * card['rate']
            via = tier
        else:
            # zero-rate or unmatched: try the Special Price postcode table
            fpc, tpc = postcode(q['collection']), postcode(q['delivery'])
            if fpc and tpc:
                for ck in (cust, 'ALL CUSTOMERS'):
                    p = lanes.get((ck, tariff, fpc, tpc))
                    if p is not None:
                        expected = p
                        via = 'postcode-lane'
                        break

        if expected is None:
            k = out['unpriceable']
            if 'REGIONAL' in tariff:
                k['regional'] += 1; k['regional_v'] += rev
            elif card and card['zero']:
                k['other'] += 1; k['other_v'] += rev
            else:
                k['no_match'] += 1; k['no_match_v'] += rev
            continue

        diff = rev - expected
        if abs(diff) <= max(TOL_ABS, TOL * expected):
            out['at'] += 1; out['at_v'] += rev
        elif diff > 0:
            out['above'] += 1; out['above_v'] += rev
            out['above_dev'].append(diff)
            if len(out['samples']['above']) < 6:
                out['samples']['above'].append(dict(
                    ref=q['our_ref'], tariff=q['tariff'], miles=miles,
                    expected=round(expected, 2), actual=rev, via=via))
        else:
            out['below'] += 1; out['below_v'] += rev
            out['below_dev'].append(diff)
            if len(out['samples']['below']) < 6:
                out['samples']['below'].append(dict(
                    ref=q['our_ref'], tariff=q['tariff'], miles=miles,
                    expected=round(expected, 2), actual=rev, via=via))

    priced = out['at'] + out['above'] + out['below']
    out['priced'] = priced
    out['above_med'] = round(st.median(out['above_dev']), 2) if out['above_dev'] else 0
    out['below_med'] = round(st.median(out['below_dev']), 2) if out['below_dev'] else 0
    del out['above_dev'], out['below_dev']
    for k in ('at_v', 'above_v', 'below_v'):
        out[k] = round(out[k], 2)
    u = out['unpriceable']
    for k in ('regional_v', 'other_v', 'no_match_v'):
        u[k] = round(u[k], 2)

    json.dump(out, open('quote_pricing_snapshot.json', 'w', encoding='utf-8'), indent=1)
    print(json.dumps(out, indent=1))


if __name__ == '__main__':
    main()
