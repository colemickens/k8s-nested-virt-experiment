#!/usr/bin/env bash

set -x

NAME="i${RANDOM}"
#NAME="$(shuf -n1 /usr/share/dict/words)"

gcloud compute instances create "${NAME}" \
    --zone="us-west1-a" \
    --machine-type="n1-highcpu-16" \
    --image-family="ubuntu-1704" --image-project="ubuntu-os-cloud" \
    --metadata-from-file="startup-script=./kubeadm-frakti.sh"
