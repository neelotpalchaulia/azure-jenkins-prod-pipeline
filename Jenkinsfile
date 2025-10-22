pipeline {
  agent any

  parameters {
    booleanParam(name: 'SONAR_ENABLED', defaultValue: true, description: 'Run SonarQube analysis')
    string(name: 'SONAR_HOST', defaultValue: 'http://sonar.example.com', description: 'SonarQube server URL (self-hosted)')
    string(name: 'SONAR_PROJECT_KEY', defaultValue: 'myorg_myapp', description: 'Sonar project key')
  }

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

    stage('SonarQube') {
      when { expression { return params.SONAR_ENABLED == true } }
      steps {
        // requires a Jenkins credential (Secret Text) with id 'sonar-token'
        withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
          // run the Sonar scanner CLI in Docker, write report-task.txt into workspace
          sh ('''docker run --rm -v "$PWD":/usr/src -w /usr/src sonarsource/sonar-scanner-cli \
            -Dsonar.projectKey=''' + "${params.SONAR_PROJECT_KEY}" + ''' \
            -Dsonar.sources=. \
            -Dsonar.host.url=''' + "${params.SONAR_HOST}" + ''' \
            -Dsonar.login=$SONAR_TOKEN

          # ensure the scanner produced the task report
          if [ ! -f .scannerwork/report-task.txt ]; then echo "Sonar report-task.txt missing"; exit 1; fi
          CE_ID=$(grep '^ceTaskId=' .scannerwork/report-task.txt | cut -d'=' -f2)
          if [ -z "$CE_ID" ]; then echo "Could not find ceTaskId in report-task.txt"; exit 1; fi

          # poll the Sonar CE task until it finishes
          for i in $(seq 1 30); do
            STATUS=$(curl -s -u $SONAR_TOKEN: "${params.SONAR_HOST}/api/ce/task?id=$CE_ID" | grep -o '\"status\"\:\"[^\"]*\"' | sed -E 's/.*\"status\"\:\"([^\"]*)\".*/\1/')
            echo "Sonar CE task status: $STATUS"
            if [ "$STATUS" = "SUCCESS" ]; then break; fi
            if [ "$STATUS" = "FAILED" ]; then echo "Sonar CE task failed"; exit 1; fi
            sleep 5
          done

          # get analysis id and check Quality Gate
          ANALYSIS_ID=$(curl -s -u $SONAR_TOKEN: "${params.SONAR_HOST}/api/ce/task?id=$CE_ID" | grep -o '\"analysisId\"\:\"[^\"]*\"' | sed -E 's/.*\"analysisId\"\:\"([^\"]*)\".*/\1/')
          if [ -z "$ANALYSIS_ID" ]; then echo "No analysisId found"; exit 1; fi
          QG=$(curl -s -u $SONAR_TOKEN: "${params.SONAR_HOST}/api/qualitygates/project_status?analysisId=$ANALYSIS_ID" | grep -o '\"status\"\:\"[^\"]*\"' | sed -E 's/.*\"status\"\:\"([^\"]*)\".*/\1/')
          echo "Sonar Quality Gate: $QG"
          if [ "$QG" != "OK" ]; then echo "Quality Gate not OK: $QG"; exit 1; fi
          ''' )
        }
      }
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
          // authenticate to ACR, push images, then instruct remote host to pull the new image
          sh '''
            echo "$ACR_PASS" | docker login ${ACR} -u "$ACR_USER" --password-stdin
          '''
          sh "docker push ${IMAGE_SHA} && docker push ${IMAGE_LATEST}"
          // remote login and pull the image we just pushed
          sh ('''echo "$ACR_PASS" | ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' docker login ''' + "${ACR}" + ''' -u "$ACR_USER" --password-stdin && ssh -o StrictHostKeyChecking=no azureuser@''' + "${DEPLOY_IP}" + ''' docker pull ''' + "${IMAGE_SHA}")
        }
      }
    }

    stage('Deploy Staging') {
      steps {
        withCredentials([
          usernamePassword(credentialsId: 'acr-creds', usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS'),
          // use sshUserPrivateKey so we can pass a private key file to ssh (-i) without requiring the ssh-agent plugin
          sshUserPrivateKey(credentialsId: 'deploy-ssh', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')
        ]) {
          // login remotely and then pipe the run_remote script to the remote host using the temporary key file
          sh ('''echo "$ACR_PASS" | ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no $SSH_USER@''' + "${DEPLOY_IP}" + ''' docker login ''' + "${ACR}" + ''' -u "$ACR_USER" --password-stdin''')
          sh ('''ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no $SSH_USER@''' + "${DEPLOY_IP}" + ''' 'bash -s' < scripts/run_remote.sh ''' + "${APP}-staging ${IMAGE_SHA} 8081")
        }
      }
    }

    stage('Healthcheck Staging') {
      steps { sh "bash scripts/health_check.sh http://${DEPLOY_IP}:8081/health" }
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
        withCredentials([
          usernamePassword(credentialsId: 'acr-creds', usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS'),
          sshUserPrivateKey(credentialsId: 'deploy-ssh', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')
        ]) {
          // login remotely (using the temporary key file created by withCredentials)
          sh ('''echo "$ACR_PASS" | ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no $SSH_USER@''' + "${DEPLOY_IP}" + ''' docker login ''' + "${ACR}" + ''' -u "$ACR_USER" --password-stdin''')
          // run the repo script on the remote host to pull and run the container
          sh ('''ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no $SSH_USER@''' + "${DEPLOY_IP}" + ''' 'bash -s' < scripts/run_remote.sh ''' + "${APP}-prod ${IMAGE_SHA} 8080")
          // healthcheck against the remote endpoint; if it fails the script exits non-zero
          sh "bash scripts/health_check.sh http://${DEPLOY_IP}:8080/health"
          // NOTE: run_remote.sh always pulls the image and starts the container. If you need previous-image rollback
          // we can extend run_remote.sh to save/restore previous image name; keeping it simple for now.
        }
      }
    }
  }

  post { always { echo 'Pipeline finished' } }
}
