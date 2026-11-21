package bccdc.provenance

import groovy.transform.CompileStatic
import nextflow.config.spec.ConfigOption
import nextflow.config.spec.ConfigScope
import nextflow.config.spec.ScopeName
import nextflow.script.dsl.Description
import nextflow.util.MemoryUnit

/**
 * Settings for the nf-bccdc-provenance plugin, e.g. in nextflow.config:
 *
 *     bccdcProvenance {
 *         directory   = 'provenance'
 *         hashMaxSize = '1 GB'
 *     }
 */
@ScopeName('bccdcProvenance')
@Description('''
    The `bccdcProvenance` scope configures the `nf-bccdc-provenance` plugin, which writes BCCDC-PHL pipeline-provenance records.
''')
@CompileStatic
class ProvenanceConfig implements ConfigScope {

    @ConfigOption
    @Description('''
        Write provenance records (default: `true` if the plugin is loaded).
    ''')
    final boolean enabled

    @ConfigOption
    @Description('''
        Directory for the provenance files, relative to the output directory unless absolute (default: `provenance`).
    ''')
    final String directory

    @ConfigOption
    @Description('''
        Files larger than this aren't hashed: their records have no `sha256` (default: `1 GB`). Hashing runs on the machine running Nextflow at the end of the run.
    ''')
    final MemoryUnit hashMaxSize

    @ConfigOption
    @Description('''
        Also write a raw JSONL dump of everything the plugin observed, for troubleshooting (default: `false`).
    ''')
    final boolean debug

    /* required by extension point -- do not remove */
    ProvenanceConfig() {}

    ProvenanceConfig(Map opts) {
        enabled = opts.enabled != null ? opts.enabled as boolean : true
        directory = opts.directory ? opts.directory as String : 'provenance'
        hashMaxSize = opts.hashMaxSize ? MemoryUnit.of(opts.hashMaxSize.toString()) : MemoryUnit.of('1 GB')
        debug = opts.debug != null ? opts.debug as boolean : false
    }
}
