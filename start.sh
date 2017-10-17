#!/usr/bin/env bash

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

######

set -x
set -e

#export CRI_TYPE="rktlet"
export CRI_TYPE="frakti"
export KUBERNETES_VERSION="stable-1.8"

ZONE="us-west1-a"
INSTANCE_NAME="k8s-nested-virt-demo"
MACHINE_TYPE="n1-highcpu-8"

TEMP_IMAGE="ubuntu-1604-lts-nested-temp"
NESTED_IMAGE="ubuntu-1604-lts-nested"

if gcloud compute instances describe "${INSTANCE_NAME}"; then
    yes Y | gcloud compute instances delete "${INSTANCE_NAME}" --zone="${ZONE}"
fi

if ! gcloud compute images describe "${NESTED_IMAGE}"; then
    gcloud compute instances create "${TEMP_IMAGE}" \
        --zone="${ZONE}" \
        --image-family="ubuntu-1604-lts" \
        --image-project="ubuntu-os-cloud" \
        --machine-type="${MACHINE_TYPE}"

    gcloud compute instances set-disk-auto-delete "${TEMP_IMAGE}" \
        --disk "${TEMP_IMAGE}" --no-auto-delete

    yes Y | gcloud compute instances delete "${TEMP_IMAGE}"

    gcloud compute images create "${NESTED_IMAGE}" \
            --source-disk="${TEMP_IMAGE}" \
            --source-disk-zone="${ZONE}" \
            --licenses "https://www.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx"

fi

SCRIPT="$(mktemp)"
cp -a "${DIR}/allinone.sh" "${SCRIPT}"

gcloud compute instances create "${INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --image="${NESTED_IMAGE}" \
    --machine-type="${MACHINE_TYPE}" \
    --tags="${INSTANCE_NAME}" \
    --metadata="kubernetes-version=${KUBERNETES_VERSION},cri-type=${CRI_TYPE}" \
    --metadata-from-file="startup-script=${SCRIPT}"
  
if ! gcloud compute firewall-rules describe "k8s-api-${INSTANCE_NAME}"; then
    gcloud compute firewall-rules create "k8s-api-${INSTANCE_NAME}" \
        --allow tcp:6443 \
        --target-tags "${INSTANCE_NAME}" \
        --source-ranges 0.0.0.0/0
fi

if ! gcloud compute firewall-rules describe "http-${INSTANCE_NAME}"; then
    gcloud compute firewall-rules create "http-${INSTANCE_NAME}" \
        --allow tcp:80 \
        --target-tags "${INSTANCE_NAME}" \
        --source-ranges 0.0.0.0/0
fi

if ! gcloud compute firewall-rules describe "https-${INSTANCE_NAME}"; then
    gcloud compute firewall-rules create "https-${INSTANCE_NAME}" \
        --allow tcp:443 \
        --target-tags "${INSTANCE_NAME}" \
        --source-ranges 0.0.0.0/0
fi

# eventually
echo "do this when kubeadm is done:"
until gcloud compute scp ${INSTANCE_NAME}:/etc/kubernetes/admin.conf \
  "$HOME/${INSTANCE_NAME}.kubeconfig"; do
    echo "trying again"
    sleep 5
done

export KUBECONFIG="${HOME}/${INSTANCE_NAME}.kubeconfig"
export EXTERNAL_IP="$(gcloud compute instances describe ${INSTANCE_NAME} \
     --format='value(networkInterfaces.accessConfigs[0].natIP)')"

kubectl config set-cluster kubernetes --server "https://${EXTERNAL_IP}:6443"

until kubectl apply -f ./example-app.yaml; do
    echo "trying again"
    sleep 5
done

kubectl -n kube-system create sa "tiller"
kubectl create clusterrolebinding tiller \
    --clusterrole="cluster-admin" \
    --serviceaccount="kube-system:tiller"
helm init --service-account="tiller"

sleep 40

# TODO: how to use chart with hostPort? :/ or target a GCE routing role to 30080/30443 or something...
helm install stable/nginx-ingress \
    --name nginxingress0 \
    --set rbac.create=true

kubectl patch deployment nginxingress0-nginx-ingress-controller \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx-ingress-controller","resources":{"limits":{"memory":"256Mi"}}}]}}}}'

helm install stable/traefik \
    --name traefik0 \
    --set rbac.enabled=true \
    --set ssl.enabled=true
