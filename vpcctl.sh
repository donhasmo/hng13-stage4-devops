#!/bin/bash
set -euo pipefail

# ===============================
#  COLORS AND HELPERS
# ===============================
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"

LOG_FILE="vpcctl.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log() {
  echo -e ">> ${YELLOW}$*${NC}"
  echo "$(timestamp) [INFO] $*" >> "$LOG_FILE"
}
pass() {
  echo -e "${GREEN}PASS:${NC} $*"
  echo "$(timestamp) [PASS] $*" >> "$LOG_FILE"
}
fail() {
  echo -e "${RED}FAIL:${NC} $*"
  echo "$(timestamp) [FAIL] $*" >> "$LOG_FILE"
}

# ===============================
#  USAGE
# ===============================
usage() {
  echo "Usage: $0 {create|delete|peer|unpeer} env_file1 [env_file2 ...]"
  exit 1
}

[ "$#" -lt 2 ] && usage

ACTION=$1
shift

# -------------------------------
# Helpers
# -------------------------------
safe_ip_link_del(){
  ip link show "$1" &>/dev/null || return 0
  ip link delete "$1" || true
  log "Deleted link $1 (if existed)."
}
safe_netns_del(){
  ip netns list | grep -q "^$1\b" 2>/dev/null || return 0
  ip netns delete "$1" || true
  log "Deleted namespace $1 (if existed)."
}

# Utility: run quietly (suppress errors) for idempotent operations
quiet() { "$@" 2>/dev/null || true; }

# ===============================
#  CREATE VPC
# ===============================
create_vpc() {
  ENV_FILE=$1
  source "$ENV_FILE"

  log "Starting creation of VPC: $BRIDGE ($VPC_CIDR)"

  BR_PUB="${BRIDGE}-pub"
  BR_PRIV="${BRIDGE}-priv"

  # --- Bridges ---
  for BR in "$BR_PUB" "$BR_PRIV"; do
    if ! ip link show "$BR" &>/dev/null; then
      sudo ip link add "$BR" type bridge
      log "Created bridge $BR"
    else
      log "Bridge $BR already exists"
    fi
    sudo ip link set "$BR" up
    # set forward delay to 0 for quick forwarding
    if [ -d "/sys/class/net/$BR/bridge" ]; then
      echo 0 | sudo tee "/sys/class/net/$BR/bridge/forward_delay" >/dev/null
    fi
  done

  # --- Router namespace ---
  if ! sudo ip netns list | grep -qw "$ROUTER_NS"; then
    sudo ip netns add "$ROUTER_NS"
    log "Created router namespace $ROUTER_NS"
  else
    log "Router namespace $ROUTER_NS already exists"
  fi
  sudo ip netns exec "$ROUTER_NS" ip link set lo up

  # --- Router <-> Public bridge veth ---
  VETH_ROUTER_PUB="vr-pub-${BRIDGE}"
  VETH_BR_PUB="vbr-pub-${BRIDGE}"
  if ! ip link show "$VETH_BR_PUB" &>/dev/null && ! ip netns exec "$ROUTER_NS" ip link show "$VETH_ROUTER_PUB" &>/dev/null; then
    sudo ip link add "$VETH_ROUTER_PUB" type veth peer name "$VETH_BR_PUB"
    log "Created router<->public veth pair: $VETH_ROUTER_PUB <-> $VETH_BR_PUB"
  else
    log "Router<->public veth pair exists"
  fi
  sudo ip link set "$VETH_BR_PUB" master "$BR_PUB" || true
  sudo ip link set "$VETH_BR_PUB" up || true
  sudo ip link set "$VETH_ROUTER_PUB" netns "$ROUTER_NS" || true
  quiet sudo ip netns exec "$ROUTER_NS" ip addr add "${PUB_GW%%/*}"/24 dev "$VETH_ROUTER_PUB"
  sudo ip netns exec "$ROUTER_NS" ip link set "$VETH_ROUTER_PUB" up

  # --- Router <-> Private bridge veth ---
  VETH_ROUTER_PRIV="vr-priv-${BRIDGE}"
  VETH_BR_PRIV="vbr-priv-${BRIDGE}"
  if ! ip link show "$VETH_BR_PRIV" &>/dev/null && ! ip netns exec "$ROUTER_NS" ip link show "$VETH_ROUTER_PRIV" &>/dev/null; then
    sudo ip link add "$VETH_ROUTER_PRIV" type veth peer name "$VETH_BR_PRIV"
    log "Created router<->private veth pair: $VETH_ROUTER_PRIV <-> $VETH_BR_PRIV"
  else
    log "Router<->private veth pair exists"
  fi
  sudo ip link set "$VETH_BR_PRIV" master "$BR_PRIV" || true
  sudo ip link set "$VETH_BR_PRIV" up || true
  sudo ip link set "$VETH_ROUTER_PRIV" netns "$ROUTER_NS" || true
  quiet sudo ip netns exec "$ROUTER_NS" ip addr add "${PRIV_GW%%/*}"/24 dev "$VETH_ROUTER_PRIV"
  sudo ip netns exec "$ROUTER_NS" ip link set "$VETH_ROUTER_PRIV" up

  # --- Public namespace ---
  if ! sudo ip netns list | grep -qw "$PUB_NS"; then
    sudo ip netns add "$PUB_NS"
    log "Created public namespace $PUB_NS"
  else
    log "Public namespace $PUB_NS exists"
  fi
  sudo ip netns exec "$PUB_NS" ip link set lo up
  quiet sudo ip link add "veth-$PUB_NS" type veth peer name "vbr-$PUB_NS"
  quiet sudo ip link set "veth-$PUB_NS" netns "$PUB_NS"
  sudo ip link set "vbr-$PUB_NS" master "$BR_PUB" || true
  sudo ip link set "vbr-$PUB_NS" up || true
  quiet sudo ip netns exec "$PUB_NS" ip addr add "$PUB_IP" dev "veth-$PUB_NS"
  sudo ip netns exec "$PUB_NS" ip link set "veth-$PUB_NS" up || true
  quiet sudo ip netns exec "$PUB_NS" ip route add default via "${PUB_GW%%/*}" dev "veth-$PUB_NS" 2>/dev/null || true
  log "Configured public namespace $PUB_NS: IP $PUB_IP , GW $PUB_GW"

  # --- Private namespace ---
  if ! sudo ip netns list | grep -qw "$PRIV_NS"; then
    sudo ip netns add "$PRIV_NS"
    log "Created private namespace $PRIV_NS"
  else
    log "Private namespace $PRIV_NS exists"
  fi
  sudo ip netns exec "$PRIV_NS" ip link set lo up
  quiet sudo ip link add "veth-$PRIV_NS" type veth peer name "vbr-$PRIV_NS"
  quiet sudo ip link set "veth-$PRIV_NS" netns "$PRIV_NS"
  sudo ip link set "vbr-$PRIV_NS" master "$BR_PRIV" || true
  sudo ip link set "vbr-$PRIV_NS" up || true
  quiet sudo ip netns exec "$PRIV_NS" ip addr add "$PRIV_IP" dev "veth-$PRIV_NS"
  sudo ip netns exec "$PRIV_NS" ip link set "veth-$PRIV_NS" up || true
  quiet sudo ip netns exec "$PRIV_NS" ip route add default via "${PRIV_GW%%/*}" dev "veth-$PRIV_NS" 2>/dev/null || true
  log "Configured private namespace $PRIV_NS: IP $PRIV_IP , GW $PRIV_GW"

  # --- Router <-> Host veth for NAT ---
  if ! ip link show "$VETH_HOST_EXT" &>/dev/null && ! ip link show "$VETH_ROUTER_EXT" &>/dev/null; then
    sudo ip link add "$VETH_HOST_EXT" type veth peer name "$VETH_ROUTER_EXT"
    log "Created host↔router veth pair: $VETH_HOST_EXT <-> $VETH_ROUTER_EXT"
  fi
  sudo ip link set "$VETH_HOST_EXT" up || true
  quiet sudo ip addr add "$HOST_EXT_IP" dev "$VETH_HOST_EXT"
  sudo ip link set "$VETH_ROUTER_EXT" netns "$ROUTER_NS" || true
  quiet sudo ip netns exec "$ROUTER_NS" ip addr add "$ROUTER_EXT_IP" dev "$VETH_ROUTER_EXT"
  sudo ip netns exec "$ROUTER_NS" ip link set "$VETH_ROUTER_EXT" up || true

  # --- Router default route via host ext ---
  sudo ip netns exec "$ROUTER_NS" ip route replace default via "${HOST_EXT_IP%%/*}" dev "$VETH_ROUTER_EXT"
  log "Router $ROUTER_NS default route set to ${HOST_EXT_IP%%/*} via $VETH_ROUTER_EXT"

  # --- NAT + IP Forwarding ---
  sudo ip netns exec "$ROUTER_NS" sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sudo ip netns exec "$ROUTER_NS" iptables -F
  sudo ip netns exec "$ROUTER_NS" iptables -t nat -F
  sudo ip netns exec "$ROUTER_NS" iptables -t nat -A POSTROUTING -s "$VPC_CIDR" -o "$VETH_ROUTER_EXT" -j MASQUERADE
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PRIV_SUBNET" -d "$PUB_SUBNET" -j ACCEPT
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PUB_SUBNET" -d "$PRIV_SUBNET" -j ACCEPT
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PUB_SUBNET" -d 0.0.0.0/0 -j ACCEPT
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PRIV_SUBNET" -d 0.0.0.0/0 -j DROP

  log "NAT and FORWARD rules applied for $ROUTER_NS"

  pass "VPC $BRIDGE ($VPC_CIDR) created successfully."
}

# ===============================
#  DELETE VPC
# ===============================
delete_vpc() {
  ENV_FILE=$1
  source "$ENV_FILE"

  log "Deleting VPC: $BRIDGE"

  for NS in "$PUB_NS" "$PRIV_NS" "$ROUTER_NS"; do
    if sudo ip netns list | grep -qw "$NS"; then
      sudo ip netns delete "$NS"
      log "Namespace $NS deleted."
    fi
  done

  for BR in "${BRIDGE}-pub" "${BRIDGE}-priv"; do
    sudo ip link set "$BR" down 2>/dev/null || true
    sudo ip link delete "$BR" type bridge 2>/dev/null || true
    log "Bridge $BR removed if present."
  done

  sudo ip link delete "$VETH_HOST_EXT" 2>/dev/null || true && log "Host ext veth $VETH_HOST_EXT removed if present."

  pass "VPC $BRIDGE deleted."
}

# ===============================
#  PEERING
# ===============================
peer_vpc() {
  if [ "$#" -lt 2 ]; then
    fail "Need at least 2 env files to peer"
    exit 1
  fi

  declare -A ROUTER_NS_MAP
  for ENV_FILE in "$@"; do
    source "$ENV_FILE"
    ROUTER_NS_MAP["$ROUTER_NS"]="$VPC_CIDR"
  done

  ROUTERS=("${!ROUTER_NS_MAP[@]}")
  PEER_IDX=1

  for ((i=0; i<${#ROUTERS[@]}; i++)); do
    for ((j=i+1; j<${#ROUTERS[@]}; j++)); do
      R1=${ROUTERS[$i]}
      R2=${ROUTERS[$j]}
      VPC1_CIDR=${ROUTER_NS_MAP[$R1]}
      VPC2_CIDR=${ROUTER_NS_MAP[$R2]}

      log "Creating peering between $R1 ($VPC1_CIDR) and $R2 ($VPC2_CIDR)"

      PEER1_IF="vpeer${PEER_IDX}a"
      PEER2_IF="vpeer${PEER_IDX}b"
      PEER_IP1="172.16.${PEER_IDX}.1"
      PEER_IP2="172.16.${PEER_IDX}.2"

      if ! ip link show "$PEER1_IF" &>/dev/null && ! ip link show "$PEER2_IF" &>/dev/null; then
        sudo ip link add "$PEER1_IF" type veth peer name "$PEER2_IF"
        log "Created peering veth pair: $PEER1_IF <-> $PEER2_IF"
      fi

      sudo ip link set "$PEER1_IF" netns "$R1"
      sudo ip link set "$PEER2_IF" netns "$R2"

      sudo ip netns exec "$R1" ip addr add "$PEER_IP1/30" dev "$PEER1_IF" || true
      sudo ip netns exec "$R1" ip link set "$PEER1_IF" up || true

      sudo ip netns exec "$R2" ip addr add "$PEER_IP2/30" dev "$PEER2_IF" || true
      sudo ip netns exec "$R2" ip link set "$PEER2_IF" up || true

      sudo ip netns exec "$R1" ip route replace "$VPC2_CIDR" via "$PEER_IP2"
      sudo ip netns exec "$R2" ip route replace "$VPC1_CIDR" via "$PEER_IP1"

      sudo ip netns exec "$R1" iptables -C FORWARD -s "$VPC1_CIDR" -d "$VPC2_CIDR" -j ACCEPT 2>/dev/null || \
        sudo ip netns exec "$R1" iptables -A FORWARD -s "$VPC1_CIDR" -d "$VPC2_CIDR" -j ACCEPT
      sudo ip netns exec "$R1" iptables -C FORWARD -s "$VPC2_CIDR" -d "$VPC1_CIDR" -j ACCEPT 2>/dev/null || \
        sudo ip netns exec "$R1" iptables -A FORWARD -s "$VPC2_CIDR" -d "$VPC1_CIDR" -j ACCEPT

      sudo ip netns exec "$R2" iptables -C FORWARD -s "$VPC2_CIDR" -d "$VPC1_CIDR" -j ACCEPT 2>/dev/null || \
        sudo ip netns exec "$R2" iptables -A FORWARD -s "$VPC2_CIDR" -d "$VPC1_CIDR" -j ACCEPT
      sudo ip netns exec "$R2" iptables -C FORWARD -s "$VPC1_CIDR" -d "$VPC2_CIDR" -j ACCEPT 2>/dev/null || \
        sudo ip netns exec "$R2" iptables -A FORWARD -s "$VPC1_CIDR" -d "$VPC2_CIDR" -j ACCEPT

      pass "Peering established between $R1 and $R2"

      PEER_IDX=$((PEER_IDX + 1))
    done
  done
}

# ===============================
#  UNPEER
# ===============================
unpeer_vpc() {
  if [ "$#" -lt 2 ]; then
    fail "Need at least 2 env files to unpeer"
    exit 1
  fi

  declare -A ROUTER_NS_MAP
  for ENV_FILE in "$@"; do
    source "$ENV_FILE"
    ROUTER_NS_MAP["$ROUTER_NS"]="$VPC_CIDR"
  done

  ROUTERS=("${!ROUTER_NS_MAP[@]}")
  PEER_IDX=1

  for ((i=0; i<${#ROUTERS[@]}; i++)); do
    for ((j=i+1; j<${#ROUTERS[@]}; j++)); do
      R1=${ROUTERS[$i]}
      R2=${ROUTERS[$j]}

      PEER1_IF="vpeer${PEER_IDX}a"
      PEER2_IF="vpeer${PEER_IDX}b"

      sudo ip netns exec "$R1" ip link delete "$PEER1_IF" 2>/dev/null || true
      sudo ip netns exec "$R2" ip link delete "$PEER2_IF" 2>/dev/null || true
      log "Peering interfaces ($PEER1_IF, $PEER2_IF) removed between $R1 and $R2."
      pass "Peering removed between $R1 and $R2"

      PEER_IDX=$((PEER_IDX + 1))
    done
  done
}

# ===============================
#  MAIN
# ===============================
for ENV_FILE in "$@"; do
  case $ACTION in
    create)  create_vpc "$ENV_FILE" ;;
    delete)  delete_vpc "$ENV_FILE" ;;
    peer)    peer_vpc "$@"; break ;;
    unpeer)  unpeer_vpc "$@"; break ;;
    *) usage ;;
  esac
done

log "✅ Action $ACTION completed."