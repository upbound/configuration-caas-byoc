#!/usr/bin/env bash
set -aeuo pipefail

# setting up colors
BLU='\033[0;104m'
YLW='\033[0;33m'
GRN='\033[0;32m'
RED='\033[0;31m'
NOC='\033[0m' # No Color

echo_info(){
    printf "\n${BLU}%s${NOC}\n" "$1"
}
echo_step(){
    printf "\n${BLU}>>>>>>> %s${NOC}\n" "$1"
}
echo_step_completed(){
    printf "${GRN} [✔] %s${NOC}\n" "$1"
}

echo_info "Running setup.sh"

SCRIPT_DIR=$( cd -- $( dirname -- "${BASH_SOURCE[0]}" ) &> /dev/null && pwd )
KUBECONFIG_PATH="${SCRIPT_DIR}/../kubeconfig"
MCP_KUBECONFIG_PATH="${SCRIPT_DIR}/../mcp-kubeconfig.yaml"
if [ -f "${KUBECONFIG_PATH}" ]; then
    chmod 0600 ${KUBECONFIG_PATH}
fi

echo_info "Waiting for all pods to come online..."
${KUBECTL} -n upbound-system wait --for=condition=Available deployment --all --timeout=5m

echo_step "Install argocd"
echo_info "Creating argocd namespace"
${KUBECTL} create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo_info "Adding argocd repo"
helm repo add argo https://argoproj.github.io/argo-helm --force-update

echo_info "Checking for argocd installation"
ARGOCD_DEPLOYMENT_STATUS=$(helm status argocd -n argocd|grep STATUS || true)
echo_info "$ARGOCD_DEPLOYMENT_STATUS"
if [[ "$ARGOCD_DEPLOYMENT_STATUS" == "STATUS: deployed" ]]; then
    echo "Uninstalling argocd; need clean installation"
    helm uninstall argocd -n argocd --wait
fi

helm install argocd argo/argo-cd --namespace argocd -f ${SCRIPT_DIR}/values.yaml --wait

echo_info "Waiting for argocd deployments"
${KUBECTL} -n argocd wait --for=condition=Available deployment --all --timeout=5m

echo_info "add new argocd account"
${KUBECTL} patch configmap/argocd-cm \
  -n argocd \
  --type merge \
  -p '{"data":{"accounts.provider-argocd":"apiKey"}}'

echo_info "set new argocd account rbac"
${KUBECTL} patch configmap/argocd-rbac-cm \
  -n argocd \
  --type merge \
  -p '{"data":{"policy.csv":"g, provider-argocd, role:admin"}}'

echo_info "create busybox"
cat <<EOF | ${KUBECTL} apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: busybox
  namespace: default
spec:
  containers:
  - image: curlimages/curl
    command:
      - sleep
      - "3600"
    imagePullPolicy: IfNotPresent
    name: busybox
  restartPolicy: Always
EOF

echo_info "Waiting for busybox pod"
${KUBECTL} wait --for=condition=ready pod busybox -n default

echo_info "Create argocd jwt token"
ARGOCD_ADMIN_SECRET=$(${KUBECTL} -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
ARGOCD_ADMIN_TOKEN_TMP=$(${KUBECTL} exec -n default --stdin busybox -- curl -s -X POST -k -H "Content-Type: application/json" --data '{"username":"admin","password":"'$ARGOCD_ADMIN_SECRET'"}' https://argocd-server.argocd.svc:443/api/v1/session)
ARGOCD_ADMIN_TOKEN=$(echo $ARGOCD_ADMIN_TOKEN_TMP | jq -r .token)
ARGOCD_PROVIDER_USER="provider-argocd"
ARGOCD_TOKEN_TMP=$(${KUBECTL} exec -n default --stdin busybox -- curl -s -X POST -k -H "Authorization: Bearer $ARGOCD_ADMIN_TOKEN" -H "Content-Type: application/json" https://argocd-server.argocd.svc:443/api/v1/account/$ARGOCD_PROVIDER_USER/token)
ARGOCD_TOKEN=$(echo $ARGOCD_TOKEN_TMP | jq -r .token)

echo_step_completed "install argocd and token generation"

${UPCLI} login -a upbound --token ${UPTEST_CLOUD_CREDENTIALS}
echo_info "get mcp control plane kubeconfig"
${UPCLI} ctp kubeconfig get ${UPTEST_MCP} -a ${UPTEST_MCP_ORG} --token ${UPTEST_CLOUD_CREDENTIALS} -f ${MCP_KUBECONFIG_PATH}

echo_info "Create secret with kubeconfig from mcp control plane - in mcp control plane for argocd server resource"
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} create secret generic mcp-kubeconfig -n default --from-file=kubeconfig=${MCP_KUBECONFIG_PATH} --dry-run=client -o yaml | KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} apply -f -

echo_info "Create XProvider API in mcp control plane"
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} apply -f ${SCRIPT_DIR}/../apis/

echo_info "Create XProvider Claim"
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} apply -f ${SCRIPT_DIR}/../.up/examples/provider-argocd.yaml
echo_info "Waiting until all installed provider packages are healthy..."
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} wait provider.pkg --all --for condition=Healthy --timeout 5m

echo_info "Create ProviderConfig"
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} apply -f ${SCRIPT_DIR}/../.up/examples/providerconfig.yaml

echo_info "Create ProviderConfig, Secret and Cluster"
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} apply -f ${SCRIPT_DIR}/../.up/examples/providerconfig.yaml
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} create secret generic argocd-credentials -n default --from-literal=authToken="$ARGOCD_TOKEN" --dry-run=client -o yaml | KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} apply -f -
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} apply -f ${SCRIPT_DIR}/../.up/examples/cluster.yaml

echo_info "Create secret with kubeconfig from mcp control plane - local for provider controller"
${KUBECTL} create secret generic mcp-kubeconfig -n default --from-file=kubeconfig=${MCP_KUBECONFIG_PATH} --dry-run=client -o yaml | ${KUBECTL} apply -f -
${KUBECTL} apply -f ${SCRIPT_DIR}/../.up/examples/local/provider-argocd.yaml
sleep 30
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} describe -f ${SCRIPT_DIR}/../.up/examples/cluster.yaml
