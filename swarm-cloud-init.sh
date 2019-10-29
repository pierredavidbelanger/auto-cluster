#!/bin/bash

##########
# UPDATE

apt-get update -y

apt-get install -y awscli \
  jq \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg-agent \
  software-properties-common

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
zone_tag=""

if [ "$asg_name" != "" ]; then
  cluster_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=cluster' --query 'Tags[].Value' --output text)
  role_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=role' --query 'Tags[].Value' --output text)
  zone_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=zone' --query 'Tags[].Value' --output text)
else
  asg_name='none'
  cluster_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=cluster' --query 'Tags[].Value' --output text)
  role_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=role' --query 'Tags[].Value' --output text)
  zone_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=zone' --query 'Tags[].Value' --output text)
fi

if [ "$cluster_tag" == '' ]; then
  cluster_tag='default'
fi
if [ "$role_tag" == '' ]; then
  role_tag='manager'
fi

##########
# DOCKER

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
apt-key fingerprint 0EBFCD88 | grep Docker
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io

usermod -aG docker ubuntu

mkdir -p /etc/systemd/system/docker.service.d
cat <<EOF > /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF

cat <<EOF > /etc/docker/daemon.json
{
  "hosts": [
    "unix:///var/run/docker.sock"
  ],
  "log-driver": "awslogs",
  "log-opts": {
    "awslogs-region": "$region",
    "awslogs-group": "/swarm/$cluster_tag/$asg_name",
    "awslogs-create-group": "true",
    "tag": "{{.Name}}/{{.ID}}/$instance_id"
  }
}
EOF

systemctl enable docker.service
systemctl daemon-reload
systemctl restart docker.service

##########
# JOIN SWARM

joined=1
retry=0
until [ $retry -ge 6 ]; do

  manager_host=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/host" | jq '.Parameters[0].Value // empty' -r)
  join_token=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/$role_tag/token" | jq '.Parameters[0].Value // empty' -r)
  if [ "$manager_host" != '' ] && [ "$join_token" != '' ]; then
    docker swarm join --token "$join_token" "$manager_host:2377"
    joined=$?
  fi

  if [ $joined == 0 ]; then
    break
  fi

  docker swarm leave

  retry=$[$retry + 1]
  sleep $retry
done

##########
# INIT SWARM

if [ "$role_tag" == 'manager' ] && [ $joined == 1 ]; then

  # SWARM
  docker swarm init

  # USER ADMIN
  user_admin_password=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/user/admin/password" | jq '.Parameters[0].Value // empty' -r)
  if [ "$user_admin_password" == '' ]; then
    user_admin_password=$(openssl rand 256 | sha256sum | head -c 32)
    aws ssm put-parameter --region "$region" --name "/swarm/$cluster_tag/manager/user/admin/password" --value "$user_admin_password" --type String
    user_admin_password=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/user/admin/password" | jq '.Parameters[0].Value // empty' -r)
  fi
  user_admin_password_hash=$(docker run --rm httpd:2.4-alpine htpasswd -nbB admin "$user_admin_password" | cut -d ":" -f 2)

  # NETWORK
  docker network create -d overlay --attachable managers

  # PORTAINER
  docker service create \
    --name portainer \
    --network managers \
    --constraint=node.role==manager \
    --publish 8000:8000 --publish 9000:9000 \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    portainer/portainer:1.22.1 \
      --admin-password="$user_admin_password_hash"

  # TRAEFIK
  docker service create \
    --name traefik \
    --network managers \
    --constraint=node.role==manager \
    --publish 80:80 --publish 8080:8080 \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    traefik:v2.0 \
      --providers.docker.swarmMode=true \
      --providers.docker.exposedbydefault=false \
      --api.insecure=true
fi

##########
# ADVERTISE SWARM

if [ "$role_tag" == 'manager' ]; then
  token_manager=$(docker swarm join-token manager --quiet)
  token_worker=$(docker swarm join-token worker --quiet)
  aws ssm put-parameter --region "$region" --name "/swarm/$cluster_tag/manager/token" --value "$token_manager" --type String --overwrite
  aws ssm put-parameter --region "$region" --name "/swarm/$cluster_tag/worker/token" --value "$token_worker" --type String --overwrite
  aws ssm put-parameter --region "$region" --name "/swarm/$cluster_tag/manager/host" --value "$private_hostname" --type String --overwrite
fi

##########
# SSH USER

if [ "$role_tag" == 'manager' ]; then

  useradd manager -m -s /bin/bash
  usermod -aG docker manager
  mkdir -p /home/manager/.ssh

  user_manager_id_rsa=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/user/manager/id_rsa" | jq '.Parameters[0].Value // empty' -r)
  user_manager_id_rsa_pub=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/user/manager/id_rsa.pub" | jq '.Parameters[0].Value // empty' -r)
  if [ "$user_manager_id_rsa" == '' ] || [ "$user_manager_id_rsa_pub" == '' ]; then
    ssh-keygen -N '' -t rsa -b 4096 -f /home/manager/.ssh/id_rsa
    user_manager_id_rsa=$(cat /home/manager/.ssh/id_rsa)
    user_manager_id_rsa_pub=$(cat /home/manager/.ssh/id_rsa.pub)
    aws ssm put-parameter --region "$region" --name "/swarm/$cluster_tag/manager/user/manager/id_rsa" --value "$user_manager_id_rsa" --type String
    aws ssm put-parameter --region "$region" --name "/swarm/$cluster_tag/manager/user/manager/id_rsa.pub" --value "$user_manager_id_rsa_pub" --type String
    user_manager_id_rsa=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/user/manager/id_rsa" | jq '.Parameters[0].Value // empty' -r)
    user_manager_id_rsa_pub=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/user/manager/id_rsa.pub" | jq '.Parameters[0].Value // empty' -r)
  fi

  echo "$user_manager_id_rsa" > /home/manager/.ssh/id_rsa
  echo "$user_manager_id_rsa_pub" > /home/manager/.ssh/id_rsa.pub

  cat /home/manager/.ssh/id_rsa.pub > /home/manager/.ssh/authorized_keys

  chown -R manager:manager /home/manager/.ssh

  chmod 700 /home/manager/.ssh
  chmod 644 /home/manager/.ssh/id_rsa.pub
  chmod 600 /home/manager/.ssh/id_rsa
  chmod 600 /home/manager/.ssh/authorized_keys
fi

##########
# ROUTE53

cat <<EOF > /tmp/Route53Changes.json
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "manager.$cluster_tag.$zone_tag", "Type": "CNAME", "TTL": 30,
        "ResourceRecords": [{ "Value": "$public_hostname" }]
      }
    }
  ]
}
EOF

if [ "$role_tag" == 'manager' ] && [ "$zone_tag" != "" ]; then
  zone_id=($(aws route53 list-hosted-zones --query "HostedZones[?Name==\`$zone_tag.\`].Id" --output text))
  if [ "$zone_id" != "" ]; then
    aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch file:///tmp/Route53Changes.json
  fi
fi
