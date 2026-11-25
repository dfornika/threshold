#!/usr/bin/env python3
"""
Build one CSV with one row per sample, pulling the main verdict/metric from
each per-stage summary TSV this pipeline already produces. Not a replacement
for those TSVs (which keep every field for each stage) - this is a single
at-a-glance table across stages.

Every stage input is optional: if a stage was skipped (or never reached a
given sample, e.g. assembly only runs for isolates), its columns are "NA" for
that row rather than the row being dropped - `--samples` (the samplesheet's
sample, platform, sample_type, expected_taxid) always determines which rows
exist.
"""

import argparse
import csv
import sys

NA = "NA"

HEADER = [
    "sample",
    "platform",
    "sample_type",
    "expected_taxid",
    "project_id",
    "tags",
    "dehost_percent_host",
    "species_check",
    "species_check_expected_taxids",
    "species_check_expected_source",
    "species_check_matched_taxid",
    "observed_species_name",
    "observed_species_taxid",
    "observed_accession",
    "observed_adjusted_ani",
    "observed_taxonomic_abundance",
    "observed_sequence_abundance",
    "species_check_sylph_dbs",
    "species_check_sylph_classified_pct",
    "species_check_kraken2_verdict",
    "species_check_kraken2_expected_pct",
    "species_check_kraken2_classified_pct",
    "species_check_kraken2_top_taxon",
    "species_check_kraken2_dbs",
    "species_id_n_hits",
    "assembler",
    "assembly_n_contigs",
    "assembly_total_length",
    "assembly_n50",
    "assembly_genome_fraction",
    "assembly_completeness",
    "assembly_contamination",
    "assembly_features_complete",
    "assembly_features_partial",
    "speccheck_overall_qc",
    "speccheck_qualibact_qc",
    "speccheck_reasons",
]


def load_rows(path):
    if not path:
        return []
    with open(path) as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def index_by_sample(rows):
    return {row["sample"]: row for row in rows}


def load_speccheck(path):
    """speccheck's summary report.csv - comma-separated, keyed by sample_id."""
    if not path:
        return {}
    with open(path) as fh:
        return {row["sample_id"]: row for row in csv.DictReader(fh)}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--samples", required=True, help="sample, platform, sample_type, expected_taxid - the anchor row list")
    ap.add_argument("--dehost")
    ap.add_argument("--species-check")
    ap.add_argument("--assembly")
    ap.add_argument("--speccheck", help="speccheck report.csv (comma-separated, keyed by sample_id)")
    args = ap.parse_args()

    samples = load_rows(args.samples)
    dehost = index_by_sample(load_rows(args.dehost))
    species_check = index_by_sample(load_rows(args.species_check))
    assembly = index_by_sample(load_rows(args.assembly))
    speccheck = load_speccheck(args.speccheck)

    writer = csv.DictWriter(sys.stdout, fieldnames=HEADER)
    writer.writeheader()

    for row in samples:
        sample = row["sample"]
        d = dehost.get(sample, {})
        sc = species_check.get(sample, {})
        asm = assembly.get(sample, {})
        sc_qc = speccheck.get(sample, {})

        writer.writerow(
            {
                "sample": sample,
                "platform": row["platform"],
                "sample_type": row["sample_type"],
                "expected_taxid": row["expected_taxid"],
                "project_id": row.get("project_id", NA),
                "tags": row.get("tags", NA),
                "dehost_percent_host": d.get("percent_host", NA),
                "species_check": sc.get("verdict", NA),
                "species_check_expected_taxids": sc.get("expected_taxid", NA),
                "species_check_expected_source": sc.get("expected_source", NA),
                "species_check_matched_taxid": sc.get("matched_taxid", NA),
                "observed_species_name": sc.get("species_name", NA),
                "observed_species_taxid": sc.get("species_taxid", NA),
                "observed_accession": sc.get("accession", NA),
                "observed_adjusted_ani": sc.get("adjusted_ani", NA),
                "observed_taxonomic_abundance": sc.get("taxonomic_abundance", NA),
                "observed_sequence_abundance": sc.get("sequence_abundance", NA),
                "species_check_sylph_dbs": sc.get("sylph_dbs", NA),
                "species_check_sylph_classified_pct": sc.get("sylph_classified_pct", NA),
                "species_check_kraken2_verdict": sc.get("kraken2_verdict", NA),
                "species_check_kraken2_expected_pct": sc.get("kraken2_expected_pct", NA),
                "species_check_kraken2_classified_pct": sc.get("kraken2_classified_pct", NA),
                "species_check_kraken2_top_taxon": sc.get("kraken2_top_taxon", NA),
                "species_check_kraken2_dbs": sc.get("kraken2_dbs", NA),
                "species_id_n_hits": sc.get("n_hits", NA),
                "assembler": asm.get("assembler", NA),
                "assembly_n_contigs": asm.get("n_contigs", NA),
                "assembly_total_length": asm.get("total_length", NA),
                "assembly_n50": asm.get("n50", NA),
                "assembly_genome_fraction": asm.get("genome_fraction", NA),
                "assembly_completeness": asm.get("completeness", NA),
                "assembly_contamination": asm.get("contamination", NA),
                "assembly_features_complete": asm.get("features_complete", NA),
                "assembly_features_partial": asm.get("features_partial", NA),
                "speccheck_overall_qc": sc_qc.get("overall_qc") or NA,
                "speccheck_qualibact_qc": sc_qc.get("qualibact_qc") or NA,
                "speccheck_reasons": sc_qc.get("reason_summary") or NA,
            }
        )


if __name__ == "__main__":
    main()
