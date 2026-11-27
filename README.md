<p align="center">
  <img src="https://raw.githubusercontent.com/dfornika/threshold/refs/heads/main/docs/images/threshold.png" width="300" alt="Accessibility Description" />
</p>

## Introduction

**threshold** is a QC and routine-analysis pipeline for microbial genomics,
intended as a standard "entrypoint" that runs on every sequenced library as it
arrives in a genomics analysis platform. It works on both **Illumina** and
**Oxford Nanopore** reads, takes a samplesheet of FASTQ files, and produces a
per-sample summary of what each library is and what is in it, collated by
[`MultiQC`](http://multiqc.info/) and into a single `sample_summary.csv`.

The pipeline does not try to work out _what_ each library is from the reads:
the samplesheet says so (platform, sample type, expected species), and the
pipeline routes each sample accordingly and checks the reads against those
claims. In deployment, the automation system that launches the pipeline fills
these in from the sequencing project metadata.

## Pipeline summary

1. Read QC and trimming (FastQC, fastp / fastplong)
2. Host read removal (minimap2)
3. Species ID and check against the samplesheet (sylph, optionally kraken2)
4. Reference genome selection / fetching (isolates)
5. Draft genome assembly (Shovill / Dragonflye; isolates)
6. Assembly QC (QUAST, CheckM2)
7. Alignment QC against the reference (minimap2, riker; isolates)
8. Species-specific QC thresholds (speccheck)
9. Reports (MultiQC and `sample_summary.csv`, overall and per project / tag)
10. Provenance records

Each step, and the parameters that control it, is described in
[`docs/pipeline.md`](docs/pipeline.md).

## Quick start

Prepare a samplesheet (`platform` and `sample_type` are required; the other
columns are optional):

```csv
sample,fastq_1,fastq_2,platform,sample_type,expected_taxid,reference,genome_size
ISOLATE_1,ISO1_R1.fastq.gz,ISO1_R2.fastq.gz,illumina,isolate,562,,
ISOLATE_2,ISO2.fastq.gz,,nanopore,isolate,1280,GCF_002310435.1,
GUT_1,GUT1_R1.fastq.gz,GUT1_R2.fastq.gz,illumina,metagenomic,,,
```

Build the provenance plugin once (it is part of this repo and not published
yet; needs a JDK 17+, see
[`plugins/nf-bccdc-provenance/README.md`](plugins/nf-bccdc-provenance/README.md)):

```bash
(cd plugins/nf-bccdc-provenance && ./gradlew install)
```

Then run the pipeline:

```bash
nextflow run BCCDC-PHL/threshold \
   -profile <conda/docker/singularity/apptainer> \
   --input samplesheet.csv \
   --sylph_db <db.syldb> \
   --species_id_manifest <manifest.csv> \
   --dehost_reference <host.fasta> \
   --outdir <OUTDIR>
```

## Documentation

- [Pipeline steps](docs/pipeline.md): what each stage does and its parameters
- [Usage](docs/usage.md): samplesheet columns, expected taxa and databases per project, the species-ID manifest, running and configuring the pipeline
- [Output](docs/output.md): the results the pipeline produces
- [Testing](docs/testing.md): test data, method rationale, validation status and known caveats

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
