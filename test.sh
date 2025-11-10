#!/usr/bin/env bash
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
#  DISCOVER ALL ENV FILES
# ===============================
ENV_DIR="envs"
ENV_FILES=($(ls "$ENV_DIR"/*.env 2>/dev/null || true))

if [ ${#ENV_FILES[@]} -eq 0 ]; then
    echo "No environment files found in $ENV_DIR/"
    exit 1
fi

echo "=============================================="
echo "🔍 Running VPC tests for all environments"
echo "=============================================="

# ===============================
#  LOOP THROUGH EACH ENV FILE
# ===============================
for ENV_FILE in "${ENV_FILES[@]}"; do
    echo
    echo "=============================================="
    log "🏗️  Testing: $ENV_FILE"
    echo "=============================================="

    export $(grep -v '^#' "$ENV_FILE" | xargs)

    PUB_IP_ONLY="${PUB_IP%%/*}"
    PRIV_IP_ONLY="${PRIV_IP%%/*}"

    log "DEBUG: PUB_NS=$PUB_NS, PRIV_NS=$PRIV_NS, ROUTER_NS=$ROUTER_NS"

    # Show iptables for router
    log "🔎 Checking iptables in $ROUTER_NS"
    sudo ip netns exec "$ROUTER_NS" iptables -L FORWARD -n -v || true

    # 1️⃣ Public → Private
    log "1️⃣ Testing internal connectivity (Public → Private)"
    if sudo ip netns exec "$PUB_NS" ping -c 2 "$PRIV_IP_ONLY" >/dev/null 2>&1; then
        pass "Public subnet can reach private subnet"
    else
        fail "Public subnet cannot reach private subnet"
    fi

    # 2️⃣ Private → Public
    log "2️⃣ Testing internal connectivity (Private → Public)"
    if sudo ip netns exec "$PRIV_NS" ping -c 2 "$PUB_IP_ONLY" >/dev/null 2>&1; then
        pass "Private subnet can reach public subnet"
    else
        fail "Private subnet cannot reach public subnet"
    fi

    # 3️⃣ Internet test
    log "3️⃣ Testing internet access (ping 8.8.8.8)"
    log "Public subnet → Internet (should succeed)"
    if sudo ip netns exec "$PUB_NS" ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        pass "Public subnet can reach internet"
    else
        fail "Public subnet cannot reach internet"
    fi

    log "Private subnet → Internet (should fail)"
    if sudo ip netns exec "$PRIV_NS" ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        fail "Private subnet should NOT reach internet, but it did"
    else
        pass "Private subnet cannot reach internet (as expected)"
    fi

    # 4️⃣ Start temporary HTTP servers
    log "4️⃣ Running HTTP servers"
    sudo ip netns exec "$PUB_NS" python3 -m http.server 80 >/dev/null 2>&1 &
    PUB_HTTP_PID=$!
    sudo ip netns exec "$PRIV_NS" python3 -m http.server 8080 >/dev/null 2>&1 &
    PRIV_HTTP_PID=$!

    log "Public:  http://$PUB_IP_ONLY"
    log "Private: http://$PRIV_IP_ONLY:8080"
    sleep 5

    # Cleanup
    sudo kill $PUB_HTTP_PID $PRIV_HTTP_PID 2>/dev/null || true
    log "✅ Servers stopped for $ENV_FILE"
done

# ==========================================================
#  🔄 CROSS-VPC CONNECTIVITY TEST (ROUTER ↔ ROUTER)
# ==========================================================
echo
echo "=============================================="
log "🌐 Cross-VPC Router Reachability Tests"
echo "=============================================="

ROUTERS=($(ip netns list | grep 'nsrouter' | awk '{print $1}' | sort))

if [ "${#ROUTERS[@]}" -lt 2 ]; then
    log "Only one router found — skipping cross-VPC test."
else
    for ((i=0; i<${#ROUTERS[@]}; i++)); do
        for ((j=i+1; j<${#ROUTERS[@]}; j++)); do
            R1=${ROUTERS[$i]}
            R2=${ROUTERS[$j]}

            log "Testing reachability between $R1 and $R2"

            R1_IP=$(sudo ip netns exec "$R1" ip addr show | grep -oP '10\.\d+\.\d+\.1' | head -n1)
            R2_IP=$(sudo ip netns exec "$R2" ip addr show | grep -oP '10\.\d+\.\d+\.1' | head -n1)

            if [ -z "$R1_IP" ] || [ -z "$R2_IP" ]; then
                fail "Could not determine router IPs for $R1 or $R2"
                continue
            fi

            if sudo ip netns exec "$R1" ping -c 2 "$R2_IP" >/dev/null 2>&1; then
                pass "$R1 can reach $R2 ($R2_IP)"
            else
                fail "$R1 cannot reach $R2 ($R2_IP)"
            fi

            if sudo ip netns exec "$R2" ping -c 2 "$R1_IP" >/dev/null 2>&1; then
                pass "$R2 can reach $R1 ($R1_IP)"
            else
                fail "$R2 cannot reach $R1 ($R1_IP)"
            fi
        done
    done
fi

# ==========================================================
#  🔄 CROSS-VPC SUBNET CONNECTIVITY TESTS
# ==========================================================
echo
echo "=============================================="
log "🌐 Cross-VPC Subnet Reachability Tests"
echo "=============================================="

# Collect public/private namespace info from envs
PUB_NS_LIST=()
PRIV_NS_LIST=()
PUB_IP_LIST=()

for ENV_FILE in "${ENV_FILES[@]}"; do
    source "$ENV_FILE"
    PUB_NS_LIST+=("$PUB_NS")
    PRIV_NS_LIST+=("$PRIV_NS")
    PUB_IP_ONLY="${PUB_IP%%/*}"
    PUB_IP_LIST+=("$PUB_IP_ONLY")
done

NUM_VPCS=${#PUB_NS_LIST[@]}

if [ "$NUM_VPCS" -lt 2 ]; then
    log "Less than 2 VPCs — skipping cross-subnet tests."
else
    # Test each pair of VPCs
    for ((i=0; i<NUM_VPCS; i++)); do
        for ((j=i+1; j<NUM_VPCS; j++)); do
            PUB1=${PUB_NS_LIST[$i]}
            PUB2=${PUB_NS_LIST[$j]}
            PRIV1=${PRIV_NS_LIST[$i]}
            PRIV2=${PRIV_NS_LIST[$j]}
            PUB1_IP=${PUB_IP_LIST[$i]}
            PUB2_IP=${PUB_IP_LIST[$j]}

            log "Testing Public $PUB1 → Public $PUB2 (should succeed)"
            if sudo ip netns exec "$PUB1" ping -c 2 "$PUB2_IP" >/dev/null 2>&1; then
                pass "Public subnet $PUB1 can reach Public subnet $PUB2"
            else
                fail "Public subnet $PUB1 cannot reach Public subnet $PUB2"
            fi

            log "Testing Public $PUB2 → Public $PUB1 (should succeed)"
            if sudo ip netns exec "$PUB2" ping -c 2 "$PUB1_IP" >/dev/null 2>&1; then
                pass "Public subnet $PUB2 can reach Public subnet $PUB1"
            else
                fail "Public subnet $PUB2 cannot reach Public subnet $PUB1"
            fi

            log "Testing Private $PRIV1 → Public $PUB2 (should fail)"
            if sudo ip netns exec "$PRIV1" ping -c 2 "$PUB2_IP" >/dev/null 2>&1; then
                fail "Private subnet $PRIV1 unexpectedly reached Public subnet $PUB2"
            else
                pass "Private subnet $PRIV1 cannot reach Public subnet $PUB2 (as expected)"
            fi

            log "Testing Private $PRIV2 → Public $PUB1 (should fail)"
            if sudo ip netns exec "$PRIV2" ping -c 2 "$PUB1_IP" >/dev/null 2>&1; then
                fail "Private subnet $PRIV2 unexpectedly reached Public subnet $PUB1"
            else
                pass "Private subnet $PRIV2 cannot reach Public subnet $PUB1 (as expected)"
            fi
        done
    done
fi

echo
log "🎯 All multi-VPC tests complete."
echo "=============================================="