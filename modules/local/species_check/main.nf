process SPECIES_CHECK {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.12' :
        'quay.io/biocontainers/python:3.12' }"

    input:
    tuple val(meta), path(profile)
    path  manifest, stageAs: 'manifest.csv?'   // optional: accession,organism,...,taxid,species_taxid,species_name

    output:
    tuple val(meta), path("*.species_check.tsv"), emit: result

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def manifest_arg = manifest ? "--manifest ${manifest}" : ''
    def expected = (meta.expected_species ?: '').toString().replace("'", "'\\''")
    """
    check_species.py \\
        --sample ${meta.id} \\
        --platform ${meta.platform} \\
        --sample-type ${meta.sample_type} \\
        --expected-species '${expected}' \\
        ${manifest_arg} \\
        ${profile} > ${prefix}.species_check.tsv
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf '%s\\t%s\\tstub\\tNA\\tNA\\tNA\\tNA\\tNA\\tNA\\t0\\n' "${meta.id}" "${meta.platform}" > ${prefix}.species_check.tsv
    """
}
