#!/usr/bin/env python3
"""
Tally how often each species-ID tool (sylph, kraken2) matched the expected
taxa, per platform - to see which tool to trust for which kind of data.

Reads one or more sample_summary.csv files (e.g. from several runs) and counts,
for every group (default: platform), the samples that have something to be
checked against (an expected_taxid of their own or from their project) and, for
each tool, how many came out as match, mismatch or no call. It also counts the
sylph/kraken2 relationship (species_check_concordance: agree_match,
agree_mismatch, disagree, sylph_only, kraken2_only, no_call).

The expected taxa are the ground truth here, so the tallies are only as good as
those labels - and a taxid above species rank (a genus, a family) makes `match`
a weaker statement. Samples seen in several files are counted once per file.

Usage:
  tally_species_calls.py run1/summary/sample_summary.csv run2/summary/sample_summary.csv
  tally_species_calls.py --by project_id --sample-type isolate sample_summary.csv
"""

import argparse
import csv
import sys
from collections import Counter, defaultdict

TOOLS = {"sylph": "species_check", "kraken2": "species_check_kraken2_verdict"}
CONCORDANCE = ["agree_match", "agree_mismatch", "disagree", "sylph_only", "kraken2_only", "no_call"]
UNLABELLED = ("not_checked", "NA", "")


def labelled(row):
    """A sample can be scored if either tool had expected taxa to check against."""
    return any(row.get(col, "NA") not in UNLABELLED for col in TOOLS.values())


def tally(rows, by):
    per_tool = defaultdict(Counter)      # (group, tool) -> verdict counts
    per_conc = defaultdict(Counter)      # group -> concordance counts
    n = Counter()
    for row in rows:
        group = row.get(by) or "NA"
        n[group] += 1
        for tool, col in TOOLS.items():
            verdict = row.get(col, "NA")
            if verdict in ("", None):
                verdict = "NA"
            per_tool[(group, tool)][verdict] += 1
        per_conc[group][row.get("species_check_concordance", "NA") or "NA"] += 1
    return n, per_tool, per_conc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("summaries", nargs="+", help="sample_summary.csv file(s)")
    ap.add_argument("--by", default="platform", help="column to group by (default: platform; e.g. project_id)")
    ap.add_argument("--sample-type", default=None, help="only samples of this sample_type (e.g. isolate)")
    args = ap.parse_args()

    rows = []
    for path in args.summaries:
        with open(path) as fh:
            rows.extend(csv.DictReader(fh))
    if args.sample_type:
        rows = [r for r in rows if r.get("sample_type") == args.sample_type]
    scored = [r for r in rows if labelled(r)]
    print(f"# {len(rows)} samples, {len(scored)} with expected taxa to check against", file=sys.stderr)

    n, per_tool, per_conc = tally(scored, args.by)
    out = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")

    # match_rate is over the samples the tool ran on; not_run (verdict NA)
    # means the tool did not run for the sample (e.g. no kraken2 database).
    out.writerow([args.by, "tool", "n", "match", "mismatch", "no_call", "not_run", "match_rate"])
    for group in sorted(n):
        for tool in TOOLS:
            c = per_tool[(group, tool)]
            match, mismatch, not_run = c["match"], c["mismatch"], c["NA"]
            no_call = n[group] - match - mismatch - not_run
            ran = n[group] - not_run
            rate = f"{match / ran:.3f}" if ran else "NA"
            out.writerow([group, tool, n[group], match, mismatch, no_call, not_run, rate])

    out.writerow([])
    out.writerow([args.by, "n"] + CONCORDANCE + ["NA"])
    for group in sorted(n):
        c = per_conc[group]
        out.writerow([group, n[group]] + [c[k] for k in CONCORDANCE] + [c["NA"]])


if __name__ == "__main__":
    main()
