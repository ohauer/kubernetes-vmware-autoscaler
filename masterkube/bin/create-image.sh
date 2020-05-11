#/bin/bash

#set -e

# This script will create 2 VM used as template
# The first one is the seed VM customized to use vmware guestinfos cloud-init datasource instead ovf datasource.
# This step is done by importing https://cloud-images.ubuntu.com/bionic/current/bionic-server-cloudimg-amd64.ova
# If don't have the right to import OVA with govc to your vpshere you can try with ovftool import method else you must build manually this seed
# Jump to Prepare seed VM comment.
# Very important, shutdown the seed VM by using shutdown guest or shutdown -P now. Never use PowerOff vsphere command
# This VM will be used to create the kubernetes template VM 

# The second VM will contains everything to run kubernetes

KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
KUBERNETES_PASSWORD=$(uuidgen)
CNI_VERSION=v0.8.5
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
CACHE=~/.local/vmware/cache
TARGET_IMAGE=bionic-kubernetes-$KUBERNETES_VERSION
PASSWORD=$(uuidgen)
OSDISTRO=$(uname -s)
SEEDIMAGE=bionic-server-cloudimg-seed
IMPORTMODE="govc"
CURDIR=$(dirname $0)
USER=ubuntu
SECOND_NETWORK_ADAPTER=vmxnet3
SECOND_NETWORK_NAME=

if [ "$OSDISTRO" == "Linux" ]; then
    TZ=$(cat /etc/timezone)
    BASE64='base64 -w 0'
    ISODIR=~/.local/vmware/cache
else
    TZ=$(sudo systemsetup -gettimezone | awk '{print $2}')
    BASE64=base64
    ISODIR=~/.local/vmware/cache/iso
fi

mkdir -p $ISODIR

TEMP=`getopt -o i:k:n:op:s:u:v: --long user:,adapter:,second-adapter:,second-network:,ovftool,seed:,custom-image:,ssh-key:,cni-version:,password:,kubernetes-version: -n "$0" -- "$@"`
eval set -- "$TEMP"

# extract options and their arguments into variables.
while true ; do
	#echo "1:$1"
    case "$1" in
        -i|--custom-image) TARGET_IMAGE="$2" ; shift 2;;
        -k|--ssh-key) SSH_KEY=$2 ; shift 2;;
        -n|--cni-version) CNI_VERSION=$2 ; shift 2;;
        -o|--ovftool) IMPORTMODE=ovftool ; shift 2;;
        -p|--password) KUBERNETES_PASSWORD=$2 ; shift 2;;
        -s|--seed) SEEDIMAGE=$2 ; shift 2;;
        -u|--user) USER=$2 ; shift 2;;
        -v|--kubernetes-version) KUBERNETES_VERSION=$2 ; shift 2;;
        --second-adapter) SECOND_NETWORK_ADAPTER=$2 ; shift 2;;
        --second-network) SECOND_NETWORK_NAME=$2 ; shift 2;;
        --) shift ; break ;;
        *) echo "$1 - Internal error!" ; exit 1 ;;
    esac
done

if [ ! -z "$(govc vm.info $TARGET_IMAGE 2>&1)" ]; then
    echo "$TARGET_IMAGE already exists!"
    exit 0
fi

echo "Kubernetes password:$KUBERNETES_PASSWORD"
echo "Used password:$PASSWORD"

USERDATA=$(base64 <<EOF
#cloud-config
password: $PASSWORD
chpasswd: { expire: false }
ssh_pwauth: true
EOF
)

# If your seed image isn't present create one by import bionic cloud ova.
# If you don't have the access right to import with govc (firewall rules blocking https traffic to esxi),
# you can try with ovftool to import the ova.
# If you have the bug "unsupported server", you must do it manually!
if [ -z "$(govc vm.info $SEEDIMAGE 2>&1)" ]; then
    [ -f bionic-server-cloudimg-amd64.ova ] || wget https://cloud-images.ubuntu.com/bionic/current/bionic-server-cloudimg-amd64.ova -O bionic-server-cloudimg-amd64.ova
        
    MAPPED_NETWORK=$(govc import.spec bionic-server-cloudimg-amd64.ova | jq .NetworkMapping[0].Name | tr -d '"')

    if [ "${IMPORTMODE}" == "govc" ]; then

        govc import.spec bionic-server-cloudimg-amd64.ova \
            | jq --arg GOVC_NETWORK "${GOVC_NETWORK}" --arg MAPPED_NETWORK "${MAPPED_NETWORK}" '.NetworkMapping |= [ { Name: $MAPPED_NETWORK, Network: $GOVC_NETWORK } ]' \
            > ${CACHE}/bionic-server-cloudimg-amd64.spec
        
        cat ${CACHE}/bionic-server-cloudimg-amd64.spec \
            | jq --arg SSH_KEY "${SSH_KEY}" \
                --arg SSH_KEY "${SSH_KEY}" \
                --arg USERDATA "${USERDATA}" \
                --arg PASSWORD "${PASSWORD}" \
                --arg NAME "${SEEDIMAGE}" \
                --arg INSTANCEID $(uuidgen) \
                --arg TARGET_IMAGE "$TARGET_IMAGE" \
                '.Name = $NAME | .PropertyMapping |= [ { Key: "instance-id", Value: $INSTANCEID }, { Key: "hostname", Value: $TARGET_IMAGE }, { Key: "public-keys", Value: $SSH_KEY }, { Key: "user-data", Value: $USERDATA }, { Key: "password", Value: $PASSWORD } ]' \
                > ${CACHE}/bionic-server-cloudimg-amd64.txt

        if [ -z "${GOVC_CLUSTER}" ]; then
            DATASTORE="/${GOVC_DATACENTER}/datastore/${GOVC_DATASTORE}"
            FOLDER="/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
        else
            DATASTORE="/${GOVC_DATACENTER}/datastore/${GOVC_CLUSTER}/CUSTOMER/${GOVC_FOLDER}/${GOVC_DATASTORE}"
            FOLDER="/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
        fi

        echo "Import bionic-server-cloudimg-amd64.ova to ${SEEDIMAGE} with govc"
        govc import.ova \
            -options=${CACHE}/bionic-server-cloudimg-amd64.txt \
            -folder="${FOLDER}" \
            -ds="${DATASTORE}" \
            -name="${SEEDIMAGE}" \
            ${CACHE}/bionic-server-cloudimg-amd64.ova
    else
        echo "Import bionic-server-cloudimg-amd64.ova to ${SEEDIMAGE} with ovftool"

        ovftool \
            --acceptAllEulas \
            --name="${SEEDIMAGE}" \
            --datastore="${GOVC_DATASTORE}" \
            --vmFolder="${GOVC_FOLDER}" \
            --diskMode=thin \
            --prop:instance-id="$(uuidgen)" \
            --prop:hostname="${SEEDIMAGE}" \
            --prop:public-keys="${SSH_KEY}" \
            --prop:user-data="" \
            --prop:password="${PASSWORD}" \
            --net:"${MAPPED_NETWORK}"="${GOVC_NETWORK}" \
            https://cloud-images.ubuntu.com/bionic/current/bionic-server-cloudimg-amd64.ova \
            "vi://${GOVC_USERNAME}:${GOVC_PASSWORD}@${GOVC_HOST}/${GOVC_RESOURCE_POOL}/"
    fi

    if [ $? -eq 0 ]; then
    
        if [ ! -z "${SECOND_NETWORK_NAME}" ]; then
            echo "Add second network card ${SECOND_NETWORK_NAME} on ${SEEDIMAGE}"

            govc vm.network.add -vm "${SEEDIMAGE}" -net="${SECOND_NETWORK_NAME}" -net.adapter="${SECOND_NETWORK_ADAPTER}"
        fi

        echo "Power On ${SEEDIMAGE}"
        govc vm.power -on "${SEEDIMAGE}"

        echo "Wait for IP from $SEEDIMAGE"
        IPADDR=$(govc vm.ip -wait 5m "${SEEDIMAGE}")

        if [ -z "${IPADDR}" ]; then
            echo "Can't get IP!"
            exit -1
        fi

        # Prepare seed VM
        echo "Install cloud-init VMWareGuestInfo datasource"
        scp "${CURDIR}/../guestinfos/install-guestinfo-datasource.sh" "${CURDIR}/../guestinfos/cloud-init-clean.sh" "${USER}@${IPADDR}:/tmp"
        ssh -t "${USER}@${IPADDR}" sudo mv /tmp/cloud-init-clean.sh /tmp/install-guestinfo-datasource.sh /usr/local/bin
        ssh -t "${USER}@${IPADDR}" sudo /usr/local/bin/install-guestinfo-datasource.sh

        # Shutdown the guest
        govc vm.power -persist-session=false -s "${SEEDIMAGE}"

        sleep 10

        echo "${SEEDIMAGE} is ready"
    else
        echo "Import failed!"
        exit -1
    fi 
else
    echo "${SEEDIMAGE} already exists, nothing to do!"
fi

KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')

echo "Prepare ${TARGET_IMAGE} image"

cat > "${ISODIR}/user-data" <<EOF
#cloud-config
EOF

cat > "${ISODIR}/network.yaml" <<EOF
#cloud-config
network:
    version: 2
    ethernets:
        eth0:
            dhcp4: true
EOF

cat > "${ISODIR}/vendor-data" <<EOF
#cloud-config
timezone: $TZ
ssh_authorized_keys:
    - $SSH_KEY
users:
    - default
system_info:
    default_user:
        name: kubernetes
EOF

cat > "${ISODIR}/meta-data" <<EOF
{
    "local-hostname": "$TARGET_IMAGE",
    "instance-id": "$(uuidgen)"
}
EOF

cat > "${ISODIR}/prepare-image.sh" <<EOF
#!/bin/bash

apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y

mkdir -p /opt/cni/bin
mkdir -p /usr/local/bin

echo "Prepare to install Docker"

# Setup daemon.
if [ $KUBERNETES_MINOR_RELEASE -ge 14 ]; then
    mkdir -p /etc/docker

    cat > /etc/docker/daemon.json <<SHELL
{
    "exec-opts": [
        "native.cgroupdriver=systemd"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2"
}
SHELL

    curl https://get.docker.com | bash

    mkdir -p /etc/systemd/system/docker.service.d

    # Restart docker.
    systemctl daemon-reload
    systemctl restart docker
else
    curl https://get.docker.com | bash
fi

# Setup Kube DNS resolver
#mkdir /etc/systemd/resolved.conf.d/
#cat > /etc/systemd/resolved.conf.d/kubernetes.conf <<SHELL
#[Resolve]
#DNS=10.96.0.10
#Domains=cluster.local
#SHELL

echo "Prepare to install CNI plugins"

curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

cd /usr/local/bin
curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/{kubeadm,kubelet,kubectl,kube-proxy}
chmod +x /usr/local/bin/kube*

mkdir -p /etc/systemd/system/kubelet.service.d

cat > /etc/systemd/system/kubelet.service <<SHELL
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=http://kubernetes.io/docs/

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
SHELL

cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<"SHELL"
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generate at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
SHELL

echo 'KUBELET_EXTRA_ARGS="--fail-swap-on=false --read-only-port=10255 --feature-gates=VolumeSubpathEnvExpansion=true"' > /etc/default/kubelet

echo 'export PATH=/opt/cni/bin:\$PATH' >> /etc/profile.d/apps-bin-path.sh

systemctl enable kubelet
systemctl restart kubelet

usermod -aG docker kubernetes

/usr/local/bin/kubeadm config images pull --kubernetes-version=${KUBERNETES_VERSION}

cat >> /etc/vmware-tools/tools.conf <<SHELL
[guestinfo]
exclude-nics=docker*,veth*,vEthernet*,flannel*,cni*,calico*
primary-nics=eth0
low-priority-nics=eth1,eth2,eth3
SHELL

[ -f /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg ] && rm /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg
rm /etc/netplan/*
cloud-init clean
rm /var/log/cloud-ini*
rm /var/log/syslog
EOF

chmod +x "${ISODIR}/prepare-image.sh"

gzip -c9 < "${ISODIR}/meta-data" | $BASE64 > ${CACHE}/metadata.base64
gzip -c9 < "${ISODIR}/user-data" | $BASE64 > ${CACHE}/userdata.base64
gzip -c9 < "${ISODIR}/vendor-data" | $BASE64 > ${CACHE}/vendordata.base64

# Due to my vsphere center the folder name refer more path, so I need to precise the path instead
if [ "${GOVC_FOLDER}" ]; then
    FOLDERS=$(govc folder.info ${GOVC_FOLDER}|grep Path|wc -l)
    if [ "${FOLDERS}" != "1" ]; then
        FOLDER_OPTIONS="-folder=/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
    fi
fi

govc vm.clone -on=false ${FOLDER_OPTIONS} -c=2 -m=4096 -vm=${SEEDIMAGE} ${TARGET_IMAGE}

govc vm.change -vm "${TARGET_IMAGE}" \
    -e guestinfo.metadata="$(cat ${CACHE}/metadata.base64)" \
    -e guestinfo.metadata.encoding="gzip+base64" \
    -e guestinfo.userdata="$(cat ${CACHE}/userdata.base64)" \
    -e guestinfo.userdata.encoding="gzip+base64" \
    -e guestinfo.vendordata="$(cat ${CACHE}/vendordata.base64)" \
    -e guestinfo.vendordata.encoding="gzip+base64"

echo "Power On ${TARGET_IMAGE}"
govc vm.power -on "${TARGET_IMAGE}"

echo "Wait for IP from ${TARGET_IMAGE}"
IPADDR=$(govc vm.ip -wait 5m "${TARGET_IMAGE}")

scp "${ISODIR}/prepare-image.sh" "${USER}@${IPADDR}:~"

ssh -t "${USER}@${IPADDR}" sudo ./prepare-image.sh

govc vm.power -persist-session=false -s=true "${TARGET_IMAGE}"

echo "Wait ${TARGET_IMAGE} to shutdown"
while [ $(govc vm.info -json "${TARGET_IMAGE}" | jq .VirtualMachines[0].Runtime.PowerState | tr -d '"') == "poweredOn" ]
do
    echo "."
    sleep 1
done
echo

echo "Created image ${TARGET_IMAGE} with kubernetes version ${KUBERNETES_VERSION}"

exit 0
