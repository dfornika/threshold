process SPECCHECK_COLLECT {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    // Seqera community container built from environment.yml (speccheck-qc
    // from PyPI + procps-ng). Not the upstream happykhan/speccheck image: it
    // has no `ps`, which Nextflow's task wrapper requires inside containers
    // when trace/timeline/report is enabled (the default).
    // Singularity/Apptainer: the SIF as a plain HTTPS blob (the same image as
    // oras://community.wave.seqera.io/library/procps-ng_pip_speccheck-qc:1d0d602d57974343),
    // like the other Seqera containers here. oras:// first requests a token
    // from Seqera's auth service, which answers 401 if the client sends any
    // credentials it doesn't accept (e.g. APPTAINER_DOCKER_USERNAME/PASSWORD
    // set for Docker Hub); the HTTPS blob needs no auth at all.
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/6b/6b244772387927d43c71a13f573e48c2f0eea6cb8c0fd43d369eaa42e55bb952/data' :
        'community.wave.seqera.io/library/procps-ng_pip_speccheck-qc:42455f7a85228765' }"

    input:
    // QC outputs speccheck can parse (QUAST report.tsv, sylph profile, fastp
    // JSON, CheckM2 quality report). Each is staged into its own numbered
    // directory: QUAST's and sylph's files are both named <sample>.tsv here.
    tuple val(meta), path(qc_files, stageAs: 'inputs/?/*'), val(organism)
    path criteria, stageAs: 'criteria.csv?'   // optional custom criteria file

    output:
    tuple val(meta), path("*.speccheck.csv"), emit: result
    tuple val("${task.process}"), val('speccheck'), eval("speccheck --version 2>&1 | sed 's/.*version: //'"), topic: versions, emit: versions_speccheck

    when:
    task.ext.when == null || task.ext.when

    script:
    def args          = task.ext.args ?: ''
    def prefix        = task.ext.prefix ?: "${meta.id}"
    def assembly_type = meta.platform == 'nanopore' ? 'long' : 'short'
    def criteria_arg  = criteria ? "--criteria-file ${criteria}" : ''
    def species       = organism.toString().replace("'", "'\\''")
    // The species goes in both --organism (selects speccheck's criteria rows)
    // and a metadata `species` column: speccheck's QualiBact compatibility
    // check reads the species from a column, and with none it falls back to
    // E. coli thresholds.
    """
    printf 'sample_id,species\\n%s,%s\\n' '${meta.id}' '${species}' > metadata.csv

    speccheck collect inputs/*/* \\
        --sample '${meta.id}' \\
        --organism '${species}' \\
        --assembly-type ${assembly_type} \\
        --metadata metadata.csv \\
        ${criteria_arg} \\
        ${args} \\
        --output-file ${prefix}.speccheck.csv
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf 'sample_id,speccheck_qc\\n%s,PASS\\n' '${meta.id}' > ${prefix}.speccheck.csv
    """
}
