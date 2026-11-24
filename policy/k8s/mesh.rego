package mesh

documents contains doc if {
	some file in input
	is_array(file.contents)
	some doc in file.contents
	is_object(doc)
}

documents contains doc if {
	some file in input
	is_object(file.contents)
	doc := file.contents
}

of_kind(kind) := {d | some d in documents; d.kind == kind}

deny contains "falta una PeerAuthentication con mTLS STRICT a nivel de namespace" if {
	count({d | some d in of_kind("PeerAuthentication"); not d.spec.selector; d.spec.mtls.mode == "STRICT"}) == 0
}

deny contains "falta la AuthorizationPolicy allow-nothing (denegacion por defecto)" if {
	count({d | some d in of_kind("AuthorizationPolicy"); not d.spec.selector; not d.spec.rules; not d.spec.action}) == 0
}

deny contains "falta un Sidecar con outboundTrafficPolicy REGISTRY_ONLY" if {
	count({d | some d in of_kind("Sidecar"); d.spec.outboundTrafficPolicy.mode == "REGISTRY_ONLY"}) == 0
}

deny contains "falta un recurso Telemetry con access logs y trazas" if {
	count({d | some d in of_kind("Telemetry"); d.spec.accessLogging; d.spec.tracing}) == 0
}

deny contains msg if {
	some d in of_kind("Deployment")
	labels := d.spec.template.metadata.labels
	count({p |
		some p in of_kind("AuthorizationPolicy")
		object.get(p.spec, "action", "ALLOW") == "ALLOW"
		every k, v in p.spec.selector.matchLabels {
			labels[k] == v
		}
	}) == 0
	msg := sprintf("Deployment/%s: no existe una AuthorizationPolicy ALLOW que lo seleccione", [d.metadata.name])
}

deny contains msg if {
	some d in of_kind("Deployment")
	count({h | some h in of_kind("HorizontalPodAutoscaler"); h.spec.scaleTargetRef.name == d.metadata.name}) == 0
	msg := sprintf("Deployment/%s: no tiene HorizontalPodAutoscaler", [d.metadata.name])
}

deny contains msg if {
	some d in of_kind("Deployment")
	count({p | some p in of_kind("PodDisruptionBudget"); p.spec.selector.matchLabels == d.spec.selector.matchLabels}) == 0
	msg := sprintf("Deployment/%s: no tiene PodDisruptionBudget", [d.metadata.name])
}
