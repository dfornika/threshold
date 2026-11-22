#!/usr/bin/env python3
"""
Merge species-ID manifests into one (the pipeline takes a single
--species_id_manifest covering every sylph database): the union of the
inputs' columns, one row per accession. If an accession appears in several
inputs, the first file wins; accessions that disagree on taxid/species_taxid
between inputs are reported.

Usage:
  merge_species_manifests.py gtdb_manifest.csv viral_manifest.csv fungal_manifest.csv -o manifest.csv
"""

import argparse
import csv
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifests", nargs="+", help="manifest CSVs, highest priority first")
    ap.add_argument("-o", "--output", help="output CSV (default: stdout)")
    args = ap.parse_args()

    fields, rows, by_accession = [], [], {}
    duplicates = conflicts = 0
    for path in args.manifests:
        with open(path, newline="") as fh:
            reader = csv.DictReader(fh)
            if "accession" not in (reader.fieldnames or []):
                sys.exit(f"{path}: not a manifest (no 'accession' column)")
            fields += [f for f in reader.fieldnames if f not in fields]
            for row in reader:
                seen = by_accession.get(row["accession"])
                if seen is None:
                    by_accession[row["accession"]] = row
                    rows.append(row)
                    continue
                duplicates += 1
                for key in ("taxid", "species_taxid"):
                    if row.get(key) and seen.get(key) and row[key] != seen[key]:
                        conflicts += 1
                        break

    out = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.DictWriter(out, fieldnames=fields, restval="")
    writer.writeheader()
    writer.writerows(rows)
    if out is not sys.stdout:
        out.close()
    print(f"wrote {len(rows)} accessions from {len(args.manifests)} manifest(s); {duplicates} duplicate(s) dropped, {conflicts} with a different taxid", file=sys.stderr)


if __name__ == "__main__":
    main()
