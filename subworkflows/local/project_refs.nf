//
// Per-project alignment references (--project_alignment_refs): a project whose
// samples are always one organism with a stable reference genome (SARS-CoV-2
// with Wuhan-Hu-1, M. tuberculosis with H37Rv) names that reference once,
// instead of on every samplesheet row or leaving it to the species-ID top hit.
//
//   --project_alignment_refs   CSV, project_id,reference (one row per project).
//                              reference is an NCBI assembly accession
//                              (GCF_ / GCA_, fetched and cached) or a path to a
//                              local FASTA, exactly as in the samplesheet's
//                              `reference` column.
//
// Reference selection, highest priority first (see REFERENCE_GENOME):
//   1. the sample's own samplesheet `reference`
//   2. its project's --project_alignment_refs entry
//   3. the species-ID top hit, when it agrees with the samplesheet
//
// A project reference is a deliberate choice, so unlike (3) it does not depend
// on the species-check verdict: a sample that doesn't belong to the project's
// organism is still aligned to it, and the species check flags the mismatch.
//
// Plain functions (no workflow), so they can be unit-tested
// (tests/project_refs.nf.test) and shared by the startup checks
// (utils_nfcore_threshold_pipeline) and REFERENCE_GENOME.
//

// An NCBI assembly accession (GCF_ / GCA_), as opposed to a path.
def isAssemblyAccession(value) {
    return value ==~ /^GC[AF]_\d+(\.\d+)?$/
}

// project_id -> reference (as written in the CSV), from the rows nf-schema's
// samplesheetToList returns. A project listed twice is an error (checked by
// projectRefProblems), so the last row wins here only in that case.
def parseProjectRefs(List rows) {
    def result = [:]
    rows.each { row -> result[row[0].toString().trim()] = row[1].toString().trim() }
    return result
}

// The reference to use for a sample: its own, else its project's, else the
// species-ID one (`observed`, may be null). Returns null for none.
def pickReference(Map meta, Map projectRefs, observed) {
    if (meta.reference) {
        return meta.reference.toString()
    }
    def projectRef = meta.project_id ? projectRefs[meta.project_id.toString()] : null
    return projectRef ?: observed
}

// Problems with --project_alignment_refs, checked at startup:
// [errors: [...], warnings: [...]]. `rows` are the raw CSV rows (so repeated
// projects are visible), `sample_metas` the samplesheet's meta maps.
// A reference that isn't an assembly accession is a path that must exist.
def projectRefProblems(List sample_metas, List rows) {
    def errors = []
    def warnings = []
    def refs = [:]   // project -> distinct references listed for it, in order
    rows.each { row ->
        def project = row[0].toString().trim()
        def ref = row[1].toString().trim()
        if (!refs.containsKey(project)) {
            refs[project] = []
        }
        if (!(ref in refs[project])) {
            refs[project].add(ref)
        }
    }
    refs.each { project, listed ->
        if (listed.size() > 1) {
            errors << "project '${project}' is listed with more than one reference in --project_alignment_refs (${listed.join(', ')}); give each project exactly one".toString()
        }
    }
    refs.each { project, listed ->
        listed.each { ref ->
            if (!isAssemblyAccession(ref) && !new File(ref).isFile()) {
                errors << "the reference for project '${project}' in --project_alignment_refs is neither an NCBI assembly accession (GCF_/GCA_...) nor an existing file: ${ref}".toString()
            }
        }
    }
    def used = sample_metas.collect { meta -> meta.project_id }.findAll { p -> p }.collect { p -> p.toString() }.unique()
    def unknown = refs.keySet() - used
    if (unknown) {
        warnings << "--project_alignment_refs lists project(s) with no samples in this samplesheet: ${unknown.join(', ')}".toString()
    }
    return [errors: errors, warnings: warnings]
}
