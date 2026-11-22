process SPECIES_CHECK {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.12' :
        'quay.io/biocontainers/python:3.12' }"

    input:
    tuple val(meta), path(profile)
    path  manifest, stageAs: 'manifest.csv?'   // accession,...,taxid,species_taxid,species_name[,lineage_taxids] - required when there are expected taxa
    path  project_taxids, stageAs: 'project_expected_taxids.csv?'   // optional: project_id,expected_taxid (one-to-many)

    output:
    tuple val(meta), path("*.species_check.tsv"), emit: result

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def manifest_arg = manifest ? "--manifest ${manifest}" : ''
    def expected_arg = meta.expected_taxid ? "--expected-taxid ${meta.expected_taxid}" : ''
    // The script applies the precedence: the sample's own expected_taxid,
    // else its project's taxids from project_expected_taxids.csv.
    def dbs_arg      = meta.sylph_dbs ? "--sylph-dbs '${meta.sylph_dbs}'" : ''
    def project_arg  = project_taxids && meta.project_id ? "--project-id '${meta.project_id}' --project-expected-taxids ${project_taxids}" : ''
    """
    check_species.py \\
        --sample ${meta.id} \\
        --platform ${meta.platform} \\
        --sample-type ${meta.sample_type} \\
        ${expected_arg} \\
        ${project_arg} \\
        ${dbs_arg} \\
        ${manifest_arg} \\
        ${profile} > ${prefix}.species_check.tsv
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf '%s\\t%s\\tstub\\tNA\\tNA\\tNA\\tNA\\tNA\\tNA\\t0\\tNA\\tNA\\tNA\\tNA\\n' "${meta.id}" "${meta.platform}" > ${prefix}.species_check.tsv
    """
}
