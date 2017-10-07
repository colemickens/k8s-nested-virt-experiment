#!/usr/bin/env bash

yes Y | \
gcloud compute instances list | \
tail -n +2 | \
awk '{printf "gcloud compute instances delete %s --zone %s &", $1, $2}' | bash
