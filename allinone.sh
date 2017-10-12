#!/bin/bash

# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

set -x

if [ "${TMUX:-}" == "" ]; then
    exec tmux new-session -d -s k8s "export HOME=/root; ${0}; /bin/bash"
fi

export KUBERNETES_VERSION=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/kubernetes-version)

export CRI_TYPE=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/cri-type)

RKT_VERSION="1.29.0"
RKT_PKGREL=1
FRAKTI_VERSION="v1.1"
CLUSTER_CIDR="10.244.0.0/16"
MASTER_CIDR="10.244.1.0/24"
cgroup_driver="systemd"

prep() {
    until apt-get update; do sleep 1; done
    until apt-get install -y gcc qemu qemu-kvm libvirt0 libvirt-bin make; do sleep 1; done
}

install-docker() {
    mkdir -p /opt/docker
    curl -fsSL get.docker.com -o /opt/docker/get-docker.sh
    until sh /opt/docker/get-docker.sh; do sleep 1; done
    systemctl start docker
}

install-rkt() {
    mkdir -p /opt/rkt
    (
        cd /opt/rkt
        # TODO: tsk tsk
        #gpg --keyserver pgp.mit.edu --recv-key 18AD5014C99EF7E3BA5F6CE950BDD3E0FC8A365E
        wget https://github.com/rkt/rkt/releases/download/v${RKT_VERSION}/rkt_${RKT_VERSION}-${RKT_PKGREL}_amd64.deb
        wget https://github.com/rkt/rkt/releases/download/v${RKT_VERSION}/rkt_${RKT_VERSION}-${RKT_PKGREL}_amd64.deb.asc
        #gpg --verify rkt_${RKT_VERSION}-1_amd64.deb.asc
        until dpkg -i rkt_${RKT_VERSION}-1_amd64.deb; do sleep 1; done
    )
}

install-rktlet() {
    mkdir -p /opt/rktlet
    (
        cd /opt/rktlet
        git clone https://github.com/kubernetes-incubator/rktlet .
        curl https://godeb.s3.amazonaws.com/godeb-amd64.tar.gz | tar xvzf -
        until ./godeb install; do sleep 1; done
        make # build-in-rkt # b-i-r doesn't work, golang rkt container is too old
        cp -a bin/rktlet /usr/bin/rktlet

        cat <<EOF > /lib/systemd/system/rktlet.service
[Unit]
Description=Rktlet container runtime for Kubernetes
After=network.target
[Service]
ExecStart=/usr/bin/rktlet --v=4
# \
#          --log-dir=/var/log/frakti \
#          --logtostderr=false \
#          --cgroup-driver=${cgroup_driver} \
#          --listen=/var/run/frakti.sock \
#          --streaming-server-addr=%H \
#          --hyper-endpoint=127.0.0.1:22318
MountFlags=shared
TasksMax=8192
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TimeoutStartSec=0
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
EOF
    systemctl enable rktlet
    systemctl start rktlet
    )
}

install-hyperd() {
    mkdir -p /opt/hyper
    curl -sSL https://hypercontainer.io/install | sed '/tput/d' > /opt/hyper/hyper-install.sh
    until bash /opt/hyper/hyper-install.sh; do sleep 1; done
    mkdir -p /etc/hyper
    echo -e "Kernel=/var/lib/hyper/kernel\n\
Initrd=/var/lib/hyper/hyper-initrd.img\n\
Hypervisor=kvm\n\
StorageDriver=overlay\n\
gRPCHost=127.0.0.1:22318" > /etc/hyper/config
    systemctl enable hyperd
    systemctl restart hyperd
}

install-frakti() {
    curl -sSL https://github.com/kubernetes/frakti/releases/download/${FRAKTI_VERSION}/frakti -o /usr/bin/frakti
    chmod +x /usr/bin/frakti
    cgroup_driver=$(docker info | awk '/Cgroup Driver/{print $3}')
    cat <<EOF > /lib/systemd/system/frakti.service
[Unit]
Description=Hypervisor-based container runtime for Kubernetes
Documentation=https://github.com/kubernetes/frakti
After=network.target
[Service]
ExecStart=/usr/bin/frakti --v=3 \
          --log-dir=/var/log/frakti \
          --logtostderr=false \
          --cgroup-driver=${cgroup_driver} \
          --listen=/var/run/frakti.sock \
          --streaming-server-addr=%H \
          --hyper-endpoint=127.0.0.1:22318
MountFlags=shared
TasksMax=8192
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TimeoutStartSec=0
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
EOF
    systemctl enable frakti
    systemctl start frakti
}

install-kubelet() {
    until apt-get install -y apt-transport-https; do sleep 1; done
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
    until apt-get update; do sleep 1; done
    until apt-get install -y kubelet kubeadm kubectl; do sleep 1; done

    echo "source <(kubectl completion bash)" >> /etc/bash.bashrc
    echo "export KUBECONFIG=\"/etc/kubernetes/admin.conf\"" >> /etc/bash.bashrc
}

install-cni() {
    mkdir -p /opt/cni/bin
    (
        cd /opt/cni/bin
        curl -sSL 'https://github.com/containernetworking/plugins/releases/download/v0.6.0/cni-plugins-amd64-v0.6.0.tgz' | tar xvzf -
    )    
}

config-gce-kubeadm() {
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
    
    INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

    cat <<EOF > kubeadm.conf
kind: MasterConfiguration
apiVersion: kubeadm.k8s.io/v1alpha1
apiServerCertSANs:
  - 10.96.0.1
  - ${EXTERNAL_IP}
  - ${INTERNAL_IP}
apiServerExtraArgs:
  admission-control: PodPreset,Initializers,GenericAdmissionWebhook,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota
  feature-gates: AllAlpha=true
  runtime-config: api/all
cloudProvider: gce
#kubernetesVersion: ${KUBERNETES_VERSION:-}
networking:
  podSubnet: ${CLUSTER_CIDR}
EOF
}

config-kubelet() {
    mkdir -p /etc/systemd/system/kubelet.service.d/

if [[ "${CRI_TYPE}" == "frakti" ]]; then
    cat > /etc/systemd/system/kubelet.service.d/20-cri.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///var/run/frakti.sock --feature-gates=AllAlpha=true"
EOF
elif [[ "${CRI_TYPE}" == "rktlet" ]]; then
    cat > /etc/systemd/system/kubelet.service.d/20-cri.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///var/run/rktlet.sock --image-service-endpoint=unix:///var/run/rktlet.sock --feature-gates=AllAlpha=true"
EOF
fi
    systemctl daemon-reload
    systemctl restart kubelet
}

config-cni() {
    mkdir -p /etc/cni/net.d
    cat >/etc/cni/net.d/10-mynet.conflist <<-EOF
{
    "cniVersion": "0.3.1",
    "name": "mynet",
    "plugins": [
        {
            "type": "bridge",
            "bridge": "cni0",
            "isGateway": true,
            "ipMasq": true,
            "ipam": {
                "type": "host-local",
                "subnet": "${MASTER_CIDR}",
                "routes": [
                    { "dst": "0.0.0.0/0"  }
                ]
            }
        },
        {
            "type": "portmap",
            "capabilities": {"portMappings": true},
            "snat": true
        },
        {
            "type": "loopback"
        }
    ]
}
EOF
}

setup-master() {
    kubeadm reset
    config-cni # TODO: refactor better

    #kubeadm init --pod-network-cidr ${CLUSTER_CIDR} --kubernetes-version stable
    kubeadm init --config=kubeadm.conf
    
    # Also enable schedule pods on the master for allinone.
    export KUBECONFIG=/etc/kubernetes/admin.conf
    chmod 0644 ${KUBECONFIG}
    kubectl taint nodes --all node-role.kubernetes.io/master-

    # approve kublelet's csr for the node.
    sleep 30
    kubectl certificate approve $(kubectl get csr | awk '/^csr/{print $1}')

    # increase memory limits for kube-dns
    kubectl -n kube-system patch deployment kube-dns -p '{"spec":{"template":{"spec":{"containers":[{"name":"kubedns","resources":{"limits":{"memory":"256Mi"}}},{"name":"dnsmasq","resources":{"limits":{"memory":"128Mi"}}},{"name":"sidecar","resources":{"limits":{"memory":"64Mi"}}}]}}}}'
}

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

lsb_dist=''
if command_exists lsb_release; then
    lsb_dist="$(lsb_release -si)"
fi
if [ -z "$lsb_dist" ] && [ -r /etc/lsb-release ]; then
    lsb_dist="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
fi
if [ -z "$lsb_dist" ] && [ -r /etc/centos-release ]; then
    lsb_dist='centos'
fi
if [ -z "$lsb_dist" ] && [ -r /etc/redhat-release ]; then
    lsb_dist='redhat'
fi
if [ -z "$lsb_dist" ] && [ -r /etc/os-release ]; then
    lsb_dist="$(. /etc/os-release && echo "$ID")"
fi

lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

case "$lsb_dist" in

    ubuntu)
        prep
        install-docker
        if [[ "${CRI_TYPE}" == "frakti" ]]; then
            install-hyperd
            install-frakti
        elif [[ "${CRI_TYPE}" == "rktlet" ]]; then
            install-rkt
            install-rktlet
        fi
        install-kubelet
        install-cni
        config-cni
        config-gce-kubeadm
        config-kubelet
        setup-master
    ;;

    *)
        echo "$lsb_dist is not supported (not in ubuntu)"
    ;;

esac
