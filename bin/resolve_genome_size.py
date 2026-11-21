#!/usr/bin/env python3
"""
Resolve a species-informed genome-size estimate (bp) for one sample, to pass as
a --gsize hint to the assemblers. Assembly quality is insensitive to this within
~2x - the hint only needs to keep Flye's / Shovill's own coverage estimation in
the right order of magnitude, and to avoid the catastrophic auto-estimate seen
on shallow data (Dragonflye estimating a ~1kb "genome"). So a ballpark is fine.

Source priority (best available wins):
  1. --override: the samplesheet's `genome_size` column, when given.
  2. --reference: the actual length of the sample's reference genome FASTA.
  3. --table + --taxid: a coarse per-species-taxid lookup, keyed on the
     species taxid of the species-ID top hit, for when there's no reference.
  4. --default: a generic backstop.

Prints one line: `<genome_size_bp>\\t<source>`.
"""

import argparse
import gzip
import sys


def reference_length(path):
    opener = gzip.open if path.endswith(".gz") else open
    total = 0
    with opener(path, "rt") as fh:
        for line in fh:
            if not line.startswith(">"):
                total += len(line.strip())
    return total if total > 0 else None


def table_lookup(path, taxid):
    if taxid is None:
        return None
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("species_taxid\t"):
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) >= 2 and cols[0] == taxid:
                try:
                    return int(cols[1])
                except ValueError:
                    return None
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--override", type=int, default=None, help="genome size (bp) given in the samplesheet")
    ap.add_argument("--reference", default=None, help="reference genome FASTA (optionally gzipped)")
    ap.add_argument("--taxid", default=None, help="species taxid of the species-ID top hit (for the table lookup)")
    ap.add_argument("--table", default=None, help="taxid -> approx genome size TSV")
    ap.add_argument("--default", type=int, required=True, help="generic backstop genome size (bp)")
    args = ap.parse_args()

    size, source = None, None

    if args.override:
        size, source = args.override, "samplesheet"

    if size is None and args.reference:
        size = reference_length(args.reference)
        if size:
            source = "reference"

    taxid = args.taxid if args.taxid not in (None, "", "NA") else None
    if size is None and args.table and taxid:
        size = table_lookup(args.table, taxid)
        if size:
            source = f"table:taxid={taxid}"

    if size is None:
        size, source = args.default, "default"

    print(f"{size}\t{source}")


if __name__ == "__main__":
    sys.exit(main())
