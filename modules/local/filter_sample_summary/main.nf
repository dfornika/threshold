process FILTER_SAMPLE_SUMMARY {
    tag "${meta.field}: ${meta.value}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.12' :
        'quay.io/biocontainers/python:3.12' }"

    input:
    tuple val(meta), val(sample_ids), path(summary, stageAs: 'all_samples/*')   // meta: [id, field, value]; the group's sample IDs; the all-samples sample_summary.csv (staged apart: the output has the same name)

    output:
    tuple val(meta), path("sample_summary.csv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    // Keep the header and this group's rows. `sample` is the first column
    // and sample IDs can't contain commas (schema pattern ^\S+$ and no
    // quoting), so a plain field match is enough.
    """
    printf '%s\\n' ${sample_ids.collect { id -> "'${id}'" }.join(' ')} > samples.txt
    awk -F',' 'NR == FNR { keep[\$1] = 1; next } FNR == 1 || (\$1 in keep)' samples.txt ${summary} > sample_summary.csv
    """

    stub:
    """
    head -n 1 ${summary} > sample_summary.csv
    """
}
