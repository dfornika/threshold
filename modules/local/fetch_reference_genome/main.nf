process FETCH_REFERENCE_GENOME {
    tag "$accession"
    label 'process_low'
    // storeDir (not publishDir - deliberately no entry in conf/modules.config
    // for this process) caches into --reference_genome_cache_dir directly, a
    // persistent, shared location outside any single run's outdir.
    storeDir "${params.reference_genome_cache_dir}/${accession}"

    conda "${moduleDir}/environment.yml"
    // StaPH-B's image rather than biocontainers: the biocontainers
    // ncbi-datasets-cli image stopped at v14.26 (2023), which no longer works
    // against NCBI's current API. Fully qualified, since the pipeline's
    // default container registry is quay.io.
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'docker://staphb/ncbi-datasets:18.39.0' :
        'docker.io/staphb/ncbi-datasets:18.39.0' }"

    input:
    val accession

    output:
    path("${accession}.fasta.gz"),                              emit: fasta
    path("${accession}.gff.gz"), optional: true,                emit: gff
    path("${accession}.assembly_report.jsonl"),                 emit: assembly_report
    path("${accession}.sequence_report.jsonl"),                 emit: sequence_report
    // No versions-topic emit here: storeDir only supports plain `val`/`path`
    // outputs, not `tuple` (which the versions-topic convention used
    // elsewhere in this pipeline requires) - confirmed by Nextflow refusing
    // to run this process otherwise ("storeDir can only be used with `val`
    // and `path` outputs"). The datasets version is pinned in
    // environment.yml/the container tag instead.

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    // NCBI Datasets: one call returns the assembly FASTA, its GFF3 annotation
    // and metadata, all from the same assembly record - so FASTA and GFF use
    // the same sequence names (e.g. NC_000913.3 in both for GCF_000005845.2).
    // Works for RefSeq (GCF_) and GenBank (GCA_) accessions. Unannotated
    // assemblies (common for MAGs) come back without a GFF, so that output is
    // optional; a missing FASTA is an error.
    """
    datasets download genome accession ${accession} \\
        --include genome,gff3,seq-report \\
        --filename ${accession}.zip \\
        --no-progressbar \\
        ${args}

    unzip -q -o ${accession}.zip -d ${accession}_dataset
    data_dir=${accession}_dataset/ncbi_dataset/data

    fna=\$(find "\$data_dir/${accession}" -name '*_genomic.fna' | head -n 1)
    if [ -z "\$fna" ] || [ ! -s "\$fna" ]; then
        echo "No genome sequence retrieved for assembly accession ${accession}" >&2
        exit 1
    fi
    gzip -c "\$fna" > ${accession}.fasta.gz

    if [ -s "\$data_dir/${accession}/genomic.gff" ]; then
        gzip -c "\$data_dir/${accession}/genomic.gff" > ${accession}.gff.gz
    else
        echo "No GFF annotation available for ${accession} - continuing with FASTA only" >&2
    fi

    cp "\$data_dir/assembly_data_report.jsonl" ${accession}.assembly_report.jsonl
    cp "\$data_dir/${accession}/sequence_report.jsonl" ${accession}.sequence_report.jsonl

    rm -rf ${accession}.zip ${accession}_dataset
    """

    stub:
    """
    echo '' | gzip > ${accession}.fasta.gz
    echo '' | gzip > ${accession}.gff.gz
    touch ${accession}.assembly_report.jsonl ${accession}.sequence_report.jsonl
    """
}
