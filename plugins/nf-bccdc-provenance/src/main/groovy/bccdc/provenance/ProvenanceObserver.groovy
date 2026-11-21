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

/**
 * SPIKE observer: records what Nextflow exposes about each task, so we can
 * see whether everything the BCCDC pipeline-provenance schema needs is
 * available to a plugin:
 *
 *   - which sample a task ran for (a `meta` map with an `id` in its inputs)
 *   - the process name and the task's container
 *   - tool arguments (`ext.args` from conf/modules.config)
 *   - tool versions (the `eval(...)` outputs nf-core modules emit to the
 *     `versions` topic)
 *   - cached (-resume) tasks as well as executed ones
 *   - published files, and which task produced them
 *
 * At the end of the run it writes everything to
 * <outdir>/pipeline_info/bccdc_provenance_spike.jsonl: one JSON object per
 * line - a `run` record, then one `task` record per task, then one `publish`
 * record per published file.
 *
 * Deliberately dynamic and defensive: the point is to find out how things are
 * represented, so anything unexpected is recorded (class name + toString)
 * rather than failing.
 */
@Slf4j
@CompileDynamic
class ProvenanceObserver implements TraceObserverV2 {

    private Session session
    private final List<Map> taskRecords = []
    private final List<Map> publishRecords = []
    private final ReentrantLock lock = new ReentrantLock()

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
        final rec = [
            type  : 'publish',
            source: event.source?.toString(),
            target: event.target?.toString(),
        ]
        lock.lock()
        try { publishRecords << rec } finally { lock.unlock() }
    }

    @Override
    void onFlowComplete() {
        try {
            write()
        }
        catch( Throwable e ) {
            log.warn "nf-bccdc-provenance (spike): failed to write report: ${e.message}", e
        }
    }

    // -- recording -----------------------------------------------------------

    private void record(TaskRun task, boolean cached) {
        Map rec
        try {
            rec = describeTask(task, cached)
        }
        catch( Throwable e ) {
            rec = [type: 'task', name: safe { task.name }, error: "${e.class.name}: ${e.message}".toString()]
        }
        lock.lock()
        try { taskRecords << rec } finally { lock.unlock() }
    }

    private Map describeTask(TaskRun task, boolean cached) {
        final inputs = safe { task.inputs }
        final outputs = safe { task.outputs }
        return [
            type      : 'task',
            name      : task.name,
            process   : safe { task.processor?.name },
            tag       : safe { task.config?.get('tag')?.toString() },
            cached    : cached,
            exit      : safe { task.exitStatus },
            hash      : safe { task.hash?.toString() },
            workDir   : safe { task.workDir?.toString() },
            container : safe { task.container },
            sample_id : findSampleId(inputs),
            ext_args  : describeValue(safe { extArgs(task) }),
            inputs    : describeParams(inputs),
            outputs   : describeParams(outputs),
        ]
    }

    /** `ext.args` as configured in conf/modules.config (may be a closure). */
    private Object extArgs(TaskRun task) {
        final ext = task.config?.get('ext')
        if( ext instanceof Map )
            return ext.get('args')
        return ext
    }

    /** The `id` of the first Map-valued input that has one (nf-core `meta`). */
    private String findSampleId(Object inputs) {
        if( !(inputs instanceof Map) )
            return null
        for( Object value : (inputs as Map).values() ) {
            if( value instanceof Map && (value as Map).containsKey('id') )
                return (value as Map).get('id')?.toString()
        }
        return null
    }

    private List<Map> describeParams(Object params) {
        if( !(params instanceof Map) )
            return params == null ? [] : [[raw: describeValue(params)]]
        return (params as Map).collect { key, value ->
            [
                param      : safe { key.name },
                param_class: key?.getClass()?.simpleName,
                value      : describeValue(value),
            ]
        }
    }

    private Map describeValue(Object value) {
        if( value == null )
            return null
        String text = value.toString()
        if( text.length() > 500 )
            text = text.substring(0, 500) + '...'
        return [class: value.getClass().name, value: text]
    }

    private static Object safe(Closure c) {
        try { return c.call() }
        catch( Throwable e ) { return "<error: ${e.class.simpleName}: ${e.message}>".toString() }
    }

    // -- output --------------------------------------------------------------

    private void write() {
        final outdir = session.outputDir ?: (session.params?.outdir ? session.params.outdir as Path : null)
        if( !outdir ) {
            log.warn "nf-bccdc-provenance (spike): no output directory - nothing written"
            return
        }
        final path = (outdir as Path).resolve('pipeline_info/bccdc_provenance_spike.jsonl')
        Files.createDirectories(path.parent)

        final meta = session.workflowMetadata
        final run = [
            type          : 'run',
            pipeline_name : safe { meta?.manifest?.name },
            pipeline_version: safe { meta?.manifest?.version },
            session_id    : safe { meta?.sessionId?.toString() },
            run_name      : safe { meta?.runName },
            start         : safe { meta?.start?.toString() },
            complete      : safe { meta?.complete?.toString() },
            success       : safe { meta?.success },
            commit_id     : safe { meta?.commitId },
            revision      : safe { meta?.revision },
            profile       : safe { meta?.profile },
            container_engine: safe { meta?.containerEngine },
            nextflow      : safe { meta?.nextflow?.version?.toString() },
            command_line  : safe { meta?.commandLine },
        ]

        // Attribute each published file to the task whose work dir it came from.
        final byWorkDir = taskRecords.findAll { it.workDir instanceof String }.collectEntries { [(it.workDir): it] }
        publishRecords.each { pub ->
            final owner = byWorkDir.find { dir, rec -> pub.source?.startsWith(dir + '/') }?.value
            pub.task = owner?.name
            pub.sample_id = owner?.sample_id
        }

        path.withWriter { w ->
            w.writeLine(JsonOutput.toJson(run))
            taskRecords.sort { it.name?.toString() }.each { w.writeLine(JsonOutput.toJson(it)) }
            publishRecords.sort { it.target?.toString() }.each { w.writeLine(JsonOutput.toJson(it)) }
        }
        log.info "nf-bccdc-provenance (spike): wrote ${taskRecords.size()} task and ${publishRecords.size()} publish records to ${path.toUriString()}"
    }
}
