#!/usr/bin/env bash
# cleanup-vpcs.sh - remove all VPC resources created by vpcctl.sh
# Run with sudo: sudo ./cleanup-vpcs.sh

set -eu
VERBOSE=1

log(){ [ $VERBOSE -eq 1 ] && echo ">> $*"; }

# Namespaces for both VPCs
NAMESPACES=(
    ns-router ns-public ns-private
    ns-router1 ns-public1 ns-private1
)

# Bridges for both VPCs
BRIDGES=(vpc-br0 vpc-br1)

# veth pairs
VETHS=(veth-router veth-router-br veth-pub veth-pub-br veth-priv veth-priv-br veth-router-ext veth-host
       veth-router1 veth-router1-br veth-pub1 veth-pub1-br veth-priv1 veth-priv1-br veth-router-ext1 veth-host1)

# VPC CIDRs for NAT removal
VPC_CIDRS=("10.0.0.0/16" "10.1.0.0/16")

# delete namespaces
for ns in "${NAMESPACES[@]}"; do
    if ip netns list | grep -q "^$ns\b"; then
        log "Deleting namespace $ns"
        ip netns delete "$ns" || true
    fi
done

# delete veths
for veth in "${VETHS[@]}"; do
    if ip link show "$veth" &>/dev/null; then
        log "Deleting veth $veth"
        ip link delete "$veth" || true
    fi
done

# delete bridges
for br in "${BRIDGES[@]}"; do
    if ip link show "$br" &>/dev/null; then
        log "Bringing down bridge $br"
        ip link set "$br" down || true
        log "Deleting bridge $br"
        ip link delete "$br" type bridge || true
    fi
done

# remove NAT rules
for cidr in "${VPC_CIDRS[@]}"; do
    if iptables -t nat -C POSTROUTING -s "$cidr" -o eth0 -j MASQUERADE &>/dev/null; then
        log "Removing NAT rule for $cidr"
        iptables -t nat -D POSTROUTING -s "$cidr" -o eth0 -j MASQUERADE || true
    fi
done

# Ensure all namespaces are removed
for ns in $(ip netns list | awk '{print $1}'); do
  sudo ip netns del $ns
done

# Remove bridges and veths
sudo ip link del br-vpc1 2>/dev/null
sudo ip link del veth-public-br 2>/dev/null
sudo ip link del veth-private-br 2>/dev/null

sudo ip netns list
ip link show | grep veth
ip link show type bridge
echo "Full VPC cleanup complete."
log "Cleanup complete. All VPC resources removed."


