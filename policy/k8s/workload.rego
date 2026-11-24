package workload

pod_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"}

pod_spec := input.spec.template.spec if input.kind in pod_kinds

pod_spec := input.spec.jobTemplate.spec.template.spec if input.kind == "CronJob"

app_containers contains c if {
	some c in pod_spec.containers
}

all_containers contains c if {
	some c in app_containers
}

all_containers contains c if {
	some c in object.get(pod_spec, "initContainers", [])
}

resource_id := sprintf("%s/%s", [input.kind, input.metadata.name])

deny contains msg if {
	some c in all_containers
	some field in ["limits", "requests"]
	some res in ["cpu", "memory"]
	not c.resources[field][res]
	msg := sprintf("%s: el contenedor '%s' no define resources.%s.%s", [resource_id, c.name, field, res])
}

deny contains msg if {
	some c in all_containers
	c.securityContext.privileged == true
	msg := sprintf("%s: el contenedor '%s' es privilegiado", [resource_id, c.name])
}

deny contains msg if {
	some c in all_containers
	not c.securityContext.allowPrivilegeEscalation == false
	msg := sprintf("%s: el contenedor '%s' debe fijar allowPrivilegeEscalation=false", [resource_id, c.name])
}

deny contains msg if {
	some c in all_containers
	not c.securityContext.readOnlyRootFilesystem == true
	msg := sprintf("%s: el contenedor '%s' debe usar readOnlyRootFilesystem=true", [resource_id, c.name])
}

deny contains msg if {
	some c in all_containers
	not "ALL" in object.get(object.get(object.get(c, "securityContext", {}), "capabilities", {}), "drop", [])
	msg := sprintf("%s: el contenedor '%s' debe eliminar todas las capabilities (drop: [ALL])", [resource_id, c.name])
}

run_as_non_root(c) if c.securityContext.runAsNonRoot == true

run_as_non_root(_) if pod_spec.securityContext.runAsNonRoot == true

deny contains msg if {
	some c in all_containers
	not run_as_non_root(c)
	msg := sprintf("%s: el contenedor '%s' debe ejecutarse como no root (runAsNonRoot)", [resource_id, c.name])
}

deny contains msg if {
	pod_spec
	not pod_spec.securityContext.seccompProfile.type
	msg := sprintf("%s: el pod debe declarar securityContext.seccompProfile", [resource_id])
}

deny contains msg if {
	some field in ["hostNetwork", "hostPID", "hostIPC"]
	pod_spec[field] == true
	msg := sprintf("%s: no se permite %s=true", [resource_id, field])
}

deny contains msg if {
	pod_spec
	not pod_spec.automountServiceAccountToken == false
	msg := sprintf("%s: automountServiceAccountToken debe ser false", [resource_id])
}

deny contains msg if {
	pod_spec
	object.get(pod_spec, "serviceAccountName", "default") == "default"
	msg := sprintf("%s: debe usar una ServiceAccount dedicada (identidad SPIFFE para AuthorizationPolicy)", [resource_id])
}

deny contains msg if {
	input.kind in {"Deployment", "StatefulSet"}
	some c in app_containers
	some probe in ["readinessProbe", "livenessProbe"]
	not c[probe]
	msg := sprintf("%s: el contenedor '%s' no define %s", [resource_id, c.name, probe])
}

image_without_tag(image) if {
	not contains(image, "@sha256:")
	parts := split(image, "/")
	not contains(parts[count(parts) - 1], ":")
}

deny contains msg if {
	some c in all_containers
	image_without_tag(c.image)
	msg := sprintf("%s: la imagen '%s' no fija etiqueta ni digest", [resource_id, c.image])
}

deny contains msg if {
	some c in all_containers
	endswith(c.image, ":latest")
	msg := sprintf("%s: la imagen '%s' usa la etiqueta mutable latest", [resource_id, c.image])
}

deny contains msg if {
	input.kind == "Deployment"
	input.spec.template.metadata.annotations["sidecar.istio.io/inject"] == "false"
	msg := sprintf("%s: no se permite desactivar la inyeccion del sidecar de Istio", [resource_id])
}

warn contains msg if {
	input.kind == "Deployment"
	not input.spec.template.metadata.annotations["prometheus.io/scrape"] == "true"
	msg := sprintf("%s: el workload no expone metricas para Prometheus", [resource_id])
}
