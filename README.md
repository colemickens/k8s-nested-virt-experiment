# k8s-nested-virt-experiment


### Overview
This houses a script that will (re)create both an image and instance with nested virt enabled.

The GCE VM boots [my fork of frakti's allinone.sh with changes for nested virt](https://github.com/colemickens/frakti/blob/master/cluster/allinone.sh).


### Usage

```
$ ./start.sh

# wait

$ gcloud compute ssh "frakti-nested-virt-demo"

[in the VM] $ sudo tmux attach

# you can see the install process
```

Then you can copy the `example-pod.yaml`, apply it, curl and see the cpuinfo from inside the container/VM.


### TODO:
* ? integrate this with some of the niceties over here: https://github.com/kelseyhightower/kubeadm-single-node-cluster
