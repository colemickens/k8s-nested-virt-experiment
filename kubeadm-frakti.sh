#!/usr/bin/env bash

# Single node `kubeadm` cluster running with CRI + rktlet
# (not yet working)

set -x

# install pre-reqs

apt-get update
apt-get install -qqy tmux

# run the rest of the script in `tmux`
touch /DEMO-install.sh
chmod +x /DEMO-install.sh
cat <<EOFINSTALL >>/DEMO-install.sh
#!/usr/bin/env bash

set -x

apt-get install -qqy dbus git qemu make gcc apt-transport-https

curl https://godeb.s3.amazonaws.com/godeb-amd64.tar.gz | tar xvzf -
./godeb install

#curl -fsSL get.docker.com -o get-docker.sh
#sh get-docker.sh

#systemctl daemon-reload
#systemctl enable docker
#systemctl start docker

# install rkt

gpg --recv-key 18AD5014C99EF7E3BA5F6CE950BDD3E0FC8A365E
wget https://github.com/rkt/rkt/releases/download/v1.28.1/rkt_1.28.1-1_amd64.deb
wget https://github.com/rkt/rkt/releases/download/v1.28.1/rkt_1.28.1-1_amd64.deb.asc
gpg --verify rkt_1.28.1-1_amd64.deb.asc
dpkg -i rkt_1.28.1-1_amd64.deb


# install kubeadm...

mkdir -p /etc/systemd/system/kubelet.service.d/
cat > /etc/systemd/system/kubelet.service.d/20-cri.conf <<EOF
[Service]
#Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --image-service-endpoint=unix:///var/run/rktlet.sock --container-runtime-endpoint=unix:///var/run/rktlet.sock --feature-gates=AllAlpha=true"
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=rkt --feature-gates=AllAlpha=true"
EOF

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl

sudo systemctl start kubelet


# build rktlet

# skip this, apparently rktlet is built into kubelet

#mkdir -p /opt/rktlet
#(
#  cd /opt/rktlet;
#  git clone https://github.com/kubernetes-incubator/rktlet .
#  make
#)


# launch rktlet

#tmux split-window "/opt/rktlet/bin/rktlet --alsologtostderr"


# launch rkt apiserver

tmux split-window "/usr/bin/rkt api-service"


# kickstart a single node cluster with kubeadm

kubeadm reset
kubeadm init --skip-preflight-checks


##############
# This is where things fail... it never inits properly... must investigate later
# AMENDMENT:
# things proceed if you set the docker crgroup driver to be "systemd" as well....
# but... calico doesn't seem to be coming up...
# and kubelet is whining a LOT about docker's CNI config. Not sure why it's so obsessed with docker even tho I'm running w/ CRI
##############


mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl apply -f https://docs.projectcalico.org/v2.0/getting-started/kubernetes/installation/hosted/kubeadm/calico.yaml


# If you do this too fast, you race the default/default SA creation... so... sleep. yay.

sleep 10

/usr/bin/env bash

EOFINSTALL


# start a pod using rkt + kvm

cat <<EOF >/DEMO-example-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-nginx
  labels:
    k8s-app: test-nginx
  annotations:
    rkt.alpha.kubernetes.io/stage1-name-override: stage1-kvm
spec:
  hostNetwork: true
  containers:
  - name: kubelet
    image: docker.io/library/nginx:latest
    securityContext:
      privileged: true
EOF

tmux new-session -d -s rktlet "/DEMO-install.sh"
