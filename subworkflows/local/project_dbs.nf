//
// Which reference databases each sample is screened against, for the species
// classifiers that take one: sylph (--sylph_db, --project_sylph_dbs) and
// kraken2 (--kraken2_db, --project_kraken2_dbs).
//
//   --<tool>_db            the default database
//   --project_<tool>_dbs   optional CSV, project_id,<tool>_db (one-to-many): a
//                          sample whose `project_id` is listed is screened ONLY
//                          against the databases listed for it; every other
//                          sample uses the default. The reserved value
//                          `default` in the database column stands for the
//                          --<tool>_db database, so a project can add to the
//                          default instead of replacing it.
//
// How a sample's databases are used differs:
//   sylph    all of them in ONE `sylph profile` call, which resolves them
//            jointly - one coherent profile whose abundances sum to 100%
//            across databases (separate runs would each call their own top
//            hit 100%).
//   kraken2  one kraken2 run per database (it takes a single database); the
//            species check evaluates each report and keeps the best verdict.
//
// Plain functions (no workflow), so they can be unit-tested
// (tests/project_dbs.nf.test) and shared by the startup checks
// (utils_nfcore_threshold_pipeline) and SPECIES_ID.
//

// project_id -> [database, ...] (as written in the CSV, in order, without
// duplicates), from the rows nf-schema's samplesheetToList returns.
def parseProjectDbs(List rows) {
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
// with none (for sylph the startup checks make that an error; for kraken2 it
// just means the sample isn't classified with kraken2).
def resolveProjectDbs(Map meta, Map projectDbs, defaultDb) {
    def listed = meta.project_id ? projectDbs[meta.project_id.toString()] : null
    def entries = listed ?: ['default']
    return entries
        .collect { entry -> entry == 'default' ? defaultDb : entry }
        .findAll { db -> db }
        .collect { db -> db.toString() }
        .unique()
}

// Problems with the databases the samples would use, checked at startup:
// [errors: [...], warnings: [...]]. `tool` is 'sylph' or 'kraken2' (names the
// options in messages); `required` says every sample that gets screened
// (everything but amplicon_16s) must end up with at least one database.
//   errors:   a listed database doesn't exist (or, for kraken2, isn't a
//             database directory); `default` is used but --<tool>_db isn't
//             set; a required database is missing for a sample; two of a
//             sample's databases share a file name (they'd collide when staged
//             together, or in kraken2's per-database output names).
//   warnings: a project in the CSV has no samples in this run.
def projectDbProblems(List metas, Map projectDbs, defaultDb, String tool, boolean required) {
    def errors = []
    def warnings = []
    def dbOption = "--${tool}_db".toString()
    def csvOption = "--project_${tool}_dbs".toString()

    projectDbs.each { project, entries ->
        entries.each { entry ->
            if (entry == 'default') {
                if (!defaultDb) {
                    errors.add("project '${project}' lists the database 'default' in ${csvOption}, but ${dbOption} was not set".toString())
                }
            }
            else if (!file(entry).exists()) {
                errors.add("project '${project}': ${tool} database '${entry}' does not exist".toString())
            }
            else if (tool == 'kraken2' && !file(entry).resolve('hash.k2d').exists()) {
                errors.add("project '${project}': '${entry}' is not a kraken2 database directory (no hash.k2d inside)".toString())
            }
        }
    }

    def screened = metas.findAll { meta -> meta.sample_type != 'amplicon_16s' }

    if (required) {
        def without = screened.findAll { meta -> !resolveProjectDbs(meta, projectDbs, defaultDb) }.collect { meta -> meta.id.toString() }
        if (without) {
            def shown = without.take(5).join(', ') + (without.size() > 5 ? " and ${without.size() - 5} more" : '')
            errors.add("no ${tool} database for sample(s) ${shown}: set ${dbOption}, or list a database for their project in ${csvOption}".toString())
        }
    }

    def sets = screened.collect { meta -> resolveProjectDbs(meta, projectDbs, defaultDb) }.findAll { dbs -> dbs }.unique()
    sets.each { dbs ->
        def names = dbs.collect { db -> file(db).name }
        def clashes = names.findAll { name -> names.count(name) > 1 }.unique()
        if (clashes) {
            errors.add("${tool} databases ${dbs.join(', ')} include more than one named ${clashes.join(', ')}; rename one".toString())
        }
    }

    def used = metas.collect { meta -> meta.project_id?.toString() }.findAll { p -> p }.unique()
    def unused = projectDbs.keySet().findAll { project -> !(project in used) }
    if (unused) {
        warnings.add("${csvOption} lists project(s) with no samples in this samplesheet: ${unused.join(', ')}".toString())
    }

    return [errors: errors, warnings: warnings]
}
