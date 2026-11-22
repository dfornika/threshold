#!/usr/bin/env python3
"""
Build a --species_id_manifest CSV from NCBI assembly summary files, for any
sylph database whose genomes are named by assembly accession (GCF_... /
GCA_...): viral, fungal, or anything else downloaded from RefSeq/GenBank.

NCBI's assembly summaries list, for every assembly, its `taxid`, `species_taxid`
and organism name:
  https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt   (~260 MB)
  https://ftp.ncbi.nlm.nih.gov/genomes/genbank/assembly_summary_genbank.txt (~1.8 GB)
  https://ftp.ncbi.nlm.nih.gov/genomes/refseq/viral/assembly_summary.txt    (viruses only, ~8 MB)
  https://ftp.ncbi.nlm.nih.gov/genomes/refseq/fungi/assembly_summary.txt    (fungi only)
The species name (scientific name of the species taxid) and the ancestor taxids
(`lineage_taxids`, which lets an expected taxid match at any rank) come from
NCBI's taxonomy dump (--taxdump: names.dmp, taxidlineage.dmp, merged.dmp from
https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/new_taxdump/).

Each RefSeq assembly is also written under its paired GenBank (GCA_) accession,
since a database built from GenBank downloads names the same genome that way.

One manifest covers every sylph database (it's keyed by accession, which is
unique), so combine this with the GTDB builder's output using
merge_species_manifests.py.

Usage:
  build_species_manifest_from_ncbi.py assembly_summary.txt [more.txt ...] \\
      --taxdump new_taxdump/ [--accessions genomes.txt] -o viral_manifest.csv

--accessions keeps only the assembly accessions found anywhere in a text file
(e.g. `ls <dir of the database's genomes> > genomes.txt`).
"""

import argparse
import csv
import gzip
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from add_lineage_to_manifest import LINEAGE_FIELD, add_lineages, load_merged, load_scientific_names  # noqa: E402

ACCESSION = re.compile(r"GC[AF]_\d+\.\d+")
NA = "NA"
OUTPUT_FIELDS = ["accession", "organism", "strain", "taxid", "species_taxid", "species_name", LINEAGE_FIELD]


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def clean(value):
    value = (value or "").strip()
    return value if value and value.lower() != "na" else NA


def summary_rows(path):
    """Rows of an NCBI assembly_summary file as dicts (header: `#assembly_accession ...`)."""
    with open_text(path) as fh:
        header = None
        for line in fh:
            if line.startswith("##"):
                continue
            if line.startswith("#"):
                header = line.lstrip("#").rstrip("\n").split("\t")
                continue
            if header is None:
                sys.exit(f"{path}: no '#assembly_accession ...' header line - not an NCBI assembly summary")
            yield dict(zip(header, line.rstrip("\n").split("\t")))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("summaries", nargs="+", help="NCBI assembly_summary file(s), optionally gzipped")
    ap.add_argument("--taxdump", required=True, help="NCBI new_taxdump directory (names.dmp, taxidlineage.dmp, merged.dmp)")
    ap.add_argument("--accessions", help="keep only assembly accessions found anywhere in this text file")
    ap.add_argument("-o", "--output", help="output CSV (default: stdout)")
    args = ap.parse_args()

    wanted = None
    if args.accessions:
        with open(args.accessions) as fh:
            wanted = set(ACCESSION.findall(fh.read()))

    rows, seen = [], set()
    for path in args.summaries:
        for r in summary_rows(path):
            accession = r.get("assembly_accession", "")
            if not ACCESSION.fullmatch(accession):
                continue
            strain = clean(r.get("infraspecific_name", "")).removeprefix("strain=")
            row = {
                "organism": clean(r.get("organism_name")),
                "strain": strain,
                "taxid": clean(r.get("taxid")),
                "species_taxid": clean(r.get("species_taxid")),
            }
            paired = clean(r.get("gbrs_paired_asm"))
            for acc in [accession] + ([paired] if ACCESSION.fullmatch(paired) else []):
                if acc in seen or (wanted is not None and acc not in wanted):
                    continue
                seen.add(acc)
                rows.append(dict(row, accession=acc))

    merged = load_merged(args.taxdump)
    taxids = {merged.get(t, t) for r in rows for t in (r["taxid"], r["species_taxid"]) if t != NA}
    names = load_scientific_names(args.taxdump, taxids)
    for r in rows:
        species = merged.get(r["species_taxid"], r["species_taxid"])
        taxon = merged.get(r["taxid"], r["taxid"])
        r["species_name"] = names.get(species) or names.get(taxon) or NA
    resolved = add_lineages(rows, args.taxdump)

    out = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.DictWriter(out, fieldnames=OUTPUT_FIELDS)
    writer.writeheader()
    writer.writerows(rows)
    if out is not sys.stdout:
        out.close()
    print(f"wrote {len(rows)} accessions ({resolved} with lineage)", file=sys.stderr)
    if wanted is not None:
        missing = wanted - seen
        if missing:
            print(
                f"{len(missing)} of {len(wanted)} requested accessions not found in the assembly summaries "
                f"(e.g. {', '.join(sorted(missing)[:5])}) - hits to these will come back 'unresolved'",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
