#!/bin/bash
set -e

# settings
export KUBECONFIG=~/.kube/app.config
export GRAFANA_PASS="operator"
unset MINIKUBEIP

MINIKUBEPROFILE="$(minikube profile list | grep '^| minikube ')" || true
if [[ "${MINIKUBEPROFILE}" != "" ]]; then
  echo
  echo "==== stop and delete the minikube cluster to start fresh (this may show errors)"
  #minikube profile list
  if [[ "$(echo ${MINIKUBEPROFILE} | cut -d '|' -f5 )" != " " ]]; then
    MINIKUBEIP=`minikube ip`
  fi
  read -p "Minikube cluster \"minikube\" exists. Ok to delete it and restart? (y/n) " -n 1 -r
  echo 
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
    echo "bailing out..."
    exit 1
  fi
  minikube stop || true 
  minikube delete || true 
fi

if [[ "${MINIKUBEIP}" == "" ]]; then
  echo
  echo "==== test minikube start and stop afterwards to find the IP address needed for etcd pod monitoring"
  minikube start
  MINIKUBEIP=`minikube ip`
  minikube stop || true 
fi

echo
echo "==== start minikube expecting minikube IP = \"${MINIKUBEIP}\"" 
minikube start \
  --extra-config=controller-manager.bind-address=0.0.0.0 \
  --extra-config=scheduler.bind-address=0.0.0.0 \
  --extra-config=etcd.listen-metrics-urls=http://127.0.0.1:2381,http://${MINIKUBEIP}:2381 
eval $(minikube docker-env)  # to allow for local docker repository usage

echo
echo "==== enable metrics server"
minikube addons enable metrics-server

echo
echo "==== install app packages"
npm install
export VERSION=`cat package.json | grep '^  \"version\":' | cut -d ' ' -f 4 | tr -d '",'`  # extract version from package.json
export APP=`cat package.json | grep '^  \"name\":' | cut -d ' ' -f 4 | tr -d '",'`         # extract app name from package.json

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
cat static-info-dashboard.json.template | envsubst | sed 's/^/    /' > static-info-dashboard.json
cat configmap.yaml.fragment static-info-dashboard.json | kubectl apply -n monitoring -f -
kubectl rollout status deployment.apps ${APP}-grafana -n monitoring --request-timeout 5m
kubectl rollout status deployment.apps ${APP}-kube-state-metrics -n monitoring --request-timeout 5m
kubectl rollout status deployment.apps ${APP}-kube-prometheus-stac-operator -n monitoring --request-timeout 5m

echo 
echo "==== making services available via NodePort"
kubectl patch svc ${APP}-grafana -n monitoring -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc ${APP}-kube-prometheus-stac-prometheus -n monitoring -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc ${APP}-kube-prometheus-stac-alertmanager -n monitoring -p '{"spec":{"type":"NodePort"}}'

echo
echo "==== DONE. Try these things:"
MINIKUBESERVICEURL=`minikube service ${APP}-service -n ${APP} --url`
MINIKUBEGRAFANAURL=`minikube service ${APP}-grafana -n monitoring --url`
MINIKUBEPROMETHEUSURL=`minikube service ${APP}-kube-prometheus-stac-prometheus -n monitoring --url`
MINIKUBEALERTMANAGERURL=`minikube service ${APP}-kube-prometheus-stac-alertmanager -n monitoring --url`
echo "set KUBECONFIG:  export KUBECONFIG=${KUBECONFIG}"
echo "${APP}: get the server info:  ${MINIKUBESERVICEURL}/info"
echo "${APP}: get a random number:  ${MINIKUBESERVICEURL}/random"
echo "${APP}: get the metrics:  ${MINIKUBESERVICEURL}/metrics"
echo "Grafana w/ user:admin and password:${GRAFANA_PASS}:  ${MINIKUBEGRAFANAURL}"
echo "Prometheus:  ${MINIKUBEPROMETHEUSURL}/targets"
echo "Alertmanager:  ${MINIKUBEALERTMANAGERURL}"
