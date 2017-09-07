#!/bin/bash
set -e

function logInToPaas() {
    local redownloadInfra="${REDOWNLOAD_INFRA}"
    local ca="PAAS_${ENVIRONMENT}_CA"
    local k8sCa="${!ca}"
    local clientCert="PAAS_${ENVIRONMENT}_CLIENT_CERT"
    local k8sClientCert="${!clientCert}"
    local clientKey="PAAS_${ENVIRONMENT}_CLIENT_KEY"
    local k8sClientKey="${!clientKey}"
    local clusterName="PAAS_${ENVIRONMENT}_CLUSTER_NAME"
    local k8sClusterName="${!clusterName}"
    local clusterUser="PAAS_${ENVIRONMENT}_CLUSTER_USERNAME"
    local k8sClusterUser="${!clusterUser}"
    local systemName="PAAS_${ENVIRONMENT}_SYSTEM_NAME"
    local k8sSystemName="${!systemName}"
    export K8S_CONTEXT="${k8sSystemName}"
    local api="PAAS_${ENVIRONMENT}_API_URL"
    local apiUrl="${!api:-192.168.99.100:8443}"
    local CLI_INSTALLED="$( kubectl version || echo "false" )"
    local CLI_DOWNLOADED="$( test -r kubectl && echo "true" || echo "false" )"
    echo "CLI Installed? [${CLI_INSTALLED}], CLI Downloaded? [${CLI_DOWNLOADED}]"
    if [[ ${CLI_INSTALLED} == "false" && (${CLI_DOWNLOADED} == "false" || ${CLI_DOWNLOADED} == "true" && ${redownloadInfra} == "true") ]]; then
        echo "Downloading CLI"
        curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/darwin/amd64/kubectl --fail
        local CLI_DOWNLOADED="true"
    else
        echo "CLI is already installed or was already downloaded but the flag to redownload was disabled"
    fi

    if [[ ${CLI_DOWNLOADED} == "true" ]]; then
        echo "Adding CLI to PATH"
        PATH=${PATH}:`pwd`
        chmod +x kubectl
    fi

    echo "Logging in to Kubernetes API [${apiUrl}], with cluster name [${k8sClusterName}] and user [${k8sClusterUser}]"
    kubectl config set-cluster ${k8sClusterName} --server=https://${apiUrl} --certificate-authority=${k8sCa}
    kubectl config set-credentials ${k8sClusterUser} --certificate-authority=${k8sCa} --client-key=${k8sClientKey} --client-certificate=${k8sClientCert}
    kubectl config set-context ${k8sSystemName} --cluster=${k8sClusterName} --user=${k8sClusterUser}
    kubectl config use-context ${k8sSystemName}

    echo "CLI version"
    kubectl version
}

function testDeploy() {
    # TODO: Consider making it less JVM specific
    local projectGroupId=$( retrieveGroupId )
    local appName=$( retrieveAppName )
    # Log in to PaaS to start deployment
    logInToPaas

    deployServices

    # deploy app
    deployAndRestartAppWithNameForSmokeTests "${appName}" "${UNIQUE_RABBIT_NAME}" "${UNIQUE_EUREKA_NAME}" "${UNIQUE_MYSQL_NAME}"
}

function testRollbackDeploy() {
    rm -rf ${OUTPUT_FOLDER}/test.properties
    local latestProdTag="${1}"
    local projectGroupId=$( retrieveGroupId )
    local appName=$( retrieveAppName )
    # Downloading latest jar
    LATEST_PROD_VERSION=${latestProdTag#prod/}
    echo "Last prod version equals ${LATEST_PROD_VERSION}"
    downloadAppArtifact 'true' ${REPO_WITH_BINARIES} ${projectGroupId} ${appName} ${LATEST_PROD_VERSION}
    logInToPaas
    deployAndRestartAppWithNameForSmokeTests ${appName} "${appName}-${LATEST_PROD_VERSION}"
    # Adding latest prod tag
    echo "LATEST_PROD_TAG=${latestProdTag}" >> ${OUTPUT_FOLDER}/test.properties
}

function deployService() {
    local serviceType=$( toLowerCase "${1}" )
    local serviceName="${2}"
    local serviceCoordinates=$( if [[ "${3}" == "null" ]] ; then echo ""; else echo "${3}" ; fi )
    local coordinatesSeparator=":"
    echo "Will deploy service with type [${serviceType}] name [${serviceName}] and coordinates [${serviceCoordinates}]"
    case ${serviceType} in
    rabbitmq)
      deployRabbitMq "${serviceName}"
      ;;
    mysql)
      deployMySql "${serviceName}"
      ;;
    eureka)
      PREVIOUS_IFS="${IFS}"
      IFS=${coordinatesSeparator} read -r EUREKA_ARTIFACT_ID EUREKA_VERSION <<< "${serviceCoordinates}"
      IFS="${PREVIOUS_IFS}"
      deployEureka "${EUREKA_ARTIFACT_ID}:${EUREKA_VERSION}" "${serviceName}"
      ;;
    stubrunner)
      UNIQUE_EUREKA_NAME="$( echo ${PARSED_YAML} | jq --arg x ${LOWER_CASE_ENV} '.[$x].services[] | select(.type == "eureka") | .name' | sed 's/^"\(.*\)"$/\1/' )"
      UNIQUE_RABBIT_NAME="$( echo ${PARSED_YAML} | jq --arg x ${LOWER_CASE_ENV} '.[$x].services[] | select(.type == "rabbitmq") | .name' | sed 's/^"\(.*\)"$/\1/' )"
      PREVIOUS_IFS="${IFS}"
      IFS=${coordinatesSeparator} read -r STUBRUNNER_ARTIFACT_ID STUBRUNNER_VERSION <<< "${serviceCoordinates}"
      IFS="${PREVIOUS_IFS}"
      PARSED_STUBRUNNER_USE_CLASSPATH="$( echo ${PARSED_YAML} | jq --arg x ${LOWER_CASE_ENV} '.[$x].services[] | select(.type == "stubrunner") | .useClasspath' | sed 's/^"\(.*\)"$/\1/' )"
      STUBRUNNER_USE_CLASSPATH=$( if [[ "${PARSED_STUBRUNNER_USE_CLASSPATH}" == "null" ]] ; then echo "false"; else echo "${PARSED_STUBRUNNER_USE_CLASSPATH}" ; fi )
      deployStubRunnerBoot "${STUBRUNNER_ARTIFACT_ID}:${STUBRUNNER_VERSION}" "${REPO_WITH_BINARIES}" "${UNIQUE_RABBIT_NAME}" "${UNIQUE_EUREKA_NAME}" "${serviceName}"
      ;;
    *)
      echo "Unknown service [${serviceType}]"
      return 1
      ;;
    esac
}

function deleteService() {
    local serviceType="${1}"
    local serviceName="${2}"
    echo "Deleting all mysql related services with name [${serviceName}]"
    deleteAppByName ${serviceName}
}

function deployRabbitMq() {
    local serviceName="${1:-rabbitmq-github}"
    echo "Waiting for RabbitMQ to start"
    local foundApp=`kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" get pods -o wide -l app=${serviceName} | awk -v "app=${serviceName}" '$1 ~ app {print($0)}'`
    if [[ "${foundApp}" == "" ]]; then
        local originalDeploymentFile="${__ROOT}/k8s/rabbitmq.yml"
        local originalServiceFile="${__ROOT}/k8s/rabbitmq-service.yml"
        local outputDirectory="$( outputFolder )"
        mkdir -p "${outputDirectory}"
        cp ${originalDeploymentFile} ${outputDirectory}
        cp ${originalServiceFile} ${outputDirectory}
        local deploymentFile="${outputDirectory}/rabbitmq.yml"
        local serviceFile="${outputDirectory}/rabbitmq-service.yml"
        substituteVariables "appName" "${serviceName}" "${deploymentFile}"
        substituteVariables "appName" "${serviceName}" "${serviceFile}"
        if [[ "${ENVIRONMENT}" == "TEST" ]]; then
            deleteAppByFile "${deploymentFile}"
            deleteAppByFile "${serviceFile}"
        fi
        replaceApp "${deploymentFile}"
        replaceApp "${serviceFile}"
    else
        echo "Service [${serviceName}] already started"
    fi
}

function deployApp() {
    local fileName="${1}"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" create -f "${fileName}"
}

function replaceApp() {
    local fileName="${1}"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" replace --force -f "${fileName}"
}

function deleteAppByName() {
    local serviceName="${1}"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" delete secret "${serviceName}" || echo "Failed to delete secret [${serviceName}]. Continuing with the script"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" delete persistentvolumeclaim "${serviceName}"  || echo "Failed to delete persistentvolumeclaim [${serviceName}]. Continuing with the script"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" delete pod "${serviceName}" || echo "Failed to delete service [${serviceName}]. Continuing with the script"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" delete deployment "${serviceName}" || echo "Failed to delete deployment [${serviceName}] . Continuing with the script"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" delete service "${serviceName}" || echo "Failed to delete service [${serviceName}]. Continuing with the script"
}

function deleteAppByFile() {
    local file="${1}"
    kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" delete -f ${file} || echo "Failed to delete app by [${file}] file. Continuing with the script"
}

function substituteVariables() {
    local variableName="${1}"
    local substitution="${2}"
    local escapedSubstitution=$( escapeValueForSed "${substitution}" )
    local fileName="${3}"
    #echo "Changing [${variableName}] -> [${escapedSubstitution}] for file [${fileName}]"
    sed -i "s/{{${variableName}}}/${escapedSubstitution}/" ${fileName}
}

function deleteMySql() {
    local serviceName="${1:-mysql-github}"
    echo "Deleting all mysql related services with name [${serviceName}]"
    deleteAppByName ${serviceName}
}

function deployMySql() {
    local serviceName="${1:-mysql-github}"
    echo "Waiting for MySQL to start"
    local foundApp=`kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" get pods -o wide -l app=${serviceName} | awk -v "app=${serviceName}" '$1 ~ app {print($0)}'`
    if [[ "${foundApp}" == "" ]]; then
        local originalDeploymentFile="${__ROOT}/k8s/mysql.yml"
        local originalServiceFile="${__ROOT}/k8s/mysql-service.yml"
        local outputDirectory="$( outputFolder )"
        mkdir -p "${outputDirectory}"
        cp ${originalDeploymentFile} ${outputDirectory}
        cp ${originalServiceFile} ${outputDirectory}
        local deploymentFile="${outputDirectory}/mysql.yml"
        local serviceFile="${outputDirectory}/mysql-service.yml"
        echo "Generating secret with name [${serviceName}]"
        kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" delete secret "${serviceName}" || echo "Failed to delete secret [${serviceName}]. Continuing with the script"
        kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" create secret generic "${serviceName}" --from-literal=username="${MYSQL_USER}" --from-literal=password="${MYSQL_PASSWORD}" --from-literal=rootpassword="${MYSQL_ROOT_PASSWORD}"
        substituteVariables "appName" "${serviceName}" "${deploymentFile}"
        substituteVariables "mysqlDatabase" "${MYSQL_DATABASE}" "${deploymentFile}"
        substituteVariables "appName" "${serviceName}" "${serviceFile}"
        if [[ "${ENVIRONMENT}" == "TEST" ]]; then
            deleteAppByFile "${deploymentFile}"
            deleteAppByFile "${serviceFile}"
        fi
        replaceApp "${deploymentFile}"
        replaceApp "${serviceFile}"
    else
        echo "Service [${serviceName}] already started"
    fi
}

function deployAndRestartAppWithName() {
    local appName="${1}"
    local jarName="${2}"
    local env="${LOWER_CASE_ENV}"
    echo "Deploying and restarting app with name [${appName}] and jar name [${jarName}]"
    deployAppWithName "${appName}" "${jarName}" "${env}" 'true'
    restartApp "${appName}"
}

function deployAndRestartAppWithNameForSmokeTests() {
    local appName="${1}"
    local rabbitName="${2}.${PAAS_NAMESPACE}"
    local eurekaName="${3}.${PAAS_NAMESPACE}"
    local mysqlName="${4}.${PAAS_NAMESPACE}"
    local profiles="smoke"
    local lowerCaseAppName=$( toLowerCase "${appName}" )
    local originalDeploymentFile="deployment.yml"
    local originalServiceFile="service.yml"
    local outputDirectory="$( outputFolder )"
    mkdir -p "${outputDirectory}"
    cp ${originalDeploymentFile} ${outputDirectory}
    cp ${originalServiceFile} ${outputDirectory}
    local deploymentFile="${outputDirectory}/deployment.yml"
    local serviceFile="${outputDirectory}/service.yml"
    local systemProps="-Dspring.profiles.active=${profiles}"
    # TODO: Not every system needs Eureka... Solve this by analyzing pipeline descriptor
    local systemProps="${systemProps} -DSPRING_RABBITMQ_ADDRESSES=${rabbitName} -Deureka.client.serviceUrl.defaultZone=http://${eurekaName}:8761/eureka"
    substituteVariables "dockerOrg" "${DOCKER_REGISTRY_ORGANIZATION}" "${deploymentFile}"
    substituteVariables "version" "${PIPELINE_VERSION}" "${deploymentFile}"
    substituteVariables "appName" "${appName}" "${deploymentFile}"
    substituteVariables "systemProps" "${systemProps}" "${deploymentFile}"
    substituteVariables "appName" "${appName}" "${serviceFile}"
    deleteAppByFile "${deploymentFile}"
    deleteAppByFile "${serviceFile}"
    deployApp "${deploymentFile}"
    deployApp "${serviceFile}"
    waitForAppToStart "${appName}"
}

function deployAndRestartAppWithNameForE2ETests() {
    local appName="${1}"
    local rabbitName="${2}.${PAAS_NAMESPACE}"
    local eurekaName="${3}.${PAAS_NAMESPACE}"
    local mysqlName="${4}.${PAAS_NAMESPACE}"
    local profiles="smoke"
    local lowerCaseAppName=$( toLowerCase "${appName}" )
    local deploymentFile="deployment.yml"
    local serviceFile="service.yml"
    local systemProps="-Dspring.profiles.active=${profiles}"
    # TODO: Not every system needs Eureka... Solve this by analyzing pipeline descriptor
    local systemProps="${systemProps} -DSPRING_RABBITMQ_ADDRESSES=${rabbitName} -Deureka.client.serviceUrl.defaultZone=http://${eurekaName}:8761/eureka"
    substituteVariables "dockerOrg" "${DOCKER_REGISTRY_ORGANIZATION}" "${deploymentFile}"
    substituteVariables "version" "${PIPELINE_VERSION}" "${deploymentFile}"
    substituteVariables "appName" "${appName}" "${deploymentFile}"
    substituteVariables "systemProps" "${systemProps}" "${deploymentFile}"
    substituteVariables "appName" "${appName}" "${serviceFile}"
    deleteAppByFile "${deploymentFile}"
    deleteAppByFile "${serviceFile}"
    deployApp "${deploymentFile}"
    deployApp "${serviceFile}"
    waitForAppToStart "${appName}"
}

function toLowerCase() {
    local string=${1}
    echo "${string}" | tr '[:upper:]' '[:lower:]'
}

function lowerCaseEnv() {
    echo "${ENVIRONMENT}" | tr '[:upper:]' '[:lower:]'
}

function deleteAppInstance() {
    local serviceName="${1}"
    local lowerCaseAppName=$( toLowerCase "${serviceName}" )
    echo "Deleting application [${lowerCaseAppName}]"
    deleteAppByName "${lowerCaseAppName}"
}

function deployEureka() {
    local imageName="${1}"
    local appName="${2}"
    echo "Deploying Eureka. Options - image name [${imageName}], app name [${appName}], env [${ENVIRONMENT}]"
    local originalDeploymentFile="${__ROOT}/k8s/eureka.yml"
    local originalServiceFile="${__ROOT}/k8s/eureka-service.yml"
    local outputDirectory="$( outputFolder )"
    mkdir -p "${outputDirectory}"
    cp ${originalDeploymentFile} ${outputDirectory}
    cp ${originalServiceFile} ${outputDirectory}
    local deploymentFile="${outputDirectory}/eureka.yml"
    local serviceFile="${outputDirectory}/eureka-service.yml"
    substituteVariables "appName" "${appName}" "${deploymentFile}"
    substituteVariables "appUrl" "${appName}.${PAAS_NAMESPACE}" "${deploymentFile}"
    substituteVariables "eurekaImg" "${imageName}" "${deploymentFile}"
    substituteVariables "appName" "${appName}" "${serviceFile}"
    if [[ "${ENVIRONMENT}" == "TEST" ]]; then
        deleteAppByFile "${deploymentFile}"
        deleteAppByFile "${serviceFile}"
    fi
    replaceApp "${deploymentFile}"
    replaceApp "${serviceFile}"
    waitForAppToStart "${appName}"
}

function escapeValueForSed() {
    echo "${1//\//\\/}"
}

function deployStubRunnerBoot() {
    local imageName="${1}"
    # TODO: Add passing of properties to docker images
    local repoWithJars="${2}"
    local rabbitName="${3}.${PAAS_NAMESPACE}"
    local eurekaName="${4}.${PAAS_NAMESPACE}"
    local stubRunnerName="${5:-stubrunner}"
    local fileExists="true"
    local stubRunnerUseClasspath="${STUBRUNNER_USE_CLASSPATH:-false}"
    echo "Deploying Stub Runner. Options - image name [${imageName}], app name [${stubRunnerName}]"
    local prop="$( retrieveStubRunnerIds )"
    echo "Found following stub runner ids [${prop}]"
    local originalDeploymentFile="${__ROOT}/k8s/stubrunner.yml"
    local originalServiceFile="${__ROOT}/k8s/stubrunner-service.yml"
    local outputDirectory="$( outputFolder )"
    mkdir -p "${outputDirectory}"
    cp ${originalDeploymentFile} ${outputDirectory}
    cp ${originalServiceFile} ${outputDirectory}
    local deploymentFile="${outputDirectory}/stubrunner.yml"
    local serviceFile="${outputDirectory}/stubrunner-service.yml"
    if [[ "${stubRunnerUseClasspath}" == "false" ]]; then
        substituteVariables "repoWithJars" "${repoWithJars}" "${deploymentFile}"
    else
        substituteVariables "repoWithJars" "" "${deploymentFile}"
    fi
    substituteVariables "appName" "${stubRunnerName}" "${deploymentFile}"
    substituteVariables "stubrunnerImg" "${imageName}" "${deploymentFile}"
    substituteVariables "rabbitAppName" "${rabbitName}" "${deploymentFile}"
    substituteVariables "eurekaAppName" "${eurekaName}" "${deploymentFile}"
    if [[ "${prop}" == "false" ]]; then
        substituteVariables "stubrunnerIds" "${prop}" "${deploymentFile}"
    else
        substituteVariables "stubrunnerIds" "" "${deploymentFile}"
    fi
    substituteVariables "appName" "${stubRunnerName}" "${serviceFile}"
    if [[ "${ENVIRONMENT}" == "TEST" ]]; then
        deleteAppByFile "${deploymentFile}"
        deleteAppByFile "${serviceFile}"
    fi
    replaceApp "${deploymentFile}"
    replaceApp "${serviceFile}"
    waitForAppToStart "${stubRunnerName}"
}

function prepareForSmokeTests() {
    echo "Retrieving group and artifact id - it can take a while..."
    local appName=$( retrieveAppName )
    mkdir -p "${OUTPUT_FOLDER}"
    logInToPaas
    # TODO: Maybe this has to be changed somehow
    local applicationPort=$( portFromKubernetes "${appName}" )
    local stubrunnerAppName="stubrunner-${appName}"
    local stubrunnerPort=$( portFromKubernetes "${stubrunnerAppName}" )
    export kubHost=$( hostFromApi "${PAAS_TEST_API_URL}" )
    export APPLICATION_URL="${kubHost}:${applicationPort}"
    export STUBRUNNER_URL="${kubHost}:${stubrunnerPort}"
    echo "Application URL [${APPLICATION_URL}]"
    echo "StubRunner URL [${STUBRUNNER_URL}]"
}

function portFromKubernetes() {
    local appName="${1}"
    echo `kubectl --context="${K8S_CONTEXT}" --namespace="${PAAS_NAMESPACE}" get svc ${appName} -o jsonpath='{.spec.ports[0].nodePort}'`
}

function waitForAppToStart() {
    local appName="${1}"
    local apiUrlVar="PAAS_${ENVIRONMENT}_API_URL"
    local apiUrl="${!apiUrlVar}"
    local port=$( portFromKubernetes "${appName}" )
    local kubHost=$( hostFromApi "${apiUrl}" )
    isAppRunning "${kubHost}" "${port}"
}

function retrieveApplicationUrl() {
    local appName=$( retrieveAppName )
    local apiUrlVar="PAAS_${ENVIRONMENT}_API_URL"
    local apiUrl="${!apiUrlVar}"
    local port=$( portFromKubernetes "${appName}" )
    local kubHost=$( hostFromApi "${apiUrl}" )
    echo "${kubHost}:${port}"
}

function isAppRunning() {
    local host="${1}"
    local port="${2}"
    local waitTime=5
    local retries=30
    local running=1
    # TODO: Why the hell I can't access /health on some services but can access other endpoints????
    local primaryHealthEndpoint="health"
    local secondaryHealthEndpoint="info"
    for i in $( seq 1 "${retries}" ); do
        sleep "${waitTime}"
        # TODO: Adding secondary health endpoint cause for some reason sometimes you can't access /health
        curl -m 5 "${host}:${port}/${primaryHealthEndpoint}" && running=0 && break ||
            curl -m 5 "${host}:${port}/${secondaryHealthEndpoint}" && running=0 && break
        echo "Fail #$i/${retries}... will try again in [${waitTime}] seconds"
    done
    if [[ "${running}" == 1 ]]; then
        echo "App failed to start"
        exit 1
    fi
    echo -e "\nApp started successfully!"
}

function hostFromApi() {
    local api="${1}"
    local string
    local id
    IFS=':' read -r id string <<< "${api}"
    echo "$id"
}

function readTestPropertiesFromFile() {
    local fileLocation="${1:-${OUTPUT_FOLDER}/test.properties}"
    local key
    local value
    if [ -f "${fileLocation}" ]
    then
      echo "${fileLocation} found."
      while IFS='=' read -r key value
      do
        key=$(echo ${key} | tr '.' '_')
        eval "${key}='${value}'"
      done < "${fileLocation}"
    else
      echo "${fileLocation} not found."
    fi
}

function stageDeploy() {
    # TODO: Consider making it less JVM specific
    local projectGroupId=$( retrieveGroupId )
    local appName=$( retrieveAppName )
    # Log in to PaaS to start deployment
    logInToPaas

    # deploy app
    deployAndRestartAppWithNameForE2ETests "${appName}" "${UNIQUE_RABBIT_NAME}" "${UNIQUE_EUREKA_NAME}" "${UNIQUE_MYSQL_NAME}"
}

function prepareForE2eTests() {
    echo "Retrieving group and artifact id - it can take a while..."
    local appName=$( retrieveAppName )
    mkdir -p "${OUTPUT_FOLDER}"
    logInToPaas
    # TODO: Maybe this has to be changed somehow
    local applicationPort=$( portFromKubernetes "${appName}" )
    local stubrunnerAppName="stubrunner-${appName}"
    export kubHost=$( hostFromApi "${PAAS_TEST_API_URL}" )
    export APPLICATION_URL="${kubHost}:${applicationPort}"
    echo "Application URL [${APPLICATION_URL}]"
}

function performGreenDeployment() {
    # TODO: Consider making it less JVM specific
    local projectGroupId=$( retrieveGroupId )
    local appName=$( retrieveAppName )
    # Log in to PaaS to start deployment
    logInToPaas

    # TODO: Consider picking services and apps from file
    # services
    export UNIQUE_RABBIT_NAME="rabbitmq-${appName}"
    deployService "RABBITMQ" "${UNIQUE_RABBIT_NAME}"
    export UNIQUE_MYSQL_NAME="mysql-${appName}"
    deployService "MYSQL" "${UNIQUE_MYSQL_NAME}"

    # dependant apps
    export UNIQUE_EUREKA_NAME="eureka-${appName}"
    deployService "EUREKA" "${UNIQUE_EUREKA_NAME}"

    # deploy app
    performGreenDeploymentOfTestedApplication "${appName}"
}

function performGreenDeploymentOfTestedApplication() {
    local appName="${1}"
    local newName="${appName}-venerable"
    echo "Renaming the app from [${appName}] -> [${newName}]"
    local appPresent="no"
    cf app "${appName}" && appPresent="yes"
    if [[ "${appPresent}" == "yes" ]]; then
        cf rename "${appName}" "${newName}"
    else
        echo "Will not rename the application cause it's not there"
    fi
    deployAndRestartAppWithName "${appName}" "${appName}-${PIPELINE_VERSION}" "PROD"
}

function deleteBlueInstance() {
    local appName=$( retrieveAppName )
    # Log in to CF to start deployment
    logInToPaas
    local oldName="${appName}-venerable"
    local appPresent="no"
    echo "Deleting the app [${oldName}]"
    cf app "${oldName}" && appPresent="yes"
    if [[ "${appPresent}" == "yes" ]]; then
        cf delete "${oldName}" -f
    else
        echo "Will not remove the old application cause it's not there"
    fi
}

__ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOWER_CASE_ENV=$( lowerCaseEnv )
export PAAS_NAMESPACE_VAR="PAAS_${ENVIRONMENT}_NAMESPACE"
[[ -z "${PAAS_NAMESPACE}" ]] && PAAS_NAMESPACE="${!PAAS_NAMESPACE_VAR}"

# CURRENTLY WE ONLY SUPPORT JVM BASED PROJECTS OUT OF THE BOX
[[ -f "${__ROOT}/projectType/pipeline-jvm.sh" ]] && source "${__ROOT}/projectType/pipeline-jvm.sh" || \
    echo "No projectType/pipeline-jvm.sh found"

# TODO: MOve this back to pipeline-jvm
# OVerriding default building options

function build() {
    local appName=$( retrieveAppName )
    echo "Additional Build Options [${BUILD_OPTIONS}]"

    ./mvnw versions:set -DnewVersion=${PIPELINE_VERSION} ${BUILD_OPTIONS}
    if [[ "${CI}" == "CONCOURSE" ]]; then
        ./mvnw clean package docker:build -DpushImageTags -DdockerImageTags="latest" -DdockerImageTags="${PIPELINE_VERSION}" ${BUILD_OPTIONS} || ( $( printTestResults ) && return 1)
        ./mvnw docker:push ${BUILD_OPTIONS} || ( $( printTestResults ) && return 1)
    else
        ./mvnw clean package docker:build -DpushImageTags -DdockerImageTags="latest" -DdockerImageTags="${PIPELINE_VERSION}" ${BUILD_OPTIONS}
        ./mvnw docker:push ${BUILD_OPTIONS}
    fi
}
