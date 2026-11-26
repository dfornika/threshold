//
// Per-sample BUSCO lineage selection. Pure functions (no channels, no
// processes) so they can be unit tested - see tests/busco_lineage.nf.test.
//
// A more specific lineage gives a more sensitive completeness estimate. The
// lineage is, first match wins:
//   1. the samplesheet busco_lineage;
//   2. the species-check name looked up in assets/busco_lineages.tsv - the
//      species row (two words) first, then its genus row;
//   3. the default lineage (--busco_default_lineage).
//
// --busco_db may hold only some lineages (a public health lab does not need
// all ~370). When the set of available lineages is given, a looked-up lineage
// that is not there falls back to the default, so an unexpected organism still
// gets a BUSCO result. A samplesheet busco_lineage is an explicit choice, so
// it is never replaced: if it is missing, BUSCO fails for that sample.
//

//
// Read assets/busco_lineages.tsv into a map of taxon name -> lineage.
// Comment lines and the header are skipped.
//
def loadBuscoLineageTable(lines) {
    def table = [:]
    lines.each { line ->
        if (!line || line.startsWith('#') || line.startsWith('taxon\t')) { return }
        def cols = line.split('\t')
        table[cols[0]] = cols[1]
    }
    return table
}

//
// species is the species-check name, or null when it is unusable (no hit, or
// it disagrees with the samplesheet). available is a collection of lineage
// names present in the BUSCO database, or null to skip the availability check.
//
def resolveBuscoLineage(meta, species, table, defaultLineage, available = null) {
    if (meta.busco_lineage) {
        return meta.busco_lineage
    }
    def lineage = defaultLineage
    if (species) {
        def genus = species.tokenize(' ')[0]
        lineage = table[species] ?: table[genus] ?: defaultLineage
    }
    if (available != null && !(lineage in available)) {
        return defaultLineage
    }
    return lineage
}
