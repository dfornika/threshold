process GENOME_SIZE {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.12' :
        'quay.io/biocontainers/python:3.12' }"

    input:
    tuple val(meta), path(reference), val(taxid)   // reference optional (staged empty when absent); taxid may be 'NA'
    path  table
    val   default_genome_size

    output:
    tuple val(meta), path("*.genome_size.txt"), emit: size

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def reference_arg = reference ? "--reference ${reference}" : ''
    def override_arg  = meta.genome_size ? "--override ${meta.genome_size}" : ''
    def taxid_arg     = taxid && taxid != 'NA' ? "--taxid ${taxid}" : ''
    def table_arg     = table     ? "--table ${table}"         : ''
    """
    resolve_genome_size.py \\
        ${override_arg} \\
        ${reference_arg} \\
        ${taxid_arg} \\
        ${table_arg} \\
        --default ${default_genome_size} > ${prefix}.genome_size.txt
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf '%s\\tstub\\n' "${default_genome_size}" > ${prefix}.genome_size.txt
    """
}
