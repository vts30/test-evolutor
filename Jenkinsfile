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

        stage('Check Tools') {
            steps {
                sh '''
                  echo "=== oc ===" && oc version || echo "oc not found"
                  echo "=== podman ===" && podman --version || echo "podman not found"
                  echo "=== helm ===" && helm version || echo "helm not found"
                  echo "=== whoami ===" && whoami
                  echo "=== namespace ===" && cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
                '''
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
                    // Build a flat single-line args string to avoid newline/backslash issues
                    // when interpolating into sh "..."
                    def helmArgs = ''
                    if (params.VALUES_FILE?.trim())     helmArgs += "-f ${params.VALUES_FILE} "
                    if (params.ENABLE_SLO_CONFIG)       helmArgs += "--set sloConfig.enabled=true --set-file sloConfig.content=${CHART_PATH}/slo.yaml "
                    helmArgs += "--set image.repository=${params.IMAGE_REPOSITORY} "
                    helmArgs += "--set image.tag=${params.IMAGE_TAG} "
                    helmArgs += "--set job.currentRun=${params.CURRENT_RUN} "
                    helmArgs += "--set job.baselineRun=${params.BASELINE_RUN} "
                    helmArgs += "--set job.baselineStrategy=${params.BASELINE_STRATEGY} "
                    helmArgs += "--set job.releaseGate=${params.RELEASE_GATE} "
                    helmArgs += "--set job.enableClustering=${params.ENABLE_CLUSTERING} "
                    helmArgs += "--set job.copyGraceSeconds=${params.COPY_GRACE_SECONDS} "
                    helmArgs += "--set db.host=${params.DB_HOST} "
                    helmArgs += "--set db.port=${params.DB_PORT} "
                    helmArgs += "--set db.name=${params.DB_NAME} "
                    helmArgs += "--set db.schema=${params.DB_SCHEMA} "
                    if (params.DB_EXISTING_SECRET?.trim()) helmArgs += "--set db.existingSecret=${params.DB_EXISTING_SECRET} "

                    if (params.DB_EXISTING_SECRET?.trim()) {
                        sh "helm template ${RELEASE_NAME} ${CHART_PATH} ${helmArgs} | oc apply -n ${params.NAMESPACE} -f -"
                    } else {
                        withCredentials([usernamePassword(
                            credentialsId: params.DB_PASSWORD_CREDENTIAL_ID,
                            usernameVariable: 'DB_CRED_USER',
                            passwordVariable: 'DB_PASSWORD'
                        )]) {
                            // Username comes from credential (same as other pipelines using PG_CREDENTIALS_ID)
                            // Password set as PGPASSWORD env var via Secret — avoids URL special-char issues
                            sh "helm template ${RELEASE_NAME} ${CHART_PATH} ${helmArgs} --set db.user=\$DB_CRED_USER --set-string db.password=\$DB_PASSWORD | oc apply -n ${params.NAMESPACE} -f -"
                        }
                    }
                    sh """
                      echo "=== Resources created in ${params.NAMESPACE} ==="
                      oc get job,secret,configmap -n ${params.NAMESPACE} | grep ${RELEASE_NAME} || echo "WARNING: no resources found matching ${RELEASE_NAME}"
                    """
                }
            }
        }

        stage('Fetch Report') {
            steps {
                script {
                    timeout(time: 10, unit: 'MINUTES') {
                        sh """
                          set -e
                          echo "=== Job details (events show why pod may not start) ==="
                          sleep 3
                          oc describe job/${RELEASE_NAME} -n ${params.NAMESPACE} || true
                          echo "=== Resource quota ==="
                          oc describe resourcequota -n ${params.NAMESPACE} || true

                          echo "Waiting for pod to be scheduled (prefix: ${RELEASE_NAME})..."
                          RETRIES=0
                          until POD=\$(oc get pods -n ${params.NAMESPACE} --no-headers 2>/dev/null | grep "^${RELEASE_NAME}" | awk '{print \$1}' | head -1) && [ -n "\$POD" ]; do
                            RETRIES=\$((RETRIES+1))
                            if [ \$RETRIES -ge 30 ]; then
                              echo "ERROR: pod not found after 30 retries. Current pods:"
                              oc get pods -n ${params.NAMESPACE} || true
                              exit 1
                            fi
                            sleep 5
                          done
                          echo "\$POD" > .pod_name
                          echo "Pod found: \$POD"

                          echo "Waiting for regression-evaluator to finish..."
                          until oc exec "\$POD" -n ${params.NAMESPACE} -- test -f ${CONTROL_DIR}/done 2>/dev/null; do
                            sleep 3
                          done
                        """
                    }

                    def pod = readFile('.pod_name').trim()

                    // Read exit code first so we always know the outcome
                    sh "oc exec ${pod} -n ${params.NAMESPACE} -- cat ${CONTROL_DIR}/exitcode > .exitcode 2>&1 || echo 'unknown' > .exitcode"

                    // Report may not exist if regression-evaluator failed — copy best-effort
                    sh "oc exec ${pod} -n ${params.NAMESPACE} -- cat ${REPORT_PATH} > perf-report.html 2>&1 || true"

                    archiveArtifacts artifacts: 'perf-report.html', allowEmptyArchive: true

                    def rc = readFile('.exitcode').trim()
                    echo "regression-evaluator exit code: ${rc}"
                    if (rc != '0') {
                        error("regression-evaluator exited with code ${rc} — check regression-evaluator.log for the root cause")
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
