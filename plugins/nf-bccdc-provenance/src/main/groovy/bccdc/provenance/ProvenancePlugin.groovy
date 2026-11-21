package bccdc.provenance

import groovy.transform.CompileStatic
import nextflow.plugin.BasePlugin
import org.pf4j.PluginWrapper

/**
 * Entry point for the nf-bccdc-provenance plugin.
 *
 * SPIKE: the plugin currently only records what Nextflow exposes about each
 * task (see ProvenanceObserver). It doesn't write BCCDC pipeline-provenance
 * records yet.
 */
@CompileStatic
class ProvenancePlugin extends BasePlugin {

    ProvenancePlugin(PluginWrapper wrapper) {
        super(wrapper)
    }
}
