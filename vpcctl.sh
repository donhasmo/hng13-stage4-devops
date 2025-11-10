#!/bin/bash
set -e

# ===============================
#  COLORS AND HELPERS
# ===============================
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"

log()  { echo -e ">> ${YELLOW}$*${NC}"; }
pass() { echo -e "${GREEN}PASS:${NC} $*"; }
fail() { echo -e "${RED}FAIL:${NC} $*"; }

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

# ===============================
#  CREATE VPC
# ===============================
create_vpc() {
  ENV_FILE=$1
  source "$ENV_FILE"

  echo ""
  echo ">> Creating VPC: $BRIDGE ($VPC_CIDR)"
  echo "---------------------------------"

  # --- Bridges ---
  BR_PUB="${BRIDGE}-pub"
  BR_PRIV="${BRIDGE}-priv"
  for BR in "$BR_PUB" "$BR_PRIV"; do
    if ! ip link show "$BR" &>/dev/null; then
      sudo ip link add "$BR" type bridge
    fi
    sudo ip link set "$BR" up
    echo 0 | sudo tee "/sys/class/net/$BR/bridge/forward_delay" >/dev/null
  done

  # --- Router namespace ---
  if ! sudo ip netns list | grep -qw "$ROUTER_NS"; then
    sudo ip netns add "$ROUTER_NS"
  fi
  sudo ip netns exec "$ROUTER_NS" ip link set lo up

  # --- Router ↔ Public Bridge ---
  VETH_ROUTER_PUB="vr-pub-${BRIDGE}"
  VETH_BR_PUB="vbr-pub-${BRIDGE}"
  if ! ip link show "$VETH_BR_PUB" &>/dev/null && ! ip link show "$VETH_ROUTER_PUB" &>/dev/null; then
    sudo ip link add "$VETH_ROUTER_PUB" type veth peer name "$VETH_BR_PUB"
  fi
  sudo ip link set "$VETH_BR_PUB" master "$BR_PUB"
  sudo ip link set "$VETH_BR_PUB" up
  sudo ip link set "$VETH_ROUTER_PUB" netns "$ROUTER_NS"
  sudo ip netns exec "$ROUTER_NS" ip addr add "${PUB_GW%%/*}"/24 dev "$VETH_ROUTER_PUB"
  sudo ip netns exec "$ROUTER_NS" ip link set "$VETH_ROUTER_PUB" up

  # --- Router ↔ Private Bridge ---
  VETH_ROUTER_PRIV="vr-priv-${BRIDGE}"
  VETH_BR_PRIV="vbr-priv-${BRIDGE}"
  if ! ip link show "$VETH_BR_PRIV" &>/dev/null && ! ip link show "$VETH_ROUTER_PRIV" &>/dev/null; then
    sudo ip link add "$VETH_ROUTER_PRIV" type veth peer name "$VETH_BR_PRIV"
  fi
  sudo ip link set "$VETH_BR_PRIV" master "$BR_PRIV"
  sudo ip link set "$VETH_BR_PRIV" up
  sudo ip link set "$VETH_ROUTER_PRIV" netns "$ROUTER_NS"
  sudo ip netns exec "$ROUTER_NS" ip addr add "${PRIV_GW%%/*}"/24 dev "$VETH_ROUTER_PRIV"
  sudo ip netns exec "$ROUTER_NS" ip link set "$VETH_ROUTER_PRIV" up

  # --- Public namespace ---
  if ! sudo ip netns list | grep -qw "$PUB_NS"; then
    sudo ip netns add "$PUB_NS"
  fi
  sudo ip netns exec "$PUB_NS" ip link set lo up
  sudo ip link add "veth-$PUB_NS" type veth peer name "vbr-$PUB_NS"
  sudo ip link set "veth-$PUB_NS" netns "$PUB_NS"
  sudo ip link set "vbr-$PUB_NS" master "$BR_PUB"
  sudo ip link set "vbr-$PUB_NS" up
  sudo ip netns exec "$PUB_NS" ip addr add "$PUB_IP" dev "veth-$PUB_NS"
  sudo ip netns exec "$PUB_NS" ip link set "veth-$PUB_NS" up
  sudo ip netns exec "$PUB_NS" ip route add default via "$PUB_GW"

  # --- Private namespace ---
  if ! sudo ip netns list | grep -qw "$PRIV_NS"; then
    sudo ip netns add "$PRIV_NS"
  fi
  sudo ip netns exec "$PRIV_NS" ip link set lo up
  sudo ip link add "veth-$PRIV_NS" type veth peer name "vbr-$PRIV_NS"
  sudo ip link set "veth-$PRIV_NS" netns "$PRIV_NS"
  sudo ip link set "vbr-$PRIV_NS" master "$BR_PRIV"
  sudo ip link set "vbr-$PRIV_NS" up
  sudo ip netns exec "$PRIV_NS" ip addr add "$PRIV_IP" dev "veth-$PRIV_NS"
  sudo ip netns exec "$PRIV_NS" ip link set "veth-$PRIV_NS" up
  sudo ip netns exec "$PRIV_NS" ip route add default via "$PRIV_GW"

  # --- Router ↔ Host veth for NAT ---
  if ! ip link show "$VETH_HOST_EXT" &>/dev/null && ! ip link show "$VETH_ROUTER_EXT" &>/dev/null; then
    sudo ip link add "$VETH_HOST_EXT" type veth peer name "$VETH_ROUTER_EXT"
  fi
  sudo ip link set "$VETH_HOST_EXT" up
  sudo ip addr add "$HOST_EXT_IP" dev "$VETH_HOST_EXT"
  sudo ip link set "$VETH_ROUTER_EXT" netns "$ROUTER_NS"
  sudo ip netns exec "$ROUTER_NS" ip addr add "$ROUTER_EXT_IP" dev "$VETH_ROUTER_EXT"
  sudo ip netns exec "$ROUTER_NS" ip link set "$VETH_ROUTER_EXT" up
  sudo ip netns exec "$ROUTER_NS" ip route add default via "${HOST_EXT_IP%%/*}" dev "$VETH_ROUTER_EXT"

  # --- Enable IP forwarding and NAT ---
  sudo ip netns exec "$ROUTER_NS" sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sudo ip netns exec "$ROUTER_NS" iptables -F
  sudo ip netns exec "$ROUTER_NS" iptables -t nat -F
  sudo ip netns exec "$ROUTER_NS" iptables -t nat -A POSTROUTING -s "$VPC_CIDR" -o "$VETH_ROUTER_EXT" -j MASQUERADE
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PRIV_SUBNET" -d "$PUB_SUBNET" -j ACCEPT
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PUB_SUBNET" -d "$PRIV_SUBNET" -j ACCEPT
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PUB_SUBNET" -d 0.0.0.0/0 -j ACCEPT
  sudo ip netns exec "$ROUTER_NS" iptables -A FORWARD -s "$PRIV_SUBNET" -d 0.0.0.0/0 -j DROP

  echo "✅ VPC $BRIDGE created successfully."
}

# ===============================
#  DELETE VPC
# ===============================
delete_vpc() {
  ENV_FILE=$1
  source "$ENV_FILE"

  echo ""
  echo ">> Deleting VPC: $BRIDGE"
  echo "--------------------------"

  for NS in "$PUB_NS" "$PRIV_NS" "$ROUTER_NS"; do
    if sudo ip netns list | grep -qw "$NS"; then
      sudo ip netns delete "$NS"
    fi
  done

  for BR in "${BRIDGE}-pub" "${BRIDGE}-priv"; do
    sudo ip link set "$BR" down 2>/dev/null || true
    sudo ip link delete "$BR" type bridge 2>/dev/null || true
  done

  sudo ip link delete "$VETH_HOST_EXT" 2>/dev/null || true

  echo "✅ VPC $BRIDGE deleted."
}

# ===============================
#  VPC PEERING
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
      fi

      sudo ip link set "$PEER1_IF" netns "$R1"
      sudo ip link set "$PEER2_IF" netns "$R2"

      sudo ip netns exec "$R1" ip addr add "$PEER_IP1/30" dev "$PEER1_IF"
      sudo ip netns exec "$R1" ip link set "$PEER1_IF" up

      sudo ip netns exec "$R2" ip addr add "$PEER_IP2/30" dev "$PEER2_IF"
      sudo ip netns exec "$R2" ip link set "$PEER2_IF" up

      sudo ip netns exec "$R1" ip route add "$VPC2_CIDR" via "$PEER_IP2" dev "$PEER1_IF"
      sudo ip netns exec "$R2" ip route add "$VPC1_CIDR" via "$PEER_IP1" dev "$PEER2_IF"

      sudo ip netns exec "$R1" iptables -A FORWARD -s "$VPC1_CIDR" -d "$VPC2_CIDR" -j ACCEPT
      sudo ip netns exec "$R1" iptables -A FORWARD -s "$VPC2_CIDR" -d "$VPC1_CIDR" -j ACCEPT
      sudo ip netns exec "$R2" iptables -A FORWARD -s "$VPC2_CIDR" -d "$VPC1_CIDR" -j ACCEPT
      sudo ip netns exec "$R2" iptables -A FORWARD -s "$VPC1_CIDR" -d "$VPC2_CIDR" -j ACCEPT

      pass "Peering established between $R1 and $R2"

      PEER_IDX=$((PEER_IDX + 1))
    done
  done
}

# ===============================
#  REMOVE VPC PEERING
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
    create)
      create_vpc "$ENV_FILE"
      ;;
    delete)
      delete_vpc "$ENV_FILE"
      ;;
    peer)
      peer_vpc "$@"
      break
      ;;
    unpeer)
      unpeer_vpc "$@"
      break
      ;;
    *)
      usage
      ;;
  esac
done

log "✅ Action $ACTION completed."