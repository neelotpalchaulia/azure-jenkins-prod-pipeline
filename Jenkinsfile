pipeline {
  agent any

  environment {
    APP = 'myapp'
    ACR = 'acrjenkinsxyz.azurecr.io'
    DEPLOY_IP = '20.63.13.135'

    IMAGE_SHA = "${ACR}/${APP}:${env.GIT_COMMIT?.take(8)}"
    IMAGE_LATEST = "${ACR}/${APP}:latest"
  }

  options { timestamps(); buildDiscarder(logRotator(numToKeepStr: '30')) }

  stages {
    stage('Checkout') { steps { checkout scm } }

    stage('Test') {
      steps {
        sh '''
          /usr/local/go/bin/go fmt ./app/... | tee fmt.out
          /usr/local/go/bin/go -C app test ./... -v | tee test.out
        '''
      }
      post { always { archiveArtifacts artifacts: 'fmt.out,test.out', onlyIfSuccessful: false } }
    }

    stage('Build') {
      steps { sh "docker build -t ${IMAGE_SHA} -t ${IMAGE_LATEST} ." }
    }

    stage('Scan') {
      steps {
        sh "trivy image --exit-code 1 --severity HIGH,CRITICAL ${IMAGE_SHA} | tee trivy.out"
      }
      post {
        always { archiveArtifacts artifacts: 'trivy.out', onlyIfSuccessful: false }
      }
    }

    stage('Push') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds', usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          // push images to ACR first, then instruct the remote host to pull the new image
          sh "docker push ${IMAGE_SHA} && docker push ${IMAGE_LATEST}"
          // remote login and pull the image we just pushed
          sh ('''echo "$ACR_PASS" | ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' docker login ''' + "${ACR}" + ''' -u "$ACR_USER" --password-stdin && ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' docker pull ''' + "${IMAGE_SHA}")
        }
      }
    }

    stage('Deploy Staging') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds', usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sshagent(credentials: ['deploy-ssh']) {
            // login remotely and then pipe the run_remote script to the remote host
            sh ('''echo "$ACR_PASS" | ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' docker login ''' + "${ACR}" + ''' -u "$ACR_USER" --password-stdin''')
            sh ('''ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' 'bash -s' < scripts/run_remote.sh ''' + "${APP}-staging ${IMAGE_SHA} 8081")
          }
        }
      }
    }

    stage('Healthcheck Staging') {
      steps { sh "scripts/health_check.sh http://${DEPLOY_IP}:8081/health" }
    }

    stage('Promote') {
      when { branch 'main' }
      steps {
        input message: 'Promote to production?', ok: 'Yes'
      }
    }

    stage('Deploy Prod') {
      when { branch 'main' }
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds', usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sshagent(credentials: ['deploy-ssh']) {
            // login remotely
            sh ('''echo "$ACR_PASS" | ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' docker login ''' + "${ACR}" + ''' -u "$ACR_USER" --password-stdin''')
            // run the repo script on the remote host to pull and run the container
            sh ('''ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' 'bash -s' < scripts/run_remote.sh ''' + "${APP}-prod ${IMAGE_SHA} 8080")
            // healthcheck against the remote endpoint; if it fails the script exits non-zero
            sh "scripts/health_check.sh http://${DEPLOY_IP}:8080/health"
            // NOTE: run_remote.sh always pulls the image and starts the container. If you need previous-image rollback
            // we can extend run_remote.sh to save/restore previous image name; keeping it simple for now.
          }
        }
      }
    }
  }

  post { always { echo 'Pipeline finished' } }
}
