//
// Reference genome per isolate sample - used by assembly QC (QUAST genome
// fraction) and as the genome-size hint for the assemblers. Only `isolate`
// samples are assembled, so only they get a reference, and nothing is
// resolved or fetched at all when --skip_assembly is set.
//
// Source, in priority order:
//   1. the samplesheet's `reference` column - a local FASTA path, used as-is,
//      or an NCBI assembly accession (GCF_/GCA_...), fetched;
//   2. otherwise, the accession of sylph's top hit, when SPECIES_CHECK found
//      it consistent with the samplesheet (verdict `match`, or `not_checked`
//      when no expected_taxid was given) - never for a `mismatch`.
//
// Fetched genomes are cached by accession in --reference_genome_cache_dir
// (Nextflow storeDir), so each is downloaded once across runs. A fetch failure
// degrades gracefully (see conf/modules.config's FETCH_REFERENCE_GENOME
// errorStrategy) - the sample just has no reference. Toggle fetching with
// --skip_reference_genome_fetch; local FASTA paths are used either way.
//

include { FETCH_REFERENCE_GENOME } from '../../modules/local/fetch_reference_genome/main'

def isAssemblyAccession(value) {
    return value ==~ /^GC[AF]_\d+(\.\d+)?$/
}

workflow REFERENCE_GENOME {

    take:
    ch_clean_reads     // tuple(meta, reads)
    ch_species_check   // tuple(meta, species_check.tsv) - from SPECIES_ID

    main:

    def ch_isolates = ch_clean_reads
        .filter { meta, _reads -> meta.sample_type == 'isolate' && !params.skip_assembly }
        .map { meta, _reads -> tuple(meta.id, meta) }

    // Observed accession from the species check, only where it's consistent
    // with the samplesheet - and only if it really is an assembly accession:
    // it comes from a database file name, so it's never treated as a path
    // (only the samplesheet's `reference` column can be a path). Join by
    // meta.id, never on the whole meta map: meta maps captured at different
    // points need not be identical.
    def ch_observed = ch_species_check.map { meta, file ->
        def cols = file.text.trim().split('\t')
        def consistent = cols[2] in ['match', 'not_checked']
        if (meta.sample_type == 'isolate' && !params.skip_assembly && consistent && cols[4] != 'NA' && !isAssemblyAccession(cols[4])) {
            log.warn("${meta.id}: species-ID top hit '${cols[4]}' isn't an NCBI assembly accession, so no reference will be fetched for it")
        }
        tuple(meta.id, (consistent && isAssemblyAccession(cols[4])) ? cols[4] : null)
    }

    def ch_source = ch_isolates
        .join(ch_observed, remainder: true)
        .filter { entry -> entry[1] != null }   // drop species-check rows for non-isolates
        .map { _id, meta, observed -> tuple(meta, meta.reference ? meta.reference.toString() : observed) }
        .branch { _meta, reference ->
            none:      !reference
            accession: isAssemblyAccession(reference)
            fasta:     true
        }

    def ch_local_reference = ch_source.fasta.map { meta, path -> tuple(meta, file(path, checkIfExists: true)) }

    def ch_fetched_reference = channel.empty()
    if (!params.skip_reference_genome_fetch && !params.skip_assembly) {
        if (!params.reference_genome_cache_dir) {
            error("Reference genome fetch is enabled but --reference_genome_cache_dir was not set. Provide a cache directory or run with --skip_reference_genome_fetch.")
        }
        FETCH_REFERENCE_GENOME(ch_source.accession.map { _meta, accession -> accession }.unique())

        def ch_reference_by_accession = FETCH_REFERENCE_GENOME.out.fasta
            .map { fasta -> tuple(fasta.name.replace('.fasta.gz', ''), fasta) }
        ch_fetched_reference = ch_source.accession
            .map { meta, accession -> tuple(accession, meta) }
            .combine(ch_reference_by_accession, by: 0)
            .map { _accession, meta, fasta -> tuple(meta, fasta) }
    }

    emit:
    sample_reference = ch_local_reference.mix(ch_fetched_reference)   // tuple(meta, reference FASTA) - isolates with a reference only
}
