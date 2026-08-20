package main

import rego.v1

templated_workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job"}

workload_kinds := templated_workload_kinds | {"Pod"}

pod_spec := input.spec.template.spec if input.kind in templated_workload_kinds

pod_spec := input.spec if input.kind == "Pod"

containers := object.get(pod_spec, "containers", [])

all_containers := array.concat(
    containers,
    object.get(pod_spec, "initContainers", []),
)

workload_name := object.get(input.metadata, "name", "<unnamed>")

approved_root_container(name) if {
    workload_name == "cn5g-upf"
    name in {"upf", "configure-dnn-network"}
}

approved_root_container(name) if {
    startswith(workload_name, "cn5g-ue")
    name == "ue"
}

approved_root_container(name) if {
    workload_name == "cn5g-mongodb"
    name == "mongodb"
}

approved_capability(name, capability) if {
    workload_name == "cn5g-upf"
    name in {"upf", "configure-dnn-network"}
    capability == "NET_ADMIN"
}

approved_capability(name, capability) if {
    workload_name == "cn5g-mongodb"
    name == "mongodb"
    capability in {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"}
}

approved_capability(name, capability) if {
    startswith(workload_name, "cn5g-ue")
    name == "ue"
    capability in {"NET_ADMIN", "NET_RAW"}
}

approved_token_workload if {
    workload_name in {
        "cn5g-observability-prometheus",
        "cn5g-observability-kube-state-metrics",
        "cn5g-observability-alloy",
    }
}

approved_kind_loaded_image(image) if {
    image in {
        "cn5g/open5gs:2.7.7",
        "cn5g/ueransim:3.2.8",
        "cn5g/data-network:0.1.0",
        "mongo:8.0.28-noble",
    }
}

approved_node_proxy_rule(rule) if {
    input.kind == "ClusterRole"
    workload_name == "cn5g-observability-prometheus"
    "nodes/proxy" in object.get(rule, "resources", [])
    object.get(rule, "verbs", []) == ["get"]
}

deny contains message if {
    input.kind == "ClusterRole"
    rule := input.rules[_]
    "nodes/proxy" in object.get(rule, "resources", [])
    not approved_node_proxy_rule(rule)
    message := sprintf("ClusterRole/%s has unapproved nodes/proxy access", [workload_name])
}

deny contains message if {
    input.kind in workload_kinds
    object.get(pod_spec, "hostNetwork", false)
    message := sprintf("%s/%s must not use hostNetwork", [input.kind, workload_name])
}

deny contains message if {
    input.kind in workload_kinds
    object.get(pod_spec, "hostPID", false)
    message := sprintf("%s/%s must not use hostPID", [input.kind, workload_name])
}

deny contains message if {
    input.kind in workload_kinds
    object.get(pod_spec, "hostIPC", false)
    message := sprintf("%s/%s must not use hostIPC", [input.kind, workload_name])
}

deny contains message if {
    input.kind in workload_kinds
    container := all_containers[_]
    object.get(object.get(container, "securityContext", {}), "privileged", false)
    message := sprintf("%s/%s container %s must not be privileged", [
        input.kind, workload_name, container.name,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    container := all_containers[_]
    context := object.get(container, "securityContext", {})
    object.get(context, "allowPrivilegeEscalation", true)
    message := sprintf("%s/%s container %s permits privilege escalation", [
        input.kind, workload_name, container.name,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    container := all_containers[_]
    context := object.get(container, "securityContext", {})
    not approved_root_container(container.name)
    not object.get(context, "runAsNonRoot", false)
    not object.get(object.get(pod_spec, "securityContext", {}), "runAsNonRoot", false)
    message := sprintf("%s/%s container %s must run as non-root", [
        input.kind, workload_name, container.name,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    container := all_containers[_]
    context := object.get(container, "securityContext", {})
    additions := object.get(object.get(context, "capabilities", {}), "add", [])
    capability := additions[_]
    not approved_capability(container.name, capability)
    message := sprintf("%s/%s container %s adds unapproved capability %s", [
        input.kind, workload_name, container.name, capability,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    container := all_containers[_]
    drops := object.get(
        object.get(object.get(container, "securityContext", {}), "capabilities", {}),
        "drop",
        [],
    )
    not "ALL" in drops
    message := sprintf("%s/%s container %s must drop ALL capabilities", [
        input.kind, workload_name, container.name,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    volume := object.get(pod_spec, "volumes", [])[_]
    host_path := object.get(volume, "hostPath", null)
    host_path != null
    not host_path.path == "/dev/net/tun"
    message := sprintf("%s/%s mounts unapproved host path %s", [
        input.kind, workload_name, host_path.path,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    volume := object.get(pod_spec, "volumes", [])[_]
    host_path := object.get(volume, "hostPath", null)
    host_path != null
    host_path.path == "/dev/net/tun"
    not workload_name in {"cn5g-upf", "cn5g-ue"}
    message := sprintf("%s/%s is not approved to mount /dev/net/tun", [
        input.kind, workload_name,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    object.get(pod_spec, "automountServiceAccountToken", true)
    not approved_token_workload
    message := sprintf("%s/%s mounts a service-account token without an approved read-only collector role", [
        input.kind, workload_name,
    ])
}

deny contains message if {
    input.kind in workload_kinds
    container := all_containers[_]
    not contains(container.image, "@sha256:")
    not approved_kind_loaded_image(container.image)
    message := sprintf("%s/%s container %s uses an image without a digest", [
        input.kind, workload_name, container.name,
    ])
}
