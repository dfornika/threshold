//
// Alignment-based QC for isolates: align the clean reads to the reference
// genome of the sample with minimap2 and collect coverage, alignment and
// (paired Illumina) insert-size metrics with riker
// (https://github.com/fulcrumgenomics/riker).
//
// This complements the assembly-based QC (QUAST, CheckM2, BUSCO) with read-
// based measures: depth, how evenly it is spread, and how many reads map.
//
// Which samples: isolates that have a reference (REFERENCE_GENOME) - without
// one there is nothing to align to. Toggle with --skip_alignment_qc.
//
// The reference is usually a species representative, not the strain of the
// sample itself, so the fraction of the reference covered and the fraction of reads
// aligned also reflect real strain differences (plasmids and accessory genes
// absent from the reference will not map). Read them as indicators, not as
// pass/fail thresholds.
//
// The mean depth is also emitted as a GHRU-style depth table (Sample_id,
// Read_type, Depth) so speccheck can report it and check it against depth
// criteria.
//

include { GUNZIP            } from '../../modules/nf-core/gunzip/main'
include { SAMTOOLS_FAIDX    } from '../../modules/nf-core/samtools/faidx/main'
include { MINIMAP2_ALIGN    } from '../../modules/nf-core/minimap2/align/main'
include { RIKER_MULTI       } from '../../modules/nf-core/riker/multi/main'
include { ALIGNMENT_SUMMARY } from '../../modules/local/alignment_summary/main'

workflow ALIGNMENT_QC {

    take:
    ch_clean_reads       // tuple(meta, reads) - meta carries platform/sample_type from the samplesheet
    ch_sample_reference  // tuple(meta, reference fasta[.gz]) - from REFERENCE_GENOME; isolates with a reference only
    outdir

    main:

    def ch_alignment_summary = channel.value([])
    def ch_depth = channel.empty()

    if (!params.skip_alignment_qc) {
        //
        // Inner join by meta.id: only isolates that have a reference get
        // aligned. The reads and the reference come from different stages, so
        // never join on the whole meta map.
        //
        def ch_ref_by_id = ch_sample_reference.map { meta, ref -> tuple(meta.id, ref) }
        def ch_to_align = ch_clean_reads
            .filter { meta, _reads -> meta.sample_type == 'isolate' }
            .map { meta, reads -> tuple(meta.id, meta, reads) }
            .join(ch_ref_by_id)

        //
        // MODULE: Reference as a plain, indexed FASTA. Fetched references are
        // gzipped and a samplesheet reference may be either; samtools faidx
        // (which riker needs) cannot index plain gzip.
        //
        def ch_ref_branched = ch_to_align
            .map { _id, meta, _reads, ref -> tuple(meta, ref) }
            .branch { _meta, ref ->
                gzipped: ref.name.endsWith('.gz')
                plain:   true
            }
        def ch_ref_plain = ch_ref_branched.plain.mix(GUNZIP(ch_ref_branched.gzipped).gunzip)
        def faidx_out = SAMTOOLS_FAIDX(ch_ref_plain.map { meta, fasta -> tuple(meta, fasta, []) }, false)
        def ch_reference = ch_ref_plain
            .map { meta, fasta -> tuple(meta.id, fasta) }
            .join(faidx_out.fai.map { meta, fai -> tuple(meta.id, fai) })

        //
        // MODULE: minimap2 - sorted, indexed BAM. The preset is per platform
        // (see conf/modules.config); paired Illumina reads go in as a pair.
        //
        def ch_align_in = ch_to_align
            .map { id, meta, reads, _ref -> tuple(id, meta, reads) }
            .join(ch_reference)
            .multiMap { _id, meta, reads, fasta, _fai ->
                reads:     tuple(meta, reads)
                reference: tuple(meta, fasta)
            }
        def align_out = MINIMAP2_ALIGN(ch_align_in.reads, ch_align_in.reference, true, 'bai', false, false)

        //
        // MODULE: riker multi - one pass over the BAM for every collector.
        // The optional inputs (known-error VCF, intervals, hybrid capture,
        // RNA) are not used here.
        //
        def ch_riker_in = align_out.bam
            .map { meta, bam -> tuple(meta.id, meta, bam) }
            .join(align_out.index.map { meta, bai -> tuple(meta.id, bai) })
            .join(ch_reference)
            .multiMap { _id, meta, bam, bai, fasta, fai ->
                bam:       tuple(meta, bam, bai, [], [], [], [], [], [], [], [], [])
                reference: tuple(meta, fasta, fai)
            }
        def riker_out = RIKER_MULTI(ch_riker_in.bam, ch_riker_in.reference)

        //
        // MODULE: One normalised row per sample, collected into one table.
        // The insert-size metrics only exist for paired Illumina, so join
        // with remainder: true and `?: []`.
        //
        def ch_summary_in = riker_out.wgs_metrics
            .map { meta, wgs -> tuple(meta.id, meta, wgs) }
            .join(riker_out.alignment_metrics.map { meta, aln -> tuple(meta.id, aln) }, remainder: true)
            .join(riker_out.isize_metrics.map { meta, isize -> tuple(meta.id, isize) }, remainder: true)
            .filter { entry -> entry[1] != null }   // samples with WGS metrics only
            .map { _id, meta, wgs, aln, isize -> tuple(meta, wgs, aln ?: [], isize ?: []) }

        def alignment_summary_out = ALIGNMENT_SUMMARY(ch_summary_in)

        ch_depth = alignment_summary_out.depth

        // .ifEmpty([]): collectFile emits nothing if no sample reached this
        // stage (no isolates, or none with a reference), so SAMPLE_SUMMARY
        // still gets a usable value.
        ch_alignment_summary = alignment_summary_out.summary
            .map { _meta, file -> file }
            .collectFile(
                name: 'alignment_summary.tsv',
                storeDir: "${outdir}/summary/stage_tables",
                sort: { file -> file.name },
                seed: "sample\tplatform\tmean_depth\tmedian_depth\tfrac_ref_1x\tfrac_ref_10x\tfold_80_penalty\tfrac_reads_aligned\tmedian_insert_size\n"
            )
            .ifEmpty([])
    }

    emit:
    alignment_summary = ch_alignment_summary   // path (or []) - for SAMPLE_SUMMARY
    depth             = ch_depth               // tuple(meta, depth.tsv) - GHRU-style depth table, for speccheck
}
