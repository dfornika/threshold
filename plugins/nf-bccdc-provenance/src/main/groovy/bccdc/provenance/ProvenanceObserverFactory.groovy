package bccdc.provenance

import groovy.transform.CompileStatic
import nextflow.Session
import nextflow.trace.TraceObserverFactoryV2
import nextflow.trace.TraceObserverV2

/**
 * Registers ProvenanceObserver for every run that loads the plugin.
 */
@CompileStatic
class ProvenanceObserverFactory implements TraceObserverFactoryV2 {

    @Override
    Collection<TraceObserverV2> create(Session session) {
        return [ new ProvenanceObserver() ] as Collection<TraceObserverV2>
    }
}
