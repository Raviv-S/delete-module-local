#!/usr/bin/env bash

set -x
set -e

# Run from main dir
export WORKING_DIR=hack/test-script
export ACCESS_KEY=1234
export SECRET_KEY=1234
export TOOLBIN=hack/tools/bin

kubernetesVersion=$(${TOOLBIN}/kubectl version -o=json | jq -r '.clientVersion.minor')
fybrikVersion=0.6.4
moduleVersion=0.6.0
certManagerVersion=1.6.2

# Trim the last two charts of the module version
# to construct the module resource path
moduleResourceVersion=${moduleVersion%??}".0"

export CLUSTER_NAME=kind-delete-fybrik

if [ $kubernetesVersion == "19" ]
then
    ${TOOLBIN}/kind delete clusters ${CLUSTER_NAME}
    ${TOOLBIN}/kind create cluster --name=${CLUSTER_NAME} --image=kindest/node:v1.19.11@sha256:07db187ae84b4b7de440a73886f008cf903fcf5764ba8106a9fd5243d6f32729
elif [ $kubernetesVersion == "20" ]
then
    ${TOOLBIN}/kind delete clusters ${CLUSTER_NAME}
    ${TOOLBIN}/kind create cluster --name=${CLUSTER_NAME} --image=kindest/node:v1.20.7@sha256:cbeaf907fc78ac97ce7b625e4bf0de16e3ea725daf6b04f930bd14c67c671ff9
elif [ $kubernetesVersion == "21" ]
then
    ${TOOLBIN}/kind delete clusters ${CLUSTER_NAME}
    kind create cluster --name=${CLUSTER_NAME} --image=kindest/node:v1.21.1@sha256:69860bda5563ac81e3c0057d654b5253219618a22ec3a346306239bba8cfa1a6
elif [ $kubernetesVersion == "22" ]
then
    ${TOOLBIN}/kind delete clusters ${CLUSTER_NAME}
    kind create cluster --name=${CLUSTER_NAME} --image=kindest/node:v1.22.0@sha256:b8bda84bb3a190e6e028b1760d277454a72267a5454b57db34437c34a588d047
else
    echo "Unsupported kind version"
    exit 1
fi


# Update helm repo
${TOOLBIN}/helm repo add jetstack https://charts.jetstack.io
${TOOLBIN}/helm repo add hashicorp https://helm.releases.hashicorp.com
${TOOLBIN}/helm repo add fybrik-charts https://fybrik.github.io/charts
${TOOLBIN}/helm repo update

# Install cert manager
${TOOLBIN}/helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version v$certManagerVersion \
    --create-namespace \
    --set installCRDs=true \
    --wait --timeout 600s


# Install vault
${TOOLBIN}/helm install vault fybrik-charts/vault --create-namespace -n fybrik-system \
        --set "vault.injector.enabled=false" \
        --set "vault.server.dev.enabled=true" \
        --values https://raw.githubusercontent.com/fybrik/fybrik/v$fybrikVersion/charts/vault/env/dev/vault-single-cluster-values.yaml
    ${TOOLBIN}/kubectl wait --for=condition=ready --all pod -n fybrik-system --timeout=400s


# Install fybrik charts
cd ~/fybrik
helm install fybrik-crd charts/fybrik-crd -n fybrik-system --wait
helm install fybrik charts/fybrik --set global.tag=master --set global.imagePullPolicy=Always -n fybrik-system --wait
cd -

# Create Module:
CMD="${TOOLBIN}/kubectl apply -f ${WORKING_DIR}/../../module.yaml -n fybrik-system"
count=0
until $CMD
do
  if [[ $count -eq 10 ]]
  then
    break
  fi
  sleep 1
  ((count=count+1))
done

# Notebook sample
${TOOLBIN}/kubectl create namespace fybrik-notebook-sample
${TOOLBIN}/kubectl config set-context --current --namespace=fybrik-notebook-sample

# Localstack:
${TOOLBIN}/helm repo add localstack-charts https://localstack.github.io/helm-charts
${TOOLBIN}/helm install localstack localstack-charts/localstack --set startServices="s3" --set service.type=ClusterIP
${TOOLBIN}/kubectl wait --for=condition=ready --all pod -n fybrik-notebook-sample --timeout=600s
${TOOLBIN}/kubectl port-forward svc/localstack 4566:4566 &

export ENDPOINT="http://127.0.0.1:4566"
export BUCKET="demo"
export OBJECT_KEY="PS_20174392719_1491204439457_log.csv"
export FILEPATH="$WORKING_DIR/PS_20174392719_1491204439457_log.csv"
aws configure set aws_access_key_id ${ACCESS_KEY} && aws configure set aws_secret_access_key ${SECRET_KEY} && aws --endpoint-url=${ENDPOINT} s3api create-bucket --bucket ${BUCKET} && aws --endpoint-url=${ENDPOINT} s3api put-object --bucket ${BUCKET} --key ${OBJECT_KEY} --body ${FILEPATH}

cat << EOF | ${TOOLBIN}/kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: paysim-csv
type: Opaque
stringData:
  access_key: "${ACCESS_KEY}"
  secret_key: "${SECRET_KEY}"
EOF

# Create Asset
${TOOLBIN}/kubectl apply -f $WORKING_DIR/Asset-0.6.0.yaml -n fybrik-notebook-sample
${TOOLBIN}/kubectl describe Asset paysim-csv -n fybrik-notebook-sample

# Create policy
${TOOLBIN}/kubectl -n fybrik-system create configmap sample-policy --from-file=$WORKING_DIR/sample-policy-0.6.0.rego
${TOOLBIN}/kubectl -n fybrik-system label configmap sample-policy openpolicyagent.org/policy=rego

c=0
while [[ $(${TOOLBIN}/kubectl get cm sample-policy -n fybrik-system -o 'jsonpath={.metadata.annotations.openpolicyagent\.org/policy-status}') != '{"status":"ok"}' ]]
do
    echo "waiting"
    ((c++)) && ((c==25)) && break
    sleep 1
done

# Install Fybrikapplication
${TOOLBIN}/kubectl apply -f ${WORKING_DIR}/fybrikapplication.yaml -n fybrik-notebook-sample
