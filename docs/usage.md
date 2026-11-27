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

| Column                   | Required | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `sample`                 | yes      | Sample name, no spaces. Identical for multiple sequencing runs of the same sample.                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `fastq_1`                | yes      | Path to the gzipped FastQ file (`.fastq.gz` / `.fq.gz`) - read 1 for paired-end Illumina, or the only file for single-end / Nanopore.                                                                                                                                                                                                                                                                                                                                                                                    |
| `fastq_2`                | no       | Path to the read 2 FastQ file, for paired-end Illumina. Must be empty for Nanopore.                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `platform`               | yes      | `illumina` or `nanopore`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `sample_type`            | yes      | `isolate` (pure culture, shotgun - gets assembled), `metagenomic` (shotgun metagenomic), `amplicon_16s` (16S rRNA amplicon - species ID is skipped), or `amplicon_other` (any other targeted amplicon, e.g. a viral tiling panel).                                                                                                                                                                                                                                                                                       |
| `expected_taxid`         | no       | NCBI taxid the sample should be within, at any rank: a strain, species (e.g. `562`, _Escherichia coli_), genus or family (e.g. `543`, Enterobacteriaceae). Names are not accepted. The species-ID result is checked against it (`match` / `mismatch` / `unresolved`); without it, the sample's project taxids are used if `--project_expected_taxids` lists them, otherwise the top hit is just reported (`not_checked`). Needs `--species_id_manifest`; matching above species level needs its `lineage_taxids` column. |
| `reference`              | no       | Reference genome for an isolate: an NCBI assembly accession (`GCF_...` / `GCA_...`, fetched and cached) or a path to a local FASTA. Without it, the species-ID top hit's genome is used when it agrees with `expected_taxid`.                                                                                                                                                                                                                                                                                            |
| `genome_size`            | no       | Expected genome size in bp, passed to the assembler. Without it, the reference genome's length (or a per-species lookup, or `--default_genome_size`) is used.                                                                                                                                                                                                                                                                                                                                                            |
| `busco_lineage`          | no       | BUSCO lineage dataset to use for this sample, e.g. `enterobacteriaceae_odb12.2`. Overrides the lineage that would be looked up from the species. Only used with `--busco_db`.                                                                                                                                                                                                                                                                                                                                            |
| `project_id`             | no       | Project the sample belongs to (letters, numbers, `_`, `-`, `.`). Samples sharing a `project_id` get their own MultiQC report and `sample_summary.csv` (see [Per-group reports](#per-group-reports)).                                                                                                                                                                                                                                                                                                                     |
| `tags`                   | no       | Free-form labels, colon-separated (e.g. `rerun:validation`), the same format as nf-core/seqinspector. Each tag gets its own report and summary.                                                                                                                                                                                                                                                                                                                                                                          |
| `publish_dehosted_reads` | no       | `true` to publish this sample's final (dehosted) reads to `by_sample/<sample>/dehost/`. Off by default; `--publish_dehosted_reads` turns it on for all samples.                                                                                                                                                                                                                                                                                                                                                          |

Every column describes the sample, not the run, so all rows for the same `sample` must agree on `platform`, `sample_type`, `expected_taxid`, `reference`, `genome_size`, `busco_lineage`, `project_id`, `tags` and `publish_dehosted_reads`.

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

## Expected taxa per project

For projects whose samples can be one of several organisms, `--project_expected_taxids` gives each project a list of acceptable taxa instead of setting `expected_taxid` on every sample:

```csv title="project_expected_taxids.csv"
project_id,expected_taxid
enteric_surveillance,543
covid,2697049
mixed_project,1280
mixed_project,561
```

- A project can be listed several times; a sample **matches** if its species-ID hit is within **any** of its project's taxids.
- Taxids can be at any rank: `543` (Enterobacteriaceae) accepts _E. coli_, _Klebsiella_, _Salmonella_, and so on. This needs a manifest with a `lineage_taxids` column (see below); without one, only exact taxid / species taxid matches are possible.
- A sample's own `expected_taxid` in the samplesheet takes precedence over its project's taxids.
- Results record which taxids were used, where they came from (`sample` or `project`) and which one matched: `species_check_expected_taxids`, `species_check_expected_source` and `species_check_matched_taxid` in `sample_summary.csv`.
- The file is checked at startup (`project_id`, integer `expected_taxid`), needs `--species_id_manifest`, and projects with no samples in the run are reported as a warning.
- Optional `taxon_name` and `taxon_rank` columns (kraken2-style rank codes: `D`, `K`, `P`, `C`, `O`, `F`, `G`, `S`, `S1`) are accepted and validated, but nothing uses them for matching yet.
- An expected taxid has to exist in the taxonomy of the classifier being checked: sylph results use the manifest's lineage (current NCBI taxonomy, or whichever dump you built it from), kraken2 results the taxonomy of the kraken2 database, which dates from when it was built. A taxid NCBI introduced later, or a species it has since renamed (e.g. SARS-CoV-2's species is now 3418604; older databases have 694009), matches in one and not the other.

## Species-ID databases (sylph and kraken2)

Two classifiers screen each sample (except `amplicon_16s` ones, which a whole-genome database can't classify):

- **sylph** (`--sylph_db`) always runs: it names the closest genome, which the reference-genome step needs. It runs with `--estimate-unknown`, so its `Sequence_abundance` values are shares of **all** reads and the hits can sum to less than 100% (the remainder is unclassified). `sylph_classified_pct` in the species-check output is that sum.
- **kraken2** (`--kraken2_db`, a database directory) is optional: it runs only for samples that have a kraken2 database. Its report lists every taxon's NCBI taxid with the reads in the taxon's whole branch, so an expected taxid at any rank is a direct lookup, with no manifest needed. bracken isn't included: it needs a database built for the reads' length and re-estimates abundances at one rank, which the species check doesn't need.

### Databases per project

Both take a per-project CSV, `--project_sylph_dbs` and `--project_kraken2_dbs`, with one row per project and database (a project can be listed several times):

```csv title="project_sylph_dbs.csv"
project_id,sylph_db
virology,/dbs/refseq_viral.syldb
mixed,default
mixed,/dbs/refseq_viral.syldb
```

- A project that is listed is screened **only** against the databases listed for it; every other sample uses the default (`--sylph_db` / `--kraken2_db`). The reserved value `default` stands for the default database, so a project can add to it instead of replacing it (`mixed` above). There's no per-sample database option.
- **sylph:** all of a sample's databases go to **one** `sylph profile` call, which resolves them jointly: one profile whose abundances sum to 100% across databases. Separate runs per database would each call their own top hit 100% and couldn't be combined. Hits are ranked by `Sequence_abundance` (share of reads), not taxonomic abundance, which counts genome copies and so favours tiny genomes (a few viral reads can out-rank a bacterium holding most of the reads).
- **kraken2:** one run per database (kraken2 takes one), with the database name in the output file name (`<sample>.<database>.kraken2.report.txt`). The species check evaluates each report and keeps the best verdict (`match` > `mismatch` > `low_classified` > `no_hit` > `not_checked`), since a viral sample is expected to be unclassified in a bacterial database. The kraken2 values reported come from the database that decided it.
- Checked at startup: every listed database exists (a kraken2 database must contain `hash.k2d`), `default` needs `--sylph_db` / `--kraken2_db`, every sample that gets screened has a sylph database, and one sample's databases don't share a file name. sylph needs a database for every such sample; kraken2 doesn't.
- Relative paths in these CSVs are resolved from the directory you launch the pipeline in.

### The kraken2 verdict

Per report, with the expected taxa from the sample's `expected_taxid` or its project (see above), E = the reads in the expected taxa's branches (an expected taxon inside another is counted once):

| verdict          | when                                                                                                                                                       |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `not_checked`    | no expected taxa (the top taxon is still reported)                                                                                                         |
| `no_hit`         | no reads were classified                                                                                                                                   |
| `low_classified` | fewer than `--kraken2_min_classified_pct` (default 50) of **all** reads were classified, so the classified ones say too little to call a match or mismatch |
| `match`          | E is at least `--kraken2_min_expected_pct` (default 70) of the **classified** reads                                                                        |
| `mismatch`       | otherwise                                                                                                                                                  |

For `metagenomic` samples a taxon only needs to be present: `match` if E is at least `--kraken2_min_metagenomic_pct` (default 1) of the classified reads, and `low_classified` isn't applied. The columns are in `species_check_summary.tsv` and, abbreviated, in `sample_summary.csv` (`species_check_kraken2_*`, `species_check_sylph_classified_pct`). The kraken2 reports are published to `kraken2/` and included in the MultiQC reports, including the per-project ones.

The sylph verdict (`species_check`) is unchanged and is still what reference selection and speccheck use; the kraken2 verdict is reported alongside it, not combined with it.

**Resources:** each kraken2 task loads its whole database into memory (the module's default request is 72 GB). Many samples at once on one node may need `--memory-mapping` (`ext.args` for `KRAKEN2_KRAKEN2` in a custom config), which lets them share the operating system's cache, or a lower concurrency (`maxForks`).

## BUSCO lineages

BUSCO is opt-in: it runs on each assembly only when `--busco_db` points at a
directory of pre-downloaded BUSCO lineage datasets (the directory that holds
`lineages/`), so runs need no network access. The full prokaryote set is large
(370 lineages), and a public health lab rarely needs it, so
`bin/fetch_busco_lineages.py` fetches a subset: the lineages for the genera in
`assets/busco_public_health_genera.txt` (about 50 lineages, roughly 1.6 GB) plus
the default lineage. It checks each download's md5, skips what is already
there, and can be re-run to top up:

```bash
bin/fetch_busco_lineages.py --out /data/busco_db --dry-run   # list what it would fetch
bin/fetch_busco_lineages.py --out /data/busco_db
bin/fetch_busco_lineages.py --out /data/busco_db --lineage rhodococcus_odb12.2   # add one
bin/fetch_busco_lineages.py --out /data/busco_db --all       # every prokaryote lineage
```

Edit the genus file to suit your lab. It lists genera, not lineages, so it
stays valid when the lineage table is regenerated.

A more specific lineage gives a more sensitive completeness estimate, so the
lineage is chosen per sample, first match wins:

1. the samplesheet's `busco_lineage`;
2. the species-check name, looked up in `assets/busco_lineages.tsv` (a species
   row, then its genus row) - only when the species check agrees with the
   samplesheet or there was nothing to check against;
3. `--busco_default_lineage` (`bacteria_odb12.2`).

With a partial `--busco_db`, a lineage from step 2 that was not downloaded falls
back to the default with a warning, so an unexpected organism still gets a
(less specific) BUSCO result. The default lineage must be in the database, or
the run stops at startup. A `busco_lineage` from the samplesheet is never
replaced: if it is missing, BUSCO fails for that sample.

`assets/busco_lineages.tsv` maps every bacterial and archaeal genus to its
most specific BUSCO lineage. It is generated, not edited: see the docstring of
`bin/make_busco_lineage_table.py` for how to regenerate it when BUSCO or the
NCBI taxonomy changes.

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
- `--taxdump new_taxdump/` adds a `lineage_taxids` column - every NCBI ancestor taxid of each genome - which lets expected taxids match at any rank (e.g. a family). Download and unpack NCBI's taxonomy dump first (about 160 MB):

  ```bash
  curl -O https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/new_taxdump/new_taxdump.tar.gz
  mkdir new_taxdump && tar -xzf new_taxdump.tar.gz -C new_taxdump taxidlineage.dmp merged.dmp
  ```

  To add the column to any existing manifest (e.g. a hand-built one): `python3 scripts/add_lineage_to_manifest.py --taxdump new_taxdump/ manifest.csv -o manifest.lineage.csv`. Retired taxids are mapped to their current ones via `merged.dmp`; an expected taxid that NCBI has since retired won't match (it comes back `mismatch`), so use current taxids.

- The NCBI taxonomy is per genome. Uncultured or metagenome-assembled genomes are often filed above species level by NCBI, and GTDB species can span several NCBI species (e.g. _E. coli_ and _Shigella_), so a hit reports the NCBI species of that particular genome.

For genomes that aren't from GTDB (viral, fungal, anything named by RefSeq/GenBank assembly accession), `scripts/build_species_manifest_from_ncbi.py` builds rows from NCBI's assembly summary files, which list every assembly's taxid, species taxid and organism, and from the taxonomy dump (species names and lineage). One manifest covers every sylph database, since it's keyed by accession, so merge the pieces:

```bash
python3 scripts/build_species_manifest_from_ncbi.py assembly_summary.txt \
    --taxdump new_taxdump/ --accessions viral_genomes.txt -o viral_manifest.csv
python3 scripts/merge_species_manifests.py gtdb_manifest.csv viral_manifest.csv -o species_id_manifest.csv
```

(add `names.dmp` to the `tar -xzf` above; `merge_species_manifests.py` keeps the first file's row when an accession is in several.) kraken2 doesn't use the manifest.

## Running the pipeline

The typical command for running the pipeline is as follows:

```bash
nextflow run BCCDC-PHL/threshold --input ./samplesheet.csv --outdir ./results  -profile docker
```

This will launch the pipeline with the `docker` configuration profile. See below for more information about profiles.

Note that the pipeline will create the following files in your working directory:

```bash
work                # Directory containing the nextflow working files
<OUTDIR>            # Finished results in specified location (defined with --outdir); layout in docs/output.md
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

Besides the all-samples MultiQC report and `sample_summary.csv` (in `summary/`), the pipeline writes a MultiQC report and a `sample_summary.csv` for each group of samples, in `by_<field>/<value>/`:

```
by_project/
  covid-19/
    project_id-covid-19_multiqc_report.html
    sample_summary.csv
by_tag/
  rerun/
    tags-rerun_multiqc_report.html
    sample_summary.csv
```

The group directories are `by_project`, `by_tag`, `by_sample_type` and `by_platform`. They hold reports only; each sample's data stays in `by_sample/<sample>/`. See [output](output.md) for the whole layout.

`--multiqc_group_by` chooses the samplesheet fields to group by: a comma-separated list of `project_id`, `tags`, `sample_type` and `platform` (default `project_id`). Each of a sample's tags is its own group, so a sample can appear in several. Samples with no value for a field are in no group for it, so samplesheets without `project_id` or `tags` get no `groups/` directory. Set `--multiqc_group_by ''` (or `multiqc_group_by: ""` in a `-params-file`) to turn per-group reports off.

### speccheck depth criteria

The mean depth from the alignment QC reaches speccheck as a GHRU-style depth
table (`Depth.Depth` and `Depth.Read_type` in `report.full.csv`;
`long` for Nanopore, `short` for Illumina). speccheck's bundled criteria have
no depth rows, so nothing gates on it by default. To gate, pass
`--speccheck_criteria` with rows such as:

```csv
species,assembly_type,software,field,operator,value,severity,source,special_field
Escherichia coli,short,DepthParser.short,Depth,>=,30,fail,local,
Escherichia coli,long,DepthParser.long,Depth,>=,20,fail,local,
```

A custom criteria file _replaces_ the bundled one (QualiBact, BUSCO, ...), so
start from a copy of speccheck's `criteria.csv` and add these rows. The depth is
measured against the sample's reference genome, so it reflects the reference
choice (a species representative unless the samplesheet names one).

### Cleaning up the work directory

`--cleanup_workdir` (off by default) deletes the work directory once a run
finishes successfully, so only the published results remain. A run that fails
keeps its work directory, but a run that cleaned up cannot be resumed.

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
