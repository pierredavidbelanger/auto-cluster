#!/bin/bash -x

#yum update -y

yum install -y jq curl awscli

##########
# VARS

instance_id=$(curl -fs http://169.254.169.254/latest/meta-data/instance-id)
region=$(curl -fs http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
public_ip=$(curl -fs http://169.254.169.254/latest/meta-data/public-ipv4)
public_hostname=$(curl -fs http://169.254.169.254/latest/meta-data/public-hostname)
private_ip=$(curl -fs http://169.254.169.254/latest/meta-data/local-ipv4)
private_hostname=$(curl -fs http://169.254.169.254/latest/meta-data/local-hostname)

##########
# CONFIGS

asg_name=$(aws autoscaling describe-auto-scaling-instances --region "$region" --instance-ids "$instance_id" --query 'AutoScalingInstances[].AutoScalingGroupName' --output text)
cluster_tag=""
role_tag=""
bucket_tag=""
zone_tag=""

if [ "$asg_name" != "" ]; then
  cluster_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=cluster' --query 'Tags[].Value' --output text)
  role_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=role' --query 'Tags[].Value' --output text)
  bucket_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=bucket' --query 'Tags[].Value' --output text)
  zone_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=zone' --query 'Tags[].Value' --output text)
else
  asg_name='none'
  cluster_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=cluster' --query 'Tags[].Value' --output text)
  role_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=role' --query 'Tags[].Value' --output text)
  bucket_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=bucket' --query 'Tags[].Value' --output text)
  zone_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=zone' --query 'Tags[].Value' --output text)
fi

if [ "$cluster_tag" == '' ]; then
  cluster_tag='default'
fi
if [ "$role_tag" == '' ]; then
  role_tag='manager'
fi
if [ "$zone_tag" == '' ]; then
  zone_tag='k3s.local'
fi

##########
# RESTORE

if [ "$role_tag" == 'manager' ] && [ "$bucket_tag" != '' ]; then
  mkdir -p /var/lib/rancher/k3s/server
  aws s3 sync "s3://$bucket_tag/$cluster_tag/server" "/var/lib/rancher/k3s/server"
fi

##########
# CLUSTER SECRET

cluster_secret_param="/k3s/$cluster_tag/cluster/secret"
cluster_secret=$(aws ssm get-parameters --region "$region" --names "$cluster_secret_param" | jq '.Parameters[0].Value // empty' -r)
if [ "$cluster_secret" == '' ]; then
  cluster_secret=$(openssl rand 256 | sha256sum | head -c 64)
  aws ssm put-parameter --region "$region" --name "$cluster_secret_param" --value "$cluster_secret" --type String
  cluster_secret=$(aws ssm get-parameters --region "$region" --names "$cluster_secret_param" | jq '.Parameters[0].Value // empty' -r)
fi

##########
# K3S

export INSTALL_K3S_VERSION='v0.9.1'
export INSTALL_K3S_EXEC=""
if [ "$role_tag" == 'manager' ]; then
  storage_endpoint=$(aws ssm get-parameters --region "$region" --names "/k3s/$cluster_tag/manager/storage-endpoint" | jq '.Parameters[0].Value // empty' -r)
  if [ "$storage_endpoint" != '' ]; then
    export INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC --storage-endpoint '$storage_endpoint'"
  fi
  export INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC --http-listen-port 6080"
else
  export K3S_URL="https://manager.$cluster_tag.k3s.local:6443"
fi

export K3S_CLUSTER_SECRET="$cluster_secret"
export K3S_NODE_NAME="$instance_id"

curl -sfL https://get.k3s.io | sh -

echo '' >> /root/.bashrc
echo 'export PATH="$PATH:/usr/local/bin"' >> /root/.bashrc

##########
# ZONE

if [ "$role_tag" == 'manager' ]; then
  tmpfile=$(mktemp)
  cat <<EOF > "$tmpfile"
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "manager.$cluster_tag.$zone_tag", "Type": "A", "TTL": 30,
        "ResourceRecords": [{ "Value": "$private_ip" }]
      }
    }
  ]
}
EOF
  zone_id=($(aws route53 list-hosted-zones --query "HostedZones[?Name==\`$zone_tag.\`].Id" --output text))
  if [ "$zone_id" != "" ]; then
    aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "file://$tmpfile"
  fi
fi

##########
# GARBAGE COLLECTOR

if [ "$role_tag" == 'manager' ]; then
  cat <<EOF > /etc/cron.hourly/k3s-00-garbage-collector.sh
#!/bin/bash
node_names=(\$(/usr/local/bin/k3s kubectl get nodes | grep NotReady | cut -d ' ' -f1))
for node_name in "\${node_names[@]}"; do
  instance_status=\$(aws ec2 describe-instance-status --region "$region" --query "InstanceStatuses[?InstanceId==\\\`\$node_name\\\`].InstanceState.Name" --output text)
  if [ "\$instance_status" == '' ] || [ "\$instance_status" == 'shutting-down' ] || [ "\$instance_status" == 'terminated' ]; then
    /usr/local/bin/k3s kubectl delete "node/\$node_name"
  fi
done
EOF
  chmod +x /etc/cron.hourly/k3s-00-garbage-collector.sh
  systemctl restart crond.service
fi

##########
# BACKUP

if [ "$role_tag" == 'manager' ] && [ "$bucket_tag" != '' ]; then
  cat <<EOF > /etc/cron.hourly/k3s-01-backup.sh
#!/bin/bash
aws s3 sync --region "$region" "/var/lib/rancher/k3s/server" "s3://$bucket_tag/$cluster_tag/server" --delete \
  --exclude "*.db-shm" --exclude "*.db-wal" --exclude "manifests/*" --exclude "static/*" \
   > /var/log/k3s-backup 2>&1
EOF
  chmod +x /etc/cron.hourly/k3s-01-backup.sh
  systemctl restart crond.service
fi
