#!/usr/bin/env python3
"""Download BUSCO lineage datasets into a directory usable as --busco_db.

The full set of prokaryote lineages is large and a lab rarely needs it all, so
by default this fetches only the lineages that assets/busco_lineages.tsv maps
the genera in assets/busco_public_health_genera.txt to, plus the default
lineage (the pipeline falls back to it for anything else). Pass --all for every
prokaryote lineage, or --lineage NAME (repeatable) to add specific ones.

Each lineage is downloaded from the BUSCO data server, checked against the md5
in its file_versions.tsv, and unpacked to <out>/lineages/<name>/. Lineages that
are already present are skipped, so the script can be re-run to top up.

Standard library only. Examples:
  fetch_busco_lineages.py --out /data/busco_db --dry-run
  fetch_busco_lineages.py --out /data/busco_db
  fetch_busco_lineages.py --out /data/busco_db --lineage rhodococcus_odb12.2
"""

import argparse
import hashlib
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

BASE = "https://busco-data.ezlab.org/v5/data"
HERE = Path(__file__).resolve().parent.parent / "assets"


def read_versions(url):
    """name -> (date, md5) for prokaryote lineages."""
    versions = {}
    with urllib.request.urlopen(url, timeout=60) as resp:
        for line in resp.read().decode().splitlines():
            fields = line.split("\t")
            if len(fields) >= 5 and fields[3] == "Prokaryota" and fields[4] == "lineages":
                versions[fields[0]] = (fields[1], fields[2])
    return versions


def read_table(path):
    table = {}
    for line in Path(path).read_text().splitlines():
        if line and not line.startswith(("#", "taxon\t")):
            taxon, lineage = line.split("\t")[:2]
            table[taxon] = lineage
    return table


def read_genera(path):
    return [g.strip() for g in Path(path).read_text().splitlines() if g.strip() and not g.startswith("#")]


def download(name, date, md5, out_dir):
    url = f"{BASE}/lineages/{name}.{date}.tar.gz"
    with tempfile.TemporaryDirectory(dir=out_dir) as tmp:
        archive = Path(tmp) / "lineage.tar.gz"
        digest = hashlib.md5()
        with urllib.request.urlopen(url, timeout=120) as resp, open(archive, "wb") as fh:
            for chunk in iter(lambda: resp.read(1 << 20), b""):
                fh.write(chunk)
                digest.update(chunk)
        if digest.hexdigest() != md5:
            raise RuntimeError(f"{name}: md5 mismatch (got {digest.hexdigest()}, expected {md5})")
        with tarfile.open(archive) as tar:
            tar.extractall(out_dir / "lineages", filter="data")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="BUSCO database directory (lineages/ is created inside)")
    ap.add_argument("--genera", default=str(HERE / "busco_public_health_genera.txt"))
    ap.add_argument("--table", default=str(HERE / "busco_lineages.tsv"))
    ap.add_argument("--default-lineage", default="bacteria_odb12.2")
    ap.add_argument("--lineage", action="append", default=[], help="extra lineage to fetch (repeatable)")
    ap.add_argument("--all", action="store_true", help="fetch every prokaryote lineage for the default version")
    ap.add_argument("--file-versions", default=f"{BASE}/file_versions.tsv")
    ap.add_argument("--dry-run", action="store_true", help="list what would be downloaded, then stop")
    args = ap.parse_args()

    versions = read_versions(args.file_versions)
    suffix = args.default_lineage.split("_", 1)[1]
    if args.all:
        wanted = {n for n in versions if n.endswith("_" + suffix)}
    else:
        table = read_table(args.table)
        wanted = {args.default_lineage, *args.lineage}
        for genus in read_genera(args.genera):
            if genus in table:
                wanted.add(table[genus])
            else:
                print(f"notice: {genus} has no row in the lineage table, skipped", file=sys.stderr)

    unknown = sorted(n for n in wanted if n not in versions)
    if unknown:
        sys.exit(f"error: not BUSCO prokaryote lineages: {', '.join(unknown)}")

    out_dir = Path(args.out)
    have = {p.name for p in (out_dir / "lineages").glob("*") if p.is_dir()}
    todo = sorted(wanted - have)
    print(f"{len(wanted)} lineages wanted, {len(wanted & have)} already present, {len(todo)} to download")
    for name in todo:
        print(f"  {name}")
    if args.dry_run or not todo:
        return

    (out_dir / "lineages").mkdir(parents=True, exist_ok=True)
    for i, name in enumerate(todo, 1):
        print(f"[{i}/{len(todo)}] {name}", flush=True)
        date, md5 = versions[name]
        download(name, date, md5, out_dir)
    print(f"done: {out_dir}")


if __name__ == "__main__":
    main()
