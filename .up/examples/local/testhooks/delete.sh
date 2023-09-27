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

echo_info "Running delete.sh"

SCRIPT_DIR=$( cd -- $( dirname -- "${BASH_SOURCE[0]}" ) &> /dev/null && pwd )
KUBECONFIG_PATH="${SCRIPT_DIR}/../../../../kubeconfig"
MCP_KUBECONFIG_PATH="${SCRIPT_DIR}/../../../../mcp-kubeconfig.yaml"
if [ -f "${KUBECONFIG_PATH}" ]; then
    chmod 0600 ${KUBECONFIG_PATH}
fi

KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} delete -f ${SCRIPT_DIR}/../../cluster.yaml
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} delete -f ${SCRIPT_DIR}/../../providerconfig.yaml
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} delete -f ${SCRIPT_DIR}/../../provider-argocd.yaml
KUBECONFIG=${MCP_KUBECONFIG_PATH} ${KUBECTL} delete -f ${SCRIPT_DIR}/../../../../apis/
