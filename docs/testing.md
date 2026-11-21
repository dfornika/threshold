# BCCDC-PHL/gx-threshold: Testing

This page describes the test datasets, how they are generated, the overall testing
strategy, and how to run the tests. It intentionally stays high level — the specific
processes and their assertions will evolve, so look at the test files themselves
(`*.nf.test`) for current, tool-specific detail.

## Philosophy

Tests should be **fast, deterministic, and runnable offline on a laptop**. To that
end the default test suite uses tiny, purpose-built fixtures rather than real
sequencing runs, so a change either clearly passes or clearly fails without waiting
on large downloads or worrying about drifting inputs.

## Test datasets

The default fixtures live in-repo under [`tests/data/`](../tests/data) and total only
a few hundred kilobytes:

```
tests/data/
  generate.py                 # deterministic generator (see below)
  samplesheet.csv             # test-profile input: one Illumina PE + one Nanopore SE sample
  references/
    host_mini.fasta           # small "host" reference
    microbe_mini.fasta        # small, unrelated "microbe" reference
  reads/
    illumina/  SAMPLE_PE_R1/R2.fastq.gz
    nanopore/  SAMPLE_ONT.fastq.gz
  real/                        # test_full profile input - see below
    README.md                  # provenance: source SRA accessions, subsampling, spike-in
    spike_human.py              # deterministic generator: reads_src + human_mt.fasta -> reads/
    samplesheet.csv
    references/
      human_mt.fasta            # real human mitochondrial genome (rCRS, NC_012920.1)
    reads/                       # reads_src + spiked-in human reads - actual pipeline input, committed (~1.7MB)
      illumina/  KPNEUMONIAE_WGS_R1/R2, ECOLI_WGS_R1/R2, SARS2_AMPLICON_ILLUMINA_R1/R2
      nanopore/  SARS2_AMPLICON_ONT.fastq.gz
    reads_src/                   # pristine downloaded+downsampled SRA reads - NOT committed, see README
  species_db/                  # tiny sylph DB - see tests/data/species_db/README.md
    manifest.csv                 # 10 reference genomes: the 3 known species above + 7 decoys
    build_dbs.py                 # regenerates the DB below from manifest.csv
    sylph/species_mini.syldb
    genomes_src/                 # downloaded genome FASTAs - NOT committed, see README
```

The two references are independent pseudo-random sequences, so reads derived from one
do **not** map to the other. Each read set is a deliberate **mix of host- and
microbe-derived reads**, which lets host-removal tests assert that the host reads are
actually removed and the microbe reads are retained — not just that the step ran.

### How the fixtures are generated

All fixtures are produced by a single seeded, dependency-free script,
[`tests/data/generate.py`](../tests/data/generate.py). Regenerate them at any time
with:

```bash
python3 tests/data/generate.py
```

The script is fully deterministic (fixed seed, timestamp-free gzip), so regenerating
produces byte-identical files. On run it prints a short **manifest** of how many
host- vs microbe-derived reads it wrote for each platform; that manifest is the
ground truth the module tests assert against.

### Synthetic vs. real data

The default fixtures are **synthetic** because they give exact, reproducible control
over what each test contains (e.g. a known host fraction). These are complemented by
a small set of **real, downsampled** reads under
[`tests/data/real/`](../tests/data/real) (see that directory's `README.md` for
provenance): real bacterial WGS (*Klebsiella pneumoniae*, *E. coli*) and SARS-CoV-2
tiling-amplicon runs, pulled from SRA/ENA and downsampled to a few thousand reads each
with [`rasusa`](https://github.com/mbhall88/rasusa) - with a small number of reads
simulated from the real human mitochondrial genome (rCRS, NC_012920.1) spiked into
each sample, so `test_full` exercises real host-read removal too (a few percent host
fraction expected), not just a 0%-host check. As the real-data collection grows
further, test inputs may move to versioned URLs (hosted in our own test-datasets
repository) referenced from the test configs, mirroring the nf-core convention,
rather than being committed in-repo.

### Read QC + dehosting

`READ_QC_AND_DEHOSTING` (`subworkflows/local/read_qc_and_dehosting.nf`) bundles
everything that runs on every sample before species ID or assembly touches
the reads: FastQC, fastp/fastplong trimming, and dehosting (`DEHOST`).

FastQC and fastp/fastplong each run **twice** - once on the raw input reads,
and again on the final (trimmed + dehosted) reads that flow to every
downstream analysis, so the QC report visible in MultiQC reflects what
downstream analyses actually see, not just the raw input. Running the same
process twice with different roles in one workflow uses **module aliasing**
(`include { FASTQC as FASTQC_RAW; FASTQC as FASTQC_FINAL } from ...`, and
likewise for fastp/fastplong) - this is the standard nf-core idiom for this
exact situation (e.g. nf-core/rnaseq's `FASTQC_RAW`/`FASTQC_TRIM`), not a
workaround; there isn't a cleaner alternative.

**The final pass is measurement-only by construction, not by convention.**
FastQC never modifies reads, so re-running it on the final reads is
inherently safe - nothing to guard against. fastp/fastplong do modify reads
by design (that's the entire point of the first pass), so the final pass
uses their built-in `discard_trimmed_pass: true` option (a real, tested,
documented upstream nf-core module feature - "use fastp for the output
report only"): with it set, fastp/fastplong never write a trimmed-reads
file at all for that invocation. There is nothing from this pass that could
accidentally be published or picked up downstream, regardless of what
fastp/fastplong would otherwise have changed - no extra `--disable_*` flags
or output-suppression logic needed.

Both passes publish to the same per-tool directory (`${outdir}/fastqc/`,
`${outdir}/fastp/`, `${outdir}/fastplong/`) with an `_raw`/`_final` filename
suffix (`ext.prefix`, `conf/modules.config`) distinguishing them, rather
than separate subdirectories - keeps the existing one-directory-per-tool
layout unchanged for every other stage.

### Samplesheet metadata instead of inference

What each sample *is* - `platform`, `sample_type` (`isolate` / `metagenomic` /
`amplicon_16s` / `amplicon_other`), and optionally `expected_taxid`,
`reference` and `genome_size` - comes from the samplesheet
(`assets/schema_input.json`); `platform` and `sample_type` are required. In
deployment, the automation system that launches the pipeline fills these in
from the sequencing project's metadata.

Earlier versions tried to infer all of this from the reads instead: platform
from single- vs paired-end, four independent amplicon-vs-shotgun detectors
fused by majority vote, pure-culture-vs-metagenomic from sourmash composition
breadth (with ANI clustering of the mash database to collapse naming
artifacts), a gated 16S detector, and a mash/sourmash/sylph vote to pick a
reference genome. Validation showed several of these had real, reproducible
failure modes on difficult samples, and they made the pipeline's structure
hard to follow. They were removed in favour of the samplesheet; see the git
history (up to commit `d8423a3`) and the version of this page there for the
full method-by-method rationale and validation results.

The samplesheet is validated up front: missing/invalid `platform` or
`sample_type` fails the run, as does a Nanopore row with a `fastq_2`, or a
sample whose repeated rows (multiple runs) disagree on any of these fields.

### Species-ID database

[`tests/data/species_db/`](../tests/data/species_db) holds a tiny sylph
database built from 10 real reference genomes - the true species of every
`test_full` sample, plus 7 decoys (including two deliberately "hard"
same-genus/family cases) - so a species call in `test_full` is checked against
a known right answer rather than a database with only one possible entry. See
that directory's `README.md` for the genome panel and why sylph was kept over
mash/sourmash.

### Species ID + check against the samplesheet

`SPECIES_ID` (`subworkflows/local/species_id.nf`) runs `SYLPH_PROFILE` on
every sample except `amplicon_16s` ones (a whole-genome database recovers
almost nothing from ~1.5kb of one gene, so any hit would be noise), then
`SPECIES_CHECK` (`bin/check_species.py`) compares the top hit with
`expected_taxid`:

- `match` - the top hit is the expected taxon (for `metagenomic` samples:
  the expected taxon is among any of the hits);
- `mismatch` - the top hit is a different taxon - a likely sample swap,
  contamination or mislabel;
- `unresolved` - the top hit's accession isn't in the manifest, so there's no
  taxid to compare (not counted as a mismatch: it says the manifest is
  incomplete, not that the sample is wrong);
- `no_hit` - sylph reported nothing above its own thresholds;
- `not_checked` - no `expected_taxid` was given; the top hit is still
  reported.

`expected_taxid` is an NCBI taxid only - names were dropped because they
drift (NCBI now calls SARS-CoV-2's species "Betacoronavirus pandemicum") and
are ambiguous. It's matched against the manifest's `species_taxid` or `taxid`
for the hit's accession, so a strain/virus-level taxid matches too (e.g.
`511145`, *E. coli* K-12, or `2697049`, SARS-CoV-2). sylph's output has no
taxonomy, so `--species_id_manifest` is required whenever any sample has an
`expected_taxid` - the run fails at startup without it. Collected into
`${outdir}/species_id/species_check_summary.tsv`.

**Validated** against `test_full`: all 4 samples `match` - the two
SARS-CoV-2 samples deliberately use the virus-level (`2697049`) and
species-level (`3418604`) taxids respectively, so both match paths are
covered. An `isolate` sample deliberately labelled with the wrong taxid comes
back `mismatch`; a hit missing from the manifest comes back `unresolved`.

### Reference genome

`REFERENCE_GENOME` (`subworkflows/local/reference_genome.nf`) resolves one
reference per `isolate` sample (only isolates are assembled, and nothing is
resolved when `--skip_assembly` is set), used for QUAST's reference-based
metrics and the assembler genome-size hint. Priority:

1. the samplesheet's `reference` column - a local FASTA path, used as-is, or
   an NCBI assembly accession (`GCF_`/`GCA_`), fetched;
2. otherwise the accession of sylph's top hit, when `SPECIES_CHECK` found it
   consistent with the samplesheet (`match`, or `not_checked`) - never for a
   `mismatch`.

Fetching uses the NCBI Datasets CLI (`datasets download genome accession
... --include genome,gff3,seq-report`). Each accession's cache entry holds:
- `<acc>.fasta.gz`: the whole assembly (all contigs/plasmids);
- `<acc>.gff.gz`: the GFF3 annotation, when NCBI has one (unannotated
  assemblies, common for MAGs, have none - not an error);
- `<acc>.assembly_report.jsonl` and `<acc>.sequence_report.jsonl`: NCBI's
  assembly metadata and per-sequence report.

`REFERENCE_GENOME` emits per-sample `sample_reference` (FASTA) and
`sample_gff` channels. Entries are cached using Nextflow's `storeDir` in
`--reference_genome_cache_dir` - never re-downloaded across runs, and
deduplicated within a run when several samples share an accession. A cache
entry missing any required file (e.g. one written by the earlier
entrez-direct version, which only had the FASTA) is re-fetched automatically.

**Tool choice, checked rather than assumed**: `datasets` fetches the FASTA,
GFF and metadata from the same assembly record in one call, for RefSeq
(`GCF_`) and GenBank (`GCA_`) accessions alike, so the FASTA and GFF use the
same sequence names. The previous approach (E-utilities: `esearch | elink |
efetch` via `assembly_nuccore_insdc`, plus the GFF from the RefSeq FTP path)
didn't: for `GCF_000005845.2` the FASTA came back as the GenBank record
`U00096.3` while the RefSeq GFF names it `NC_000913.3`, so tools pairing the
two would silently find no features; and GenBank-only accessions have no
RefSeq FTP path at all. `datasets` was passed over originally only because
the biocontainers `ncbi-datasets-cli` image stopped at v14.26 (May 2023),
which no longer works against NCBI's API. The module now uses StaPH-B's
regularly updated image (`staphb/ncbi-datasets:18.39.0`; conda:
`conda-forge::ncbi-datasets-cli=18.39.0`). `ncbi-genome-download` (the
nf-core `ncbigenomedownload` module) remains unusable - it fails to parse
NCBI's current `assembly_summary.txt`
([kblin/ncbi-genome-download#237](https://github.com/kblin/ncbi-genome-download/issues/237)).

**Fetching is on by default** (`--skip_reference_genome_fetch` defaults to
`false`) - the planned deployment environments have network access. A
per-accession fetch failure doesn't fail the run: `conf/modules.config` gives
`FETCH_REFERENCE_GENOME` a retry-twice-then-ignore `errorStrategy`, and that
sample simply has no reference (a failed fetch isn't cached, so a bad
accession is retried on every run) (QUAST runs reference-free, and the genome-size
hint falls back to the taxid table). The offline `test`/`test_full` profiles
set `skip_reference_genome_fetch = true`; local FASTA paths in the samplesheet
are used either way.

**Validated** with `test_full`'s reads plus assembly and fetch turned on (via
`-params-file`, since Nextflow's CLI doesn't reliably coerce `--flag false` to
boolean for schema-validated params): a *K. pneumoniae* isolate with a
`match` fetches `GCF_058435815.1`, its length (5,489,631 bp) becomes the
genome-size hint, and QUAST runs with `-r`. With `datasets`: an annotated
RefSeq accession (`GCF_000005845.2`) caches FASTA + GFF + reports with
matching sequence names; an unannotated GenBank MAG (`GCA_041569275.1`)
caches FASTA + reports and no GFF, without error; a nonexistent accession is
retried, then ignored, and that sample falls back to the taxid genome-size
table; an old FASTA-only cache entry is re-fetched in full; and a second run
skips every cached accession, including the one with no GFF.

#### Dev-only sample datasets

Deeper, more representative real samples than the tiny fixtures above - not
committed (`data/dev_samples/`, `data/dev_metagenomic_samples/`, gitignored) -
one per platform × library-type combination, plus real shotgun-metagenomic
and 16S samples. See the `README.md` in each for the SRA accessions and
regeneration recipe (same `download_fastq` + `rasusa reads -n <N> -s 42`
approach as `tests/data/real/`).

### Draft assembly + assembly QC

`ASSEMBLY_ANALYSIS` (`subworkflows/local/assembly.nf`) implements the
assembly stages. It runs **only for `isolate` samples** (the samplesheet's
`sample_type`), so amplicon and metagenomic samples are never assembled.
Single-end Illumina isolates are skipped with a warning, since Shovill needs
paired reads.

**Two dedicated single-platform assemblers, no hybrid.** The samplesheet is
one platform per sample, so there's no way to pair an Illumina and an ONT
library for the same isolate; each assembled sample routes by `meta.platform`
to exactly one assembler:

- Illumina → [`Shovill`](https://github.com/tseemann/shovill) (SPAdes/SKESA
  wrapper with routine-bacterial defaults).
- Nanopore → [`Dragonflye`](https://github.com/rpetit3/dragonflye) (Flye +
  Racon/Medaka polish + reorientation).

This split (rather than one unified/hybrid tool like Unicycler) is deliberate:
the best short-read and long-read assemblers are genuinely different
algorithms, and Unicycler's long-read-only mode is its weakest configuration.
Unicycler is held in reserve for a future hybrid path, if the input model ever
grows to express it.

**Species-informed genome-size hint.** Both assemblers estimate a genome size
to calibrate their coverage/parameter selection, and both estimators failed on
the shallow dev fixtures - Dragonflye produced a catastrophic ~1kb estimate on
a shallow ONT subsample, and Shovill's `kmc` estimation step segfaulted on
~1x Illumina data. `GENOME_SIZE` (`modules/local/genome_size/`,
`bin/resolve_genome_size.py`) resolves a per-sample `--gsize` up front instead,
best-available source first: (1) the samplesheet's **`genome_size`** column,
(2) the actual length of the sample's **reference genome** (see above), (3) a
coarse **taxid → size lookup** (`assets/genome_sizes.tsv`, keyed on the
species taxid of sylph's top hit) for when there's no reference, or (4)
`--default_genome_size` (a generic backstop, default 5 Mb). The resolved value
is folded into `meta.genome_size` and passed to both assemblers via
`ext.args` (`conf/modules.config`). Assembly quality is insensitive to this
within ~2x, so a ballpark is all that's needed - the hint only exists to keep
the assemblers' coverage estimation in the right order of magnitude and to
avoid the pathological auto-estimates above. The chosen value + its source are
written to `${outdir}/assembly/<sample>/<sample>.genome_size.txt`.

**QC on the resulting assembly** is platform-agnostic:

- [`QUAST`](https://github.com/ablab/quast) for contiguity (#contigs, total
  length, largest contig, N50) plus, **when the sample has a reference
  genome**, reference-based metrics (genome fraction, NGA50, misassemblies,
  mismatch/indel rates). Each assembly is paired with its sample's reference
  (joined by `meta.id`) and `multiMap`-ed into QUAST's
  three inputs, so QUAST runs reference-based per-sample where a reference
  exists and reference-free otherwise - a mix is handled in one call.
  **Interpretation caveat:** the reference is usually a species
  representative genome, not the sample's own strain, so **genome fraction and
  NGA50 are robust, but the misassembly and mismatch/indel counts also reflect
  real strain divergence (SNPs, indels, plasmid presence/absence,
  rearrangements), not just assembly error** - they're advisory. For that
  reason only **genome fraction** (a robust completeness cross-check against
  CheckM2) is surfaced in the one-row summary; the misassembly/mismatch numbers
  stay in the full QUAST report (`${outdir}/assembly/quast/`) rather than
  inviting over-interpretation in the headline table.
  When the reference was fetched from NCBI with a GFF3 annotation, it's also
  passed as QUAST's `--features`, adding genomic-feature recovery (complete +
  partial genes, e.g. `510 + 2 part`), surfaced as `features_complete` /
  `features_partial`. Local FASTA references and unannotated assemblies have
  no GFF, so those columns are `NA`. Verified on a 500 kb slice of a fetched
  *K. pneumoniae* reference: QUAST matched the NCBI GFF's sequence names and
  reported 510 complete + 2 partial features.
- [`CheckM2`](https://github.com/chklovski/CheckM2) for completeness +
  contamination. **Only runs when `--checkm2_db` is provided** - its DIAMOND
  database is a large external download, so it's opt-in. Without it, the
  completeness/contamination columns are `NA` and only QUAST metrics appear.

`bin/parse_assembly_qc.py` + the `ASSEMBLY_SUMMARY` module normalise each
sample's QUAST `report.tsv` (+ CheckM2 `quality_report.tsv` when present) into
one row, collected into `${outdir}/assembly/assembly_summary.tsv`. Annotation
(the "and annotation" half of the original step 8) is **not yet implemented** -
Bakta/Prokka are the candidates; deferred until the core assembly + QC path is
validated on more real data.

**Graceful degradation.** Assembly is a routine entrypoint stage, so a single
library failing to assemble (too shallow, an odd read set, a transient OOM)
must not sink the whole batch. `SHOVILL`/`DRAGONFLYE` get a retry-then-ignore
`errorStrategy` (`conf/modules.config`), the same pattern as
`FETCH_REFERENCE_GENOME`: retry a couple of times (the base config scales
`memory` with `task.attempt`, so retries also cover transient OOM), then give
up gracefully. An ignored assembler simply leaves that sample out of the
assembly channel - its assembly columns come back `NA`, exactly as if it never
reached the gate - and the run still completes.

**On by default** (`--skip_assembly`, default `false`) - unlike reference-genome
fetch, assembly itself needs no external database (Dragonflye bundles its Medaka
model). But **both `test` and `test_full` explicitly set `skip_assembly = true`**:
the synthetic `test` fixtures wouldn't assemble meaningfully, and
`test_full`'s reads are downsampled to ~1200 read pairs - fine for the read-level analyses but far too
shallow to assemble meaningfully. Assembly is validated instead against the
deeper `data/dev_samples/` isolates (see above).

**Validated against `data/dev_samples/` isolates** through the full pipeline
(`-profile dev,docker`, dev species DB, assembly on): the ONT path
(Dragonflye) on `SAUREUS_WGS_ONT_DEV` / `LMONOCYTOGENES_WGS_ONT_DEV` (~5k reads
≈ ~9x, enough for a Flye/Medaka draft) and the Illumina path (Shovill) on
`SAUREUS_WGS_ILLUMINA_DEV`. **Known limitation (same honest-caveats spirit as
the rest of this project)**: the current dev Illumina isolates are only ~1-2x
coverage (10k read pairs) - enough to exercise the wiring end to end, but too
shallow for a *quality* Shovill assembly (expect a fragmented result). A proper
Illumina assembly-quality check needs a deeper subsample; the target read count
in `data/download_and_subsample.py`'s `MANIFEST` can simply be bumped for a
dedicated deeper fixture. The ONT isolates are adequate as-is.

### Sample summary

`SAMPLE_SUMMARY` (`modules/local/sample_summary/`,
`bin/build_sample_summary.py`) builds one CSV with one row per sample -
`${outdir}/sample_summary.csv` - so a reviewer can see the main verdict/metric
from every stage above without opening several different TSVs. It doesn't
replace those TSVs (which keep every field for each stage); it's a single
at-a-glance table across stages, deliberately kept to one or two headline
columns per stage (verdict plus one supporting metric) rather than every
field - see the header row in `bin/build_sample_summary.py` for the exact
columns.

The sample manifest emitted by `READ_QC_AND_DEHOSTING` (sample, platform,
sample_type, expected_taxid - straight from the samplesheet) is the only
required input and anchors which rows exist; every other stage's
summary TSV is optional. If a stage was skipped (by flag, e.g.
`--skip_reference_genome_fetch`) or simply produced nothing for this run
(e.g. no isolates in this run, so no assemblies), its columns are just `NA` for the affected rows - the row
itself is never dropped.

**A real, non-obvious bug found while building this**: `collectFile()`
emits nothing at all - not even the seed/header row - when its input channel
is completely empty, rather than falling back to a header-only file. This
first surfaced as `SAMPLE_SUMMARY` silently running **zero times** (no
error, just absent from the process list) whenever any upstream stage's
collated TSV happened to have zero rows for a given run - which is exactly
what happened under the plain `test` profile when a species-ID tool
correctly found no hit for the tiny synthetic fixtures against the real
species DB (expected behaviour, not a bug in that stage). Every conditional
summary channel now ends in `.ifEmpty([])`, falling back to the same "stage
produced nothing" placeholder used when a stage is toggled off - documented
inline at each site (see `subworkflows/local/species_id.nf` for the
first occurrence). The same goes for joining two `tuple(meta, ...)`
channels on the whole `meta` map: meta maps captured at different points in
the pipeline needn't be identical, so such a join silently matches nothing -
always join by `meta.id`. Worth remembering as a recurring Nextflow failure
mode: **missing output shows up as "nothing happened," not
an error**.

**Validated** against both `test` (2 synthetic samples, species check
`no_hit` as expected) and `test_full` (4 real samples, all `match`ing their
`expected_taxid`).

## Testing strategy

Tests are layered:

1. **Module tests** (`modules/**/tests/*.nf.test`) — exercise a single process in
   isolation with the tiny fixtures. These favour **explicit assertions** (exact read
   counts, invariants) for correctness, plus snapshots to catch unintended drift.
2. **End-to-end / smoke test** — run the whole pipeline on the `test` profile to
   confirm everything wires together and produces the expected outputs, fully offline.
3. **Realistic test** (`test_full`) — real, downsampled SRA reads (see
   [`tests/data/real/README.md`](../tests/data/real/README.md)) for a more
   representative check than the synthetic fixtures, still small and fast enough to
   run routinely rather than reserved for release validation only.

Continuous integration runs the suite across container engines in parallel — **Docker,
Conda, and Singularity/Apptainer** — via `.github/workflows/nf-test.yml`, so a change
is validated on every supported backend.

### A note on snapshots

Some tests use nf-test **snapshots**. A snapshot records a fingerprint of a test's
outputs (file checksums, channel contents, reported tool versions) the first time it
runs; later runs compare against it. A snapshot therefore guards against **unintended
change**, not correctness in the abstract — when a change is intentional (new output,
deliberate version bump), re-bless the baseline with `--update-snapshot` and commit the
updated `.snap` file.

## Running the tests

### End-to-end (pipeline) run

```bash
# Offline, uses the in-repo synthetic fixtures
nextflow run . -profile test,docker --outdir results
```

Swap `docker` for `conda`, `singularity`, or `apptainer` to check another engine.

For the realistic dataset (real, downsampled SRA reads - still fully in-repo, no
download needed at run time):

```bash
nextflow run . -profile test_full,docker --outdir results
```

### On a memory-constrained machine (e.g. a laptop)

Compose the `dev` profile, which lowers the resource ceilings so every process fits:

```bash
nextflow run . -profile test,dev,docker --outdir results
```

### Component tests with nf-test

[Install nf-test](https://www.nf-test.com/installation/), then from the repo root:

```bash
# a single module
nf-test test modules/local/dehost/tests/main.nf.test --profile=+docker

# everything
nf-test test --profile=+docker
```

`--profile=+docker` adds `docker` to the `test` profile already configured in
`nf-test.config`. Add `,dev` (e.g. `--profile=+docker,dev`) on a constrained machine.
Use `--update-snapshot` when you intend to update snapshot baselines.
