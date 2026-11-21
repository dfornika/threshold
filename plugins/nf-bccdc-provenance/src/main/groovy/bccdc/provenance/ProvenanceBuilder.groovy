package bccdc.provenance

import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest

import groovy.transform.CompileDynamic

/**
 * Builds BCCDC-PHL pipeline-provenance records
 * (https://github.com/BCCDC-PHL/pipeline-provenance-schema) from what
 * ProvenanceObserver collected. Each record list starts with the pipeline
 * record, then input files, processes and output files.
 *
 * Input (TaskInfo maps, one per task attempt):
 *   name, process, cached, success, sampleId, container, extArgs,
 *   tools    : [[name, version], ...]
 *   inputs   : [[param, path], ...]    every file input, original location
 *   outputs  : [Path, ...]
 *   workDir  : Path
 * and published files: [[source: Path, target: Path], ...].
 *
 * Rules:
 *   - A sample is a `meta.id` seen in at least two different processes, so a
 *     run-wide ID like MultiQC's (one process) isn't mistaken for a sample.
 *   - Tasks without a sample (e.g. a reference fetched once per accession)
 *     are attached to every sample whose tasks used their output files;
 *     anything still unattached goes in the run-level records.
 *   - A sample's input files are its tasks' file inputs that live outside the
 *     work dir (pipeline inputs, references, databases), not intermediates.
 *   - Retries: a process is reported once per successful task; if it never
 *     succeeded for that sample, its last attempt is reported as `failed`.
 *   - `ext.args` is split into tool parameters, attached to the process's
 *     first tool (the one nf-core's `args` applies to).
 *   - Files up to `hashMaxBytes` get a `sha256`. `file_size` is left out for
 *     now: the schema types it as an integer, but the schema repo's validator
 *     loads YAML with yaml.BaseLoader (every value a string), so a record
 *     with file_size can never validate there.
 */
@CompileDynamic
class ProvenanceBuilder {

    private final Map pipelineRecord
    private final List<Map> tasks
    private final List<Map> published
    private final Path workDir
    private final long hashMaxBytes

    private final Set<String> samples
    private final Map<Map,Set<String>> sharedTaskSamples = [:]
    private final Map<Path,Map> fileInfoCache = [:]

    ProvenanceBuilder(Map pipelineRecord, List<Map> tasks, List<Map> published, Path workDir, long hashMaxBytes) {
        this.pipelineRecord = pipelineRecord
        this.tasks = tasks
        this.published = published
        this.workDir = workDir
        this.hashMaxBytes = hashMaxBytes
        this.samples = findSamples()
        attachSharedTasks()
    }

    List<String> sampleIds() {
        return samples.sort()
    }

    List<Map> sampleRecords(String sampleId) {
        final sampleTasks = tasks.findAll { t -> t.sampleId == sampleId }
        // the sample's own tasks plus shared ones it used, in completion order
        final allTasks = tasks.findAll { t -> t.sampleId == sampleId || sharedTaskSamples[t]?.contains(sampleId) }
        return [pipelineRecord] +
            inputRecords(sampleTasks) +
            processRecords(allTasks) +
            outputRecords(allTasks)
    }

    /** Pipeline record plus the tasks (and their outputs) not attributed to any sample. */
    List<Map> runRecords() {
        final runTasks = tasks.findAll { t -> !(t.sampleId in samples) && !sharedTaskSamples[t] }
        return [pipelineRecord] + processRecords(runTasks) + outputRecords(runTasks)
    }

    // -- attribution ---------------------------------------------------------

    private Set<String> findSamples() {
        final Map<String,Set<String>> processesById = [:]
        tasks.each { t ->
            if( t.sampleId )
                processesById.computeIfAbsent(t.sampleId as String) { new HashSet<String>() } << (t.process as String)
        }
        return processesById.findAll { id, processes -> processes.size() >= 2 }.keySet() as Set<String>
    }

    private void attachSharedTasks() {
        final Map<Path,Set<String>> inputUsers = [:]
        tasks.findAll { t -> t.sampleId in samples }.each { t ->
            t.inputs.each { i -> inputUsers.computeIfAbsent(i.path as Path) { new HashSet<String>() } << (t.sampleId as String) }
        }
        tasks.findAll { t -> !(t.sampleId in samples) }.each { t ->
            final Set<String> users = new HashSet<String>()
            t.outputs.each { Path out -> users.addAll(inputUsers[out] ?: []) }
            if( users )
                sharedTaskSamples[t] = users
        }
    }

    // -- records -------------------------------------------------------------

    private List<Map> inputRecords(List<Map> sampleTasks) {
        final Map<Path,String> external = new LinkedHashMap<>()
        sampleTasks.each { t ->
            t.inputs.each { i ->
                final path = i.path as Path
                if( !isIntermediate(path) )
                    external.putIfAbsent(path, i.param as String)
            }
        }
        return external.collect { path, param ->
            [input_filename: path.fileName.toString(), file_type: param, file_path: path.toString()] + fileInfo(path)
        }
    }

    private List<Map> processRecords(List<Map> processTasks) {
        final Map<String,List<Map>> byProcess = new LinkedHashMap<>()
        processTasks.each { t -> byProcess.computeIfAbsent(t.process as String) { [] } << t }

        final List<Map> records = []
        byProcess.each { process, attempts ->
            final successes = attempts.findAll { t -> t.success }
            final chosen = successes ?: [attempts.last()]
            chosen.each { t -> records << processRecord(t) }
        }
        return records
    }

    private Map processRecord(Map t) {
        final Map record = [process_name: t.process]
        final parameters = parseArgs(t.extArgs as String)
        if( t.tools ) {
            record.tools = t.tools.withIndex().collect { tool, i ->
                final Map out = [tool_name: tool.name, tool_version: tool.version]
                if( i == 0 && parameters )
                    out.parameters = parameters
                out
            }
        }
        else if( parameters ) {
            // No tool versions reported (e.g. a local module without a
            // `versions` output): keep the parameters on the process.
            record.parameters = parameters
        }
        record.status = !t.success ? 'failed' : (t.cached ? 'cached' : 'completed')
        if( t.container )
            record.container = t.container
        return record
    }

    private List<Map> outputRecords(List<Map> producingTasks) {
        final dirs = producingTasks.collect { t -> t.workDir as Path }.findAll { it != null }
        final outputs = producingTasks.collectMany { t -> t.outputs as List<Path> } as Set<Path>
        return published.findAll { p ->
            final source = p.source as Path
            source in outputs || dirs.any { d -> source.startsWith(d) }
        }.collect { p ->
            final target = p.target as Path
            [output_filename: target.fileName.toString(), file_path: target.toString()] + fileInfo(target)
        }.unique { r -> r.file_path }
    }

    // -- helpers -------------------------------------------------------------

    private boolean isIntermediate(Path path) {
        return workDir != null && path.startsWith(workDir)
    }

    /** `--gsize 4641652 --quiet` -> [[parameter: --gsize, value: 4641652], [parameter: --quiet, value: null]] */
    static List<Map> parseArgs(String args) {
        if( !args?.trim() )
            return []
        final tokens = (args =~ /"[^"]*"|'[^']*'|\S+/).collect { String tok ->
            (tok.length() >= 2 && (tok[0] == '"' || tok[0] == "'") && tok[-1] == tok[0]) ? tok[1..-2] : tok
        }
        final List<Map> parameters = []
        int i = 0
        while( i < tokens.size() ) {
            final tok = tokens[i]
            final next = i + 1 < tokens.size() ? tokens[i + 1] : null
            if( tok.startsWith('-') && next != null && !looksLikeFlag(next) ) {
                parameters << [parameter: tok, value: next]
                i += 2
            }
            else {
                parameters << [parameter: tok, value: null]
                i += 1
            }
        }
        return parameters
    }

    private static boolean looksLikeFlag(String tok) {
        // a flag, but not a negative number
        return tok.startsWith('-') && !(tok ==~ /-\d+(\.\d+)?/)
    }

    private Map fileInfo(Path path) {
        return fileInfoCache.computeIfAbsent(path) { Path p ->
            final Map info = [:]
            try {
                if( !Files.isRegularFile(p) )
                    return info
                if( Files.size(p) <= hashMaxBytes )
                    info.sha256 = sha256(p)
            }
            catch( Exception e ) {
                // unreadable/remote file: leave out sha256/file_size
            }
            return info
        }
    }

    private static String sha256(Path path) {
        final digest = MessageDigest.getInstance('SHA-256')
        final buffer = new byte[1 << 20]
        Files.newInputStream(path).withCloseable { stream ->
            int n
            while( (n = stream.read(buffer)) > 0 )
                digest.update(buffer, 0, n)
        }
        return digest.digest().encodeHex().toString()
    }
}
