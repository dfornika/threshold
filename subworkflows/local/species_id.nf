//
// Species identification + check against the samplesheet: sylph profiles
// each sample against its reference-genome database(s), then SPECIES_CHECK
// compares the top hit with the sample's expected taxa (its own
// `expected_taxid`, else its project's). What a sample *is* comes from the
// samplesheet; this stage is there to catch sample swaps, contamination and
// mislabelling.
//
// Databases: --sylph_db is the default; projects listed in
// --project_sylph_dbs are screened ONLY against their own databases ('default'
// stands for --sylph_db) - see sylph_dbs.nf. All of a sample's databases go to
// one sylph call, so the profile is a single joint one across databases.
//
// Skipped for `amplicon_16s` samples: a whole-genome database recovers
// almost nothing from ~1.5kb of one gene, so any hit would be noise.
//

include { SYLPH_PROFILE } from '../../modules/nf-core/sylph/profile/main'
include { KRAKEN2_KRAKEN2 } from '../../modules/nf-core/kraken2/kraken2/main'
include { SPECIES_CHECK } from '../../modules/local/species_check/main'
include { samplesheetToList } from 'plugin/nf-schema'
include { parseProjectSylphDbs } from './sylph_dbs'
include { resolveSylphDbs } from './sylph_dbs'

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

	
        // Each sample's databases: its project's (--project_sylph_dbs) or the
        // default (--sylph_db); the startup checks guarantee at least one.
        def project_db_rows = params.project_sylph_dbs ? samplesheetToList(params.project_sylph_dbs, "${projectDir}/assets/schema_project_sylph_dbs.json") : []
        def project_dbs = parseProjectSylphDbs(project_db_rows)

        // SYLPH_PROFILE takes the reads and the databases as separate inputs,
        // so split each sample into two channels with multiMap - it emits
        // both in lockstep, keeping a sample's reads paired with its own
        // database list. The database names go in meta (sylph's output
        // doesn't say which databases a hit came from) for the species-check
        // output.
        def ch_to_profile = ch_clean_reads
            .filter { meta, _reads -> meta.sample_type != 'amplicon_16s' }
            .map { meta, reads ->
                def dbs = resolveSylphDbs(meta, project_dbs, params.sylph_db)
                if (!dbs) {
                    error("No sylph database for sample ${meta.id}: set --sylph_db, or list a database for its project in --project_sylph_dbs")
                }
                tuple(meta + [sylph_dbs: dbs.collect { db -> file(db).name }.join(';')], reads, dbs.collect { db -> file(db, checkIfExists: true) })
            }
            .multiMap { meta, reads, dbs ->
                reads:     tuple(meta, reads)
                databases: dbs
            }
	def ch_kraken2_db = file(params.kraken2_db, checkIfExists: true)
	def kraken2_kraken2_out = KRAKEN2_KRAKEN2(ch_to_profile.reads, ch_kraken2_db, false, false)

        def sylph_profile_out = SYLPH_PROFILE(ch_to_profile.reads, ch_to_profile.databases)
        ch_sylph_profile = sylph_profile_out.profile_out
        ch_multiqc_files = ch_multiqc_files.mix(sylph_profile_out.profile_out)

        def ch_project_taxids = params.project_expected_taxids ? file(params.project_expected_taxids, checkIfExists: true) : []
        def species_check_out = SPECIES_CHECK(sylph_profile_out.profile_out, ch_species_id_manifest, ch_project_taxids)
        ch_species_check = species_check_out.result

        // .ifEmpty([]): collectFile emits nothing at all (not even the seed
        // header) if its input is empty - e.g. every sample is amplicon_16s -
        // so SAMPLE_SUMMARY still gets a usable value.
        ch_species_check_summary = species_check_out.result
            .map { _meta, file -> file }
            .collectFile(
                name: 'species_check_summary.tsv',
                storeDir: "${outdir}/species_id",
                sort: { file -> file.name },   // by file name (= sample), not full work-dir path, so row order is stable across runs
                seed: "sample\tplatform\tverdict\texpected_taxid\taccession\tspecies_taxid\tspecies_name\tadjusted_ani\ttaxonomic_abundance\tn_hits\texpected_source\tmatched_taxid\tsequence_abundance\tsylph_dbs\n"
            )
            .ifEmpty([])
    }

    emit:
    species_check         = ch_species_check          // tuple(meta, species_check.tsv) - one per profiled sample
    species_check_summary = ch_species_check_summary  // path (or []) - for SAMPLE_SUMMARY
    multiqc_files         = ch_multiqc_files   // tuple(meta, file) - per-sample MultiQC inputs, with meta for per-group reports
    sylph_profile         = ch_sylph_profile          // tuple(meta, profile.tsv) - empty channel if species ID is skipped
}
