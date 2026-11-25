#!/usr/bin/env python3
"""
Build a tiny sylph reference database from a small panel of real reference
genomes, for checking species ID against the known-species
samples in tests/data/real/ (KPNEUMONIAE_WGS, ECOLI_WGS, SARS2_AMPLICON_*).

Panel: manifest.csv - 3 "known" genomes matching those samples' true species,
plus ~7 "decoy" genomes (a mix of easy/distant-genus and hard/same-genus cases)
so a correct call is a real discrimination test, not a trivial one-entry lookup.

Identifiers are NCBI *assembly* accessions (GCF_.../GCA_...), matching what the
official sylph GTDB databases use - not plain nucleotide accessions (which is what this script
used before; see git history). `manifest.csv`'s `source_nucleotide_accession`
column records the single representative record originally used to pick each
organism, resolved to its assembly via `elink` (nuccore -> assembly).

Requires (not installed by this script):
  - ncbi-client (https://github.com/dfornika/ncbi-client-py) for genome download
  - sylph CLI on PATH (see the `species-db` conda env)

Downloads each assembly's whole-genome FASTA (all contigs/plasmids in one file)
into a gitignored genomes_src/ scratch dir (not committed - see README.md to
regenerate), then builds the committed DB artifacts: sylph/species_mini.syldb
(all genomes) and sylph/viral_mini.syldb (the two viruses only).
sylph sketches a whole file as one entry by default, so the sketch-building
function below is accession-format-agnostic.

(mash and sourmash databases used to be built here too, while those tools were
being compared - see git history.)

Regenerate with: python3 tests/data/species_db/build_dbs.py
"""

import csv
import subprocess
import zipfile
from pathlib import Path

from ncbi_client import NCBIClient

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "manifest.csv"
GENOMES_SRC = HERE / "genomes_src"
SYLPH_DIR = HERE / "sylph"


MANIFEST_FIELDS = [
    "accession", "organism", "strain", "category", "source_nucleotide_accession",
    "taxid", "species_taxid", "species_name", "lineage_taxids",
]


def read_manifest():
    with MANIFEST.open() as fh:
        return list(csv.DictReader(fh))


def write_manifest(rows):
    with MANIFEST.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=MANIFEST_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def resolve_taxonomy(client, rows):
    """Fill in taxid/species_taxid/species_name for any row missing them, via the
    assembly accession - NCBI's assembly esummary already resolves a (possibly
    strain-level) taxid to its species-level parent for us (`speciestaxid`/
    `speciesname`), so no manual taxonomy-tree walking is needed. More robust
    than looking up a taxid from the organism name string: current ICTV virus
    species names (e.g. "Betacoronavirus pandemicum" for SARS-CoV-2) don't match
    the informal names historically used in sequence records."""
    for row in rows:
        if row.get("taxid"):
            continue
        acc = row["accession"]
        print(f"  resolving taxonomy for {acc} ({row['organism']})")
        res = client.esearch("assembly", f"{acc}[Assembly Accession]", retmax=1)
        summ = client.esummary("assembly", res["ids"])[0]
        row["taxid"] = summ["taxid"]
        row["species_taxid"] = summ["speciestaxid"]
        row["species_name"] = summ["speciesname"]


def download_genomes(client, rows):
    GENOMES_SRC.mkdir(exist_ok=True)
    paths = []
    for row in rows:
        acc = row["accession"]
        dest = GENOMES_SRC / f"{acc}.fasta"
        if dest.exists():
            print(f"  {acc}: already downloaded, skipping")
            paths.append(dest)
            continue
        print(f"  downloading {acc} ({row['organism']})")
        zip_path = GENOMES_SRC / f"{acc}.zip"
        client.download_genome(acc, zip_path)
        with zipfile.ZipFile(zip_path) as zf:
            fna_name = next(n for n in zf.namelist() if n.endswith("_genomic.fna"))
            with zf.open(fna_name) as src, dest.open("wb") as out:
                out.write(src.read())
        zip_path.unlink()
        paths.append(dest)
    return paths


# The two viruses in the panel also go into their own database, so tests can
# screen a project against a database of its own (see --project_sylph_dbs).
VIRAL_ACCESSIONS = {"GCF_009858895.2", "GCF_000858645.1"}


def build_sylph(genome_paths):
    SYLPH_DIR.mkdir(exist_ok=True)
    for name, paths in (
        ("species_mini", genome_paths),
        ("viral_mini", [p for p in genome_paths if p.name.split(".fasta")[0] in VIRAL_ACCESSIONS]),
    ):
        subprocess.run(
            ["sylph", "sketch", "-g", *[str(p) for p in paths], "-o", name],
            check=True,
            cwd=SYLPH_DIR,
        )
        print(f"  wrote {SYLPH_DIR}/{name}.syldb")


def main():
    rows = read_manifest()
    client = NCBIClient()

    print("Resolving taxonomy:")
    resolve_taxonomy(client, rows)
    write_manifest(rows)

    print(f"\nDownloading {len(rows)} reference genomes:")
    genome_paths = download_genomes(client, rows)

    print("\nBuilding sylph database:")
    build_sylph(genome_paths)


if __name__ == "__main__":
    main()
