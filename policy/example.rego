package kopa.admission

default decision := true

# Deny pods that request privileged containers.
decision := false if {
  input.request.kind.kind == "Pod"
  some c in input.request.object.spec.containers
  c.securityContext.privileged == true
}
