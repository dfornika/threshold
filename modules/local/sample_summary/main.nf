process SAMPLE_SUMMARY {
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.12' :
        'quay.io/biocontainers/python:3.12' }"

    input:
    path samples                     // sample manifest (sample, platform, sample_type, expected_taxid) - always present, anchors the row list
    path dehost, stageAs: 'dehost_summary.tsv?'
    path species_check, stageAs: 'species_check_summary.tsv?'
    path assembly, stageAs: 'assembly_summary.tsv?'
    path speccheck, stageAs: 'speccheck_report.csv?'

    output:
    path "sample_summary.csv", emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def dehost_arg        = dehost        ? "--dehost ${dehost}"               : ''
    def species_check_arg = species_check ? "--species-check ${species_check}" : ''
    def assembly_arg      = assembly      ? "--assembly ${assembly}"           : ''
    def speccheck_arg     = speccheck     ? "--speccheck ${speccheck}"         : ''
    """
    build_sample_summary.py \\
        --samples ${samples} \\
        ${dehost_arg} \\
        ${species_check_arg} \\
        ${assembly_arg} \\
        ${speccheck_arg} \\
        > sample_summary.csv
    """

    stub:
    """
    touch sample_summary.csv
    """
}
