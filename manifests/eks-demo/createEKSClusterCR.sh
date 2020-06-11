#!/bin/bash
# You need:
# - kubectl w/ qliksense plugin installed
# - eksctl & awscli, pre-configured with AccessKey

# This script uses bash prompt and CR.yaml to generate the qlik-stack

#####
# Read in variables from prompt
echo "What version of QLik Sense?"
read QLIKSENSE_VERSION
echo "What is the DNS domain name of Qlik Sense?"
read DOMAIN
echo "What is the instance/host name of Qlik Sense?"
read QLIKSENSE_HOST
echo "What is the realm/host name of Keycloak?"
read KEYCLOAK_HOST
echo "What is the Keycloak client secret?"
read KEYCLOAK_SECRET
echo "What is the Default Password for Demo Users?"
read DEFAULT_USER_PASSWORD
echo "What will be the Keycloak admin password?"
read KEYCLOAK_ADMIN_PASSWORD


#####
# Use vars and eksctl/awscli CLI to create a (4) node cluster w/GKE
#### 16 vCPU and 60GB RAM
#### Boot disk == 100GB
#### IP Alias?
#### Max Pods == 110
#### HPA, HTTP LB

start=`date +%s`
##### Create Cluster
# Use eksctl to apply pre-defined config YAML
# eksctl create cluster -f cluster.yaml # Replace with $EKS_YAML
aws ec2 describe-regions --all-regions|jq -r '.Regions[].RegionName'
eksctl create cluster -n qseok --version 1.15 -r $REGION -t $NODE_TYPE -m 3 -M 5 --asg-access --external-dns-access --auto-kubeconfig
echo "Cluster"
echo "--"
echo "Cluster: $QLIKSENSE_HOST"

#####
# Create (2) public IP Addresses. One Regional and One Global.
# Tag Regional address as $QLIKSENSE_HOST-ip
# Tag Keycloak address as $KEYCLOAK_HOST-ip
## Create QSEoK DNS Address and set to variable with jq
QLIKSENSE_IP=$(aws ec2 allocate-address | jq -r '.PublicIp'|sed -e 's/\"//g')
# Create a Route53 HostedZone using inputed vars. Pipe through jq to store values.
##### Instead - does it make sense to wait for propogation and then list?
aws route53 create-hosted-zone --name $QLIKSENSE_HOST.$DOMAIN --caller-reference $QLIKSENSE_HOST | jq -r '.HostedZone.Id,.DelegationSet.NameServers[]'
## Create Keycloak Address and set to variable with jq
KEYCLOAK_IP=$(aws ec2 allocate-address | jq -r '.PublicIp'|sed -e 's/\"//g')
aws route53 create-hosted-zone --name $KEYCLOAK_HOST.$DOMAIN --caller-reference $KEYCLOAK_HOST | jq -r '.HostedZone.Id,.DelegationSet.NameServers[]'

###
# **************** Must update registrar to point to new NS


## Create a DNS record for the new IP.
# Generate JSON using variables.
cat <<EOF >> /tmp/route53recordSet-$DOMAIN.json
{
  "Comment": "Create QSEoK and Keycloak Route 53 RecordSet",
  "Changes": [ {
            "Action": "CREATE",
            "ResourceRecordSet": {
              "Name": "$QLIKSENSE_HOST.$DOMAIN",
              "Type": "A",
              "TTL": 300,
              "ResourceRecords": [{"Value": "QLIKSENSE_IP"}]
            }},
{
            "Action": "CREATE",
            "ResourceRecordSet": {
              "Name": "$KEYCLOAK_HOST.$DOMAIN",
              "Type": "A",
              "TTL": 300,
              "ResourceRecords": [{"Value": "KEYCLOAK_IP"}]
            }}
]
}
EOF

aws route53 change-resource-record-sets --hosted-zone-id 



## Create a DNS record for the new IP.

## echo values to screen
echo "Addresses"
echo "--"
echo "Qliksense Host: $QLIKSENSE_HOST"
echo "Qliksense IP: $QLIKSENSE_IP"
echo "Keycloak Host: $KEYCLOAK_HOST"
echo "Keycloak IP: $KEYCLOAK_IP"

#####
# Add new public IPs to Cloud DNS

# DNS
gcloud dns record-sets transaction start --zone=qseok
gcloud dns record-sets transaction add $KEYCLOAK_IP --name=$KEYCLOAK_HOST.$DOMAIN. --ttl=300 --type=A --zone=qseok
gcloud dns record-sets transaction add $QLIKSENSE_IP --name=$QLIKSENSE_HOST.$DOMAIN. --ttl=300 --type=A --zone=qseok
gcloud dns record-sets transaction execute --zone=qseok

echo "DNS"
echo "--"
echo "Qliksense Name: $QLIKSENSE_HOST.$DOMAIN."
echo "Qliksense IP: $QLIKSENSE_IP"
echo "Keycloak Name: $KEYCLOAK_HOST.$DOMAIN."
echo "Keycloak IP: $KEYCLOAK_IP"

#####
# Create File Store to use as base for RWX PVCs
gcloud filestore instances create $QLIKSENSE_HOST --file-share=name="qliksense",capacity=1T --network=name="default" --zone northamerica-northeast1-a
NFS_IP=$(gcloud filestore instances describe $QLIKSENSE_HOST --zone northamerica-northeast1-a --format='value(networks[0].ipAddresses[0])')
echo "Filestore"
echo "--"
echo "nfsShare: /qliksense"
echo "nfsServer: $NFS_IP"

#####
# Merge kubeconfig to local
gcloud container clusters get-credentials $QLIKSENSE_HOST --zone northamerica-northeast1-a
end=`date +%s`
echo "gcloud duration: $((($(date +%s)-$start)/60)) minutes"

#####
# Generate qliksense CR for git/later installation

cat <<EOF >> $QLIKSENSE_HOST.yaml
apiVersion: qlik.com/v1
kind: Qliksense
metadata:
  labels:
    version: $QLIKSENSE_VERSION
  name: $QLIKSENSE_HOST
spec:
  storageClassName: $QLIKSENSE_HOST-nfs-client
  profile: gke-demo
  rotateKeys: "yes"
  configs:
    qliksense:
    - name: acceptEULA
      value: "no"
    gke:
    - name: realmName
      value: $QLIKSENSE_HOST
    - name: idpHostName
      value: $KEYCLOAK_HOST.$DOMAIN
    - name: qlikSenseDomain
      value: $DOMAIN
    keycloak:
    - name: staticIpName
      value: $KEYCLOAK_HOST-ip
    certificate:
    - name: adminEmailAddress
      value: admin@$DOMAIN
    nfs-client-provisioner:
    - name: nfsServer
      value: $NFS_IP
    - name: nfsPath
      value: /qliksense
    elastic-infra:
    - name: qlikSenseIp
      value: $QLIKSENSE_IP
  secrets:
    qliksense:
    - name: mongoDbUri
      value: "mongodb://$QLIKSENSE_HOST-mongodb:27017/qsefe?ssl=false"
    gke:
    - name: clientSecret
      value: $KEYCLOAK_SECRET
    keycloak:
    - name: defaultUserPassword
      value: $DEFAULT_USER_PASSWORD
    - name: password
      value: $KEYCLOAK_ADMIN_PASSWORD
EOF
