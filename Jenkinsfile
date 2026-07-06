pipeline {
    agent any

    parameters {
        string(name: 'IMAGE_REPOSITORY', defaultValue: '', description: 'Image repository, e.g. registry.example.com/regression-evaluator')
        string(name: 'IMAGE_TAG', defaultValue: 'latest', description: 'Image tag to deploy')
        string(name: 'NAMESPACE', defaultValue: 'default', description: 'Target Kubernetes namespace')

        string(name: 'CURRENT_RUN', defaultValue: '', description: 'UUID of the run to evaluate (--current-run)')
        string(name: 'BASELINE_RUN', defaultValue: '', description: 'Optional: pin a baseline run UUID, overrides BASELINE_STRATEGY')
        choice(name: 'BASELINE_STRATEGY', choices: ['latest', 'golden'], description: 'Baseline selection strategy')
        booleanParam(name: 'RELEASE_GATE', defaultValue: true, description: 'Fail the job (and this build) on regression')
        booleanParam(name: 'ENABLE_CLUSTERING', defaultValue: true, description: 'Enable clustering analysis')

        string(name: 'DB_HOST', defaultValue: '', description: 'PostgreSQL host')
        string(name: 'DB_PORT', defaultValue: '5432', description: 'PostgreSQL port')
        string(name: 'DB_NAME', defaultValue: 'perfdb', description: 'PostgreSQL database name')
        string(name: 'DB_USER', defaultValue: 'perfuser', description: 'PostgreSQL user')
        string(name: 'DB_SCHEMA', defaultValue: '', description: 'PostgreSQL schema (search_path). Leave blank to use the role default.')
        string(name: 'DB_EXISTING_SECRET', defaultValue: '', description: 'Name of an existing Secret in NAMESPACE holding the DB password (key: password). Leave blank to supply DB_PASSWORD_CREDENTIAL_ID instead.')
        string(name: 'DB_PASSWORD_CREDENTIAL_ID', defaultValue: '', description: 'Jenkins "Secret text" credential ID holding the DB password. Ignored if DB_EXISTING_SECRET is set.')

        string(name: 'KUBECONFIG_CREDENTIAL_ID', defaultValue: 'kubeconfig', description: 'Jenkins "Secret file" credential ID for the target cluster kubeconfig')
        string(name: 'VALUES_FILE', defaultValue: '', description: 'Optional path (relative to repo root) to an extra Helm values file, e.g. for sloConfig.content. Layered under the --set overrides below.')
    }

    environment {
        RELEASE_NAME = "regression-evaluator-${env.BUILD_NUMBER}"
        CHART_PATH   = "helm/regression-evaluator"
        // Must match helm/regression-evaluator/values.yaml job.outputPath and job.controlDir
        // (override both here and via --set if you change them in values.yaml).
        REPORT_PATH  = "/tmp/perf-report.html"
        CONTROL_DIR  = "/tmp/regression-evaluator-control"
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
                withCredentials([file(credentialsId: params.KUBECONFIG_CREDENTIAL_ID, variable: 'KUBECONFIG')]) {
                    script {
                        def dbSecretArgs = ''
                        def valuesArgs = params.VALUES_FILE?.trim() ? "-f ${params.VALUES_FILE}" : ''
                        // No --wait: the Job intentionally keeps its pod alive (sleeping) after
                        // regression-evaluator exits so "Fetch Report" below can kubectl cp out
                        // of it. --wait would block here until that sleep elapses.
                        if (params.DB_EXISTING_SECRET?.trim()) {
                            dbSecretArgs = "--set db.existingSecret=${params.DB_EXISTING_SECRET}"
                            sh """
                              helm upgrade --install ${RELEASE_NAME} ${CHART_PATH} \\
                                --namespace ${params.NAMESPACE} --create-namespace \\
                                ${valuesArgs} \\
                                --set image.repository=${params.IMAGE_REPOSITORY} \\
                                --set image.tag=${params.IMAGE_TAG} \\
                                --set job.currentRun=${params.CURRENT_RUN} \\
                                --set job.baselineRun=${params.BASELINE_RUN} \\
                                --set job.baselineStrategy=${params.BASELINE_STRATEGY} \\
                                --set job.releaseGate=${params.RELEASE_GATE} \\
                                --set job.enableClustering=${params.ENABLE_CLUSTERING} \\
                                --set db.host=${params.DB_HOST} \\
                                --set db.port=${params.DB_PORT} \\
                                --set db.name=${params.DB_NAME} \\
                                --set db.user=${params.DB_USER} \\
                                --set db.schema=${params.DB_SCHEMA} \\
                                ${dbSecretArgs}
                            """
                        } else {
                            withCredentials([string(credentialsId: params.DB_PASSWORD_CREDENTIAL_ID, variable: 'DB_PASSWORD')]) {
                                sh """
                                  helm upgrade --install ${RELEASE_NAME} ${CHART_PATH} \\
                                    --namespace ${params.NAMESPACE} --create-namespace \\
                                    ${valuesArgs} \\
                                    --set image.repository=${params.IMAGE_REPOSITORY} \\
                                    --set image.tag=${params.IMAGE_TAG} \\
                                    --set job.currentRun=${params.CURRENT_RUN} \\
                                    --set job.baselineRun=${params.BASELINE_RUN} \\
                                    --set job.baselineStrategy=${params.BASELINE_STRATEGY} \\
                                    --set job.releaseGate=${params.RELEASE_GATE} \\
                                    --set job.enableClustering=${params.ENABLE_CLUSTERING} \\
                                    --set db.host=${params.DB_HOST} \\
                                    --set db.port=${params.DB_PORT} \\
                                    --set db.name=${params.DB_NAME} \\
                                    --set db.user=${params.DB_USER} \\
                                    --set db.schema=${params.DB_SCHEMA} \\
                                    --set-string db.password='${DB_PASSWORD}'
                                """
                            }
                        }
                    }
                }
            }
        }

        stage('Fetch Report') {
            steps {
                withCredentials([file(credentialsId: params.KUBECONFIG_CREDENTIAL_ID, variable: 'KUBECONFIG')]) {
                    script {
                        timeout(time: 10, unit: 'MINUTES') {
                            sh """
                              set -e
                              echo "Waiting for pod to be scheduled..."
                              until POD=\$(kubectl get pods -n ${params.NAMESPACE} -l job-name=${RELEASE_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [ -n "\$POD" ]; do
                                sleep 2
                              done
                              echo "\$POD" > .pod_name
                              echo "Pod: \$POD"

                              echo "Waiting for regression-evaluator to finish (done marker at ${CONTROL_DIR})..."
                              until kubectl exec "\$POD" -n ${params.NAMESPACE} -- test -f ${CONTROL_DIR}/done 2>/dev/null; do
                                sleep 3
                              done
                            """
                        }

                        def pod = readFile('.pod_name').trim()
                        sh """
                          kubectl cp ${params.NAMESPACE}/${pod}:${REPORT_PATH} ./perf-report.html || true
                          kubectl exec ${pod} -n ${params.NAMESPACE} -- cat ${CONTROL_DIR}/exitcode > .exitcode
                        """
                        archiveArtifacts artifacts: 'perf-report.html', allowEmptyArchive: true

                        def rc = readFile('.exitcode').trim()
                        echo "regression-evaluator exit code: ${rc}"
                        if (rc != '0') {
                            error("regression-evaluator exited with code ${rc} (regression detected or run error) - see perf-report.html and regression-evaluator.log")
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            // Runs even if "Fetch Report" failed (e.g. release-gate caught a regression),
            // which is the case where the logs matter most.
            withCredentials([file(credentialsId: params.KUBECONFIG_CREDENTIAL_ID, variable: 'KUBECONFIG')]) {
                sh "kubectl logs job/${RELEASE_NAME} -n ${params.NAMESPACE} > regression-evaluator.log 2>&1 || true"
                archiveArtifacts artifacts: 'regression-evaluator.log', allowEmptyArchive: true
                sh "helm uninstall ${RELEASE_NAME} -n ${params.NAMESPACE} || true"
            }
        }
    }
}
