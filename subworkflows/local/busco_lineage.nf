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
// it disagrees with the samplesheet).
//
def resolveBuscoLineage(meta, species, table, defaultLineage) {
    if (meta.busco_lineage) {
        return meta.busco_lineage
    }
    if (species) {
        def genus = species.tokenize(' ')[0]
        return table[species] ?: table[genus] ?: defaultLineage
    }
    return defaultLineage
}
