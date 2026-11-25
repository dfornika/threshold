#!/usr/bin/env python3
"""
Normalise the assembly-QC outputs for one sample into a single summary row, so
QUAST (contiguity) and CheckM2 (completeness/contamination) can be read side by
side per sample - the same one-row-per-sample-per-stage convention every other
stage in this pipeline uses (cf. bin/parse_species_id.py).

QUAST's `report.tsv` has one metric per row (metric name in column 1, value in
column 2). CheckM2's `quality_report.tsv` is a normal header + one data row per
input genome (we give it exactly one assembly, so one row). CheckM2 is
optional - it only runs when a --checkm2_db was provided - so its columns come
back as NA when absent. BUSCO (a short_summary.*.txt) is optional in the same
way - it only runs with --busco_db.
"""

import argparse
import csv
import re
import sys

NA = "NA"

# The one-line BUSCO result, e.g. C:98.7%[S:98.0%,D:0.7%],F:0.4%,M:0.9%,n:124
BUSCO_RE = re.compile(r"C:(?P<complete>[0-9.]+)%\[S:[0-9.]+%,D:(?P<duplicated>[0-9.]+)%\],F:[0-9.]+%,M:(?P<missing>[0-9.]+)%")
BUSCO_LINEAGE_RE = re.compile(r"(?:lineage_dataset|The lineage dataset is):?\s*([^\s#]+)")
BUSCO_NA = {"busco_complete": NA, "busco_duplicated": NA, "busco_missing": NA, "busco_lineage": NA}


def parse_quast(path):
    """QUAST report.tsv -> {metric: value}. Exact-key lookups below pick the
    plain '# contigs'/'Total length' rows, not the '(>= N bp)' threshold variants."""
    metrics = {}
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                metrics[parts[0]] = parts[1]
    return {
        "n_contigs": metrics.get("# contigs", NA),
        "total_length": metrics.get("Total length", NA),
        "largest_contig": metrics.get("Largest contig", NA),
        "n50": metrics.get("N50", NA),
        # Only present when QUAST ran reference-based; NA otherwise. Robust to
        # strain divergence (unlike the misassembly/mismatch counts, which stay
        # in the full QUAST report rather than this summary).
        "genome_fraction": metrics.get("Genome fraction (%)", NA),
        # Only present when QUAST ran with --features (the reference's GFF3);
        # reported as e.g. "510 + 2 part" - complete + partially recovered.
        **parse_features(metrics.get("# genomic features")),
    }


def parse_features(value):
    if not value:
        return {"features_complete": NA, "features_partial": NA}
    match = re.match(r"\s*(\d+)\s*(?:\+\s*(\d+)\s*part)?", value)
    if not match:
        return {"features_complete": NA, "features_partial": NA}
    return {"features_complete": match.group(1), "features_partial": match.group(2) or "0"}


def parse_checkm2(path):
    with open(path) as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    if not rows:
        return {"completeness": NA, "contamination": NA}
    row = rows[0]
    return {
        "completeness": row.get("Completeness", NA),
        "contamination": row.get("Contamination", NA),
    }


def parse_busco(path):
    with open(path) as fh:
        text = fh.read()
    match = BUSCO_RE.search(text)
    if not match:
        return dict(BUSCO_NA)
    lineage = BUSCO_LINEAGE_RE.search(text)
    return {
        "busco_complete": match.group("complete"),
        "busco_duplicated": match.group("duplicated"),
        "busco_missing": match.group("missing"),
        "busco_lineage": lineage.group(1) if lineage else NA,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--platform", required=True)
    ap.add_argument("--assembler", required=True, help="shovill (Illumina) or dragonflye (Nanopore)")
    ap.add_argument("--quast", required=True, help="QUAST report.tsv for this sample")
    ap.add_argument("--checkm2", default=None, help="CheckM2 quality_report.tsv (omit if CheckM2 did not run)")
    ap.add_argument("--busco", default=None, help="BUSCO short_summary.*.txt (omit if BUSCO did not run)")
    args = ap.parse_args()

    q = parse_quast(args.quast)
    c = parse_checkm2(args.checkm2) if args.checkm2 else {"completeness": NA, "contamination": NA}

    b = parse_busco(args.busco) if args.busco else BUSCO_NA

    print(
        f"{args.sample}\t{args.platform}\t{args.assembler}\t"
        f"{q['n_contigs']}\t{q['total_length']}\t{q['largest_contig']}\t{q['n50']}\t"
        f"{q['genome_fraction']}\t{c['completeness']}\t{c['contamination']}\t"
        f"{q['features_complete']}\t{q['features_partial']}\t"
        f"{b['busco_complete']}\t{b['busco_duplicated']}\t{b['busco_missing']}\t{b['busco_lineage']}"
    )


if __name__ == "__main__":
    sys.exit(main())
