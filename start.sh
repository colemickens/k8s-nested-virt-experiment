#!/usr/bin/env bash

set -x

ZONE="us-west1-a"
INSTANCE_NAME="frakti-nested-virt-demo"
MACHINE_TYPE="n1-highcpu-16"

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
curl 'https://raw.githubusercontent.com/colemickens/frakti/develop/cluster/allinone.sh' > "${SCRIPT}"

gcloud compute instances create "${INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --image="${NESTED_IMAGE}" \
    --machine-type="${MACHINE_TYPE}" \
    --tags="${INSTANCE_NAME}" \
    --metadata-from-file="startup-script=${SCRIPT}"
  
gcloud compute firewall-rules create "k8s-api-${INSTANCE_NAME}" \
  --allow tcp:6443 \
  --target-tags "${INSTANCE_NAME}" \
  --source-ranges 0.0.0.0/0

gcloud compute firewall-rules create "http-${INSTANCE_NAME}" \
  --allow tcp:80 \
  --target-tags "${INSTANCE_NAME}" \
  --source-ranges 0.0.0.0/0

gcloud compute firewall-rules create "https-${INSTANCE_NAME}" \
  --allow tcp:443 \
  --target-tags "${INSTANCE_NAME}" \
  --source-ranges 0.0.0.0/0

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

#    --values service.type="ClusterIP" \
