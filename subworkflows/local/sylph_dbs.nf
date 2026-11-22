//
// Which sylph databases each sample is screened against.
//
//   --sylph_db            the default database
//   --project_sylph_dbs   optional CSV, project_id,sylph_db (one-to-many):
//                         a sample whose `project_id` is listed is screened
//                         ONLY against the databases listed for it; every
//                         other sample uses the default. The reserved value
//                         `default` in the sylph_db column stands for the
//                         --sylph_db database, so a project can add to the
//                         default instead of replacing it.
//
// All of a sample's databases go to ONE `sylph profile` call, which resolves
// them jointly: one coherent profile whose abundances sum to 100% across
// databases. Separate runs per database each report their own top hit as
// 100% and can't be combined.
//
// Plain functions (no workflow), so they can be unit-tested
// (tests/sylph_dbs.nf.test) and shared by the startup checks
// (utils_nfcore_threshold_pipeline) and SPECIES_ID.
//

// project_id -> [sylph_db, ...] (as written in the CSV, in order, without
// duplicates), from the rows nf-schema's samplesheetToList returns.
def parseProjectSylphDbs(List rows) {
    def result = [:]
    rows.each { row ->
        def project = row[0].toString().trim()
        def db = row[1].toString().trim()
        if (!result.containsKey(project)) {
            result[project] = []
        }
        if (!(db in result[project])) {
            result[project].add(db)
        }
    }
    return result
}

// The databases (path strings, unique, in order) a sample is screened
// against: its project's if listed, else the default. Empty if it ends up
// with none (the startup checks make that an error).
def resolveSylphDbs(Map meta, Map projectDbs, defaultDb) {
    def listed = meta.project_id ? projectDbs[meta.project_id.toString()] : null
    def entries = listed ?: ['default']
    return entries
        .collect { entry -> entry == 'default' ? defaultDb : entry }
        .findAll { db -> db }
        .collect { db -> db.toString() }
        .unique()
}

// Problems with the databases the samples would use, checked at startup:
// [errors: [...], warnings: [...]].
//   errors:   a listed database doesn't exist; `default` is used but
//             --sylph_db isn't set; a sample ends up with no database; two
//             of a sample's databases share a file name (they'd collide when
//             staged into the same task directory).
//   warnings: a project in the CSV has no samples in this run.
def sylphDbProblems(List metas, Map projectDbs, defaultDb) {
    def errors = []
    def warnings = []

    projectDbs.each { project, entries ->
        entries.each { entry ->
            if (entry == 'default') {
                if (!defaultDb) {
                    errors.add("project '${project}' lists the database 'default', but --sylph_db was not set".toString())
                }
            }
            else if (!file(entry).exists()) {
                errors.add("project '${project}': sylph database '${entry}' does not exist".toString())
            }
        }
    }

    def screened = metas.findAll { meta -> meta.sample_type != 'amplicon_16s' }

    def without = screened.findAll { meta -> !resolveSylphDbs(meta, projectDbs, defaultDb) }.collect { meta -> meta.id.toString() }
    if (without) {
        def shown = without.take(5).join(', ') + (without.size() > 5 ? " and ${without.size() - 5} more" : '')
        errors.add("no sylph database for sample(s) ${shown}: set --sylph_db, or list a database for their project in --project_sylph_dbs".toString())
    }

    def sets = screened.collect { meta -> resolveSylphDbs(meta, projectDbs, defaultDb) }.findAll { dbs -> dbs }.unique()
    sets.each { dbs ->
        def names = dbs.collect { db -> file(db).name }
        def clashes = names.findAll { name -> names.count(name) > 1 }.unique()
        if (clashes) {
            errors.add("sylph databases ${dbs.join(', ')} include more than one file named ${clashes.join(', ')}; they would collide when staged together - rename one".toString())
        }
    }

    def used = metas.collect { meta -> meta.project_id?.toString() }.findAll { p -> p }.unique()
    def unused = projectDbs.keySet().findAll { project -> !(project in used) }
    if (unused) {
        warnings.add("--project_sylph_dbs lists project(s) with no samples in this samplesheet: ${unused.join(', ')}".toString())
    }

    return [errors: errors, warnings: warnings]
}
