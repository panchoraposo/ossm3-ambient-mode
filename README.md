# ossm3-ambient-mode
### 1. Setup Virtual Environment

Create and activate a clean Python environment to avoid conflicts.

**For Bash/Zsh:**

Bash

Bash

```
python3 -m venv venv
source venv/bin/activate

```

**For Fish Shell:**

Bash

Bash

```
python3 -m venv venv
source venv/bin/activate.fish

```


oc create namespace istio-system
oc apply -f istio.yaml
oc wait --for=condition=Ready istios/default --timeout=3m

oc create namespace istio-cni
oc apply -f istio-cni.yaml
oc wait --for=condition=Ready istios/default --timeout=3m

oc create namespace ztunnel
oc apply -f ztunnel.yaml
oc wait --for=condition=Ready ztunnel/default --timeout=3m

oc label namespace istio-system istio-discovery=enabled
oc label namespace istio-cni istio-discovery=enabled
oc label namespace ztunnel istio-discovery=enabled

oc apply -f istio-discovery-selectors.yaml

oc create namespace bookinfo
oc label namespace bookinfo istio-discovery=enabled
oc apply -n bookinfo -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
oc apply -n bookinfo -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.26/samples/bookinfo/platform/kube/bookinfo-versions.yaml
oc -n bookinfo get pods

oc exec "$(oc get pod -l app=ratings -n bookinfo \
  -o jsonpath='{.items[0].metadata.name}')" \
  -c ratings -n bookinfo \
  -- curl -sS productpage:9080/productpage | grep -o "<title>.*</title>"

oc label namespace bookinfo istio.io/dataplane-mode=ambient

istioctl ztunnel-config workloads --namespace ztunnel

oc apply -f waypoint.yaml
oc label namespace bookinfo istio.io/use-waypoint=waypoint
istioctl ztunnel-config svc --namespace ztunnel