pipeline {
  agent any

  environment {
    APP   = 'myapp'
    ACR   = 'acrjenkinsxyz.azurecr.io'      //ACR login server
    DEPLOY_IP = '20.63.13.135'              // Deploy VM public IP

    IMAGE_SHA    = "${ACR}/${APP}:${env.GIT_COMMIT?.take(8)}"
    IMAGE_LATEST = "${ACR}/${APP}:latest"
  }

  options {
    timestamps()
    ansiColor('xterm')
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  triggers {
    pollSCM('@daily') // add GitHub webhook later
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Go fmt & Tests') {
      steps {
        sh '''
          /usr/local/go/bin/go fmt ./app/... | tee fmt.out
          /usr/local/go/bin/go -C app test ./... -v | tee test.out
        '''
      }
      post {
        always { archiveArtifacts artifacts: 'fmt.out,test.out', onlyIfSuccessful: false }
      }
    }

    stage('Build Docker image') {
      steps {
        sh "docker build -t ${IMAGE_SHA} -t ${IMAGE_LATEST} ."
      }
    }

    stage('Security scan (Trivy)') {
      steps {
        sh "trivy image --exit-code 1 --severity HIGH,CRITICAL ${IMAGE_SHA} | tee trivy.out"
      }
      post {
        always { archiveArtifacts artifacts: 'trivy.out', onlyIfSuccessful: false }
      }
    }

    stage('Push to ACR') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds',
                    usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sh '''
            echo "$ACR_PASS" | docker login ${ACR} -u "$ACR_USER" --password-stdin
          '''
          sh """
            docker push ${IMAGE_SHA}
            docker push ${IMAGE_LATEST}
          """
        }
      }
    }

    stage('Deploy to STAGING (remote)') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds',
                    usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sshagent(credentials: ['deploy-ssh']) {
            sh ('''ssh -o StrictHostKeyChecking=no azureuser@''' +
              "${DEPLOY_IP}" + ''' '\n                echo "$ACR_PASS" | docker login ''' +
              "${ACR}" + ''' -u "$ACR_USER" --password-stdin &&\n                docker pull ''' +
              "${IMAGE_SHA}" + ''' &&\n                docker rm -f ''' +
              "${APP}-staging" + ''' || true &&\n                docker run -d --name ''' +
              "${APP}-staging" + ''' -p 8081:8080 ''' +
              "${IMAGE_SHA}" + '''\n              '\n            ''')
          }
        }
      }
    }

    stage('Health check (staging)') {
      steps {
        sh "scripts/health_check.sh http://${DEPLOY_IP}:8081/health"
      }
    }

    stage('Approval for PROD') {
      when { branch 'main' }
      steps { input message: 'Promote to PRODUCTION?', ok: 'Deploy' }
    }

    stage('Deploy to PROD (with rollback)') {
      when { branch 'main' }
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds',
                    usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sshagent(credentials: ['deploy-ssh']) {
            sh ('''ssh -o StrictHostKeyChecking=no azureuser@''' +
              "${DEPLOY_IP}" + ''' '\n                set -e\n                prev=$(docker inspect -f "{{.Config.Image}}" ''' +
              "${APP}-prod" + ''' 2>/dev/null || true)\n                echo "$ACR_PASS" | docker login ''' +
              "${ACR}" + ''' -u "$ACR_USER" --password-stdin\n                docker pull ''' +
              "${IMAGE_SHA}" + '''\n                docker rm -f ''' +
              "${APP}-prod" + ''' || true\n                docker run -d --name ''' +
              "${APP}-prod" + ''' -p 8080:8080 ''' +
              "${IMAGE_SHA}" + '''\n                # health check prod locally on the server\n                for i in {1..30}; do\n                  curl -fsS http://localhost:8080/health && ok=1 && break || true\n                  sleep 3\n                done\n                if [ "$ok" != "1" ]; then\n                  echo "Prod health failed. Rolling back..."\n                  if [ -n "$prev" ]; then\n                    docker rm -f ''' +
              "${APP}-prod" + ''' || true\n                    docker run -d --name ''' +
              "${APP}-prod" + ''' -p 8080:8080 "$prev"\n                  fi\n                  exit 1\n                fi\n              '\n            ''')
          }
        }
      }
    }
  }

  post {
    success { echo '✅ Pipeline succeeded' }
    failure { echo '❌ Pipeline failed' }
  }
}
