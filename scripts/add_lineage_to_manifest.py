#!/usr/bin/env python3
"""
Add a `lineage_taxids` column to a species-ID manifest: every NCBI ancestor
taxid of each genome's `taxid` (falling back to its `species_taxid`),
`;`-separated. The pipeline's species check uses it to match a sample against
an expected taxid at any rank - e.g. expected 543 (Enterobacteriaceae) accepts
a hit whose lineage contains 543.

Uses NCBI's new_taxdump (https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/new_taxdump/):
  taxidlineage.dmp   taxid -> its ancestors
  merged.dmp         retired taxid -> current taxid (applied first)

Usage:
  add_lineage_to_manifest.py --taxdump new_taxdump/ manifest.csv -o manifest.lineage.csv

Also importable: build_species_manifest_from_gtdb.py uses
load_lineages()/load_merged() via its --taxdump option.
"""

import argparse
import csv
import os
import sys

LINEAGE_FIELD = "lineage_taxids"


def load_merged(taxdump_dir):
    """retired taxid -> current taxid, from merged.dmp."""
    merged = {}
    path = os.path.join(taxdump_dir, "merged.dmp")
    if not os.path.isfile(path):
        return merged
    with open(path) as fh:
        for line in fh:
            parts = [p.strip() for p in line.split("|")]
            if len(parts) >= 2 and parts[0] and parts[1]:
                merged[parts[0]] = parts[1]
    return merged


def load_lineages(taxdump_dir, wanted):
    """taxid -> [ancestor taxids, root first] for the taxids in `wanted`.
    Streams taxidlineage.dmp (several hundred MB) keeping only what's needed."""
    lineages = {}
    with open(os.path.join(taxdump_dir, "taxidlineage.dmp")) as fh:
        for line in fh:
            taxid, _, rest = line.partition("\t|\t")
            if taxid in wanted:
                lineages[taxid] = rest.rstrip("\t|\n").split()
    return lineages


def load_scientific_names(taxdump_dir, wanted):
    """taxid -> scientific name for the taxids in `wanted`, from names.dmp."""
    names = {}
    with open(os.path.join(taxdump_dir, "names.dmp")) as fh:
        for line in fh:
            parts = [p.strip() for p in line.split("|")]
            if len(parts) >= 4 and parts[3] == "scientific name" and parts[0] in wanted:
                names[parts[0]] = parts[1]
    return names


def lineage_for(row, lineages, merged):
    """`;`-separated ancestors of the row's taxid (or species_taxid), '' if unknown."""
    for field in ("taxid", "species_taxid"):
        taxid = (row.get(field) or "").strip()
        if not taxid or taxid == "NA":
            continue
        taxid = merged.get(taxid, taxid)
        if taxid in lineages:
            return ";".join(lineages[taxid])
    return ""


def add_lineages(rows, taxdump_dir):
    """Add `lineage_taxids` to each row (in place); returns the number of rows resolved."""
    merged = load_merged(taxdump_dir)
    wanted = set()
    for row in rows:
        for field in ("taxid", "species_taxid"):
            taxid = (row.get(field) or "").strip()
            if taxid and taxid != "NA":
                wanted.add(merged.get(taxid, taxid))
    lineages = load_lineages(taxdump_dir, wanted)
    resolved = 0
    for row in rows:
        row[LINEAGE_FIELD] = lineage_for(row, lineages, merged)
        resolved += bool(row[LINEAGE_FIELD])
    return resolved


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest", help="species-ID manifest CSV (needs a taxid and/or species_taxid column)")
    ap.add_argument("--taxdump", required=True, help="directory with NCBI new_taxdump's taxidlineage.dmp and merged.dmp")
    ap.add_argument("-o", "--output", help="output CSV (default: stdout)")
    args = ap.parse_args()

    with open(args.manifest) as fh:
        reader = csv.DictReader(fh)
        fields = list(reader.fieldnames or [])
        rows = list(reader)
    if not {"taxid", "species_taxid"} & set(fields):
        sys.exit(f"{args.manifest}: needs a taxid or species_taxid column")
    if LINEAGE_FIELD not in fields:
        fields.append(LINEAGE_FIELD)

    resolved = add_lineages(rows, args.taxdump)

    out = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.DictWriter(out, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
    if out is not sys.stdout:
        out.close()
    print(f"lineage found for {resolved} of {len(rows)} rows", file=sys.stderr)


if __name__ == "__main__":
    main()
