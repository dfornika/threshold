# nf-bccdc-provenance (spike)

A Nextflow plugin to produce [BCCDC-PHL pipeline provenance](https://github.com/BCCDC-PHL/pipeline-provenance-schema) records automatically, so pipelines no longer need a `printf` block in every module. It lives in this repo while it's a spike, and will move to its own repo once it works reliably.

**Status: spike.** The plugin doesn't write provenance records yet. It records what Nextflow exposes about each task, to check that a plugin can get everything the schema needs. Its only output is `<outdir>/pipeline_info/bccdc_provenance_spike.jsonl`: one JSON object per line - a `run` record, one `task` record per task (executed, cached or failed) and one `publish` record per published file.

## Build and install

The pipeline's `nextflow.config` loads this plugin, so it must be installed before running the pipeline. It isn't published anywhere yet, so Nextflow can't download it: without it, a run stops immediately with `Plugin with id nf-bccdc-provenance not found in any repository`.

Needs a JDK (17+). The Gradle wrapper downloads Gradle itself.

```bash
cd plugins/nf-bccdc-provenance
./gradlew install
```

That installs it into `~/.nextflow/plugins`, where Nextflow looks by default; set `NXF_PLUGINS_DIR` first to install somewhere else (Nextflow then looks there too). Rerun it after changing the plugin. `./gradlew assemble` just builds the zip (`build/distributions/nf-bccdc-provenance-0.1.0.zip`). CI runs `./gradlew install` before nf-test (`.github/actions/nf-test/action.yml`).

To try a different build of the plugin without editing `nextflow.config`, note that both `-plugins` on the command line and a `plugins {}` block in an extra `-c` config **replace** the pipeline's plugin list rather than adding to it - so repeat the pipeline's own plugins at their pinned versions, e.g. `-plugins nf-schema@2.5.1,nf-prov@1.7.0,nf-bccdc-provenance@0.1.0`. Leaving them out makes Nextflow pull the latest nf-schema, whose API differs, and the run fails.

## Spike findings

Built against the Nextflow 25.10.0 API (`TraceObserverV2`) and run on Nextflow 26.04.4 with threshold's `test_full` profile, then again with `-resume` and assembly on (30 cached + 10 executed tasks).

### Available, and what the schema needs it for

| Schema field                                            | Where it comes from                                                                 | Result                                                                                                                                                                                                    |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pipeline name/version, session ID, run name, start time | `session.workflowMetadata`                                                          | Available, along with commit ID, revision, profile, container engine, Nextflow version and command line                                                                                                   |
| Which sample a task ran for                             | the `meta` map (with `id`) in the task's inputs                                     | Found for every per-sample task                                                                                                                                                                           |
| Process name                                            | `task.processor.name`                                                               | Available                                                                                                                                                                                                 |
| Tool name + version                                     | nf-core modules' `versions` outputs: `tuple val(process), val(tool), eval(version)` | Available: each version (`CmdEvalParam`) directly follows its tool name in the task's outputs, e.g. `minimap2` → `2.28-r1209`, `samtools` → `1.20`                                                        |
| Tool parameters                                         | `ext.args` from `conf/modules.config`                                               | Available and already resolved, including per-sample closures: Shovill got `--gsize 4641652` (E. coli) and `--gsize 5489631` (_K. pneumoniae_)                                                            |
| Container                                               | `task.container`                                                                    | Available for every task (a useful extra field)                                                                                                                                                           |
| Input files per sample                                  | the task's file inputs located outside the work dir                                 | Available, with no pipeline-specific wiring: raw FASTQs, dehosting reference, sylph DB, species manifest, and the fetched reference FASTA + GFF (seen as inputs to that sample's QUAST/GENOME_SIZE tasks) |
| Output files per sample                                 | publish events, mapped to the task whose work dir the file came from                | 87 of 96 published files traced to a sample (rest below)                                                                                                                                                  |
| `-resume`                                               | `onTaskCached`                                                                      | Cached tasks are reported with full inputs, outputs and versions                                                                                                                                          |

### To design for in the real plugin

1. **Run-level tasks that have a `meta.id`.** MultiQC's `meta.id` is `threshold`, the run-wide ID, not a sample. The plugin needs a reliable way to tell samples apart: e.g. the IDs read from the samplesheet, or IDs that appear across several processes, or a configurable list of run-level processes.
2. **Tasks keyed by something other than a sample**, such as `FETCH_REFERENCE_GENOME` (one task per accession, shared by samples). They're linked to samples because their outputs show up as inputs to per-sample tasks.
3. **`storeDir` outputs are published from the cache, not a work dir** (8 of the 9 unattributed files), so they need attributing by output file name to the task that declares them.
4. **Failed attempts are reported** (via `onTaskComplete`, with no outputs) - e.g. Shovill's retries on too-shallow data. Record them as failed rather than as normal steps.
5. **Local modules without `versions` outputs** (e.g. `SPECIES_CHECK`, `GENOME_SIZE`, `SAMPLE_SUMMARY`) report no tool version. Adding a `versions`-topic output to each local module, as nf-core modules have, fixes that for every consumer.
6. **Hashing** (`sha256` for input/output files) isn't attempted yet. Large FASTQs or databases shouldn't be hashed on the Nextflow head node every run: hash in parallel, or cache hashes by path + size + modification time.

## Next steps

1. Write records in the BCCDC schema: one `<sample>_provenance.yml` per sample plus the pipeline record, handling the cases above.
2. Validate the output with `scripts/validate-pipeline-provenance.py` from the schema repo, in the plugin's tests and in threshold's CI.
3. Configuration (`bccdcProvenance { ... }` scope: enable/disable, output path, hashing).
4. Move to its own repo, publish (Nextflow plugin registry, or a self-hosted index for offline clusters), and add it to `nextflow.config`.
