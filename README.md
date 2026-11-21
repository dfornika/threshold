<p align="center">
  <img src="https://raw.githubusercontent.com/dfornika/threshold/refs/heads/main/docs/images/threshold.png" width="300" alt="Accessibility Description" />
</p>

## Introduction

**threshold** is a QC and routine-analysis pipeline for microbial genomics,
intended as a standard "entrypoint" that runs on every sequenced library as it
arrives in a genomics analysis platform. It works on both **Illumina** and
**Oxford Nanopore** reads throughout, takes a simple samplesheet of FASTQ
files, and produces a per-sample summary of what each library is and what's in
it. Results from every stage are collated by [`MultiQC`](http://multiqc.info/)
and into a single `sample_summary.csv`.

The pipeline doesn't try to work out _what_ each library is from the reads:
the samplesheet says so (platform, sample type, expected species - see
[Usage](#usage)), and the pipeline routes each sample accordingly and checks
the reads against those claims. In deployment, the automation system that
launches the pipeline fills these in from the sequencing project's metadata.
See [`docs/testing.md`](docs/testing.md) for method rationale, validation
status and known caveats.

### Analyses

1. **Read QC & trimming** — [`FastQC`](https://www.bioinformatics.babraham.ac.uk/projects/fastqc/)
   plus [`fastp`](https://github.com/OpenGene/fastp) (Illumina) /
   [`fastplong`](https://github.com/OpenGene/fastp) (Nanopore), run on both the
   raw reads and again on the final trimmed/dehosted reads that flow downstream.
2. **Host read removal (dehosting)** — [`minimap2`](https://github.com/lh3/minimap2)
   against a host reference (`--dehost_reference`); toggle with `--skip_dehosting`.
3. **Species ID + check** — [`sylph`](https://github.com/bluenote-1577/sylph)
   against a reference-genome database (`--sylph_db`); the top hit is compared
   with the samplesheet's `expected_taxid` (an NCBI taxid, resolved via
   `--species_id_manifest`) and reported as `match` / `mismatch` /
   `unresolved` / `no_hit` / `not_checked`, to catch sample swaps, contamination
   and mislabelling. Skipped for `amplicon_16s` samples; toggle with
   `--skip_species_id`.
4. **Reference genome** — for isolates: the samplesheet's `reference` (a local
   FASTA, or an NCBI assembly accession fetched with the
   [NCBI Datasets CLI](https://www.ncbi.nlm.nih.gov/datasets/)), else the
   species-ID top hit when it agrees with `expected_taxid`. Fetched references
   include the GFF3 annotation (when NCBI has one) and NCBI's assembly and
   sequence reports, and are cached by accession across runs (`--reference_genome_cache_dir`); a
   fetch failure degrades gracefully. Toggle fetching with
   `--skip_reference_genome_fetch`.
5. **Draft genome assembly** — for `isolate` samples only, routed by platform:
   [`Shovill`](https://github.com/tseemann/shovill) (Illumina, paired-end) /
   [`Dragonflye`](https://github.com/rpetit3/dragonflye) (Nanopore). On by
   default; toggle with `--skip_assembly`.
6. **Assembly QC** — [`QUAST`](https://github.com/ablab/quast) for contiguity
   (reference-based metrics when the sample has a reference), plus
   [`CheckM2`](https://github.com/chklovski/CheckM2) for completeness /
   contamination when a `--checkm2_db` is provided.
7. **Provenance** — the pipeline's `nf-bccdc-provenance` plugin writes
   [BCCDC-PHL pipeline provenance](https://github.com/BCCDC-PHL/pipeline-provenance-schema)
   records to `provenance/`: one `<sample>_provenance.yml` per sample (inputs
   with `sha256`, each process with its tool versions, parameters and
   container, and outputs) plus `run_provenance.yml`. See
   [`plugins/nf-bccdc-provenance/README.md`](plugins/nf-bccdc-provenance/README.md).

Planned but not yet implemented: genome annotation (Bakta/Prokka) of the draft
assemblies, and hybrid (short + long) assembly (which needs an input model that
can pair an Illumina and a Nanopore library for the same isolate).

## Usage

First, prepare a samplesheet with your input data that looks as follows:

`samplesheet.csv`:

```csv
sample,fastq_1,fastq_2,platform,sample_type,expected_taxid,reference,genome_size
ISOLATE_1,ISO1_S1_L001_R1_001.fastq.gz,ISO1_S1_L001_R2_001.fastq.gz,illumina,isolate,562,,
ISOLATE_2,ISO2.fastq.gz,,nanopore,isolate,1280,GCF_002310435.1,
GUT_1,GUT1_R1.fastq.gz,GUT1_R2.fastq.gz,illumina,metagenomic,,,
```

Each row is one FASTQ file (single-end) or a pair of FASTQ files (paired-end).
`platform` (`illumina` / `nanopore`) and `sample_type` (`isolate` /
`metagenomic` / `amplicon_16s` / `amplicon_other`) are required; the rest are
optional. `expected_taxid` is an NCBI taxid (names aren't accepted); checking it
needs `--species_id_manifest`, which maps the sylph database's accessions to
NCBI taxids. See [`docs/usage.md`](docs/usage.md) for details.

Before the first run, install the pipeline's provenance plugin, which is built
from this repo (it isn't published yet). It needs a JDK (17+):

```bash
(cd plugins/nf-bccdc-provenance && ./gradlew install)
```

See [`plugins/nf-bccdc-provenance/README.md`](plugins/nf-bccdc-provenance/README.md).

Now, you can run the pipeline using:

```bash
nextflow run BCCDC-PHL/threshold \
   -profile <conda/docker/singularity/apptainer> \
   --input samplesheet.csv \
   --sylph_db <db.syldb> \
   --species_id_manifest <manifest.csv> \
   --dehost_reference <host.fasta> \
   --outdir <OUTDIR>
```

## Contributions and Support

If you would like to contribute to this pipeline, please see the [contributing guidelines](docs/CONTRIBUTING.md).

## Citations

<!-- TODO nf-core: Add citation for pipeline after first release. Uncomment lines below and update Zenodo doi and badge at the top of this file. -->
<!-- If you use BCCDC-PHL/threshold for your analysis, please cite it using the following doi: [10.5281/zenodo.XXXXXX](https://doi.org/10.5281/zenodo.XXXXXX) -->

<!-- TODO nf-core: Add bibliography of tools and data used in your pipeline -->

An extensive list of references for the tools used by the pipeline can be found in the [`CITATIONS.md`](CITATIONS.md) file.

This pipeline uses code and infrastructure developed and maintained by the [nf-core](https://nf-co.re) community, reused here under the [MIT license](https://github.com/nf-core/tools/blob/main/LICENSE).

> **The nf-core framework for community-curated bioinformatics pipelines.**
>
> Philip Ewels, Alexander Peltzer, Sven Fillinger, Harshil Patel, Johannes Alneberg, Andreas Wilm, Maxime Ulysse Garcia, Paolo Di Tommaso & Sven Nahnsen.
>
> _Nat Biotechnol._ 2020 Feb 13. doi: [10.1038/s41587-020-0439-x](https://dx.doi.org/10.1038/s41587-020-0439-x).
