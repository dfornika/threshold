#!/usr/bin/env python3
"""
Check one sample's species-ID result (sylph profile TSV) against the species the
samplesheet says it should be, and report the observed top hit.

The samplesheet's `expected_taxid` is the source of truth for what a sample
*should* be; this check exists to catch sample swaps, contamination and
mislabelled samples - not to decide what the sample is.

`expected_taxid` is an NCBI taxid. It's matched against the manifest's
`species_taxid` or `taxid` for the hit's assembly accession, so a strain- or
virus-level taxid (e.g. 511145, E. coli K-12) matches as well as a species
one. sylph's output carries no taxonomy, so the manifest (accession ->
taxid/species_taxid) is required whenever an expected taxid is given.

Verdicts:
  match        - the top hit is the expected taxon (for `metagenomic`
                 samples: the expected taxon is among any of the hits)
  mismatch     - the top hit (for `metagenomic`: every hit) is a different
                 taxon
  unresolved   - the top hit's accession (for `metagenomic`: no matching hit,
                 and at least one hit's accession) isn't in the manifest, so
                 there's no taxid to compare against
  no_hit       - sylph reported nothing above its own thresholds
  not_checked  - no expected_taxid was given; the top hit is still reported

Prints one tab-separated line:
  sample, platform, verdict, expected_taxid, accession, species_taxid,
  species_name, adjusted_ani, taxonomic_abundance, n_hits
"""

import argparse
import csv
import os
import re
import sys

NA = "NA"


def load_manifest(path):
    if not path:
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
                "adjusted_ani": row["Adjusted_ANI"],
                "taxonomic_abundance": float(row["Taxonomic_abundance"]),
            }
        )
    hits.sort(key=lambda h: h["taxonomic_abundance"], reverse=True)
    return hits


def is_resolved(hit):
    return hit["species_taxid"] != NA or hit["taxid"] != NA


def is_expected(hit, expected):
    return expected in (hit["species_taxid"], hit["taxid"])


def verdict_for(hits, expected, sample_type):
    if not hits:
        return "no_hit"
    if not expected:
        return "not_checked"
    if sample_type == "metagenomic":
        if any(is_expected(h, expected) for h in hits):
            return "match"
        return "unresolved" if any(not is_resolved(h) for h in hits) else "mismatch"
    top = hits[0]
    if not is_resolved(top):
        return "unresolved"
    return "match" if is_expected(top, expected) else "mismatch"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--platform", required=True)
    ap.add_argument("--sample-type", required=True)
    ap.add_argument("--expected-taxid", default="")
    ap.add_argument("--manifest", default=None, help="species_db manifest.csv (accession -> taxid/species_taxid/species_name); required with --expected-taxid")
    ap.add_argument("profile", help="sylph profile TSV for this sample")
    args = ap.parse_args()

    expected = args.expected_taxid.strip()
    if expected and not expected.isdigit():
        ap.error(f"--expected-taxid must be an NCBI taxid (digits only), got {expected!r}")
    if expected and not args.manifest:
        ap.error("--manifest is required with --expected-taxid: sylph's output has no taxonomy to compare against")

    hits = load_hits(args.profile, load_manifest(args.manifest))
    verdict = verdict_for(hits, expected, args.sample_type)

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
