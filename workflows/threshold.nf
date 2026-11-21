/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { MULTIQC                       } from '../modules/nf-core/multiqc/main'
include { READ_QC_AND_DEHOSTING         } from '../subworkflows/local/read_qc_and_dehosting'
include { SPECIES_ID                    } from '../subworkflows/local/species_id'
include { REFERENCE_GENOME              } from '../subworkflows/local/reference_genome'
include { ASSEMBLY_ANALYSIS             } from '../subworkflows/local/assembly'
include { SAMPLE_SUMMARY                } from '../modules/local/sample_summary/main'
include { paramsSummaryMap       } from 'plugin/nf-schema'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_threshold_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow THRESHOLD {

    take:
    ch_samplesheet // channel: samplesheet read in from --input
    multiqc_config
    multiqc_logo
    multiqc_methods_description
    outdir

    main:

    def ch_versions = channel.empty()
    def ch_multiqc_files = channel.empty()

    //
    // What each sample is (platform, sample_type, expected_taxid, and
    // optionally reference / genome_size) comes from the samplesheet - see
    // assets/schema_input.json. Nothing downstream tries to infer it.
    //

    //
    // SUBWORKFLOW: Read QC + dehosting - FastQC/fastp/fastplong on the raw
    // reads, dehosting, then a measurement-only FastQC/fastp/fastplong pass
    // on the final reads that flow to every downstream analysis.
    //
    READ_QC_AND_DEHOSTING(ch_samplesheet, outdir)
    def ch_clean_reads = READ_QC_AND_DEHOSTING.out.reads
    ch_multiqc_files   = ch_multiqc_files.mix(READ_QC_AND_DEHOSTING.out.multiqc_files)

    //
    // SUBWORKFLOW: Species ID (sylph) + check against the samplesheet's
    // expected_taxid - catches sample swaps / contamination / mislabelling.
    //
    def ch_species_id_manifest = params.species_id_manifest ? file(params.species_id_manifest, checkIfExists: true) : []
    SPECIES_ID(ch_clean_reads, ch_species_id_manifest, outdir)
    ch_multiqc_files = ch_multiqc_files.mix(SPECIES_ID.out.multiqc_files)

    //
    // SUBWORKFLOW: Reference genome per isolate - the samplesheet's
    // `reference` (local FASTA or fetched accession), else the species-ID
    // top hit when it agrees with the samplesheet.
    //
    REFERENCE_GENOME(ch_clean_reads, SPECIES_ID.out.species_check)

    //
    // SUBWORKFLOW: Draft genome assembly + assembly QC - isolates only,
    // routed by platform to Shovill (Illumina) / Dragonflye (Nanopore), then
    // QUAST + (optional) CheckM2.
    //
    ASSEMBLY_ANALYSIS(
        ch_clean_reads,
        REFERENCE_GENOME.out.sample_reference,
        REFERENCE_GENOME.out.sample_gff,
        SPECIES_ID.out.species_check,
        outdir
    )
    ch_multiqc_files = ch_multiqc_files.mix(ASSEMBLY_ANALYSIS.out.multiqc_files)

    //
    // MODULE: One-row-per-sample summary CSV. The sample manifest anchors
    // which rows exist; every other input is optional ([] if that stage was
    // skipped or reached no samples).
    //
    SAMPLE_SUMMARY(
        READ_QC_AND_DEHOSTING.out.sample_manifest,
        READ_QC_AND_DEHOSTING.out.dehost_summary,
        SPECIES_ID.out.species_check_summary,
        ASSEMBLY_ANALYSIS.out.assembly_summary
    )

    //
    // Collate and save software versions
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name:  'gx-threshold_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    //
    // MODULE: MultiQC
    //
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    def ch_summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def ch_workflow_summary = channel.value(paramsSummaryMultiqc(ch_summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    def ch_multiqc_custom_methods_description = multiqc_methods_description
        ? file(multiqc_methods_description, checkIfExists: true)
        : file("${projectDir}/assets/methods_description_template.yml", checkIfExists: true)
    def ch_methods_description = channel.value(methodsDescriptionText(ch_multiqc_custom_methods_description))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: true))
    MULTIQC(
        ch_multiqc_files.flatten().collect().map { files ->
            [
                [id: 'gx-threshold'],
                files,
                multiqc_config
                    ? file(multiqc_config, checkIfExists: true)
                    : file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true),
                multiqc_logo ? file(multiqc_logo, checkIfExists: true) : [],
                [],
                [],
            ]
        }
    )
    emit:multiqc_report = MULTIQC.out.report.map { _meta, report -> [report] }.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
