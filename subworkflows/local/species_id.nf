//
// Species identification + check against the samplesheet: sylph profiles
// each sample against the reference-genome database, then SPECIES_CHECK
// compares the top hit with the samplesheet's `expected_taxid`. What a
// sample *is* comes from the samplesheet; this stage is there to catch
// sample swaps, contamination and mislabelling.
//
// Skipped for `amplicon_16s` samples: a whole-genome database recovers
// almost nothing from ~1.5kb of one gene, so any hit would be noise.
//

include { SYLPH_PROFILE } from '../../modules/nf-core/sylph/profile/main'
include { SPECIES_CHECK } from '../../modules/local/species_check/main'

workflow SPECIES_ID {

    take:
    ch_clean_reads          // tuple(meta, reads)
    ch_species_id_manifest  // path (or []) - accession -> organism/taxonomy CSV
    outdir

    main:

    def ch_multiqc_files = channel.empty()
    def ch_species_check = channel.empty()
    def ch_species_check_summary = channel.value([])

    if (!params.skip_species_id) {
        if (!params.sylph_db) {
            error("Species ID is enabled but --sylph_db was not set. Provide a sylph genome database (.syldb) or run with --skip_species_id.")
        }
        def ch_sylph_db = channel.value(file(params.sylph_db, checkIfExists: true))
        def ch_to_profile = ch_clean_reads.filter { meta, _reads -> meta.sample_type != 'amplicon_16s' }

        SYLPH_PROFILE(ch_to_profile, ch_sylph_db)
        ch_multiqc_files = ch_multiqc_files.mix(SYLPH_PROFILE.out.profile_out.map { _meta, file -> file })

        SPECIES_CHECK(SYLPH_PROFILE.out.profile_out, ch_species_id_manifest)
        ch_species_check = SPECIES_CHECK.out.result

        // .ifEmpty([]): collectFile emits nothing at all (not even the seed
        // header) if its input is empty - e.g. every sample is amplicon_16s -
        // so SAMPLE_SUMMARY still gets a usable value.
        ch_species_check_summary = SPECIES_CHECK.out.result
            .map { _meta, file -> file }
            .collectFile(
                name: 'species_check_summary.tsv',
                storeDir: "${outdir}/species_id",
                sort: { file -> file.name },   // by file name (= sample), not full work-dir path, so row order is stable across runs
                seed: "sample\tplatform\tverdict\texpected_taxid\taccession\tspecies_taxid\tspecies_name\tadjusted_ani\ttaxonomic_abundance\tn_hits\n"
            )
            .ifEmpty([])
    }

    emit:
    species_check         = ch_species_check          // tuple(meta, species_check.tsv) - one per profiled sample
    species_check_summary = ch_species_check_summary  // path (or []) - for SAMPLE_SUMMARY
    multiqc_files         = ch_multiqc_files
}
