# BCCDC-PHL/threshold: Output

Everything is published under `--outdir`, laid out by what you want to ask:

```
<outdir>/
  summary/             all-samples results: start here
  by_sample/<id>/      everything for one sample, by stage
  by_project/<id>/     per-project reports (and by_tag/, by_sample_type/, by_platform/)
  run_info/            how the run went: Nextflow reports, provenance, RO-Crate
```

Publishing is an allowlist (`conf/modules.config`): a process publishes only if
it has a rule there, so intermediates such as the alignment BAMs stay in the
work directory. File names inside `by_sample/<id>/` keep the sample id, so they
stay identifiable if you move them.

## `summary/`

- `sample_summary.csv` - one row per sample, with the key results of every
  stage (read QC, dehosting, species check, assembly QC, alignment QC,
  speccheck). The best single file to open first.
- `multiqc/` - the all-samples [MultiQC](http://multiqc.info/) report
  (`multiqc_report.html`, `multiqc_data/`, `multiqc_plots/`).
- `speccheck/` - speccheck's `report.csv`, `report.full.csv` and `report.html`:
  each assembled isolate against the QC criteria for its species.
- `stage_tables/` - the per-stage tables behind `sample_summary.csv`, one row
  per sample: `dehost_summary.tsv`, `species_check_summary.tsv`,
  `assembly_summary.tsv` (isolates) and `alignment_summary.tsv` (isolates with
  a reference). A table only exists if its stage produced rows.

## `by_sample/<id>/`

Only the stages that ran for the sample are present.

| Directory             | Contents                                                                                                              |
| --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `reads_qc/fastqc/`    | FastQC reports, `_raw` (before trimming) and `_final` (after dehosting)                                               |
| `reads_qc/fastp/`     | fastp reports (Illumina), trimming and final pass                                                                     |
| `reads_qc/fastplong/` | fastplong reports (Nanopore)                                                                                          |
| `dehost/`             | `<id>.dehost.stats.tsv`; the reads themselves only on request (`--publish_dehosted_reads`, or the samplesheet column) |
| `species_id/`         | `<id>.species_check.tsv`, the verdict against the samplesheet                                                         |
| `species_id/sylph/`   | the sylph profile                                                                                                     |
| `species_id/kraken2/` | kraken2 reports, one per database, when `--kraken2_db` is set                                                         |
| `assembly/`           | `<id>.contigs.fa` (and `<id>.contigs.reoriented.fa` for Nanopore when dnaapler succeeded), `<id>.genome_size.txt`     |
| `assembly/quast/`     | the full QUAST report                                                                                                 |
| `assembly/checkm2/`   | CheckM2 output, with `--checkm2_db`                                                                                   |
| `assembly/busco/`     | BUSCO short summaries, with `--busco_db`                                                                              |
| `alignment/`          | riker metrics (coverage, alignment, GC bias, insert size for paired Illumina) for isolates with a reference           |
| `speccheck/`          | `<id>.speccheck.csv`, the sample's speccheck result                                                                   |

## `by_<field>/<value>/`

For each field in `--multiqc_group_by` (default `project_id`), each value gets a
MultiQC report and a `sample_summary.csv` filtered to its samples:

```
by_project/<project_id>/    project_id-<value>_multiqc_report.html, sample_summary.csv
by_tag/<tag>/               likewise; each tag of a sample is its own group
by_sample_type/<type>/      likewise
by_platform/<platform>/     likewise
```

These hold reports only. The sample data stays in `by_sample/`, so nothing is
duplicated; a group's `sample_summary.csv` lists which samples to look at.

## `run_info/`

- `pipeline_info/` - Nextflow's execution report, timeline, trace and DAG,
  `params_<timestamp>.json`, `sample_manifest.tsv` (the samples as the pipeline
  read them), and `threshold_software_mqc_versions.yml` (tool versions).
- `provenance/` - [BCCDC-PHL pipeline provenance](https://github.com/BCCDC-PHL/pipeline-provenance-schema):
  one `<sample>_provenance.yml` per sample plus `run_provenance.yml`.
- `ro-crate/` - a [Workflow Run RO-Crate](https://www.researchobject.org/workflow-run-crate/)
  from nf-prov: `ro-crate-metadata.json` and copies of the pipeline's
  `README.md`, `main.nf`, `nextflow.config`, `nextflow_schema.json` and the
  samplesheet, so the crate is self-contained.

## Adding a new process

Give it a `publishDir` in `conf/modules.config` if its results should be kept,
under `by_sample/${meta.id}/<stage>/` for per-sample files. Without a rule
nothing is published. For an all-samples table, write it with `collectFile` to
`summary/stage_tables/`.
