# k8s-nested-virt-experiment


### Overview
This houses a script that will (re)create both an image and instance with nested virt enabled.

The GCE VM boots using the `./allinone.sh` script (forked from `frakti`'s `cluster/allinone.sh` script).


### Status

#### frakti

Working!

#### rktlet

Abandonded for now. It apparently doesn't work with Kubernetes 1.8...


### Usage

```
$ ./start.sh

# wait

$ gcloud compute ssh "k8s-nested-virt-demo"

[in the VM] $ sudo tmux attach

# you can see the install process
```

The `./start.sh` script will attempt to install helm, and then traefik, along with
an example pod that shows `/proc/cpuinfo` from inside a container (inside a KVM VM).


### TODO

The example pod isn't setting the rkt stage1, and rkt stage1 probably doesn't default to 'kvm',
so the rktlet setup probably isn't actually taking advantage of any nested virt right now.
