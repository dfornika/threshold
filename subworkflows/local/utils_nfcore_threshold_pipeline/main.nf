//
// Subworkflow with functionality specific to the BCCDC-PHL/threshold pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { samplesheetToList         } from 'plugin/nf-schema'
include { parseProjectDbs           } from '../project_dbs'
include { projectDbProblems         } from '../project_dbs'
include { paramsHelp                } from 'plugin/nf-schema'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW TO INITIALISE PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process MAX_SAMPLES_CHECK {
    tag "max_samples_error"
    publishDir "${params.outdir}/error"

    input:
    val sample_count // number of samples provided to mikrokondo

    output:
    path output_file_path, emit: failure_report

    exec:
    def output_file =  "max_samples_exceeded.error.txt"
    output_file_path = task.workDir.resolve(output_file)
    file_out = file(output_file_path)
    file_out.text = """
    ${sample_count} samples were selected, which exceeds the maximum number of samples: ${params.max_samples}
    Please reduce samples to ${params.max_samples}.

    If running from command-line make sure that --max_samples 0
    """.stripIndent().trim()
}


workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    monochrome_logs   // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    input             //  string: Path to input samplesheet
    help              // boolean: Display help message and exit
    help_full         // boolean: Show the full help message
    show_hidden       // boolean: Show hidden parameters in the help message

    main:

    ch_versions = channel.empty()

    prepareRunInfoDirs(outdir)

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //

    def before_text = ""
    def after_text = ""
    if (monochrome_logs) {
        before_text = before_text.replaceAll(/\033\[[0-9;]*m/, '')
    }

    command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input samplesheet.csv --outdir <OUTDIR>"

    UTILS_NFSCHEMA_PLUGIN (
        workflow,
        validate_params,
        null,
        help,
        help_full,
        show_hidden,
        before_text,
        after_text,
        command
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )

    //
    // Create channel from input file provided through params.input
    //

    def samplesheet_rows = samplesheetToList(input, "${projectDir}/assets/schema_input.json")

    // expected_taxid can only be checked via the species-ID manifest
    // (accession -> taxid): sylph's own output has no taxonomy. Fail up
    // front rather than partway through the run.
    if (!params.skip_species_id && !params.species_id_manifest && samplesheet_rows.any { row -> row[0].expected_taxid }) {
        error("The samplesheet has expected_taxid values, but --species_id_manifest was not set. The manifest (accession -> taxid/species_taxid) is needed to check them; provide one or remove expected_taxid.")
    }

    // --project_expected_taxids: validate its contents up front (schema), and
    // like expected_taxid it can only be checked with a manifest.
    if (params.project_expected_taxids) {
        def project_rows = samplesheetToList(params.project_expected_taxids, "${projectDir}/assets/schema_project_expected_taxids.json")
        if (!params.skip_species_id && !params.species_id_manifest && project_rows) {
            error("--project_expected_taxids was given, but --species_id_manifest was not set. The manifest (accession -> taxid/species_taxid) is needed to check expected taxa; provide one or drop --project_expected_taxids.")
        }
        def listed = project_rows.collect { row -> row[0].toString() }.unique()
        def used = samplesheet_rows.collect { row -> row[0].project_id }.findAll { p -> p }.collect { p -> p.toString() }.unique()
        def unknown = listed - used
        if (unknown) {
            log.warn("--project_expected_taxids lists project(s) with no samples in this samplesheet: ${unknown.join(', ')}")
        }
    }

    // Species-ID databases: --sylph_db / --kraken2_db are the defaults,
    // --project_sylph_dbs / --project_kraken2_dbs give projects their own.
    // sylph: every non-16S sample must end up with at least one. kraken2 is
    // optional: samples with no kraken2 database just aren't classified with
    // it. Either way, listed databases must exist and be usable together
    // (see subworkflows/local/project_dbs.nf).
    if (!params.skip_species_id) {
        def db_errors = []
        def sample_metas = samplesheet_rows.collect { row -> row[0] }
        [
            [tool: 'sylph', default_db: params.sylph_db, csv: params.project_sylph_dbs, required: true],
            [tool: 'kraken2', default_db: params.kraken2_db, csv: params.project_kraken2_dbs, required: false],
        ].each { cfg ->
            def rows = cfg.csv ? samplesheetToList(cfg.csv, "${projectDir}/assets/schema_project_${cfg.tool}_dbs.json") : []
            def checks = projectDbProblems(sample_metas, parseProjectDbs(rows), cfg.default_db, cfg.tool, cfg.required)
            checks.warnings.each { warning -> log.warn(warning) }
            db_errors.addAll(checks.errors)
        }
        if (db_errors) {
            error("Problem with the species-ID databases:\n  - " + db_errors.join("\n  - "))
        }
    }

    def ch_samplesheet = channel
        .fromList(samplesheet_rows)
        .map {
            meta, fastq_1, fastq_2 ->
                if (meta.platform == 'nanopore' && fastq_2) {
                    error("Please check input samplesheet -> Nanopore samples must be single-end (no fastq_2): ${meta.id}")
                }
                if (!fastq_2) {
                    return [ meta.id, meta + [ single_end:true ], [ fastq_1 ] ]
                } else {
                    return [ meta.id, meta + [ single_end:false ], [ fastq_1, fastq_2 ] ]
                }
        }
        .groupTuple()
        .map { samplesheet ->
            validateInputSamplesheet(samplesheet)
        }
        .map {
            meta, fastqs ->
                return [ meta, fastqs.flatten() ]
        }

    emit:
    samplesheet = ch_samplesheet
    versions    = ch_versions
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    multiqc_report  //  string: Path to MultiQC report

    main:
    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def multiqc_reports = multiqc_report.toList()

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(
                summary_params,
                email,
                email_on_fail,
                plaintext_email,
                outdir,
                monochrome_logs,
                multiqc_reports.getVal(),
            )
        }

        completionSummary(monochrome_logs)

    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs for common issues: https://nf-co.re/docs/running/troubleshooting"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Validate channels from input samplesheet
//
def validateInputSamplesheet(input) {
    def (metas, fastqs) = input[1..2]

    // Check that multiple runs of the same sample are of the same datatype i.e. single-end / paired-end
    def endedness_ok = metas.collect{ meta -> meta.single_end }.unique().size == 1
    if (!endedness_ok) {
        error("Please check input samplesheet -> Multiple runs of a sample must be of the same datatype i.e. single-end or paired-end: ${metas[0].id}")
    }

    // Every samplesheet-provided field must agree across a sample's runs -
    // they describe the sample, not the run.
    ['platform', 'sample_type', 'expected_taxid', 'reference', 'genome_size', 'busco_lineage', 'project_id', 'tags', 'publish_dehosted_reads'].each { key ->
        if (metas.collect { meta -> meta[key] }.unique().size() != 1) {
            error("Please check input samplesheet -> Multiple runs of a sample must have the same ${key}: ${metas[0].id}")
        }
    }

    return [ metas[0], fastqs ]
}
//
// Create the directory nf-prov copies the pipeline files into: it does not
// create it, and the first copy would otherwise turn the path into a plain file.
//
def prepareRunInfoDirs(outdir) {
    file("${outdir}/run_info/ro-crate").mkdirs()
}

//
// Generate methods description for MultiQC
//
def toolCitationText() {
    // TODO nf-core: Optionally add in-text citation tools to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "Tool (Foo et al. 2023)" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def citation_text = [
            "Tools used in the workflow included:",
            "FastQC (Andrews 2010),",
            "MultiQC (Ewels et al. 2016)",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    // TODO nf-core: Optionally add bibliographic entries to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "<li>Author (2023) Pub name, Journal, DOI</li>" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def reference_text = [
            "<li>Andrews S, (2010) FastQC, URL: https://www.bioinformatics.babraham.ac.uk/projects/fastqc/).</li>",
            "<li>Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics , 32(19), 3047–3048. doi: /10.1093/bioinformatics/btw354</li>"
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familiar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    if (meta.manifest_map.doi) {
        // Using a loop to handle multiple DOIs
        // Removing `https://doi.org/` to handle pipelines using DOIs vs DOI resolvers
        // Removing ` ` since the manifest.doi is a string and not a proper list
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    // TODO nf-core: Only uncomment below if logic in toolCitationText/toolBibliographyText has been filled!
    // meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    // meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}
