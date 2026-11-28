//
// Per-group reports: one MultiQC report and one sample_summary.csv for each
// value of each field in --multiqc_group_by (e.g. each project_id, each tag),
// in addition to the all-samples ones. Published to
// ${outdir}/by_<field>/<value>/ (by_project, by_tag, ...).
//
// Groups come from the samplesheet: `project_id`, `sample_type`, `platform`
// (one value per sample) or `tags` (colon-separated, a sample is in every
// tag's group - the same convention as nf-core/seqinspector). A sample with
// no value for a field (e.g. no project_id) is in no group for that field.
//
// Each group also gets speccheck's report (report.csv, report.full.csv,
// report.html) over just its samples, in a speccheck/ subdirectory - only
// groups with at least one speccheck result (assembled isolates whose species
// is settled).
//
// Every per-sample MultiQC input keeps its sample's meta, so each group's
// report gets exactly its samples' files, plus the run-level extras
// (software versions, workflow summary, methods description).
//

include { MULTIQC as MULTIQC_GROUP } from '../../modules/nf-core/multiqc/main'
include { SPECCHECK_SUMMARY as SPECCHECK_GROUP } from '../../modules/local/speccheck_summary/main'
include { FILTER_SAMPLE_SUMMARY    } from '../../modules/local/filter_sample_summary/main'

// [[field, value], ...] groups a sample belongs to for the requested fields.
def groupKeys(Map meta, List<String> fields) {
    return fields.collectMany { field ->
        if( field == 'tags' )
            return meta.tags ? meta.tags.toString().tokenize(':').collect { tag -> [field, tag] } : []
        return meta[field] ? [[field, meta[field].toString()]] : []
    }
}

workflow GROUP_REPORTS {

    take:
    ch_samplesheet       // tuple(meta, reads) - samplesheet meta (id, project_id, tags, ...)
    ch_multiqc_files     // tuple(meta, file) - per-sample MultiQC inputs
    ch_multiqc_extra     // path - run-level MultiQC inputs (versions, workflow summary, methods)
    ch_sample_summary    // path - all-samples sample_summary.csv
    ch_speccheck_results // tuple(meta, <id>.speccheck.csv) - per-sample speccheck results (empty when speccheck didn't run)
    multiqc_config       // path or [] - pipeline MultiQC config
    multiqc_logo         // path or []

    main:

    def ch_speccheck_report = channel.empty()

    def fields = params.multiqc_group_by
        ? params.multiqc_group_by.toString().tokenize(',')*.trim().findAll { f -> f } as List<String>
        : [] as List<String>

    if (fields) {
        // [field, value] -> [sample IDs]
        def ch_members = ch_samplesheet
            .flatMap { meta, _reads -> groupKeys(meta, fields).collect { key -> tuple(key, meta.id) } }
            .groupTuple()

        // [field, value] -> [files]
        def ch_group_files = ch_multiqc_files
            .flatMap { meta, files -> groupKeys(meta, fields).collect { key -> tuple(key, files) } }
            .groupTuple()

        def ch_extra = ch_multiqc_extra.collect().map { files -> [files] }

        def ch_multiqc_in = ch_members
            .join(ch_group_files, remainder: true)   // a group may have no QC files yet still gets a report
            .filter { entry -> entry[1] != null }     // drop remainder-only entries (shouldn't happen)
            .combine(ch_extra)
            .map { key, _ids, files, extra ->
                tuple(
                    [id: "${key[0]}_${key[1]}", field: key[0], value: key[1]],
                    ((files ?: []) + extra).flatten().unique(),
                    multiqc_config,
                    multiqc_logo,
                    [],
                    []
                )
            }
        MULTIQC_GROUP(ch_multiqc_in)

        FILTER_SAMPLE_SUMMARY(
            ch_members
                .map { key, ids -> tuple([id: "${key[0]}_${key[1]}", field: key[0], value: key[1]], ids) }
                .combine(ch_sample_summary)
        )

        // speccheck's report per group: the same grouping, over the per-sample
        // speccheck results (a group with none gets no report).
        def ch_speccheck_in = ch_speccheck_results
            .flatMap { meta, csv -> groupKeys(meta, fields).collect { key -> tuple(key, csv) } }
            .groupTuple()
            .map { key, csvs -> tuple([id: "${key[0]}_${key[1]}", field: key[0], value: key[1]], csvs.sort { csv -> csv.name }) }
        ch_speccheck_report = SPECCHECK_GROUP(ch_speccheck_in).report
    }

    emit:
    speccheck_report = ch_speccheck_report   // tuple(meta, report.csv) per group
}
