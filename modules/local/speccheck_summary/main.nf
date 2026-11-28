process SPECCHECK_SUMMARY {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/6b/6b244772387927d43c71a13f573e48c2f0eea6cb8c0fd43d369eaa42e55bb952/data' :
        'community.wave.seqera.io/library/procps-ng_pip_speccheck-qc:42455f7a85228765' }"

    input:
    tuple val(meta), path(collected, stageAs: 'collected/*')   // per-sample CSVs from SPECCHECK_COLLECT; meta is the group ([id, field, value]) or [id: 'all']

    output:
    tuple val(meta), path("speccheck_report/report.csv"),      emit: report
    tuple val(meta), path("speccheck_report/report.full.csv"), emit: report_full
    tuple val(meta), path("speccheck_report/report.html"),     emit: html
    tuple val("${task.process}"), val('speccheck'), eval("speccheck --version 2>&1 | sed 's/.*version: //'"), topic: versions, emit: versions_speccheck

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    // --qualibact-compat adds a qualibact_qc column: the sample's metrics
    // against its species' pinned QualiBact scheme (PASS/WARN/FAIL).
    """
    speccheck summary collected \\
        --output speccheck_report \\
        --plot \\
        --qualibact-compat \\
        ${args}
    """

    stub:
    """
    mkdir -p speccheck_report
    printf 'sample_id,overall_qc,speccheck_qc,qualibact_qc,reason_summary\\n' > speccheck_report/report.csv
    touch speccheck_report/report.full.csv speccheck_report/report.html
    """
}
