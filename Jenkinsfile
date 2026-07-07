pipeline {
    agent any

    parameters {
        string(name: 'IMAGE_REPOSITORY', defaultValue: '', description: 'Image repository, e.g. registry.example.com/regression-evaluator')
        string(name: 'IMAGE_TAG', defaultValue: 'latest', description: 'Image tag to deploy')
        string(name: 'NAMESPACE', defaultValue: 'default', description: 'Target OpenShift namespace/project')

        string(name: 'CURRENT_RUN', defaultValue: '', description: 'UUID of the run to evaluate (--current-run)')
        string(name: 'BASELINE_RUN', defaultValue: '', description: 'Optional: pin a baseline run UUID, overrides BASELINE_STRATEGY')
        choice(name: 'BASELINE_STRATEGY', choices: ['latest', 'golden'], description: 'Baseline selection strategy')
        booleanParam(name: 'RELEASE_GATE', defaultValue: true, description: 'Fail the build on regression')
        booleanParam(name: 'ENABLE_CLUSTERING', defaultValue: true, description: 'Enable clustering analysis')
        booleanParam(name: 'ENABLE_SLO_CONFIG', defaultValue: false, description: 'Mount slo.yaml and pass it via --slo-config')

        string(name: 'DB_HOST', defaultValue: '', description: 'PostgreSQL host')
        string(name: 'DB_PORT', defaultValue: '5432', description: 'PostgreSQL port')
        string(name: 'DB_NAME', defaultValue: 'perfdb', description: 'PostgreSQL database name')
        string(name: 'DB_USER', defaultValue: 'perfuser', description: 'PostgreSQL user')
        string(name: 'DB_SCHEMA', defaultValue: '', description: 'PostgreSQL schema (search_path). Leave blank to use the role default.')
        string(name: 'DB_EXISTING_SECRET', defaultValue: '', description: 'Name of an existing Secret in NAMESPACE holding the DB password (key: password). Leave blank to supply DB_PASSWORD_CREDENTIAL_ID instead.')
        string(name: 'DB_PASSWORD_CREDENTIAL_ID', defaultValue: '', description: 'Jenkins "Secret text" credential ID for the DB password. Ignored if DB_EXISTING_SECRET is set.')

        string(name: 'VALUES_FILE', defaultValue: '', description: 'Optional path to an extra Helm values file (relative to repo root).')
        string(name: 'COPY_GRACE_SECONDS', defaultValue: '300', description: 'Seconds the pod sleeps after generating the report, giving Jenkins time to copy it out.')
    }

    environment {
        RELEASE_NAME = "regression-evaluator-${env.BUILD_NUMBER}"
        CHART_PATH   = "."
        REPORT_PATH  = "/tmp/perf-report.html"
        CONTROL_DIR  = "/tmp"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Helm Lint') {
            steps {
                sh "helm lint ${CHART_PATH}"
            }
        }

        stage('Deploy Job') {
            steps {
                script {
                    def valuesArgs   = params.VALUES_FILE?.trim()        ? "-f ${params.VALUES_FILE}" : ''
                    def sloArgs      = params.ENABLE_SLO_CONFIG          ? "--set sloConfig.enabled=true --set-file sloConfig.content=${CHART_PATH}/slo.yaml" : ''
                    def dbSecretArgs = params.DB_EXISTING_SECRET?.trim() ? "--set db.existingSecret=${params.DB_EXISTING_SECRET}" : ''

                    def commonArgs = """
                          ${valuesArgs} \\
                          ${sloArgs} \\
                          --set image.repository=${params.IMAGE_REPOSITORY} \\
                          --set image.tag=${params.IMAGE_TAG} \\
                          --set job.currentRun=${params.CURRENT_RUN} \\
                          --set job.baselineRun=${params.BASELINE_RUN} \\
                          --set job.baselineStrategy=${params.BASELINE_STRATEGY} \\
                          --set job.releaseGate=${params.RELEASE_GATE} \\
                          --set job.enableClustering=${params.ENABLE_CLUSTERING} \\
                          --set job.copyGraceSeconds=${params.COPY_GRACE_SECONDS} \\
                          --set db.host=${params.DB_HOST} \\
                          --set db.port=${params.DB_PORT} \\
                          --set db.name=${params.DB_NAME} \\
                          --set db.user=${params.DB_USER} \\
                          --set db.schema=${params.DB_SCHEMA} \\
                          ${dbSecretArgs}
                    """

                    // helm template | oc apply avoids Helm storing release state as Secrets,
                    // which requires list permission on secrets in the target namespace.
                    if (params.DB_EXISTING_SECRET?.trim()) {
                        sh "helm template ${RELEASE_NAME} ${CHART_PATH} ${commonArgs} | oc apply -n ${params.NAMESPACE} -f -"
                    } else {
                        withCredentials([usernamePassword(
                            credentialsId: params.DB_PASSWORD_CREDENTIAL_ID,
                            usernameVariable: 'DB_CRED_USER',
                            passwordVariable: 'DB_PASSWORD'
                        )]) {
                            sh "helm template ${RELEASE_NAME} ${CHART_PATH} ${commonArgs} --set-string db.password='${DB_PASSWORD}' | oc apply -n ${params.NAMESPACE} -f -"
                        }
                    }
                }
            }
        }

        stage('Fetch Report') {
            steps {
                script {
                    timeout(time: 10, unit: 'MINUTES') {
                        sh """
                          set -e
                          echo "Waiting for pod to be scheduled..."
                          until POD=\$(oc get pods -n ${params.NAMESPACE} -l job-name=${RELEASE_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [ -n "\$POD" ]; do
                            sleep 2
                          done
                          echo "\$POD" > .pod_name
                          echo "Pod: \$POD"

                          echo "Waiting for regression-evaluator to finish..."
                          until oc exec "\$POD" -n ${params.NAMESPACE} -- test -f ${CONTROL_DIR}/done 2>/dev/null; do
                            sleep 3
                          done
                        """
                    }

                    def pod = readFile('.pod_name').trim()
                    sh "oc exec ${pod} -n ${params.NAMESPACE} -- cat ${REPORT_PATH} > perf-report.html"
                    sh "oc exec ${pod} -n ${params.NAMESPACE} -- cat ${CONTROL_DIR}/exitcode > .exitcode"

                    archiveArtifacts artifacts: 'perf-report.html', allowEmptyArchive: true

                    def rc = readFile('.exitcode').trim()
                    echo "regression-evaluator exit code: ${rc}"
                    if (rc != '0') {
                        error("regression-evaluator exited with code ${rc} — check perf-report.html and regression-evaluator.log")
                    }
                }
            }
        }
    }

    post {
        always {
            sh "oc logs job/${RELEASE_NAME} -n ${params.NAMESPACE} > regression-evaluator.log 2>&1 || true"
            archiveArtifacts artifacts: 'regression-evaluator.log', allowEmptyArchive: true
            // Clean up all resources created by the chart (no helm uninstall needed)
            sh "oc delete job/${RELEASE_NAME} -n ${params.NAMESPACE} --ignore-not-found || true"
            sh "oc delete secret/${RELEASE_NAME}-db -n ${params.NAMESPACE} --ignore-not-found || true"
            sh "oc delete configmap/${RELEASE_NAME}-slo -n ${params.NAMESPACE} --ignore-not-found || true"
        }
    }
}
