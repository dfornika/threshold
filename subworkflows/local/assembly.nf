//
// Draft genome assembly + assembly QC, for `isolate` samples only. Two dedicated single-platform assemblers (no hybrid - the samplesheet
// is one platform per sample), routed by meta.platform:
//   - Illumina  -> SHOVILL   (SPAdes/SKESA wrapper)
//   - Nanopore  -> DRAGONFLYE (Flye + Racon/Medaka polish + reorientation)
// then platform-agnostic QC on the resulting assembly:
//   - QUAST    (contiguity: #contigs, N50, total length, largest contig)
//   - CHECKM2  (completeness + contamination) - only when --checkm2_db is set,
//     since its DIAMOND database is a large external download.
//   - BUSCO    (single-copy ortholog completeness) - only when --busco_db is
//     set (a directory of pre-downloaded BUSCO lineage datasets), so runs
//     need no network access. The lineage is chosen per sample - see below.
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
include { BUSCO_BUSCO       } from '../../modules/nf-core/busco/busco/main'
include { ASSEMBLY_SUMMARY  } from '../../modules/local/assembly_summary/main'

workflow ASSEMBLY_ANALYSIS {

    take:
    ch_clean_reads          // tuple(meta, reads) - meta carries platform/sample_type from the samplesheet
    ch_sample_reference     // tuple(meta, reference fasta) - from REFERENCE_GENOME; isolates with a reference only
    ch_sample_gff           // tuple(meta, reference gff3) - from REFERENCE_GENOME; fetched references with NCBI annotation only
    ch_species_check        // tuple(meta, species_check tsv) - from SPECIES_ID; taxid fallback for the gsize hint
    outdir

    main:

    def ch_multiqc_files = channel.empty()
    def ch_assembly_summary = channel.value([])
    def ch_quast_report = channel.empty()
    def ch_checkm2_report = channel.empty()
    def ch_busco_report = channel.empty()

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
        def genome_size_out = GENOME_SIZE(ch_size_in, ch_genome_size_table, params.default_genome_size)

        def ch_reads_sized = ch_gated.assemble
            .map { meta, reads -> tuple(meta.id, meta, reads) }
            .join(genome_size_out.size.map { meta, file -> tuple(meta.id, file.text.trim().split('\t')[0]) })
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
        def shovill_out = SHOVILL(ch_to_assemble.short_reads)
        def ch_shovill = shovill_out.contigs.map { meta, fa -> tuple(meta + [assembler: 'shovill'], fa) }

        //
        // MODULE: Dragonflye (Nanopore) - Flye + Racon/Medaka polish +
        // reorientation. shortreads input is empty (ONT-only, no hybrid). Gets
        // --gsize from meta.genome_size (see conf/modules.config).
        //
        def dragonflye_out = DRAGONFLYE(ch_to_assemble.long_reads.map { meta, reads -> tuple(meta, [], reads) })
        // The module emits every *.fa: the final assembly (<id>.fa) and, when
        // dnaapler succeeded, <id>.reoriented.fa. Keep only the final one, or
        // CheckM2 reports two rows per sample (which speccheck rejects) and
        // QUAST gets two assemblies.
        def ch_dragonflye = dragonflye_out.contigs.map { meta, fas ->
            def final_fa = [fas].flatten().find { fa -> !fa.name.endsWith('.reoriented.fa') }
            tuple(meta + [assembler: 'dragonflye'], final_fa)
        }

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
        // The reference's GFF3 annotation, when there is one (fetched NCBI
        // references only - not local FASTAs or unannotated assemblies), goes
        // in as QUAST's `--features`, adding genomic-feature counts (complete
        // and partial genes recovered). Joined by meta.id the same way.
        //
        def ch_gff_by_id = ch_sample_gff.map { m, gff -> tuple(m.id, gff) }
        def ch_quast_in = ch_assembly
            .map { meta, fa -> tuple(meta.id, meta, fa) }
            .join(ch_ref_by_id, remainder: true)
            .join(ch_gff_by_id, remainder: true)
            .filter { entry -> entry[1] != null }   // keep only assemblies, not remainder-only references/GFFs
            .multiMap { _id, meta, fa, reference, gff ->
                assembly:  tuple(meta, fa)
                reference: tuple(meta, reference ?: [])
                // QUAST's --features only means something against the
                // reference the annotation belongs to, so never pass a GFF
                // without its reference.
                gff:       tuple(meta, (reference && gff) ? gff : [])
            }
        def quast_out = QUAST(ch_quast_in.assembly, ch_quast_in.reference, ch_quast_in.gff)
        ch_multiqc_files = ch_multiqc_files.mix(quast_out.tsv)
        ch_quast_report = quast_out.tsv

        //
        // MODULE: CheckM2 - completeness + contamination. Only runs when a
        // database is provided (large external download).
        //
        def ch_checkm2 = channel.empty()
        if (params.checkm2_db) {
            def ch_checkm2_db = channel.value([[id: 'checkm2_db'], file(params.checkm2_db, checkIfExists: true)])
            def checkm2_predict_out = CHECKM2_PREDICT(ch_assembly.map { meta, fa -> tuple(meta, fa) }, ch_checkm2_db)
            ch_checkm2 = checkm2_predict_out.checkm2_tsv
            ch_checkm2_report = ch_checkm2
            ch_multiqc_files = ch_multiqc_files.mix(checkm2_predict_out.checkm2_tsv)
        }

        //
        // MODULE: BUSCO - single-copy ortholog completeness. Only runs when a
        // directory of BUSCO lineage datasets is provided (--busco_db). The
        // lineage is the most specific one for the sample: the samplesheet's
        // busco_lineage if given, else the species-check name (species row,
        // then genus row of assets/busco_lineages.tsv - generated by
        // bin/make_busco_lineage_table.py), else --busco_default_lineage.
        // As with speccheck, the species-check name is only used when it
        // agrees with the samplesheet (or there was nothing to check against).
        //
        def ch_busco = channel.empty()
        if (params.busco_db) {
            def busco_table = [:]
            file("${projectDir}/assets/busco_lineages.tsv", checkIfExists: true).eachLine { line ->
                if (line.startsWith('#') || line.startsWith('taxon\t')) { return }
                def cols = line.split('\t')
                busco_table[cols[0]] = cols[1]
            }

            def ch_organism_by_id = ch_species_check.map { m, tsv ->
                def cols = tsv.text.trim().split('\t')
                tuple(m.id, (cols[2] in ['match', 'not_checked'] && cols[6] != 'NA') ? cols[6] : null)
            }

            def ch_busco_in = ch_assembly
                .map { meta, fa -> tuple(meta.id, meta, fa) }
                .join(ch_organism_by_id, remainder: true)
                .filter { entry -> entry[1] != null }   // assemblies only, not remainder-only species rows
                .multiMap { _id, meta, fa, species ->
                    def genus = species ? species.tokenize(' ')[0] : null
                    assembly: tuple(meta, fa)
                    lineage:  meta.busco_lineage ?: busco_table[species] ?: busco_table[genus] ?: params.busco_default_lineage
                }

            def ch_busco_db = channel.value(file(params.busco_db, checkIfExists: true))
            def busco_out = BUSCO_BUSCO(ch_busco_in.assembly, 'genome', ch_busco_in.lineage, ch_busco_db, [], true)
            ch_busco = busco_out.short_summaries_txt
            ch_busco_report = ch_busco
            ch_multiqc_files = ch_multiqc_files.mix(busco_out.short_summaries_txt)
        }

        //
        // Pair each assembly's QUAST tsv with its CheckM2 tsv (if any) by
        // sample id (and likewise the BUSCO summary) and normalise into one row
        // per sample. remainder: true + `?: []` so samples flow through even
        // when CheckM2 or BUSCO did not run (no db) - always join by meta.id,
        // never on the whole meta map.
        //
        def ch_summary_in = quast_out.tsv
            .map { meta, tsv -> tuple(meta.id, meta, tsv) }
            .join(ch_checkm2.map { meta, tsv -> tuple(meta.id, tsv) }, remainder: true)
            .join(ch_busco.map { meta, txt -> tuple(meta.id, txt) }, remainder: true)
            .map { _id, meta, quast, checkm2, busco -> tuple(meta, quast, checkm2 ?: [], busco ?: []) }

        def assembly_summary_out = ASSEMBLY_SUMMARY(ch_summary_in)

        // .ifEmpty([]): see subworkflows/local/species_id.nf for why -
        // collectFile emits nothing at all if no sample reached assembly (e.g.
        // no isolates this run), so SAMPLE_SUMMARY still
        // gets a usable value.
        ch_assembly_summary = assembly_summary_out.summary
            .map { _meta, file -> file }
            .collectFile(
                name: 'assembly_summary.tsv',
                storeDir: "${outdir}/assembly",
                sort: { file -> file.name },   // by file name (= sample), not full work-dir path, so row order is stable across runs
                seed: "sample\tplatform\tassembler\tn_contigs\ttotal_length\tlargest_contig\tn50\tgenome_fraction\tcompleteness\tcontamination\tfeatures_complete\tfeatures_partial\tbusco_complete\tbusco_duplicated\tbusco_missing\tbusco_lineage\n"
            )
            .ifEmpty([])
    }

    emit:
    multiqc_files     = ch_multiqc_files   // tuple(meta, file) - per-sample MultiQC inputs, with meta for per-group reports
    assembly_summary  = ch_assembly_summary // path (or []) - for SAMPLE_SUMMARY
    quast_report      = ch_quast_report     // tuple(meta, report.tsv) - one per assembled sample; empty if assembly is skipped
    checkm2_report    = ch_checkm2_report   // tuple(meta, quality_report.tsv) - only when --checkm2_db is set
    busco_report      = ch_busco_report     // tuple(meta, short_summary.*.txt) - only when --busco_db is set
}
