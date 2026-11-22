#!/usr/bin/env python3
"""
Check one sample's species-ID result (sylph profile TSV) against the taxa the
sample is expected to be, and report the observed top hit.

What a sample *should* be comes from the samplesheet; this check exists to
catch sample swaps, contamination and mislabelled samples - not to decide what
the sample is.

Expected taxa (NCBI taxids), in order of precedence:
  1. the sample's own `expected_taxid` (--expected-taxid), source `sample`;
  2. otherwise every taxid listed for the sample's `project_id` in the
     --project-expected-taxids CSV (project_id,expected_taxid; one-to-many),
     source `project`;
  3. otherwise none: `not_checked`.

A hit is "within" an expected taxid if that taxid is the hit's `taxid`, its
`species_taxid`, or any of its ancestors (the manifest's `lineage_taxids`,
`;`-separated). So a family-level taxid such as 543 (Enterobacteriaceae)
accepts E. coli and K. pneumoniae, and a strain-level one (511145, E. coli
K-12) still matches its own genome. Without a `lineage_taxids` column only
exact taxid/species_taxid matches are possible. sylph's output carries no
taxonomy, so the manifest is required whenever there are expected taxa.

Verdicts:
  match        - the top hit is within an expected taxid (for `metagenomic`
                 samples: any hit is)
  mismatch     - the top hit (for `metagenomic`: every hit) is outside all of
                 them
  unresolved   - the top hit's accession (for `metagenomic`: no matching hit,
                 and at least one hit's accession) isn't in the manifest, so
                 there's no taxonomy to compare against
  no_hit       - sylph reported nothing above its own thresholds
  not_checked  - no expected taxa; the top hit is still reported

Hits are ranked by sylph's Sequence_abundance (share of reads), which, unlike
Taxonomic_abundance, doesn't favour tiny genomes when several databases (e.g.
bacterial and viral) are profiled together.

Prints one tab-separated line:
  sample, platform, verdict, expected_taxid (;-separated), accession,
  species_taxid, species_name, adjusted_ani, taxonomic_abundance, n_hits,
  expected_source (sample/project/NA), matched_taxid, sequence_abundance,
  sylph_dbs (;-separated database file names, or NA)
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
                "lineage": {t for t in (entry.get("lineage_taxids") or "").split(";") if t},
                "adjusted_ani": row["Adjusted_ANI"],
                "taxonomic_abundance": float(row["Taxonomic_abundance"]),
                "sequence_abundance": float(row["Sequence_abundance"]),
            }
        )
    # Rank by sequence abundance (the share of reads), not taxonomic abundance
    # (genome copies, which weights by genome size): with viral and bacterial
    # databases together, a tiny viral genome with a few reads can out-rank a
    # bacterium holding most of the reads on taxonomic abundance.
    hits.sort(key=lambda h: (h["sequence_abundance"], h["taxonomic_abundance"]), reverse=True)
    return hits


def is_resolved(hit):
    return hit["species_taxid"] != NA or hit["taxid"] != NA


def hit_taxa(hit):
    """The hit's taxid, species taxid and every ancestor taxid."""
    return {t for t in (hit["taxid"], hit["species_taxid"]) if t != NA} | hit["lineage"]


def matched_taxid(hit, expected):
    """The first expected taxid the hit is within, or None."""
    taxa = hit_taxa(hit)
    return next((t for t in expected if t in taxa), None)


def verdict_for(hits, expected, sample_type):
    """(verdict, matched expected taxid or None)"""
    if not hits:
        return "no_hit", None
    if not expected:
        return "not_checked", None
    if sample_type == "metagenomic":
        for h in hits:
            m = matched_taxid(h, expected)
            if m:
                return "match", m
        return ("unresolved" if any(not is_resolved(h) for h in hits) else "mismatch"), None
    top = hits[0]
    if not is_resolved(top):
        return "unresolved", None
    m = matched_taxid(top, expected)
    return ("match", m) if m else ("mismatch", None)


def load_project_taxids(path, project_id):
    """Expected taxids listed for project_id (project_id,expected_taxid CSV)."""
    if not path or not project_id:
        return []
    taxids = []
    with open(path) as fh:
        for row in csv.DictReader(fh):
            if row.get("project_id", "").strip() == project_id:
                taxid = row.get("expected_taxid", "").strip()
                if taxid and taxid not in taxids:
                    taxids.append(taxid)
    return taxids


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--platform", required=True)
    ap.add_argument("--sample-type", required=True)
    ap.add_argument("--expected-taxid", default="", help="the sample's own expected taxid (samplesheet); takes precedence over the project's")
    ap.add_argument("--project-id", default="", help="the sample's project_id")
    ap.add_argument("--sylph-dbs", default="", help="names of the sylph databases the sample was profiled against (recorded in the output)")
    ap.add_argument("--project-expected-taxids", default=None, help="CSV of project_id,expected_taxid (one-to-many)")
    ap.add_argument("--manifest", default=None, help="species_db manifest.csv (accession -> taxid/species_taxid/species_name); required with --expected-taxid")
    ap.add_argument("profile", help="sylph profile TSV for this sample")
    args = ap.parse_args()

    sample_taxid = args.expected_taxid.strip()
    if sample_taxid:
        expected, source = [sample_taxid], "sample"
    else:
        expected = load_project_taxids(args.project_expected_taxids, args.project_id.strip())
        source = "project" if expected else NA
    bad = [t for t in expected if not t.isdigit()]
    if bad:
        ap.error(f"expected taxids must be NCBI taxids (digits only), got {bad!r}")
    if expected and not args.manifest:
        ap.error("--manifest is required when there are expected taxids: sylph's output has no taxonomy to compare against")

    hits = load_hits(args.profile, load_manifest(args.manifest))
    verdict, matched = verdict_for(hits, expected, args.sample_type)

    top = hits[0] if hits else None
    fields = [
        args.sample,
        args.platform,
        verdict,
        ";".join(expected) or NA,
        top["accession"] if top else NA,
        top["species_taxid"] if top else NA,
        top["species_name"] if top else NA,
        top["adjusted_ani"] if top else NA,
        f"{top['taxonomic_abundance']:.4g}" if top else NA,
        str(len(hits)),
        source,
        matched or NA,
        f"{top['sequence_abundance']:.4g}" if top else NA,
        args.sylph_dbs or NA,
    ]
    print("\t".join(fields))


if __name__ == "__main__":
    sys.exit(main())
