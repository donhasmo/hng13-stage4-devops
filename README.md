# hng13-stage4-devops
DevOps Intern Stage 4 Task -  Build Your Own Virtual Private Cloud (VPC) on Linux

### PREREQUISITES
1. A linux based system (wsl ubuntu in my case).

2. Internet connection.

3. Run the WSL shell as normal user but use sudo for privileged commands. Many operations require CAP_NET_ADMIN.

### Concept Overview
                        +---------------------------+
                        |       Linux Host (WSL)   |
                        |                           |
                        |   [eth0] → Internet       |
                        |        |                  |
                        |     (NAT via iptables)    |
                        |        |                  |
                        |   [vpc-br0] (bridge)      |
                        |      /       \            |
                        +-----/---------\-----------+
                             /           \
                            /             \
                     veth-pub             veth-priv
                         |                    |
                    [ns-public]          [ns-private]
                    10.0.1.2/24          10.0.2.2/24
                         |                    |
                     default gw           default gw
                      → 10.0.1.1          → 10.0.2.1
                            \             /
                             \           /
                              [ns-router]
                              (acts as gateway)


### Project Structure

vpcctl/                 # project root
├─ vpcctl.py            # main Python CLI (create/destroy/list/peer/etc)
├─ README.md
├─ envs/
│   ├─ 1.env
│   └─ 2.env
│         
└─ tests/
    └─ test.sh         # quick smoke test

### SET UP VPC WITH SCRIPT
#### Steps
1. Make script executable
```
sudo chmod +x vpcctl.sh
```
2. Create VPC and resources:
```
# Create VPC1
sudo ./vpcctl.sh create envs/1.env
```
OR
```
# Create VPC2
sudo ./vpcctl.sh create envs/2.env 
```
OR create all
```
sudo ./vpcctl.sh create envs/1.env envs/2.env
```

### Destroy VPCs
#### Steps
```
# Destroy VPC1
sudo ./vpcctl.sh delete envs/1.env
```
OR
```
# Destroy VPC2
sudo ./vpcctl.sh delete envs/2.env 
```
OR delete all
```
sudo ./vpcctl.sh delete envs/1.env envs/2.env
```
### Check Status of VPCs
#### Steps
```
NB: For better clean up:
```
sudo ./cleanup.sh
```

# Status of VPC1
sudo ./vpcctl.sh envs/1.env status
```
OR
```
# Status of VPC2
sudo ./vpcctl.sh envs/2.env status
```

### AUTOMATED TEST
1. Make ./test.sh executable:
```
sudo chmod +x ./test.sh 
```
2. Run script:
```
sudo ./test.sh envs/1.env
```
NB: Last 2 test cases will fail because peering has not been set up yet

### MANUAL TEST

1. internal connectivity:
```
sudo ip netns exec ns-public1 ping -c 2 10.0.2.2   # should reach private subnet
```

2. Test internet access (only from public subnet):
```
sudo ip netns exec ns-public1 ping -c 2 8.8.8.8    # should succeed
sudo ip netns exec ns-private1 ping -c 2 8.8.8.8   # should FAIL (no NAT)

```
3. Run Web Server in Subnets (10.0.1.2 from browser):
```
sudo ip netns exec ns-public1 python3 -m http.server 80 &
sudo ip netns exec ns-private1 python3 -m http.server 8080 &
```
4. Test packet filtering:
```
# Test public → private
# Expected to fail
sudo ip netns exec ns-public1 ping -c 3 10.0.2.2
```

5. From your private to internet:
```
sudo ip netns exec ns-private1 ping -c 3 8.8.8.8  
#connection refused or timeout, because the private subnet isn’t exposed externally
```
### SET UP VPC PEERING
#Create VPC peering between VPCs:
```
sudo ./vpcctl.sh peer envs/1.env envs/2.env
```
#Remove VPC peering between VPCs:
```
sudo ./vpcctl.sh unpeer envs/1.env envs/2.env
```

#### VPC Peering test
#Re-run test.sh
```
sudo ./test.sh
```

### CLEAN UP
#### Steps
1. Make cleanup.sh executable:
```
sudo chmod +x cleanup.sh
```
2. Run script:
```
sudo ./cleanup.sh
```