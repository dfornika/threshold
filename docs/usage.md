# BCCDC-PHL/threshold: Usage

> _Documentation of pipeline parameters is generated automatically from the pipeline schema and can no longer be found in markdown files._

## Introduction

<!-- TODO nf-core: Add documentation about anything specific to running your pipeline. For general topics, please point to (and add to) the main nf-core website. -->

## Samplesheet input

You will need to create a samplesheet with information about the samples you would like to analyse before running the pipeline. Use this parameter to specify its location. It has to be a comma-separated file with a header row, as shown in the examples below.

```bash
--input '[path to samplesheet file]'
```

The pipeline does not try to infer what kind of library each sample is - it takes that from the samplesheet. In deployment, these columns are expected to be filled in by the automation system that launches the pipeline (e.g. from the sequencing project's metadata).

### Columns

| Column                   | Required | Description                                                                                                                                                                                                                                                                                                                  |
| ------------------------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sample`                 | yes      | Sample name, no spaces. Identical for multiple sequencing runs of the same sample.                                                                                                                                                                                                                                           |
| `fastq_1`                | yes      | Path to the gzipped FastQ file (`.fastq.gz` / `.fq.gz`) - read 1 for paired-end Illumina, or the only file for single-end / Nanopore.                                                                                                                                                                                        |
| `fastq_2`                | no       | Path to the read 2 FastQ file, for paired-end Illumina. Must be empty for Nanopore.                                                                                                                                                                                                                                          |
| `platform`               | yes      | `illumina` or `nanopore`.                                                                                                                                                                                                                                                                                                    |
| `sample_type`            | yes      | `isolate` (pure culture, shotgun - gets assembled), `metagenomic` (shotgun metagenomic), `amplicon_16s` (16S rRNA amplicon - species ID is skipped), or `amplicon_other` (any other targeted amplicon, e.g. a viral tiling panel).                                                                                           |
| `expected_taxid`         | no       | NCBI taxid (e.g. `562` for _Escherichia coli_) the sample should contain - species level, or a strain/virus-level taxid. Names are not accepted. The species-ID result is checked against it (`match` / `mismatch` / `unresolved`); without it, the top hit is just reported (`not_checked`). Needs `--species_id_manifest`. |
| `reference`              | no       | Reference genome for an isolate: an NCBI assembly accession (`GCF_...` / `GCA_...`, fetched and cached) or a path to a local FASTA. Without it, the species-ID top hit's genome is used when it agrees with `expected_taxid`.                                                                                                |
| `genome_size`            | no       | Expected genome size in bp, passed to the assembler. Without it, the reference genome's length (or a per-species lookup, or `--default_genome_size`) is used.                                                                                                                                                                |
| `project_id`             | no       | Project the sample belongs to (letters, numbers, `_`, `-`, `.`). Samples sharing a `project_id` get their own MultiQC report and `sample_summary.csv` (see [Per-group reports](#per-group-reports)).                                                                                                                         |
| `tags`                   | no       | Free-form labels, colon-separated (e.g. `rerun:validation`), the same format as nf-core/seqinspector. Each tag gets its own report and summary.                                                                                                                                                                              |
| `publish_dehosted_reads` | no       | `true` to publish this sample's final (dehosted) reads to `dehost/`. Off by default; `--publish_dehosted_reads` turns it on for all samples.                                                                                                                                                                                 |

Every column describes the sample, not the run, so all rows for the same `sample` must agree on `platform`, `sample_type`, `expected_taxid`, `reference`, `genome_size`, `project_id`, `tags` and `publish_dehosted_reads`.

### Multiple runs of the same sample

The `sample` identifiers have to be the same when you have re-sequenced the same sample more than once e.g. to increase sequencing depth. The pipeline will concatenate the raw reads before performing any downstream analysis. Below is an example for the same sample sequenced across 3 lanes:

```csv title="samplesheet.csv"
sample,fastq_1,fastq_2,platform,sample_type,expected_taxid
ISOLATE_1,ISO1_S1_L002_R1_001.fastq.gz,ISO1_S1_L002_R2_001.fastq.gz,illumina,isolate,562
ISOLATE_1,ISO1_S1_L003_R1_001.fastq.gz,ISO1_S1_L003_R2_001.fastq.gz,illumina,isolate,562
ISOLATE_1,ISO1_S1_L004_R1_001.fastq.gz,ISO1_S1_L004_R2_001.fastq.gz,illumina,isolate,562
```

### Full samplesheet

A samplesheet mixing platforms and sample types may look something like the one below.

```csv title="samplesheet.csv"
sample,fastq_1,fastq_2,platform,sample_type,expected_taxid,reference,genome_size
ISOLATE_1,ISO1_R1.fastq.gz,ISO1_R2.fastq.gz,illumina,isolate,562,,
ISOLATE_2,ISO2.fastq.gz,,nanopore,isolate,1280,GCF_002310435.1,
ISOLATE_3,ISO3_R1.fastq.gz,ISO3_R2.fastq.gz,illumina,isolate,573,/refs/kpn_local.fasta,5500000
GUT_1,GUT1_R1.fastq.gz,GUT1_R2.fastq.gz,illumina,metagenomic,,,
STOOL_16S,STOOL_16S.fastq.gz,,nanopore,amplicon_16s,,,
SARS2_1,SARS2_1_R1.fastq.gz,SARS2_1_R2.fastq.gz,illumina,amplicon_other,2697049,,
```

An [example samplesheet](../assets/samplesheet.csv) has been provided with the pipeline.

## Species-ID manifest

sylph reports hits as reference-genome accessions with no taxonomy, so checking a sample's `expected_taxid` needs `--species_id_manifest`: a CSV mapping each accession in the sylph database to its NCBI taxonomy. The columns used are `accession` (an NCBI assembly accession, `GCF_...` / `GCA_...`), `taxid` and `species_taxid`, plus optionally `species_name` and `organism` for readable output. A hit whose accession isn't in the manifest is reported as `unresolved`, not `mismatch`.

For a database built from GTDB genomes, build the manifest from GTDB's own release metadata, which records each genome's NCBI taxid and species taxid:

```bash
curl -O https://data.gtdb.ecogenomic.org/releases/latest/bac120_metadata.tsv.gz
curl -O https://data.gtdb.ecogenomic.org/releases/latest/ar53_metadata.tsv.gz
python3 scripts/build_species_manifest_from_gtdb.py \
    bac120_metadata.tsv.gz ar53_metadata.tsv.gz \
    --accessions genomes.txt \
    -o species_id_manifest.csv
```

- `--accessions` keeps only the accessions found anywhere in a text file (e.g. `ls <genome dir> > genomes.txt`, the genomes the sylph database was built from), and reports any it couldn't find. Without it the manifest covers every GTDB genome (several hundred thousand rows).
- `--representatives-only` keeps only GTDB species representatives, which is what GTDB-based sylph databases are usually built from.
- Use the GTDB release the database was built from: newer genomes than the release won't be in its metadata.
- The NCBI taxonomy is per genome. Uncultured or metagenome-assembled genomes are often filed above species level by NCBI, and GTDB species can span several NCBI species (e.g. _E. coli_ and _Shigella_), so a hit reports the NCBI species of that particular genome.

## Running the pipeline

The typical command for running the pipeline is as follows:

```bash
nextflow run BCCDC-PHL/threshold --input ./samplesheet.csv --outdir ./results  -profile docker
```

This will launch the pipeline with the `docker` configuration profile. See below for more information about profiles.

Note that the pipeline will create the following files in your working directory:

```bash
work                # Directory containing the nextflow working files
<OUTDIR>            # Finished results in specified location (defined with --outdir)
.nextflow_log       # Log file from Nextflow
# Other nextflow hidden files, eg. history of pipeline runs and old logs.
```

If you wish to repeatedly use the same parameters for multiple runs, rather than specifying each flag in the command, you can specify these in a params file.

Pipeline settings can be provided in a `yaml` or `json` file via `-params-file <file>`.

> [!WARNING]
> Do not use `-c <file>` to specify parameters as this will result in errors. Custom config files specified with `-c` must only be used for [tuning process resource specifications](https://nf-co.re/docs/running/run-pipelines#configuring-pipelines), other infrastructural tweaks (such as output directories), or module arguments (args).

The above pipeline run specified with a params file in yaml format:

```bash
nextflow run BCCDC-PHL/threshold -profile docker -params-file params.yaml
```

with:

```yaml title="params.yaml"
input: './samplesheet.csv'
outdir: './results/'
<...>
```

You can also generate such `YAML`/`JSON` files via [nf-core/launch](https://nf-co.re/launch).

### Updating the pipeline

When you run the above command, Nextflow automatically pulls the pipeline code from GitHub and stores it as a cached version. When running the pipeline after this, it will always use the cached version if available - even if the pipeline has been updated since. To make sure that you're running the latest version of the pipeline, make sure that you regularly update the cached version of the pipeline:

```bash
nextflow pull BCCDC-PHL/threshold
```

### Reproducibility

It is a good idea to specify the pipeline version when running the pipeline on your data. This ensures that a specific version of the pipeline code and software are used when you run your pipeline. If you keep using the same tag, you'll be running the same version of the pipeline, even if there have been changes to the code since.

First, go to the [BCCDC-PHL/threshold releases page](https://github.com/BCCDC-PHL/threshold/releases) and find the latest pipeline version - numeric only (eg. `1.3.1`). Then specify this when running the pipeline with `-r` (one hyphen) - eg. `-r 1.3.1`. Of course, you can switch to another version by changing the number after the `-r` flag.

This version number will be logged in reports when you run the pipeline, so that you'll know what you used when you look back in the future. For example, at the bottom of the MultiQC reports.

To further assist in reproducibility, you can use share and reuse [parameter files](#running-the-pipeline) to repeat pipeline runs with the same settings without having to write out a command with every single parameter.

> [!TIP]
> If you wish to share such profile (such as upload as supplementary material for academic publications), make sure to NOT include cluster specific paths to files, nor institutional specific profiles.

## Core Nextflow arguments

> [!NOTE]
> These options are part of Nextflow and use a _single_ hyphen (pipeline parameters use a double-hyphen)

### `-profile`

Use this parameter to choose a configuration profile. Profiles can give configuration presets for different compute environments.

Several generic profiles are bundled with the pipeline which instruct the pipeline to use software packaged using different methods (Docker, Singularity, Podman, Shifter, Charliecloud, Apptainer, Conda) - see below.

> [!IMPORTANT]
> We highly recommend the use of Docker or Singularity containers for full pipeline reproducibility, however when this is not possible, Conda is also supported.

The pipeline also dynamically loads configurations from [https://github.com/nf-core/configs](https://github.com/nf-core/configs) when it runs, making multiple config profiles for various institutional clusters available at run time. For more information and to check if your system is supported, please see the [nf-core/configs documentation](https://github.com/nf-core/configs#documentation).

Note that multiple profiles can be loaded, for example: `-profile test,docker` - the order of arguments is important!
They are loaded in sequence, so later profiles can overwrite earlier profiles.

If `-profile` is not specified, the pipeline will run locally and expect all software to be installed and available on the `PATH`. This is _not_ recommended, since it can lead to different results on different machines dependent on the computer environment.

- `test`
  - A profile with a complete configuration for automated testing
  - Includes links to test data so needs no other parameters
- `docker`
  - A generic configuration profile to be used with [Docker](https://docker.com/)
- `singularity`
  - A generic configuration profile to be used with [Singularity](https://sylabs.io/docs/)
- `podman`
  - A generic configuration profile to be used with [Podman](https://podman.io/)
- `shifter`
  - A generic configuration profile to be used with [Shifter](https://nersc.gitlab.io/development/shifter/how-to-use/)
- `charliecloud`
  - A generic configuration profile to be used with [Charliecloud](https://charliecloud.io/)
- `apptainer`
  - A generic configuration profile to be used with [Apptainer](https://apptainer.org/)
- `wave`
  - A generic configuration profile to enable [Wave](https://seqera.io/wave/) containers. Use together with one of the above (requires Nextflow ` 24.03.0-edge` or later).
- `conda`
  - A generic configuration profile to be used with [Conda](https://conda.io/docs/). Please only use Conda as a last resort i.e. when it's not possible to run the pipeline with Docker, Singularity, Podman, Shifter, Charliecloud, or Apptainer.

### `-resume`

Specify this when restarting a pipeline. Nextflow will use cached results from any pipeline steps where the inputs are the same, continuing from where it got to previously. For input to be considered the same, not only the names must be identical but the files' contents as well. For more info about this parameter, see [this blog post](https://www.nextflow.io/blog/2019/demystifying-nextflow-resume.html).

You can also supply a run name to resume a specific run: `-resume [run-name]`. Use the `nextflow log` command to show previous run names.

### `-c`

Specify the path to a specific config file (this is a core Nextflow command). See the [nf-core website documentation](https://nf-co.re/usage/configuration) for more information.

## Custom configuration

### Resource requests

Whilst the default requirements set within the pipeline will hopefully work for most people and with most input data, you may find that you want to customise the compute resources that the pipeline requests. Each step in the pipeline has a default set of requirements for number of CPUs, memory and time. For most of the pipeline steps, if the job exits with any of the error codes specified [here](https://github.com/nf-core/rnaseq/blob/4c27ef5610c87db00c3c5a3eed10b1d161abf575/conf/base.config#L18) it will automatically be resubmitted with higher resources request (2 x original, then 3 x original). If it still fails after the third attempt then the pipeline execution is stopped.

To change the resource requests, please see the [max resources](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#set-max-resources) and [customise process resources](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#customize-process-resources) section of the nf-core website.

### Custom Containers

In some cases, you may wish to change the container or conda environment used by a pipeline steps for a particular tool. By default, nf-core pipelines use containers and software from the [biocontainers](https://biocontainers.pro/) or [bioconda](https://bioconda.github.io/) projects. However, in some cases the pipeline specified version maybe out of date.

To use a different container from the default container or conda environment specified in a pipeline, please see the [updating tool versions](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#update-tool-versions) section of the nf-core website.

### Custom Tool Arguments

A pipeline might not always support every possible argument or option of a particular tool used in pipeline. Fortunately, nf-core pipelines provide some freedom to users to insert additional parameters that the pipeline does not include by default.

To learn how to provide additional arguments to a particular tool of the pipeline, please see the [customising tool arguments](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#modifying-tool-arguments) section of the nf-core website.

### nf-core/configs

In most cases, you will only need to create a custom config as a one-off but if you and others within your organisation are likely to be running nf-core pipelines regularly and need to use the same settings regularly it may be a good idea to request that your custom config file is uploaded to the `nf-core/configs` git repository. Before you do this please can you test that the config file works with your pipeline of choice using the `-c` parameter. You can then create a pull request to the `nf-core/configs` repository with the addition of your config file, associated documentation file (see examples in [`nf-core/configs/docs`](https://github.com/nf-core/configs/tree/master/docs)), and amending [`nfcore_custom.config`](https://github.com/nf-core/configs/blob/master/nfcore_custom.config) to include your custom profile.

See the main [Nextflow documentation](https://www.nextflow.io/docs/latest/config.html) for more information about creating your own configuration files.

If you have any questions or issues please send us a message on [Slack](https://nf-co.re/join/slack) on the [`#configs` channel](https://nfcore.slack.com/channels/configs).

### Per-group reports

Besides the all-samples MultiQC report (`multiqc/`) and `sample_summary.csv`, the pipeline writes a MultiQC report and a `sample_summary.csv` for each group of samples, in `groups/<field>/<value>/`:

```
groups/
  project_id/
    covid-19/
      project_id-covid-19_multiqc_report.html
      sample_summary.csv
  tags/
    rerun/
      tags-rerun_multiqc_report.html
      sample_summary.csv
```

`--multiqc_group_by` chooses the samplesheet fields to group by: a comma-separated list of `project_id`, `tags`, `sample_type` and `platform` (default `project_id,tags`). Each of a sample's tags is its own group, so a sample can appear in several. Samples with no value for a field are in no group for it, so samplesheets without `project_id` or `tags` get no `groups/` directory. Set `--multiqc_group_by ''` (or `multiqc_group_by: ""` in a `-params-file`) to turn per-group reports off.

### Published reads

Read files aren't published by default: the output directory gets the QC reports, dehosting stats and analysis results, but not the reads themselves. To publish the final (trimmed, dehosted) reads to `dehost/`, use `--publish_dehosted_reads` for all samples, or set `publish_dehosted_reads` to `true` in the samplesheet for individual samples.

Trimmed reads from before dehosting still contain host reads, so they're never published while dehosting runs. With `--skip_dehosting` the trimmed reads are the final reads, so the same option publishes those instead (to `fastp/` or `fastplong/`).

### Temporary files (`TMPDIR`)

By default each task gets its own `TMPDIR`: a `tmp/` directory inside its work directory (`--task_tmpdir`, on by default; see `conf/task_tmpdir.config`). Nextflow forwards your shell's `TMPDIR` into Apptainer/Singularity containers but only mounts the task's work directory, so a `TMPDIR` anywhere else (e.g. under your home directory) doesn't exist inside the container, and any tool writing temporary files fails. The work directory is always mounted, sits on the same filesystem as the rest of the run, and is cleaned up with it. When the work directory path is long (over 70 characters, typical on a cluster), `TMPDIR` is instead a short symlink, `/tmp/nxf-<task hash>`, pointing at that `tmp/` directory. Unix socket paths are limited to about 107 characters, and tools using Python's `multiprocessing` (e.g. CheckM2) create a socket under `TMPDIR`, failing with `OSError: AF_UNIX path too long` otherwise. Files still land in the work directory; only the symlink is in `/tmp`.

To use your own `TMPDIR` instead, set `task_tmpdir: false` in a `-params-file`, and make sure that path is mounted in the container (e.g. via `apptainer.runOptions = '-B /path/to/tmp'` in a custom config).

## Running in the background

Nextflow handles job submissions and supervises the running jobs. The Nextflow process must run until the pipeline is finished.

The Nextflow `-bg` flag launches Nextflow in the background, detached from your terminal so that the workflow does not stop if you log out of your session. The logs are saved to a file.

Alternatively, you can use `screen` / `tmux` or similar tool to create a detached session which you can log back into at a later time.
Some HPC setups also allow you to run nextflow within a cluster job submitted your job scheduler (from where it submits more jobs).

## Nextflow memory requirements

In some cases, the Nextflow Java virtual machines can start to request a large amount of memory.
We recommend adding the following line to your environment to limit this (typically in `~/.bashrc` or `~./bash_profile`):

```bash
NXF_OPTS='-Xms1g -Xmx4g'
```
