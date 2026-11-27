# nf-bccdc-provenance

A Nextflow plugin that writes [BCCDC-PHL pipeline provenance](https://github.com/BCCDC-PHL/pipeline-provenance-schema) records automatically, so pipelines no longer need a `printf` block in every module. It lives in this repo for now and will move to its own repo once it's settled.

**Status: early (0.2.0).** It writes schema-valid records for threshold, with the known gaps listed below.

## What it writes

At the end of a run, in `<outdir>/provenance/` by default (threshold sets `directory` to `run_info/provenance`):

- `<sample>_provenance.yml`, one per sample
- `run_provenance.yml` for tasks that don't belong to a sample (e.g. MultiQC, the sample summary)

Each file is a YAML list in the schema's format, in this order:

- **Pipeline record:** `pipeline_name`, `pipeline_version`, `nextflow_session_id`, `nextflow_run_name`, `timestamp_analysis_start`, `nextflow_version` (and `pipeline_commit` when run from a git checkout).
- **Input files:** the sample's tasks' file inputs that live outside the work dir, i.e. pipeline inputs, references, databases, not intermediate files: `input_filename`, `file_type` (the module's input name, e.g. `reads`, `reference`, `database`), `file_path`, `sha256`.
- **Processes:** one per process the sample went through, in completion order. `process_name`, plus `tools` (`tool_name`, `tool_version` from nf-core-style `versions` outputs, and `parameters` from the task's resolved `ext.args`, split into flag/value pairs), `status` (`completed`, `cached` or `failed`) and `container` (the image the module declares).
- **Output files:** published files produced by the sample's tasks: `output_filename`, `file_path`, `sha256`.

How it decides what belongs to a sample:

- A sample is a `meta.id` seen in at least two different processes, so a run-wide ID like MultiQC's isn't mistaken for one.
- Tasks without a sample (e.g. `FETCH_REFERENCE_GENOME`, one per accession) are attached to every sample whose tasks used their output files.
- When a process failed and was retried, only the successful task is listed. A process that never succeeded for a sample appears once, as `failed`.

All files pass the schema repo's `scripts/validate-pipeline-provenance.py`, checked on threshold's `test_full` profile with assembly and reference fetching on.

## Settings

```groovy
bccdcProvenance {
    enabled     = true          // set false to turn it off
    directory   = 'provenance'  // relative to outdir unless absolute
    hashMaxSize = '1 GB'        // larger files get no sha256
    debug       = false         // also write provenance_debug.jsonl (raw observations)
}
```

## Build and install

The pipeline's `nextflow.config` loads this plugin, so it must be installed before running the pipeline. It isn't published anywhere yet, so Nextflow can't download it: without it, a run stops immediately with `Plugin with id nf-bccdc-provenance not found in any repository`.

Needs a JDK (17+) to run Gradle; the Gradle wrapper downloads Gradle itself.

The build _compiles_ with a Java 21 toolchain, whichever JDK runs Gradle: Nextflow's Gradle plugin fixes that version, and targets Java 17 bytecode so the plugin runs on any Nextflow JVM. If Gradle can't find a JDK 21 (e.g. a machine with only Java 25), it downloads one automatically, via the Foojay toolchain resolver in `settings.gradle`, and caches it in `~/.gradle/jdks`. Without internet access, point Gradle at an existing JDK 21 instead, e.g. a cluster module:

```bash
./gradlew install -Porg.gradle.java.installations.paths=/path/to/jdk-21
```

or set `org.gradle.java.installations.paths=/path/to/jdk-21` in `~/.gradle/gradle.properties`.

```bash
cd plugins/nf-bccdc-provenance
./gradlew install
```

That installs it into `~/.nextflow/plugins`, where Nextflow looks by default; set `NXF_PLUGINS_DIR` first to install somewhere else (Nextflow then looks there too). Rerun it after changing the plugin. `./gradlew assemble` just builds the zip (`build/distributions/nf-bccdc-provenance-0.2.0.zip`). In CI, a `build-plugin` job builds it once per run (with Gradle's downloads cached between runs) and every test job unpacks that zip into `~/.nextflow/plugins` (`.github/workflows/nf-test.yml`, `.github/actions/nf-test/action.yml`).

The build needs Seqera's Maven repository, but only for Nextflow's own artifacts (`io.nextflow:*`, which aren't on Maven Central) and the `io.seqera` libraries they use. `build.gradle` restricts that repository to those groups: Seqera's repository is an S3 bucket that answers `403 Forbidden` (not 404) for anything it doesn't host, so letting Gradle fall through to it for ordinary libraries turned any Maven Central hiccup into a failed build.

To try a different build of the plugin without editing `nextflow.config`, note that both `-plugins` on the command line and a `plugins {}` block in an extra `-c` config **replace** the pipeline's plugin list rather than adding to it - so repeat the pipeline's own plugins at their pinned versions, e.g. `-plugins nf-schema@2.5.1,nf-prov@1.7.0,nf-bccdc-provenance@0.2.0`. Leaving them out makes Nextflow pull the latest nf-schema, whose API differs, and the run fails.

## Known gaps

1. **No `file_size`.** The schema types `file_size` as an integer, but the schema repo's validator loads YAML with `yaml.BaseLoader`, which makes every value a string, so any record with `file_size` fails validation. (With a typed loader the reverse problem appears: `value: null` for flag-only parameters fails, because `value` is typed as a string.) It's left out until the schema and validator agree.
2. **Hashing runs on the machine running Nextflow**, at the end of the run, for every input and published file up to `hashMaxSize`. That's fine for threshold's test data. For large runs it may need to move into tasks, or cache hashes by path, size and modification time.
3. **Local modules without a `versions` output** (e.g. `SPECIES_CHECK`, `GENOME_SIZE`, `SAMPLE_SUMMARY`) report no tools. Their `ext.args`, if any, go in a process-level `parameters` field. Adding a `versions`-topic output to each local module fixes this.
4. **Failed tasks have no tool version**, since versions are only captured from a successful task's outputs.
5. **Sample detection is a heuristic** (an ID in two or more processes). A sample that only ever reaches one process would be missed. Reading the IDs from the samplesheet would be more robust.
6. **Untyped processes only.** The plugin reads Nextflow's legacy input/output declarations; typed processes (static typing, still a preview) will need handling when nf-core modules adopt them.

## Next steps

1. Settle `file_size` with the schema (see above), and consider tagging a schema release for the plugin to target.
2. Validate the provenance files in threshold's CI, not just locally.
3. Unit tests for `ProvenanceBuilder` (attribution, retries, `ext.args` parsing).
4. Move to its own repo, publish it (Nextflow plugin registry, or a self-hosted index for offline clusters), and try it in another BCCDC-PHL pipeline.
