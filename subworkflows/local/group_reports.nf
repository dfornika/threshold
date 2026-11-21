//
// Per-group reports: one MultiQC report and one sample_summary.csv for each
// value of each field in --multiqc_group_by (e.g. each project_id, each tag),
// in addition to the all-samples ones. Published to
// ${outdir}/groups/<field>/<value>/.
//
// Groups come from the samplesheet: `project_id`, `sample_type`, `platform`
// (one value per sample) or `tags` (colon-separated, a sample is in every
// tag's group - the same convention as nf-core/seqinspector). A sample with
// no value for a field (e.g. no project_id) is in no group for that field.
//
// Every per-sample MultiQC input keeps its sample's meta, so each group's
// report gets exactly its samples' files, plus the run-level extras
// (software versions, workflow summary, methods description).
//

include { MULTIQC as MULTIQC_GROUP } from '../../modules/nf-core/multiqc/main'
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
    multiqc_config       // path or [] - pipeline MultiQC config
    multiqc_logo         // path or []

    main:

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
    }
}
