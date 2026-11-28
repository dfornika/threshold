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
include { ALIGNMENT_QC                  } from '../subworkflows/local/alignment_qc'
include { SPECCHECK                     } from '../subworkflows/local/speccheck'
include { SAMPLE_SUMMARY                } from '../modules/local/sample_summary/main'
include { GROUP_REPORTS                 } from '../subworkflows/local/group_reports'
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
    def read_qc_and_dehosting_out = READ_QC_AND_DEHOSTING(ch_samplesheet, outdir)
    def ch_clean_reads = read_qc_and_dehosting_out.reads
    ch_multiqc_files   = ch_multiqc_files.mix(read_qc_and_dehosting_out.multiqc_files)

    //
    // SUBWORKFLOW: Species ID (sylph) + check against the samplesheet's
    // expected_taxid - catches sample swaps / contamination / mislabelling.
    //
    def ch_species_id_manifest = params.species_id_manifest ? file(params.species_id_manifest, checkIfExists: true) : []
    def species_id_out = SPECIES_ID(ch_clean_reads, ch_species_id_manifest, outdir)
    ch_multiqc_files = ch_multiqc_files.mix(species_id_out.multiqc_files)

    //
    // SUBWORKFLOW: Reference genome per isolate - the samplesheet's
    // `reference` (local FASTA or fetched accession), else the species-ID
    // top hit when it agrees with the samplesheet.
    //
    def reference_genome_out = REFERENCE_GENOME(ch_clean_reads, species_id_out.species_check)

    //
    // SUBWORKFLOW: Draft genome assembly + assembly QC - isolates only,
    // routed by platform to Shovill (Illumina) / Dragonflye (Nanopore), then
    // QUAST + (optional) CheckM2 and BUSCO.
    //
    def assembly_analysis_out = ASSEMBLY_ANALYSIS(
        ch_clean_reads,
        reference_genome_out.sample_reference,
        reference_genome_out.sample_gff,
        species_id_out.species_check,
        outdir
    )
    ch_multiqc_files = ch_multiqc_files.mix(assembly_analysis_out.multiqc_files)

    //
    // SUBWORKFLOW: Alignment-based QC - align the reads of each isolate to its
    // reference with minimap2 and collect coverage / alignment / insert-size
    // metrics with riker. Isolates with a reference only.
    //
    def alignment_qc_out = ALIGNMENT_QC(
        ch_clean_reads,
        reference_genome_out.sample_reference,
        outdir
    )

    //
    // SUBWORKFLOW: Species-specific QC thresholds (incl. QualiBact) with
    // speccheck, for assembled isolates whose species is settled - checks the
    // QUAST / sylph / fastp / CheckM2 / BUSCO outputs above against criteria for the
    // sample's species.
    //
    def speccheck_out = SPECCHECK(
        species_id_out.species_check,
        assembly_analysis_out.quast_report,
        assembly_analysis_out.checkm2_report,
        assembly_analysis_out.busco_report,
        species_id_out.sylph_profile,
        read_qc_and_dehosting_out.fastp_json,
        alignment_qc_out.depth
    )

    //
    // MODULE: One-row-per-sample summary CSV. The sample manifest anchors
    // which rows exist; every other input is optional ([] if that stage was
    // skipped or reached no samples).
    //
    def sample_summary_out = SAMPLE_SUMMARY(
        read_qc_and_dehosting_out.sample_manifest,
        read_qc_and_dehosting_out.dehost_summary,
        species_id_out.species_check_summary,
        assembly_analysis_out.assembly_summary,
        alignment_qc_out.alignment_summary,
        speccheck_out.report
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
            storeDir: "${outdir}/run_info/pipeline_info",
            name:  'threshold_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    //
    // MODULE: MultiQC - all samples. ch_multiqc_files holds per-sample inputs
    // as tuple(meta, file) (the meta drives the per-group reports below);
    // run-level inputs (software versions, workflow summary, methods
    // description) go in every report.
    //
    def ch_summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def ch_workflow_summary = channel.value(paramsSummaryMultiqc(ch_summary_params))
    def ch_multiqc_custom_methods_description = multiqc_methods_description
        ? file(multiqc_methods_description, checkIfExists: true)
        : file("${projectDir}/assets/methods_description_template.yml", checkIfExists: true)
    def ch_methods_description = channel.value(methodsDescriptionText(ch_multiqc_custom_methods_description))
    def ch_multiqc_extra_files = ch_collated_versions
        .mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
        .mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: true))

    def ch_multiqc_config = multiqc_config
        ? file(multiqc_config, checkIfExists: true)
        : file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true)
    def ch_multiqc_logo = multiqc_logo ? file(multiqc_logo, checkIfExists: true) : []

    def multiqc_out = MULTIQC(
        ch_multiqc_files.map { _meta, files -> files }
            .mix(ch_multiqc_extra_files)
            .flatten()
            .collect()
            .map { files -> [[id: 'threshold'], files, ch_multiqc_config, ch_multiqc_logo, [], []] }
    )

    //
    // SUBWORKFLOW: per-group reports (--multiqc_group_by, e.g. each
    // project_id and tag) - a MultiQC report and sample_summary.csv per group,
    // in ${outdir}/by_<field>/<value>/, alongside the all-samples ones.
    //
    GROUP_REPORTS(
        ch_samplesheet,
        ch_multiqc_files,
        ch_multiqc_extra_files,
        sample_summary_out.summary,
        speccheck_out.results,
        ch_multiqc_config,
        ch_multiqc_logo
    )
    emit:multiqc_report = multiqc_out.report.map { _meta, report -> [report] }.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
