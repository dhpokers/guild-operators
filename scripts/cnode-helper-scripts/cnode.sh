#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CPU_CORES=2              # Number of CPU cores cardano-node process has access to (please don't set higher than physical core count, 2-4 recommended)
#MEMPOOL_BYTES=8388608    # Override mempool in bytes (Default: Do not override)
#CNODE_LISTEN_IP4=0.0.0.0 # IP to use for listening (only applicable to Node Connection Port) for IPv4
#CNODE_LISTEN_IP6=::      # IP to use for listening (only applicable to Node Connection Port) for IPv6

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d]
		
		Cardano Node wrapper script !!
		-d    Deploy cnode as a systemd service
		
		EOF
  exit 1
}

set_defaults() {
  [[ -n ${CPU_CORES} ]] && CPU_RUNTIME=( "+RTS" "-N${CPU_CORES}" "-RTS" ) || CPU_RUNTIME=()
  [[ -z ${CNODE_LISTEN_IP4} ]] && CNODE_LISTEN_IP4=0.0.0.0
  [[ -z ${CNODE_LISTEN_IP6} ]] && CNODE_LISTEN_IP6=::
  [[ ! -d "${LOG_DIR}/archive" ]] && mkdir -p "${LOG_DIR}/archive"
  host_addr=()
  [[ ${IP_VERSION} = "4" || ${IP_VERSION} = "mix" ]] && host_addr+=("--host-addr" "${CNODE_LISTEN_IP4}")
  [[ ${IP_VERSION} = "6" || ${IP_VERSION} = "mix" ]] && host_addr+=("--host-ipv6-addr" "${CNODE_LISTEN_IP6}")
  [[ -z ${MEMPOOL_BYTES} ]] && MEMPOOL_OVERRIDE="" || MEMPOOL_OVERRIDE="--mempool-capacity-override ${MEMPOOL_BYTES}"
}

pre_startup_sanity() {
  # Check if node is already running, or if stale socket file is left
  if [[ -S "${CARDANO_NODE_SOCKET_PATH}" ]]; then
    if pgrep -f "$(basename ${CNODEBIN}).*.${CARDANO_NODE_SOCKET_PATH}"; then
       echo "ERROR: A Cardano node is already running, please terminate this node before starting a new one with this script."
       exit 1
    else
      echo "WARN: A prior running Cardano node was not cleanly shutdown, socket file still exists. Cleaning up."
      unlink "${CARDANO_NODE_SOCKET_PATH}"
    fi
  fi
  # Move logs to archive
  [[ $(find "${LOG_DIR}"/node*.json 2>/dev/null | wc -l) -gt 0 ]] && mv "${LOG_DIR}"/node*.json "${LOG_DIR}"/archive/
}

deploy_systemd() {
  echo "Deploying ${CNODE_VNAME} as systemd service.."
  sudo bash -c "cat <<-'EOF' > /etc/systemd/system/${CNODE_VNAME}.service
	[Unit]
	Description=Cardano Node
	Wants=network-online.target
	After=network-online.target
	
	[Service]
	Type=simple
	Restart=always
	RestartSec=5
	User=${USER}
	LimitNOFILE=1048576
	WorkingDirectory=${CNODE_HOME}/scripts
	ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cnode.sh\"
	ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep ${CNODEBIN}.*.${CNODE_HOME}/ | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
	KillSignal=SIGINT
	SuccessExitStatus=143
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=${CNODE_VNAME}
	TimeoutStopSec=5
	KillMode=mixed
	
	[Install]
	WantedBy=multi-user.target
	EOF" && echo "${CNODE_VNAME}.service deployed successfully!!" && sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}.service
}

###################
# Execution       #
###################

# Parse command line options
while getopts :d opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    \? ) usage ;;
  esac
done

# Check if env file is missing in current folder (no update checks as will mostly run as daemon), source env if present
[[ ! -f "$(dirname $0)"/env ]] && echo -e "\nCommon env file missing, please ensure latest prereqs.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
. "$(dirname $0)"/env offline
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

# Set defaults and do basic sanity checks
set_defaults
#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && exit 0
  exit 2
fi
pre_startup_sanity

# Run Node
if [[ -f "${POOL_DIR}/${POOL_OPCERT_FILENAME}" && -f "${POOL_DIR}/${POOL_VRF_SK_FILENAME}" && -f "${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}" ]]; then
  "${CNODEBIN}" "${CPU_RUNTIME[@]}" run \
    --topology "${TOPOLOGY}" \
    --config "${CONFIG}" \
    --database-path "${DB_DIR}" \
    --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
    --shelley-kes-key "${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}" \
    --shelley-vrf-key "${POOL_DIR}/${POOL_VRF_SK_FILENAME}" \
    --shelley-operational-certificate "${POOL_DIR}/${POOL_OPCERT_FILENAME}" \
    --port ${CNODE_PORT} \
    ${MEMPOOL_OVERRIDE} "${host_addr[@]}"
else
  "${CNODEBIN}" "${CPU_RUNTIME[@]}" run \
    --topology "${TOPOLOGY}" \
    --config "${CONFIG}" \
    --database-path "${DB_DIR}" \
    --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
    --port ${CNODE_PORT} \
    ${MEMPOOL_OVERRIDE} "${host_addr[@]}"
fi
