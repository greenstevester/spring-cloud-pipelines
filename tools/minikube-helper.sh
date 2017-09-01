#!/bin/bash

function usage {
	echo "usage: $0: <download-kubectl|download-minikube|delete-all-apps|delete-all-test-apps|\
delete-all-stage-apps|delete-all-prod-apps|setup-namespaces|setup-prod-infra>"
	exit 1
}

function substituteVariables() {
    local variableName="${1}"
    local substitution="${2}"
    local escapedSubstitution=$( escapeValueForSed "${substitution}" )
    local fileName="${3}"
    #echo "Changing [${variableName}] -> [${escapedSubstitution}] for file [${fileName}]"
    sed -i "s/{{${variableName}}}/${escapedSubstitution}/" ${fileName}
}

function escapeValueForSed() {
    echo "${1//\//\\/}"
}

function createNamespace() {
    local namespaceName="${1}"
    local folder=""
    if [ -d "tools" ]; then
        folder="tools/"
    fi
    mkdir -p "${folder}build"
    cp "${folder}k8s/namespace.yml" "${folder}build/namespace.yml"
    substituteVariables "name" "${namespaceName}" "${folder}build/namespace.yml"
    kubectl create -f "${folder}build/namespace.yml"
}

function system {
    unameOut="$(uname -s)"
    case "${unameOut}" in
        Linux*)     machine=linux;;
        Darwin*)    machine=darwin;;
        *)          echo "Unsupported system" && exit 1
    esac
    echo ${machine}
}

SYSTEM=$( system )

[[ $# -eq 1 ]] || usage

case $1 in
	download-kubectl)
        curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/${SYSTEM}/amd64/kubectl
        chmod +x ./kubectl
        sudo mv ./kubectl /usr/local/bin/kubectl
        ;;

	download-minikube)
		curl -Lo minikube https://storage.googleapis.com/minikube/releases/v0.20.0/minikube-${SYSTEM}-amd64 && chmod +x minikube && sudo mv minikube /usr/local/bin/
		;;

	delete-all-apps)
		kubectl delete pods,deployments,services,persistentvolumeclaims,secrets,replicationcontrollers --namespace=sc-pipelines-test --all
		kubectl delete pods,deployments,services,persistentvolumeclaims,secrets,replicationcontrollers --namespace=sc-pipelines-stage --all
		kubectl delete pods,deployments,services,persistentvolumeclaims,secrets,replicationcontrollers --namespace=sc-pipelines-prod --all
		;;

	delete-all-test-apps)
		kubectl delete pods,deployments,services,persistentvolumeclaims,secrets,replicationcontrollers --namespace=sc-pipelines-test --all
		;;

	delete-all-stage-apps)
		kubectl delete pods,deployments,services,persistentvolumeclaims,secrets,replicationcontrollers --namespace=sc-pipelines-stage --all
		;;

	delete-all-prod-apps)
		kubectl delete pods,deployments,services,persistentvolumeclaims,secrets,replicationcontrollers --namespace=sc-pipelines-prod --all
		;;

	setup-namespaces)
		mkdir -p build
		createNamespace "sc-pipelines-test"
		createNamespace "sc-pipelines-stage"
		createNamespace "sc-pipelines-prod"
		;;

	setup-prod-infra)
		# TODO
		echo "TODO"
		exit 1
		;;

    *)
		usage
		;;
esac
