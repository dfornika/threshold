package bccdc.provenance

import groovy.transform.CompileStatic
import nextflow.Session
import nextflow.trace.TraceObserverFactoryV2
import nextflow.trace.TraceObserverV2

/**
 * Registers ProvenanceObserver for every run that loads the plugin, unless
 * `bccdcProvenance.enabled = false`.
 */
@CompileStatic
class ProvenanceObserverFactory implements TraceObserverFactoryV2 {

    @Override
    Collection<TraceObserverV2> create(Session session) {
        final opts = session.config.navigate('bccdcProvenance') as Map ?: Collections.emptyMap()
        final config = new ProvenanceConfig(opts)
        if( !config.enabled )
            return [] as Collection<TraceObserverV2>
        return [ new ProvenanceObserver(config) ] as Collection<TraceObserverV2>
    }
}
