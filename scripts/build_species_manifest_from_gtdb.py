#!/usr/bin/env python3
"""
Build a --species_id_manifest CSV from GTDB release metadata, mapping each
genome's NCBI assembly accession to its NCBI taxonomy.

GTDB's per-release metadata files (bac120_metadata*.tsv.gz,
ar53_metadata*.tsv.gz - see https://data.gtdb.ecogenomic.org/releases/)
already record, for every genome, the NCBI taxid / species taxid / organism
name it's filed under. No separate GTDB <-> NCBI taxonomy map is needed: every
GTDB genome is an NCBI assembly, so its NCBI taxonomy is looked up directly.

The pipeline compares a sample's expected_taxid against the `taxid` or
`species_taxid` of the sylph top hit's accession. Notes:

  - The NCBI taxonomy is whatever NCBI filed each genome under. For uncultured
    / metagenome-assembled genomes that's often above species level (e.g. a
    family-level "... archaeon"); `species_name` is NA when NCBI has no
    species-level name.
  - GTDB species can span several NCBI species (e.g. E. coli and Shigella).
    The mapping here is per genome, so a hit reports the NCBI species of that
    particular genome.

GTDB accessions carry an RS_ (RefSeq) / GB_ (GenBank) prefix, which is
stripped. RefSeq genomes are also written under their paired GenBank (GCA_)
accession, since a sylph database built from GenBank downloads names the same
genome that way.

Usage:
  build_species_manifest_from_gtdb.py bac120_metadata.tsv.gz ar53_metadata.tsv.gz \\
      [--representatives-only] [--accessions genomes.txt] -o manifest.csv

--accessions takes any text file and keeps only the assembly accessions found
anywhere in it (e.g. `ls genomes_dir/ > genomes.txt`, or a list of the genome
files the sylph database was built from).
"""

import argparse
import csv
import gzip
import re
import sys

ACCESSION = re.compile(r"GC[AF]_\d+\.\d+")
NA = "NA"

OUTPUT_FIELDS = [
    "accession",
    "organism",
    "strain",
    "taxid",
    "species_taxid",
    "species_name",
    "gtdb_species",
    "gtdb_representative",
]

REQUIRED_COLUMNS = [
    "accession",
    "gtdb_representative",
    "gtdb_taxonomy",
    "ncbi_genbank_assembly_accession",
    "ncbi_organism_name",
    "ncbi_species_taxid",
    "ncbi_strain_identifiers",
    "ncbi_taxid",
    "ncbi_taxonomy",
]


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def species_from_lineage(lineage):
    """'d__Bacteria;...;s__Escherichia coli' -> 'Escherichia coli' (or NA)."""
    for rank in lineage.split(";"):
        rank = rank.strip()
        if rank.startswith("s__"):
            return rank[3:] or NA
    return NA


def clean(value):
    value = (value or "").strip()
    return value if value and value.lower() not in ("none", "na", "n/a") else NA


def read_wanted(path):
    with open(path) as fh:
        return set(ACCESSION.findall(fh.read()))


def manifest_rows(metadata_path, representatives_only):
    with open_text(metadata_path) as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        missing = [c for c in REQUIRED_COLUMNS if c not in (reader.fieldnames or [])]
        if missing:
            sys.exit(f"{metadata_path}: not a GTDB metadata file (missing columns: {', '.join(missing)})")
        for row in reader:
            is_rep = row["gtdb_representative"].strip().lower() in ("t", "true")
            if representatives_only and not is_rep:
                continue
            accession = ACCESSION.search(row["accession"])
            if not accession:
                continue
            accession = accession.group(0)
            out = {
                "organism": clean(row["ncbi_organism_name"]),
                "strain": clean(row["ncbi_strain_identifiers"]),
                "taxid": clean(row["ncbi_taxid"]),
                "species_taxid": clean(row["ncbi_species_taxid"]),
                "species_name": species_from_lineage(row["ncbi_taxonomy"]),
                "gtdb_species": species_from_lineage(row["gtdb_taxonomy"]),
                "gtdb_representative": "t" if is_rep else "f",
            }
            yield dict(out, accession=accession)
            paired = ACCESSION.search(row["ncbi_genbank_assembly_accession"] or "")
            if paired and paired.group(0) != accession:
                yield dict(out, accession=paired.group(0))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("metadata", nargs="+", help="GTDB metadata TSV(s), optionally gzipped (bac120_metadata*, ar53_metadata*)")
    ap.add_argument("--representatives-only", action="store_true", help="keep only GTDB species representative genomes")
    ap.add_argument("--accessions", help="keep only assembly accessions found anywhere in this text file")
    ap.add_argument("-o", "--output", help="output CSV (default: stdout)")
    args = ap.parse_args()

    csv.field_size_limit(sys.maxsize)
    wanted = read_wanted(args.accessions) if args.accessions else None

    out = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.DictWriter(out, fieldnames=OUTPUT_FIELDS)
    writer.writeheader()

    written, seen = 0, set()
    for path in args.metadata:
        for row in manifest_rows(path, args.representatives_only):
            if row["accession"] in seen:
                continue
            if wanted is not None and row["accession"] not in wanted:
                continue
            seen.add(row["accession"])
            writer.writerow(row)
            written += 1

    if out is not sys.stdout:
        out.close()
    print(f"wrote {written} accessions", file=sys.stderr)
    if wanted is not None:
        missing = wanted - seen
        if missing:
            print(
                f"{len(missing)} of {len(wanted)} requested accessions not found in the GTDB metadata "
                f"(e.g. {', '.join(sorted(missing)[:5])}) - hits to these will come back 'unresolved'",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
