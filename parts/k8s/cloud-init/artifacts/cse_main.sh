#!/bin/bash
ERR_FILE_WATCH_TIMEOUT=6 # Timeout waiting for a file
set -x
echo `date`,`hostname`, startcustomscript>>/opt/m
AZURE_STACK_ENV="azurestackcloud"

script_lib=/opt/azure/containers/provision_source.sh
for i in $(seq 1 3600); do
    if [ -f $script_lib ]; then
        break
    fi
    if [ $i -eq 3600 ]; then
        exit $ERR_FILE_WATCH_TIMEOUT
    else
        sleep 1
    fi
done
source $script_lib

install_script=/opt/azure/containers/provision_installs.sh
wait_for_file 3600 1 $install_script || exit $ERR_FILE_WATCH_TIMEOUT
source $install_script

config_script=/opt/azure/containers/provision_configs.sh
wait_for_file 3600 1 $config_script || exit $ERR_FILE_WATCH_TIMEOUT
source $config_script

cis_script=/opt/azure/containers/provision_cis.sh
wait_for_file 3600 1 $cis_script || exit $ERR_FILE_WATCH_TIMEOUT
source $cis_script

if [[ "${TARGET_ENVIRONMENT,,}" == "${AZURE_STACK_ENV}"  ]]; then 
    config_script_custom_cloud=/opt/azure/containers/provision_configs_custom_cloud.sh
    wait_for_file 3600 1 $config_script_custom_cloud || exit $ERR_FILE_WATCH_TIMEOUT
    source $config_script_custom_cloud
fi

CUSTOM_SEARCH_DOMAIN_SCRIPT=/opt/azure/containers/setup-custom-search-domains.sh

set +x
ETCD_PEER_CERT=$(echo ${ETCD_PEER_CERTIFICATES} | cut -d'[' -f 2 | cut -d']' -f 1 | cut -d',' -f $((${NODE_INDEX}+1)))
ETCD_PEER_KEY=$(echo ${ETCD_PEER_PRIVATE_KEYS} | cut -d'[' -f 2 | cut -d']' -f 1 | cut -d',' -f $((${NODE_INDEX}+1)))
set -x

if [[ $OS == $COREOS_OS_NAME ]]; then
    echo "Changing default kubectl bin location"
    KUBECTL=/opt/kubectl
fi

if [ -f /var/run/reboot-required ]; then
    REBOOTREQUIRED=true
else
    REBOOTREQUIRED=false
fi

if [ -f /var/log.vhd/azure/golden-image-install.complete ]; then
    echo "detected golden image pre-install"
    FULL_INSTALL_REQUIRED=false
    rm -rf /home/packer
    deluser packer
    groupdel packer
else
    FULL_INSTALL_REQUIRED=true
fi

if [[ $OS == $UBUNTU_OS_NAME ]] && [ "$FULL_INSTALL_REQUIRED" = "true" ]; then
    cis_sysctl=/etc/sysctl.d/60-CIS.conf
    wait_for_file 3600 1 $cis_sysctl || exit $ERR_FILE_WATCH_TIMEOUT
    cis_rsyslog=/etc/rsyslog.d/60-CIS.conf
    wait_for_file 3600 1 $cis_rsyslog || exit $ERR_FILE_WATCH_TIMEOUT
    sysctl_reload 20 5 10 || exit $ERR_SYSCTL_RELOAD
    applyOSConfig
    installDeps
else 
    echo "Golden image; skipping dependencies installation"
fi

if [[ ! -z "${MASTER_NODE}" ]] && [[ -z "${COSMOS_URI}" ]]; then
    installEtcd
fi

if [[ $OS != $COREOS_OS_NAME ]]; then
    installContainerRuntime
fi
installNetworkPlugin
if [[ "$CONTAINER_RUNTIME" == "clear-containers" ]] || [[ "$CONTAINER_RUNTIME" == "kata-containers" ]] || [[ "$CONTAINER_RUNTIME" == "containerd" ]]; then
    installContainerd
else
    cleanUpContainerd
fi
if [[ "${GPU_NODE}" = true ]]; then
    if $FULL_INSTALL_REQUIRED; then
        installGPUDrivers
    fi
    ensureGPUDrivers
else
    cleanUpGPUDrivers
fi
installKubeletAndKubectl
if [[ $OS != $COREOS_OS_NAME ]]; then
    ensureRPC
fi
createKubeManifestDir
if [[ "${SGX_NODE}" = true ]]; then
    installSGXDrivers
fi

# create etcd user if we are configured for etcd
if [[ ! -z "${MASTER_NODE}" ]] && [[ -z "${COSMOS_URI}" ]]; then
  configureEtcdUser
fi

if [[ ! -z "${MASTER_NODE}" ]]; then 
  # this step configures all certs
  # both configs etcd/cosmos
  configureSecrets 
fi
# configure etcd if we are configured for etcd
if [[ ! -z "${MASTER_NODE}" ]] && [[ -z "${COSMOS_URI}" ]]; then
    configureEtcd
else
    removeEtcd
fi


if [ -f $CUSTOM_SEARCH_DOMAIN_SCRIPT ]; then
    $CUSTOM_SEARCH_DOMAIN_SCRIPT > /opt/azure/containers/setup-custom-search-domain.log 2>&1 || exit $ERR_CUSTOM_SEARCH_DOMAINS_FAIL
fi

if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    ensureDocker
elif [[ "$CONTAINER_RUNTIME" == "clear-containers" ]]; then
	if grep -q vmx /proc/cpuinfo; then
        ensureCCProxy
	fi
elif [[ "$CONTAINER_RUNTIME" == "kata-containers" ]]; then
    if grep -q vmx /proc/cpuinfo; then
        installKataContainersRuntime
    fi
fi

configureK8s

if [[ "${TARGET_ENVIRONMENT,,}" == "${AZURE_STACK_ENV}"  ]]; then 
    configureK8sCustomCloud
fi

configureCNI

if [[ ! -z "${MASTER_NODE}" ]]; then
    configAddons
fi

if [[ "$CONTAINER_RUNTIME" == "clear-containers" ]] || [[ "$CONTAINER_RUNTIME" == "kata-containers" ]] || [[ "$CONTAINER_RUNTIME" == "containerd" ]]; then
    ensureContainerd
fi

if [[ ! -z "${MASTER_NODE}" && "${KMS_PROVIDER_VAULT_NAME}" != "" ]]; then
    ensureKMS
fi

ensureKubelet
ensureJournal

if [[ ! -z "${MASTER_NODE}" ]]; then
    writeKubeConfig
    if [[ -z "${COSMOS_URI}" ]]; then
      ensureEtcd
    fi
    ensureK8sControlPlane
    ensurePodSecurityPolicy
fi

if $FULL_INSTALL_REQUIRED; then
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        # mitigation for bug https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1676635
        echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind
        sed -i "13i\echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind\n" /etc/rc.local
    fi
fi

echo "Custom script finished successfully"

echo `date`,`hostname`, endcustomscript>>/opt/m
mkdir -p /opt/azure/containers && touch /opt/azure/containers/provision.complete
ps auxfww > /opt/azure/provision-ps.log &

if $FULL_INSTALL_REQUIRED; then
  if [[ $OS == $UBUNTU_OS_NAME ]]; then
    applyCIS
  fi
else
  cleanUpContainerImages
fi

if $REBOOTREQUIRED; then
  echo 'reboot required, rebooting node in 1 minute'
  /bin/bash -c "shutdown -r 1 &"
  if [[ $OS == $UBUNTU_OS_NAME ]]; then
      aptmarkWALinuxAgent unhold &
  fi
else
  if [[ $OS == $UBUNTU_OS_NAME ]]; then
      /usr/lib/apt/apt.systemd.daily &
      aptmarkWALinuxAgent unhold &
  fi
fi
