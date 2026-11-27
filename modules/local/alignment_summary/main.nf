process ALIGNMENT_SUMMARY {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.12' :
        'quay.io/biocontainers/python:3.12' }"

    input:
    tuple val(meta), path(wgs), path(alignment), path(isize)   // alignment / isize optional (staged as '' when absent)

    output:
    tuple val(meta), path("*.alignment_summary.tsv"), emit: summary
    tuple val(meta), path("*.depth.tsv"),             emit: depth, optional: true   // GHRU-style depth table for speccheck; absent when there is no mean depth

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix        = task.ext.prefix ?: "${meta.id}"
    def alignment_arg = alignment ? "--alignment ${alignment}" : ''
    def isize_arg     = isize     ? "--isize ${isize}"         : ''
    """
    parse_riker.py \\
        --sample ${meta.id} \\
        --platform ${meta.platform} \\
        --wgs ${wgs} \\
        ${alignment_arg} \\
        ${isize_arg} \\
        --depth-out ${prefix}.depth.tsv > ${prefix}.alignment_summary.tsv
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf '%s\\t%s\\tNA\\tNA\\tNA\\tNA\\tNA\\tNA\\tNA\\n' "${meta.id}" "${meta.platform}" > ${prefix}.alignment_summary.tsv
    printf 'Sample_id\\tRead_type\\tDepth\\n%s\\tshort\\t0\\n' "${meta.id}" > ${prefix}.depth.tsv
    """
}
