//
// Species-specific QC thresholds with speccheck
// (https://github.com/happykhan/speccheck), including the QualiBact
// thresholds (https://qualibact.org) bundled with it.
//
// speccheck doesn't run any tools: it reads QC outputs this pipeline already
// produces - QUAST report.tsv, the sylph profile, fastp JSON (Illumina) and,
// when --checkm2_db / --busco_db are set, the CheckM2 quality report and the
// BUSCO short summary - and checks them
// against criteria for the sample's species and assembly type (`short` for
// Illumina, `long` for Nanopore). Metrics from a tool that didn't run are
// simply not checked (e.g. CheckM2 completeness/contamination without
// --checkm2_db). The mean depth from the alignment QC goes in as a GHRU-style
// depth table; speccheck's default criteria have no depth rows, so it is only
// reported unless a --speccheck_criteria file adds `DepthParser.short` /
// `DepthParser.long` rows. speccheck's default criteria include BUSCO thresholds for
// every species (Complete and Missing), so with --busco_db they count towards
// the verdict.
//
// Which samples: those with a QUAST report, i.e. isolates with an assembly -
// the thresholds are assembly thresholds, and an isolate whose assembly
// failed shouldn't get a speccheck PASS from read-level checks alone.
//
// Species: the NCBI species name from SPECIES_CHECK, only when it agrees with
// the samplesheet (`match`) or there was nothing to check against
// (`not_checked`). For `mismatch` / `unresolved` / `no_hit` the species is in
// doubt, so the sample is skipped with a warning rather than checked against
// possibly the wrong species' thresholds.
//
// SPECCHECK_COLLECT runs per sample; SPECCHECK_SUMMARY merges them into
// speccheck's report (report.csv / report.full.csv / report.html), adding a
// QualiBact-compatibility verdict (qualibact_qc).
//

include { SPECCHECK_COLLECT } from '../../modules/local/speccheck_collect/main'
include { SPECCHECK_SUMMARY } from '../../modules/local/speccheck_summary/main'

workflow SPECCHECK {

    take:
    ch_species_check    // tuple(meta, species_check.tsv) - from SPECIES_ID
    ch_quast_report     // tuple(meta, report.tsv) - from ASSEMBLY_ANALYSIS
    ch_checkm2_report   // tuple(meta, quality_report.tsv) - from ASSEMBLY_ANALYSIS (only with --checkm2_db)
    ch_busco_report     // tuple(meta, short_summary.*.txt) - from ASSEMBLY_ANALYSIS (only with --busco_db)
    ch_sylph_profile    // tuple(meta, profile.tsv) - from SPECIES_ID
    ch_fastp_json       // tuple(meta, json) - from READ_QC_AND_DEHOSTING (Illumina only)
    ch_depth            // tuple(meta, depth.tsv) - GHRU-style depth table from ALIGNMENT_QC (isolates with a reference)

    main:

    def ch_report  = channel.value([])
    def ch_results = channel.empty()

    if (!params.skip_speccheck) {
        // [id, [name: species name or null, verdict: species-check verdict]] -
        // one value per joined channel, so remainder joins pad predictably.
        def ch_organism = ch_species_check.map { meta, tsv ->
            def cols = tsv.text.trim().split('\t')
            def usable = cols[2] in ['match', 'not_checked'] && cols[6] && cols[6] != 'NA'
            tuple(meta.id, [name: usable ? cols[6] : null, verdict: cols[2]])
        }

        // Anchor on the QUAST report (one per assembled isolate) and join
        // everything else by meta.id; remainder: true because the other
        // inputs are optional (no sylph if species ID was skipped, no fastp
        // JSON for Nanopore, no CheckM2 / BUSCO without their databases).
        def ch_candidates = ch_quast_report
            .map { meta, tsv -> tuple(meta.id, meta, tsv) }
            .join(ch_organism, remainder: true)
            .join(ch_sylph_profile.map { meta, f -> tuple(meta.id, f) }, remainder: true)
            .join(ch_fastp_json.map { meta, f -> tuple(meta.id, f) }, remainder: true)
            .join(ch_checkm2_report.map { meta, f -> tuple(meta.id, f) }, remainder: true)
            .join(ch_busco_report.map { meta, f -> tuple(meta.id, f) }, remainder: true)
            .join(ch_depth.map { meta, f -> tuple(meta.id, f) }, remainder: true)
            .filter { entry -> entry[1] != null }   // assembled samples only
            .branch { _id, _meta, _quast, organism, _sylph, _fastp, _checkm2, _busco, _depth ->
                ready:   organism?.name
                skipped: true
            }

        ch_candidates.skipped.subscribe { id, _meta, _quast, organism, _sylph, _fastp, _checkm2, _busco, _depth ->
            log.warn("speccheck: skipping ${id} - species check verdict '${organism?.verdict ?: 'none'}', so its species isn't settled enough to pick thresholds")
        }

        def ch_collect_in = ch_candidates.ready.map { _id, meta, quast, organism, sylph, fastp, checkm2, busco, depth ->
            tuple(meta, [quast, sylph, fastp, checkm2, busco, depth].findAll { f -> f }, organism.name)
        }

        def ch_criteria = params.speccheck_criteria ? channel.value(file(params.speccheck_criteria, checkIfExists: true)) : channel.value([])

        def speccheck_collect_out = SPECCHECK_COLLECT(ch_collect_in, ch_criteria)
        ch_results = speccheck_collect_out.result

        // collect() emits nothing if no sample reached speccheck, so the
        // summary doesn't run; ifEmpty([]) gives SAMPLE_SUMMARY its usual
        // "stage produced nothing" placeholder.
        def speccheck_summary_out = SPECCHECK_SUMMARY(
            speccheck_collect_out.result.map { _meta, csv -> csv }.collect().map { csvs -> tuple([id: 'all'], csvs) }
        )
        ch_report = speccheck_summary_out.report.map { _meta, csv -> csv }.ifEmpty([])
    }

    emit:
    report  = ch_report    // path (or []) - speccheck report.csv, for SAMPLE_SUMMARY
    results = ch_results   // tuple(meta, <id>.speccheck.csv) - per-sample results, for the per-group speccheck reports
}
