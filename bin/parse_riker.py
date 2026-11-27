#!/usr/bin/env python3
"""
Normalise one sample's riker metrics into a single summary row, the same one-
row-per-sample-per-stage convention the other stages use (cf.
bin/parse_assembly_qc.py).

Inputs are riker's tab-separated metrics files, each a header plus one row per
category:
  --wgs        <prefix>.wgs-metrics.txt        coverage depth and evenness
  --alignment  <prefix>.alignment-metrics.txt  fraction of reads aligned
  --isize      <prefix>.isize-metrics.txt      insert size (paired Illumina only)

The alignment metrics have one row per read category: `pair` for paired reads
(the whole-pair figure), `read1` for single-end reads. The insert-size file
exists for every sample but is empty unless there are read pairs.
Anything missing comes back as NA.
"""

import argparse
import csv
import sys

NA = "NA"


def rows(path):
    if not path:
        return []
    with open(path) as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def pick(row, key):
    value = row.get(key) if row else None
    return value if value not in (None, "") else NA


def alignment_row(all_rows):
    """The whole-pair row for paired reads, else the single-end (read1) row."""
    by_category = {row.get("category"): row for row in all_rows}
    return by_category.get("pair") or by_category.get("read1") or (all_rows[0] if all_rows else None)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--platform", required=True)
    ap.add_argument("--wgs", required=True, help="riker wgs-metrics.txt")
    ap.add_argument("--alignment", default=None, help="riker alignment-metrics.txt")
    ap.add_argument("--isize", default=None, help="riker isize-metrics.txt (omit or empty for unpaired reads)")
    args = ap.parse_args()

    wgs = (rows(args.wgs) or [None])[0]
    aln = alignment_row(rows(args.alignment))
    isize = (rows(args.isize) or [None])[0]

    print(
        "\t".join(
            [
                args.sample,
                args.platform,
                pick(wgs, "mean_coverage"),
                pick(wgs, "median_coverage"),
                pick(wgs, "frac_bases_at_1x"),
                pick(wgs, "frac_bases_at_10x"),
                pick(wgs, "fold_80_base_penalty"),
                pick(aln, "frac_aligned"),
                pick(isize, "median_insert_size"),
            ]
        )
    )


if __name__ == "__main__":
    sys.exit(main())
