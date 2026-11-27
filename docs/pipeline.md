# BCCDC-PHL/threshold: Pipeline steps

What each stage of the pipeline does, and the parameters that control it. See
[usage.md](usage.md) for the samplesheet and running the pipeline, and
[testing.md](testing.md) for method rationale, validation status and known
caveats.

1. **Read QC & trimming** — [`FastQC`](https://www.bioinformatics.babraham.ac.uk/projects/fastqc/)
   plus [`fastp`](https://github.com/OpenGene/fastp) (Illumina) /
   [`fastplong`](https://github.com/OpenGene/fastp) (Nanopore), run on both the
   raw reads and again on the final trimmed/dehosted reads that flow downstream.
2. **Host read removal (dehosting)** — [`minimap2`](https://github.com/lh3/minimap2)
   against a host reference (`--dehost_reference`); toggle with `--skip_dehosting`.
   The dehosted reads are only published on request (`--publish_dehosted_reads`,
   or per sample in the samplesheet); reads from before dehosting never are.
3. **Species ID + check** — [`sylph`](https://github.com/bluenote-1577/sylph)
   against a reference-genome database (`--sylph_db`) and, optionally,
   [`kraken2`](https://github.com/DerrickWood/kraken2) (`--kraken2_db`); both
   can take different databases per project (`--project_sylph_dbs`,
   `--project_kraken2_dbs`). The results are compared with the samplesheet's
   `expected_taxid`, or the sample's project taxids from
   `--project_expected_taxids` (NCBI taxids, matched at any rank - e.g. a
   family) and reported as `match` / `mismatch` / `no_hit` / `not_checked`
   (kraken2 also `low_classified`), along with the fraction of reads each
   classified, to catch sample swaps, contamination and mislabelling. Skipped
   for `amplicon_16s` samples; toggle with `--skip_species_id`.
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
   contamination when a `--checkm2_db` is provided, and
   [`BUSCO`](https://busco.ezlab.org) for single-copy ortholog completeness when
   a `--busco_db` is provided. BUSCO uses the most specific lineage for the
   sample (see [usage](usage.md#busco-lineages)).
7. **Alignment QC** — for `isolate` samples with a reference, the clean reads
   are aligned to it with [`minimap2`](https://github.com/lh3/minimap2) and
   [`riker`](https://github.com/fulcrumgenomics/riker) collects coverage
   (mean / median depth, fraction of the reference at 1x and 10x, evenness),
   the fraction of reads aligned and, for paired Illumina, the median insert
   size. The reference is usually a species representative, not the strain of
   the sample itself, so plasmids and accessory genes will not map: read these
   as indicators, not pass / fail thresholds (speccheck does not use them).
   Toggle with `--skip_alignment_qc`.
8. **Species-specific QC thresholds** — [`speccheck`](https://gitlab.com/cgps/tools/speccheck)
   checks each assembled isolate's QUAST, sylph, fastp and (with
   `--checkm2_db`) CheckM2 and (with `--busco_db`) BUSCO results against criteria for its species, including
   the [QualiBact](https://qualibact.org) thresholds, giving a PASS / WARN /
   FAIL with reasons. Runs only when the species check agrees with the
   samplesheet (or there was no expected taxid). Toggle with `--skip_speccheck`;
   custom criteria via `--speccheck_criteria`.
9. **Reports** — an all-samples [MultiQC](http://multiqc.info/) report and
   `sample_summary.csv`, plus one of each per project and per tag (optional
   `project_id` / `tags` samplesheet columns; `--multiqc_group_by`) in
   `groups/<field>/<value>/`.
10. **Provenance** — the pipeline's `nf-bccdc-provenance` plugin writes
    [BCCDC-PHL pipeline provenance](https://github.com/BCCDC-PHL/pipeline-provenance-schema)
    records to `provenance/`: one `<sample>_provenance.yml` per sample (inputs
    with `sha256`, each process with its tool versions, parameters and
    container, and outputs) plus `run_provenance.yml`. See
    [`plugins/nf-bccdc-provenance/README.md`](plugins/nf-bccdc-provenance/README.md).

Planned but not yet implemented: genome annotation (Bakta/Prokka) of the draft
assemblies, and hybrid (short + long) assembly (which needs an input model that
can pair an Illumina and a Nanopore library for the same isolate).
