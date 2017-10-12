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

The `./start.sh` script will attempt to install helm, and then traefik, along with
an example pod that shows `/proc/cpuinfo` from inside a container (inside a KVM VM)o


### TODO

The example pod isn't setting the rkt stage1, and rkt stage1 probably doesn't default to 'kvm',
so the rktlet setup probably isn't actually taking advantage of any nested virt right now.
