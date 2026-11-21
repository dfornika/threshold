//
// Draft genome assembly + assembly QC, for `isolate` samples only. Two dedicated single-platform assemblers (no hybrid - the samplesheet
// is one platform per sample), routed by meta.platform:
//   - Illumina  -> SHOVILL   (SPAdes/SKESA wrapper)
//   - Nanopore  -> DRAGONFLYE (Flye + Racon/Medaka polish + reorientation)
// then platform-agnostic QC on the resulting assembly:
//   - QUAST    (contiguity: #contigs, N50, total length, largest contig)
//   - CHECKM2  (completeness + contamination) - only when --checkm2_db is set,
//     since its DIAMOND database is a large external download.
//
// Gated on the samplesheet's sample_type == 'isolate' (and, for Illumina,
// paired-end reads - Shovill needs pairs). Toggle the whole stage with
// --skip_assembly. See docs/testing.md.
//

include { GENOME_SIZE       } from '../../modules/local/genome_size/main'
include { SHOVILL           } from '../../modules/nf-core/shovill/main'
include { DRAGONFLYE        } from '../../modules/nf-core/dragonflye/main'
include { QUAST             } from '../../modules/nf-core/quast/main'
include { CHECKM2_PREDICT   } from '../../modules/nf-core/checkm2/predict/main'
include { ASSEMBLY_SUMMARY  } from '../../modules/local/assembly_summary/main'

workflow ASSEMBLY_ANALYSIS {

    take:
    ch_clean_reads          // tuple(meta, reads) - meta carries platform/sample_type from the samplesheet
    ch_sample_reference     // tuple(meta, reference fasta) - from REFERENCE_GENOME; isolates with a reference only
    ch_species_check        // tuple(meta, species_check tsv) - from SPECIES_ID; taxid fallback for the gsize hint
    outdir

    main:

    def ch_multiqc_files = channel.empty()
    def ch_assembly_summary = channel.value([])

    if (!params.skip_assembly) {
        //
        // Gate: only isolates get assembled. Single-end Illumina isolates
        // can't go through Shovill, so they're skipped with a warning.
        //
        def ch_gated = ch_clean_reads.branch { meta, _reads ->
            assemble: meta.sample_type == 'isolate' && !(meta.platform == 'illumina' && meta.single_end)
            skip:     true
        }
        ch_gated.skip
            .filter { meta, _reads -> meta.sample_type == 'isolate' }
            .subscribe { meta, _reads -> log.warn("Skipping assembly for ${meta.id}: single-end Illumina reads are not supported by Shovill") }

        //
        // MODULE: Genome-size hint. Resolve a --gsize per sample - the
        // samplesheet's genome_size, else reference length, else a coarse
        // taxid lookup, else a generic default - and fold it into
        // meta.genome_size for the assemblers (see docs/testing.md). This
        // avoids the assemblers' own genome-size estimation, which produced a
        // catastrophic ~1kb estimate on shallow ONT data during validation;
        // it also skips Shovill's kmc estimation step (which segfaulted on
        // shallow Illumina data). Assembly quality is insensitive to this
        // within ~2x, so a ballpark is enough.
        //
        // ch_sample_reference / ch_species_check meta were captured
        // earlier in the pipeline, so join by meta.id (remainder: true - a
        // sample may have no reference and/or no species check). The rejoin of the
        // resolved size back onto the reads is a plain inner join, since
        // GENOME_SIZE runs for every assemble sample.
        //
        def ch_ref_by_id  = ch_sample_reference.map { m, fa -> tuple(m.id, fa) }
        def ch_taxid_by_id = ch_species_check.map { m, tsv -> tuple(m.id, tsv.text.trim().split('\t')[5]) }

        def ch_size_in = ch_gated.assemble
            .map { meta, _reads -> tuple(meta.id, meta) }
            .join(ch_ref_by_id, remainder: true)
            .join(ch_taxid_by_id, remainder: true)
            .filter { entry -> entry[1] != null }   // keep only real assemble samples, not remainder-only ref/species rows
            .map { _id, meta, reference, taxid -> tuple(meta, reference ?: [], taxid ?: 'NA') }

        def ch_genome_size_table = channel.value(file("${projectDir}/assets/genome_sizes.tsv", checkIfExists: true))
        GENOME_SIZE(ch_size_in, ch_genome_size_table, params.default_genome_size)

        def ch_reads_sized = ch_gated.assemble
            .map { meta, reads -> tuple(meta.id, meta, reads) }
            .join(GENOME_SIZE.out.size.map { meta, file -> tuple(meta.id, file.text.trim().split('\t')[0]) })
            .map { _id, meta, reads, gsize -> tuple(meta + [genome_size: gsize], reads) }

        //
        // Route the assemble branch by platform (same branch idiom the read-QC
        // stage uses for fastp vs fastplong).
        //
        def ch_to_assemble = ch_reads_sized.branch { meta, _reads ->
            long_reads:  meta.platform == 'nanopore'
            short_reads: meta.platform == 'illumina'
        }

        //
        // MODULE: Shovill (Illumina) - SPAdes/SKESA wrapper with routine-
        // bacterial defaults. Gets --gsize from meta.genome_size (see
        // conf/modules.config).
        //
        SHOVILL(ch_to_assemble.short_reads)
        def ch_shovill = SHOVILL.out.contigs.map { meta, fa -> tuple(meta + [assembler: 'shovill'], fa) }

        //
        // MODULE: Dragonflye (Nanopore) - Flye + Racon/Medaka polish +
        // reorientation. shortreads input is empty (ONT-only, no hybrid). Gets
        // --gsize from meta.genome_size (see conf/modules.config).
        //
        DRAGONFLYE(ch_to_assemble.long_reads.map { meta, reads -> tuple(meta, [], reads) })
        def ch_dragonflye = DRAGONFLYE.out.contigs.map { meta, fa -> tuple(meta + [assembler: 'dragonflye'], fa) }

        def ch_assembly = ch_shovill.mix(ch_dragonflye)   // tuple(meta, assembly fasta)

        //
        // MODULE: QUAST - contiguity + (when a reference is available)
        // reference-based metrics. Pair each assembly with the reference
        // for its sample (join by meta.id, remainder: true
        // - a sample may have no reference if fetch was off/failed), then
        // multiMap into QUAST's three separate inputs so they stay aligned
        // per-sample. QUAST's module runs reference-based (`-r`) for samples
        // whose `reference` path is non-empty and reference-free for the rest,
        // per-item, so a mix of with/without-reference samples is handled in
        // one call. The reference is usually a species representative, not the
        // sample's own strain, so genome fraction / NGA50 are robust but the
        // misassembly / mismatch counts reflect strain divergence too, not
        // just assembly error - see docs/testing.md (they stay in the full
        // QUAST report, only genome fraction is surfaced in the summary).
        //
        def ch_quast_in = ch_assembly
            .map { meta, fa -> tuple(meta.id, meta, fa) }
            .join(ch_ref_by_id, remainder: true)
            .filter { entry -> entry[1] != null }   // keep only assemblies, not remainder-only references
            .multiMap { _id, meta, fa, reference ->
                assembly:  tuple(meta, fa)
                reference: tuple(meta, reference ?: [])
                gff:       tuple([:], [])
            }
        QUAST(ch_quast_in.assembly, ch_quast_in.reference, ch_quast_in.gff)
        ch_multiqc_files = ch_multiqc_files.mix(QUAST.out.tsv.map { _meta, file -> file })

        //
        // MODULE: CheckM2 - completeness + contamination. Only runs when a
        // database is provided (large external download).
        //
        def ch_checkm2 = channel.empty()
        if (params.checkm2_db) {
            def ch_checkm2_db = channel.value([[id: 'checkm2_db'], file(params.checkm2_db, checkIfExists: true)])
            CHECKM2_PREDICT(ch_assembly.map { meta, fa -> tuple(meta, fa) }, ch_checkm2_db)
            ch_checkm2 = CHECKM2_PREDICT.out.checkm2_tsv
            ch_multiqc_files = ch_multiqc_files.mix(CHECKM2_PREDICT.out.checkm2_tsv.map { _meta, file -> file })
        }

        //
        // Pair each assembly's QUAST tsv with its CheckM2 tsv (if any) by
        // sample id and normalise into one row per sample. remainder: true +
        // `?: []` so samples flow through even when CheckM2 didn't run (no db)
        // - always join by meta.id, never on the whole meta map.
        //
        def ch_summary_in = QUAST.out.tsv
            .map { meta, tsv -> tuple(meta.id, meta, tsv) }
            .join(ch_checkm2.map { meta, tsv -> tuple(meta.id, tsv) }, remainder: true)
            .map { _id, meta, quast, checkm2 -> tuple(meta, quast, checkm2 ?: []) }

        ASSEMBLY_SUMMARY(ch_summary_in)

        // .ifEmpty([]): see subworkflows/local/species_id.nf for why -
        // collectFile emits nothing at all if no sample reached assembly (e.g.
        // no isolates this run), so SAMPLE_SUMMARY still
        // gets a usable value.
        ch_assembly_summary = ASSEMBLY_SUMMARY.out.summary
            .map { _meta, file -> file }
            .collectFile(
                name: 'assembly_summary.tsv',
                storeDir: "${outdir}/assembly",
                sort: true,
                seed: "sample\tplatform\tassembler\tn_contigs\ttotal_length\tlargest_contig\tn50\tgenome_fraction\tcompleteness\tcontamination\n"
            )
            .ifEmpty([])
    }

    emit:
    multiqc_files     = ch_multiqc_files
    assembly_summary  = ch_assembly_summary // path (or []) - for SAMPLE_SUMMARY
}
