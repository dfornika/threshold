#!/usr/bin/env python3
"""
Check one sample's species-ID result (sylph profile TSV) against the species the
samplesheet says it should be, and report the observed top hit.

The samplesheet's `expected_species` is the source of truth for what a sample
*should* be; this check exists to catch sample swaps, contamination and
mislabelled samples - not to decide what the sample is.

`expected_species` may be a species name (matched case-insensitively against
the manifest's species_name or organism, or - with no manifest - as a substring
of sylph's contig name) or an NCBI taxid (matched against the manifest's
species_taxid or taxid).

Verdicts:
  match        - the top hit is the expected species (for `metagenomic`
                 samples: the expected species is among any of the hits)
  mismatch     - there were hits, but not of the expected species
  no_hit       - sylph reported nothing above its own thresholds
  not_checked  - no expected_species was given; the top hit is still reported

Prints one tab-separated line:
  sample, platform, verdict, expected_species, accession, species_taxid,
  species_name, adjusted_ani, taxonomic_abundance, n_hits
"""

import argparse
import csv
import os
import re
import sys

NA = "NA"


def load_manifest(path):
    if not path or not os.path.isfile(path):
        return {}
    with open(path) as fh:
        return {row["accession"]: row for row in csv.DictReader(fh)}


ASSEMBLY_ACCESSION = re.compile(r"GC[AF]_\d+\.\d+")


def accession_from_path(path):
    """Genome file name -> NCBI assembly accession. Handles plain names
    (GCF_000005845.2.fasta) as well as NCBI/GTDB-style ones
    (GCF_011064845.1_genomic.fna.gz, GCF_000005845.2_ASM584v2_genomic.fna.gz).
    Falls back to the extension-stripped file name if there's no accession in it."""
    name = os.path.basename(path)
    match = ASSEMBLY_ACCESSION.search(name)
    if match:
        return match.group(0)
    for suffix in (".gz", ".fasta", ".fna", ".fa"):
        name = name.removesuffix(suffix)
    return name


def load_hits(path, manifest):
    with open(path) as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    hits = []
    for row in rows:
        accession = accession_from_path(row["Genome_file"])
        entry = manifest.get(accession, {})
        hits.append(
            {
                "accession": accession,
                "species_taxid": entry.get("species_taxid", NA),
                "taxid": entry.get("taxid", NA),
                "species_name": entry.get("species_name", NA),
                "organism": entry.get("organism", NA),
                "contig_name": row.get("Contig_name", ""),
                "adjusted_ani": row["Adjusted_ANI"],
                "taxonomic_abundance": float(row["Taxonomic_abundance"]),
            }
        )
    hits.sort(key=lambda h: h["taxonomic_abundance"], reverse=True)
    return hits


def is_expected(hit, expected):
    expected = expected.strip().lower()
    if expected.isdigit():
        return expected in (hit["species_taxid"], hit["taxid"])
    names = {hit["species_name"].lower(), hit["organism"].lower()} - {NA.lower()}
    if names:
        return expected in names
    return expected in hit["contig_name"].lower()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--platform", required=True)
    ap.add_argument("--sample-type", required=True)
    ap.add_argument("--expected-species", default="")
    ap.add_argument("--manifest", default=None, help="species_db manifest.csv (accession -> organism/taxonomy)")
    ap.add_argument("profile", help="sylph profile TSV for this sample")
    args = ap.parse_args()

    expected = args.expected_species.strip()
    hits = load_hits(args.profile, load_manifest(args.manifest))

    if not hits:
        verdict = "no_hit"
    elif not expected:
        verdict = "not_checked"
    elif args.sample_type == "metagenomic":
        verdict = "match" if any(is_expected(h, expected) for h in hits) else "mismatch"
    else:
        verdict = "match" if is_expected(hits[0], expected) else "mismatch"

    top = hits[0] if hits else None
    fields = [
        args.sample,
        args.platform,
        verdict,
        expected or NA,
        top["accession"] if top else NA,
        top["species_taxid"] if top else NA,
        top["species_name"] if top else NA,
        top["adjusted_ani"] if top else NA,
        f"{top['taxonomic_abundance']:.4g}" if top else NA,
        str(len(hits)),
    ]
    print("\t".join(fields))


if __name__ == "__main__":
    sys.exit(main())
