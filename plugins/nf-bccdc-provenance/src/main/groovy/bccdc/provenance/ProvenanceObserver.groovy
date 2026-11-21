package bccdc.provenance

import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.locks.ReentrantLock

import groovy.json.JsonOutput
import groovy.transform.CompileDynamic
import groovy.util.logging.Slf4j
import nextflow.Session
import nextflow.processor.TaskRun
import nextflow.trace.TraceObserverV2
import nextflow.trace.event.FilePublishEvent
import nextflow.trace.event.TaskEvent
import org.yaml.snakeyaml.DumperOptions
import org.yaml.snakeyaml.Yaml

/**
 * Collects what each task did (executed, cached or failed) and every published
 * file, then at the end of the run writes BCCDC-PHL pipeline-provenance
 * records (https://github.com/BCCDC-PHL/pipeline-provenance-schema):
 *
 *   <directory>/<sample>_provenance.yml   one per sample
 *   <directory>/run_provenance.yml        tasks that don't belong to a sample
 *
 * Record building lives in ProvenanceBuilder; this class only turns Nextflow's
 * task objects into plain maps (TaskInfo) and writes the result.
 *
 * Dynamic and defensive on purpose: anything unexpected about a task is
 * skipped rather than failing the run - provenance must never sink a run.
 */
@Slf4j
@CompileDynamic
class ProvenanceObserver implements TraceObserverV2 {

    private final ProvenanceConfig config
    private Session session
    private final List<Map> tasks = []
    private final List<Map> published = []
    private final ReentrantLock lock = new ReentrantLock()

    ProvenanceObserver(ProvenanceConfig config) {
        this.config = config
    }

    @Override
    void onFlowCreate(Session session) {
        this.session = session
    }

    @Override
    void onTaskComplete(TaskEvent event) {
        record(event.handler.task, false)
    }

    @Override
    void onTaskCached(TaskEvent event) {
        record(event.handler.task, true)
    }

    @Override
    void onFilePublish(FilePublishEvent event) {
        if( event.source == null || event.target == null )
            return
        lock.lock()
        try { published << [source: normalize(event.source), target: normalize(event.target)] } finally { lock.unlock() }
    }

    @Override
    void onFlowComplete() {
        try {
            write()
        }
        catch( Throwable e ) {
            log.warn "nf-bccdc-provenance: failed to write provenance records: ${e.message}", e
        }
    }

    // -- collecting ----------------------------------------------------------

    private void record(TaskRun task, boolean cached) {
        Map info
        try {
            info = describe(task, cached)
        }
        catch( Throwable e ) {
            log.debug "nf-bccdc-provenance: couldn't describe task ${task?.name}: ${e.message}"
            return
        }
        lock.lock()
        try { tasks << info } finally { lock.unlock() }
    }

    /** A TaskInfo map - see ProvenanceBuilder for the fields it relies on. */
    private Map describe(TaskRun task, boolean cached) {
        final inputs = (task.inputs ?: [:]) as Map
        final outputs = (task.outputs ?: [:]) as Map
        return [
            name     : task.name,
            process  : simpleName(task.processor?.name),
            cached   : cached,
            success  : cached || isSuccess(task),
            sampleId : findSampleId(inputs),
            container: containerName(task),
            extArgs  : extArgs(task),
            tools    : versions(outputs),
            inputs   : fileInputs(inputs),
            outputs  : fileOutputs(outputs),
            workDir  : task.workDir ? normalize(task.workDir) : null,
        ]
    }

    private static String simpleName(String processName) {
        return processName ? processName.tokenize(':').last() : null
    }

    /**
     * The container image as the module declares it (e.g. a registry or
     * depot URL), rather than `task.container`, which under Apptainer/
     * Singularity is the path of the locally cached image file.
     */
    private static String containerName(TaskRun task) {
        try {
            final declared = task.config?.get('container')
            if( declared instanceof CharSequence && declared.toString().trim() )
                return declared.toString().trim()
        }
        catch( Throwable e ) {
            // fall back to the resolved name
        }
        return task.container
    }

    private static boolean isSuccess(TaskRun task) {
        try {
            return task.isSuccess()
        }
        catch( Throwable e ) {
            return task.exitStatus == 0
        }
    }

    /** The `id` of the first Map-valued input that has one (nf-core `meta`). */
    private static String findSampleId(Map inputs) {
        for( Object value : inputs.values() ) {
            if( value instanceof Map && (value as Map).containsKey('id') )
                return (value as Map).get('id')?.toString()
        }
        return null
    }

    /** `ext.args` from conf/modules.config, already resolved for this task. */
    private static String extArgs(TaskRun task) {
        final ext = task.config?.get('ext')
        final args = ext instanceof Map ? (ext as Map).get('args') : null
        return args instanceof CharSequence && args.toString().trim() ? args.toString().trim() : null
    }

    /**
     * Tool versions from nf-core-style `versions` outputs:
     * `tuple val(process), val(tool), eval(version)`. Each eval output's
     * value is the version; the value output just before it is the tool name.
     */
    private static List<Map> versions(Map outputs) {
        final List<Map> tools = []
        String lastValue = null
        outputs.each { param, value ->
            final kind = param?.getClass()?.simpleName
            if( kind == 'ValueOutParam' && value instanceof CharSequence ) {
                lastValue = value.toString()
            }
            else if( kind == 'CmdEvalParam' && lastValue && value != null ) {
                tools << [name: lastValue, version: value.toString().trim()]
                lastValue = null
            }
        }
        return tools
    }

    /** [param: <input name>, path: <original location>] for every file input. */
    private static List<Map> fileInputs(Map inputs) {
        final List<Map> files = []
        inputs.each { param, value ->
            if( param?.getClass()?.simpleName != 'FileInParam' )
                return
            final holders = value instanceof Collection ? value : [value]
            holders.each { holder ->
                final source = holder?.hasProperty('sourceObj') ? holder.sourceObj : null
                if( source instanceof Path )
                    files << [param: param.name, path: normalize(source as Path)]
            }
        }
        return files
    }

    private static List<Path> fileOutputs(Map outputs) {
        final List<Path> files = []
        outputs.each { param, value ->
            if( param?.getClass()?.simpleName != 'FileOutParam' )
                return
            final values = value instanceof Collection ? value : [value]
            values.each { v -> if( v instanceof Path ) files << normalize(v as Path) }
        }
        return files
    }

    private static Path normalize(Path path) {
        return path.toAbsolutePath().normalize()
    }

    // -- writing -------------------------------------------------------------

    private void write() {
        final outdir = session.outputDir ?: (session.params?.outdir ? (session.params.outdir as Path) : null)
        final configured = config.directory as Path
        final dir = configured.isAbsolute() ? configured : (outdir ? outdir.resolve(config.directory) : null)
        if( !dir ) {
            log.warn "nf-bccdc-provenance: no output directory - no provenance records written"
            return
        }
        Files.createDirectories(dir)

        final builder = new ProvenanceBuilder(
            pipelineRecord(),
            tasks,
            published,
            session.workDir ? normalize(session.workDir) : null,
            config.hashMaxSize?.toBytes() ?: 0L
        )

        final yaml = newYaml()
        builder.sampleIds().each { sampleId ->
            dir.resolve("${sampleId}_provenance.yml").text = yaml.dump(builder.sampleRecords(sampleId))
        }
        dir.resolve('run_provenance.yml').text = yaml.dump(builder.runRecords())

        if( config.debug )
            writeDebug(dir)

        log.info "nf-bccdc-provenance: wrote provenance for ${builder.sampleIds().size()} sample(s) to ${dir.toUriString()}"
    }

    private Map pipelineRecord() {
        final meta = session.workflowMetadata
        final Map record = [
            pipeline_name           : meta?.manifest?.name,
            pipeline_version        : meta?.manifest?.version,
            nextflow_session_id     : meta?.sessionId?.toString(),
            nextflow_run_name       : meta?.runName,
            timestamp_analysis_start: meta?.start?.toString(),
            nextflow_version        : meta?.nextflow?.version?.toString(),
        ]
        if( meta?.commitId )
            record.pipeline_commit = meta.commitId
        return record.findAll { k, v -> v != null }
    }

    private static Yaml newYaml() {
        final options = new DumperOptions()
        options.defaultFlowStyle = DumperOptions.FlowStyle.BLOCK
        options.indent = 2
        options.indicatorIndent = 0
        options.width = 1000
        return new Yaml(options)
    }

    private void writeDebug(Path dir) {
        dir.resolve('provenance_debug.jsonl').withWriter { w ->
            tasks.each { t -> w.writeLine(JsonOutput.toJson(t.collectEntries { k, v -> [k, v instanceof Path || v instanceof Collection ? v.toString() : v] })) }
            published.each { p -> w.writeLine(JsonOutput.toJson([source: p.source.toString(), target: p.target.toString()])) }
        }
    }
}
