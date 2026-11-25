#!/usr/bin/env python3
"""Generate assets/busco_lineages.tsv: genus -> most specific BUSCO lineage.

BUSCO ships one lineage dataset per clade (phylum, class, order, family, genus,
...). A more specific lineage gives a more sensitive completeness estimate. For
every bacterial / archaeal genus in the NCBI taxonomy this walks up the
taxonomy from the genus and takes the first clade that has a BUSCO lineage.
Genera with no lineage of their own are left out - the pipeline falls back to
the universal lineage (--busco_default_lineage) for those.

Inputs (all downloadable, nothing is bundled):
  --file-versions  https://busco-data.ezlab.org/v5/data/file_versions.tsv
  --taxdump        directory holding names.dmp and nodes.dmp from
                   https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz

Regenerate when BUSCO ships a new dataset version or NCBI renames clades:
  make_busco_lineage_table.py --file-versions file_versions.tsv \\
      --taxdump taxdump/ --suffix odb12 > assets/busco_lineages.tsv
"""

import argparse
import re
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

BACTERIA, ARCHAEA = 2, 2157

# BUSCO lineages that do not match a single NCBI scientific name: informal
# groups, names that are only synonyms in NCBI, and homonyms.
MANUAL_TAXIDS = {
    "aquificae": 200783,                       # phylum Aquificota (name is a synonym)
    "bosea": 85413,                            # bacterial genus, NCBI now calls it Allobosea
    "bacteroidota-chlorobiota_group": 68336,   # Bacteroidetes/Chlorobi group
    "delta-epsilon_subdivisions": 68525,       # delta/epsilon subdivisions
    "rhizobium-agrobacterium_group": 227290,   # Rhizobium/Agrobacterium group
}

# Universal lineages, used as the pipeline default rather than listed here.
ROOTS = {"bacteria", "archaea"}

# Keys must be plain names: NCBI also holds names like "Aalborgiella (SeqCode)"
# and quoted or Candidatus names that a species-check name never matches.
GENUS_RE = re.compile(r"^[A-Z][A-Za-z-]*$")
SPECIES_RE = re.compile(r"^[A-Z][a-z]+ [a-z-]+$")


def read_nodes(path):
    parent, rank = {}, {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.split("\t|\t")
            taxid = int(fields[0])
            parent[taxid] = int(fields[1])
            rank[taxid] = fields[2]
    return parent, rank


def read_names(path):
    """Return (scientific name by taxid, taxids by lower-cased any-class name)."""
    scientific, by_name = {}, defaultdict(set)
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t|\t")
            taxid, name = int(fields[0]), fields[1]
            name_class = fields[3].rstrip("\t|")
            by_name[name.lower()].add(taxid)
            if name_class == "scientific name":
                scientific[taxid] = name
    return scientific, by_name


def prokaryote_taxids(parent):
    children = defaultdict(list)
    for taxid, par in parent.items():
        if taxid != par:
            children[par].append(taxid)
    found, stack = set(), [BACTERIA, ARCHAEA]
    while stack:
        taxid = stack.pop()
        if taxid in found:
            continue
        found.add(taxid)
        stack.extend(children[taxid])
    return found


def busco_lineages(path, suffix):
    """Prokaryote lineage dataset names with the given version suffix."""
    names = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 5 or fields[3] != "Prokaryota" or fields[4] != "lineages":
                continue
            if fields[0].endswith("_" + suffix):
                names.append(fields[0][: -len(suffix) - 1])
    return sorted(names)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file-versions", required=True)
    ap.add_argument("--taxdump", required=True)
    ap.add_argument("--suffix", default="odb12", help="BUSCO dataset version, e.g. odb12")
    args = ap.parse_args()

    taxdump = Path(args.taxdump)
    parent, rank = read_nodes(taxdump / "nodes.dmp")
    scientific, by_name = read_names(taxdump / "names.dmp")
    prok = prokaryote_taxids(parent)

    # Resolve each BUSCO lineage name to a prokaryote taxid.
    lineage_taxid, unresolved = {}, []
    for name in busco_lineages(args.file_versions, args.suffix):
        if name in ROOTS:
            continue
        if name in MANUAL_TAXIDS:
            lineage_taxid[MANUAL_TAXIDS[name]] = name
            continue
        hits = [t for t in by_name.get(name.replace("_", " "), ()) if t in prok]
        if len(hits) > 1:   # a homonym or synonym elsewhere: keep the scientific name
            hits = [t for t in hits if scientific.get(t, "").lower() == name.replace("_", " ")]
        if len(hits) == 1:
            lineage_taxid[hits[0]] = name
        else:
            unresolved.append((name, len(hits)))
    for name, n_hits in unresolved:
        print(f"warning: no unique taxid for lineage {name} ({n_hits} hits), skipped", file=sys.stderr)

    rows = {}
    for taxid in prok:
        if rank[taxid] not in ("genus", "species"):
            continue
        node = taxid
        while True:
            if node in lineage_taxid:
                break
            if parent[node] == node:
                node = None
                break
            node = parent[node]
        if node is None or taxid not in scientific:
            continue
        key_re = GENUS_RE if rank[taxid] == "genus" else SPECIES_RE
        if not key_re.match(scientific[taxid]):
            continue
        if rank[taxid] == "species" and node != taxid:
            continue   # species rows only where a species has a lineage of its own
        rows[scientific[taxid]] = f"{lineage_taxid[node]}_{args.suffix}"

    print("# Genus -> most specific BUSCO lineage, generated by bin/make_busco_lineage_table.py")
    print(f"# from BUSCO {args.suffix} lineages and the NCBI taxonomy ({date.today().isoformat()}).")
    print("# A species-level row (two words) takes precedence over its genus.")
    print("# Taxa not listed use --busco_default_lineage. Do not edit by hand; regenerate.")
    print("taxon\tbusco_lineage")
    for taxon in sorted(rows):
        print(f"{taxon}\t{rows[taxon]}")


if __name__ == "__main__":
    main()
