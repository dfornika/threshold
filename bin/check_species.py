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
bacterial and viral) are profiled together. With sylph's --estimate-unknown
(on in this pipeline) Sequence_abundance is a share of ALL reads, so the hits
can sum to less than 100%; `sylph_classified_pct` is that sum.

Optionally the sample's kraken2 reports (one per kraken2 database, from
--kraken2-report) are checked against the same expected taxa. A kraken2 report
lists every taxon's NCBI taxid with the reads in its whole branch ("clade"), so
an expected taxid at any rank is a direct lookup - no manifest needed. Per
report, with E = clade reads of the expected taxa (nested ones counted once):
  not_checked    - no expected taxa
  no_hit         - no reads classified
  low_classified - fewer than --kraken2-min-classified-pct of all reads were
                   classified, so a match/mismatch call isn't made (not applied
                   to `metagenomic` samples, where much is expected to be unknown)
  match          - E is at least --kraken2-min-expected-pct of the CLASSIFIED
                   reads (`metagenomic`: --kraken2-min-metagenomic-pct, and > 0)
  mismatch       - otherwise
With several databases the best verdict wins (match > mismatch > low_classified
> no_hit > not_checked): a viral sample is expected to be unclassified in a
bacterial database. The kraken2 values reported come from the database that
decided it. Expected taxids must exist in the database's taxonomy (its build
date): a taxid NCBI introduced later - or a species since renamed - isn't there.

Prints one tab-separated line:
  sample, platform, verdict, expected_taxid (;-separated), accession,
  species_taxid, species_name, adjusted_ani, taxonomic_abundance, n_hits,
  expected_source (sample/project/NA), matched_taxid, sequence_abundance,
  sylph_dbs (;-separated database file names, or NA), sylph_classified_pct,
  kraken2_verdict, kraken2_matched_taxid, kraken2_expected_pct,
  kraken2_classified_pct, kraken2_top_taxon, kraken2_top_pct, kraken2_dbs
  (;-separated), kraken2_best_db  (all kraken2_* are NA without kraken2 reports)
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


KRAKEN2_REPORT_SUFFIX = ".kraken2.report.txt"
# best first, for choosing among several databases' verdicts
KRAKEN2_VERDICT_ORDER = ["match", "mismatch", "low_classified", "no_hit", "not_checked"]


def parse_kraken2_report(path):
    """A kraken2 report -> {total, classified, entries}. Entries are in report
    order: taxid, rank, name, clade (reads in the taxon's whole branch) and
    parent (index of the enclosing taxon, from the name indentation).
    Columns, from the right: rank code, taxid, indented name."""
    entries, stack, unclassified = [], [], 0
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 6:
                continue
            clade, rank, taxid, raw = int(parts[1]), parts[-3], parts[-2], parts[-1]
            if taxid == "0":
                unclassified = clade
                continue
            depth = (len(raw) - len(raw.lstrip(" "))) // 2
            while stack and stack[-1][0] >= depth:
                stack.pop()
            entries.append({"taxid": taxid, "rank": rank, "name": raw.strip(), "clade": clade, "parent": stack[-1][1] if stack else None})
            stack.append((depth, len(entries) - 1))
    root = next((e for e in entries if e["taxid"] == "1"), None)
    classified = root["clade"] if root else 0
    return {"total": classified + unclassified, "classified": classified, "entries": entries}


def expected_clade_reads(report, expected):
    """(reads in the expected taxa's branches, expected taxid with the most
    reads). Where one expected taxid is inside another's branch it's counted once."""
    entries = report["entries"]
    present = {e["taxid"]: i for i, e in enumerate(entries) if e["taxid"] in expected}
    reads, best = 0, None
    for taxid, i in present.items():
        parent, nested = entries[i]["parent"], False
        while parent is not None:
            if entries[parent]["taxid"] in present:
                nested = True
                break
            parent = entries[parent]["parent"]
        if not nested:
            reads += entries[i]["clade"]
        if best is None or entries[i]["clade"] > entries[present[best]]["clade"]:
            best = taxid
    return reads, best


def evaluate_kraken2(report, expected, sample_type, min_expected, min_classified, min_metagenomic):
    total, classified = report["total"], report["classified"]
    classified_pct = 100.0 * classified / total if total else 0.0
    species = [e for e in report["entries"] if e["rank"] == "S"]
    top = max(species, key=lambda e: e["clade"]) if species else None
    result = {
        "classified_pct": classified_pct,
        "expected_pct": None,
        "matched": None,
        "top_taxon": top["name"] if top else NA,
        "top_pct": 100.0 * top["clade"] / classified if top and classified else None,
    }
    if not expected:
        result["verdict"] = "not_checked"
        return result
    if not classified:
        result["verdict"] = "no_hit"
        return result
    reads, best = expected_clade_reads(report, expected)
    expected_pct = 100.0 * reads / classified
    result["expected_pct"] = expected_pct
    result["matched"] = best if reads else None
    if sample_type == "metagenomic":
        result["verdict"] = "match" if reads and expected_pct >= min_metagenomic else "mismatch"
    elif classified_pct < min_classified:
        result["verdict"] = "low_classified"
    else:
        result["verdict"] = "match" if reads and expected_pct >= min_expected else "mismatch"
    return result


def kraken2_db_name(path, sample):
    """Database name from <sample>.<database>.kraken2.report.txt."""
    name = os.path.basename(path).removesuffix(KRAKEN2_REPORT_SUFFIX)
    return name.removeprefix(sample + ".")


def check_kraken2(paths, sample, expected, sample_type, min_expected, min_classified, min_metagenomic):
    """Evaluate each database's report; the best verdict decides the values reported.
    Returns the kraken2_* output fields (NA when there are no reports)."""
    if not paths:
        return [NA] * 8
    results = []
    for path in paths:
        r = evaluate_kraken2(parse_kraken2_report(path), expected, sample_type, min_expected, min_classified, min_metagenomic)
        r["db"] = kraken2_db_name(path, sample)
        results.append(r)
    best = min(results, key=lambda r: (KRAKEN2_VERDICT_ORDER.index(r["verdict"]), -(r["expected_pct"] or 0), -r["classified_pct"]))

    def fmt(value):
        return NA if value is None else f"{value:.4g}"

    return [
        best["verdict"],
        best["matched"] or NA,
        fmt(best["expected_pct"]),
        fmt(best["classified_pct"]),
        best["top_taxon"],
        fmt(best["top_pct"]),
        ";".join(r["db"] for r in results),
        best["db"],
    ]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--platform", required=True)
    ap.add_argument("--sample-type", required=True)
    ap.add_argument("--expected-taxid", default="", help="the sample's own expected taxid (samplesheet); takes precedence over the project's")
    ap.add_argument("--project-id", default="", help="the sample's project_id")
    ap.add_argument("--sylph-dbs", default="", help="names of the sylph databases the sample was profiled against (recorded in the output)")
    ap.add_argument("--project-expected-taxids", default=None, help="CSV of project_id,expected_taxid (one-to-many)")
    ap.add_argument("--kraken2-report", action="append", default=[], help="a kraken2 report for this sample (repeat for several databases): <sample>.<database>.kraken2.report.txt")
    ap.add_argument("--kraken2-min-expected-pct", type=float, default=70.0, help="match needs at least this %% of the classified reads in the expected taxa")
    ap.add_argument("--kraken2-min-classified-pct", type=float, default=50.0, help="below this %% of all reads classified, no match/mismatch call is made (low_classified)")
    ap.add_argument("--kraken2-min-metagenomic-pct", type=float, default=1.0, help="for metagenomic samples: min %% of the classified reads in the expected taxa")
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
        f"{sum(h['sequence_abundance'] for h in hits):.4g}",
    ] + check_kraken2(
        args.kraken2_report, args.sample, expected, args.sample_type,
        args.kraken2_min_expected_pct, args.kraken2_min_classified_pct, args.kraken2_min_metagenomic_pct,
    )
    print("\t".join(fields))


if __name__ == "__main__":
    sys.exit(main())
