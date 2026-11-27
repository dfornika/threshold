//
// Species identification + check against the samplesheet: sylph (and,
// optionally, kraken2) classify each sample against reference database(s),
// then SPECIES_CHECK compares the result with the sample's expected taxa (its
// own `expected_taxid`, else its project's). What a sample *is* comes from the
// samplesheet; this stage is there to catch sample swaps, contamination and
// mislabelling.
//
// Databases (see project_dbs.nf): --sylph_db / --kraken2_db are the defaults;
// projects listed in --project_sylph_dbs / --project_kraken2_dbs are screened
// ONLY against their own databases ('default' stands for the default one).
//   sylph    always runs (it names the genome, which reference selection uses).
//            All of a sample's databases go to one sylph call, so the profile
//            is a single joint one across databases.
//   kraken2  optional: runs only for samples that have a kraken2 database,
//            once per database (it takes one); SPECIES_CHECK evaluates each
//            report against the expected taxa at any rank.
//
// Skipped for `amplicon_16s` samples: a whole-genome database recovers
// almost nothing from ~1.5kb of one gene, so any hit would be noise.
//

include { SYLPH_PROFILE } from '../../modules/nf-core/sylph/profile/main'
include { KRAKEN2_KRAKEN2 } from '../../modules/nf-core/kraken2/kraken2/main'
include { SPECIES_CHECK } from '../../modules/local/species_check/main'
include { samplesheetToList } from 'plugin/nf-schema'
include { parseProjectDbs } from './project_dbs'
include { resolveProjectDbs } from './project_dbs'

workflow SPECIES_ID {

    take:
    ch_clean_reads          // tuple(meta, reads)
    ch_species_id_manifest  // path (or []) - accession -> organism/taxonomy CSV
    outdir

    main:

    def ch_multiqc_files = channel.empty()
    def ch_species_check = channel.empty()
    def ch_species_check_summary = channel.value([])
    def ch_sylph_profile = channel.empty()

    if (!params.skip_species_id) {
        // Each sample's databases: its project's or the default, per tool. For
        // sylph the startup checks guarantee at least one; for kraken2 there
        // may be none (the sample is then not classified with kraken2).
        def project_sylph_dbs = parseProjectDbs(params.project_sylph_dbs ? samplesheetToList(params.project_sylph_dbs, "${projectDir}/assets/schema_project_sylph_dbs.json") : [])
        def project_kraken2_dbs = parseProjectDbs(params.project_kraken2_dbs ? samplesheetToList(params.project_kraken2_dbs, "${projectDir}/assets/schema_project_kraken2_dbs.json") : [])

        def ch_to_classify = ch_clean_reads.filter { meta, _reads -> meta.sample_type != 'amplicon_16s' }

        // SYLPH_PROFILE takes the reads and the databases as separate inputs,
        // so split each sample into two channels with multiMap - it emits
        // both in lockstep, keeping a sample's reads paired with its own
        // database list. The database names go in meta (sylph's output
        // doesn't say which databases a hit came from) for the species-check
        // output.
        def ch_sylph_in = ch_to_classify
            .map { meta, reads ->
                def dbs = resolveProjectDbs(meta, project_sylph_dbs, params.sylph_db)
                if (!dbs) {
                    error("No sylph database for sample ${meta.id}: set --sylph_db, or list a database for its project in --project_sylph_dbs")
                }
                tuple(meta + [sylph_dbs: dbs.collect { db -> file(db).name }.join(';')], reads, dbs.collect { db -> file(db, checkIfExists: true) })
            }
            .multiMap { meta, reads, dbs ->
                reads:     tuple(meta, reads)
                databases: dbs
            }

        def sylph_profile_out = SYLPH_PROFILE(ch_sylph_in.reads, ch_sylph_in.databases)
        ch_sylph_profile = sylph_profile_out.profile_out
        ch_multiqc_files = ch_multiqc_files.mix(sylph_profile_out.profile_out)

        // kraken2: one run per (sample, database), same lockstep trick. The
        // database name goes in meta - it names the output files (see
        // conf/modules.config) - along with how many databases the sample has,
        // so its reports can be grouped as soon as they're all in.
        def ch_kraken2_in = ch_to_classify
            .flatMap { meta, reads ->
                def dbs = resolveProjectDbs(meta, project_kraken2_dbs, params.kraken2_db)
                dbs.collect { db -> tuple(meta + [kraken2_db: file(db).name, kraken2_n_dbs: dbs.size()], reads, file(db, checkIfExists: true)) }
            }
            .multiMap { meta, reads, db ->
                reads:    tuple(meta, reads)
                database: db
            }

        def kraken2_out = KRAKEN2_KRAKEN2(ch_kraken2_in.reads, ch_kraken2_in.database, false, false)
        ch_multiqc_files = ch_multiqc_files.mix(kraken2_out.report)

        // Each sample's kraken2 reports, grouped by sample ID (groupKey: emit
        // the group as soon as it has all of the sample's databases), joined to
        // its sylph profile. remainder: true - samples without kraken2 reports
        // still get checked.
        def ch_kraken2_by_id = kraken2_out.report
            .map { meta, report -> tuple(groupKey(meta.id, meta.kraken2_n_dbs), report) }
            .groupTuple()
            // sorted by file name: groupTuple order is arrival order, and the
            // order of the reports decides ties for the best database
            .map { key, reports -> tuple(key.getGroupTarget(), reports.sort { report -> report.name }) }

        def ch_check_in = sylph_profile_out.profile_out
            .map { meta, profile -> tuple(meta.id, meta, profile) }
            .join(ch_kraken2_by_id, remainder: true)
            .filter { entry -> entry[1] != null }
            .map { _id, meta, profile, reports -> tuple(meta, profile, reports ?: []) }

        def ch_project_taxids = params.project_expected_taxids ? file(params.project_expected_taxids, checkIfExists: true) : []
        def species_check_out = SPECIES_CHECK(ch_check_in, ch_species_id_manifest, ch_project_taxids)
        ch_species_check = species_check_out.result

        // .ifEmpty([]): collectFile emits nothing at all (not even the seed
        // header) if its input is empty - e.g. every sample is amplicon_16s -
        // so SAMPLE_SUMMARY still gets a usable value.
        ch_species_check_summary = species_check_out.result
            .map { _meta, file -> file }
            .collectFile(
                name: 'species_check_summary.tsv',
                storeDir: "${outdir}/summary/stage_tables",
                sort: { file -> file.name },   // by file name (= sample), not full work-dir path, so row order is stable across runs
                seed: "sample\tplatform\tverdict\texpected_taxid\taccession\tspecies_taxid\tspecies_name\tadjusted_ani\ttaxonomic_abundance\tn_hits\texpected_source\tmatched_taxid\tsequence_abundance\tsylph_dbs\tsylph_classified_pct\tkraken2_verdict\tkraken2_matched_taxid\tkraken2_expected_pct\tkraken2_classified_pct\tkraken2_top_taxon\tkraken2_top_pct\tkraken2_dbs\tkraken2_best_db\n"
            )
            .ifEmpty([])
    }

    emit:
    species_check         = ch_species_check          // tuple(meta, species_check.tsv) - one per profiled sample
    species_check_summary = ch_species_check_summary  // path (or []) - for SAMPLE_SUMMARY
    multiqc_files         = ch_multiqc_files   // tuple(meta, file) - per-sample MultiQC inputs, with meta for per-group reports
    sylph_profile         = ch_sylph_profile          // tuple(meta, profile.tsv) - empty channel if species ID is skipped
}
