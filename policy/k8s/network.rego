package network

resource_id := sprintf("%s/%s", [input.kind, input.metadata.name])

deny contains msg if {
	input.kind == "Namespace"
	not input.metadata.labels["istio-injection"] == "enabled"
	msg := sprintf("%s: el namespace debe tener istio-injection=enabled", [resource_id])
}

deny contains msg if {
	input.kind == "Namespace"
	not input.metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted"
	msg := sprintf("%s: el namespace debe aplicar Pod Security Standard restricted", [resource_id])
}

deny contains msg if {
	input.kind == "Service"
	input.spec.type in {"LoadBalancer", "NodePort"}
	msg := sprintf("%s: los servicios de la aplicacion se exponen solo a traves del ingress gateway de Istio", [resource_id])
}

deny contains msg if {
	input.kind == "PeerAuthentication"
	not input.spec.mtls.mode == "STRICT"
	msg := sprintf("%s: mTLS debe estar en modo STRICT", [resource_id])
}

deny contains msg if {
	input.kind == "PeerAuthentication"
	some port, cfg in object.get(input.spec, "portLevelMtls", {})
	not cfg.mode == "STRICT"
	msg := sprintf("%s: el puerto %v relaja mTLS", [resource_id, port])
}

deny contains msg if {
	input.kind == "DestinationRule"
	input.spec.trafficPolicy.tls.mode == "DISABLE"
	msg := sprintf("%s: no se permite desactivar TLS hacia el destino", [resource_id])
}

deny contains msg if {
	input.kind == "AuthorizationPolicy"
	input.spec.action != "DENY"
	some rule in object.get(input.spec, "rules", [])
	not rule.from
	msg := sprintf("%s: toda regla ALLOW debe restringir el origen (from)", [resource_id])
}

deny contains msg if {
	input.kind == "Service"
	some port in input.spec.ports
	not port.appProtocol
	not regex.match(`^(http|http2|https|grpc|tcp|tls|mongo|mysql|redis)(-.*)?$`, object.get(port, "name", ""))
	msg := sprintf("%s: el puerto %v debe declarar el protocolo (appProtocol o prefijo en el nombre) para Istio", [resource_id, port.port])
}
