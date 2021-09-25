#!/bin/bash
set -e

# settings
export KUBECONFIG=~/.kube/app.config
export GRAFANA_PASS="operator"

echo
echo "==== stop and delete the minikube cluster to start fresh (this may show errors)"
if [[ "$(minikube profile list | grep '^| minikube ')" != "" ]]; then
  minikube profile list
  read -p "Minikube cluster \"minikube\"  exists. ok to delete it and restart? (y/n) " -n 1 -r
  echo 
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
    echo "bailing out..."
    exit 1
  fi
  minikube stop || true 
  minikube delete || true 
fi

echo
echo "==== start minikube fresh with KUBECONFIG=${KUBECONFIG}" 
minikube start
eval $(minikube docker-env)  # to allow for local docker repository usage

echo
echo "==== enable metrics server"
minikube addons enable metrics-server

echo
echo "==== install app packages"
npm install
export VERSION=`cat package.json | grep '^  \"version\":' | cut -d ' ' -f 4 | tr -d '",'`  # extract version from package.json
export APP=`cat package.json | grep '^  \"name\":' | cut -d ' ' -f 4 | tr -d '",'`         # extract app name from package.json

echo
echo "==== build app image ${APP}:${VERSION}"
docker build -t ${APP}:${VERSION} .

echo
echo "==== deploy application (namespaces, pods and services)"
cat app.yaml.template | envsubst | kubectl create -f - --save-config

echo
echo "==== install prometheus-community stack (this may show warnings related to beta APIs)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
cat values.yaml.template | envsubst | helm install --values - ${APP} prometheus-community/kube-prometheus-stack -n monitoring

echo 
echo "==== making services available via NodePort"
kubectl patch svc ${APP}-grafana -n monitoring -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc ${APP}-kube-prometheus-stac-prometheus -n monitoring -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc ${APP}-kube-prometheus-stac-alertmanager -n monitoring -p '{"spec":{"type":"NodePort"}}'

echo
echo "==== DONE. Try these things:"
cat static-info-dashboard.json.template | envsubst > static-info-dashboard.json
MINIKUBESERVICEURL=`minikube service ${APP}-service -n ${APP} --url`
echo "set KUBECONFIG:  export KUBECONFIG=${KUBECONFIG}"
echo "get the server info:  ${MINIKUBESERVICEURL}/info"
echo "get a random number:  ${MINIKUBESERVICEURL}/random"
echo "get the metrics:  ${MINIKUBESERVICEURL}/metrics"
echo "access grafana w/ user:admin and password:${GRAFANA_PASS}:  minikube service ${APP}-grafana -n monitoring"
echo "  import the local dashboard \"static-info-dashboard.json\" to Grafana manually."
echo "access prometheus:  minikube service ${APP}-kube-prometheus-stac-prometheus -n monitoring"
echo "access alertmanager:  minikube service ${APP}-kube-prometheus-stac-alertmanager -n monitoring"
