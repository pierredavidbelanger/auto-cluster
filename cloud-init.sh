#!/bin/sh

##########
# INSTALL

yum install -y jq wget awscli docker amazon-efs-utils

##########
# VARS

instance_id=$(curl -fs http://169.254.169.254/latest/meta-data/instance-id)
region=$(curl -fs http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
public_ip=$(curl -fs http://169.254.169.254/latest/meta-data/public-ipv4)
private_ip=$(curl -fs http://169.254.169.254/latest/meta-data/local-ipv4)
private_hostname=$(curl -fs http://169.254.169.254/latest/meta-data/local-hostname)
asg_name=$(aws autoscaling describe-auto-scaling-instances --region "$region" --instance-ids "$instance_id" --query 'AutoScalingInstances[].AutoScalingGroupName' --output text)

##########
# CONFIGS

cluster_tag=""
role_tag=""
if [ "$asg_name" != "" ]; then
  cluster_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=cluster' --query 'Tags[].Value' --output text)
  role_tag=$(aws autoscaling describe-tags --region "$region" --filters "Name=auto-scaling-group,Values=$asg_name" 'Name=key,Values=role' --query 'Tags[].Value' --output text)
else
  asg_name='none'
  cluster_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=cluster' --query 'Tags[].Value' --output text)
  role_tag=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" 'Name=key,Values=role' --query 'Tags[].Value' --output text)
fi
if [ "$cluster_tag" == '' ]; then
  cluster_tag='default'
fi
if [ "$role_tag" == '' ]; then
  role_tag='manager'
fi

##########
# DOCKER

usermod -a -G docker ec2-user

cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "awslogs",
  "log-opts": {
    "awslogs-region": "$region",
    "awslogs-group": "/swarm/$cluster_tag/$asg_name",
    "awslogs-create-group": "true",
    "tag": "{{.Name}}/{{.ID}}/$instance_id"
  }
}
EOF

service docker restart

##########
# EFS

efs_ids=($(aws efs describe-file-systems --region "$region" --query 'FileSystems[].FileSystemId' --output text))
for efs_id in "${efs_ids[@]}"; do
    efs_name=$(aws efs describe-file-systems --region "$region" --file-system-id "$efs_id" --query 'FileSystems[].Name' --output text)
    mkdir -p "/mnt/efs/$efs_name"
    echo "$efs_id:/ /mnt/efs/$efs_name efs" >> /etc/fstab
    mount "/mnt/efs/$efs_name"
done

##########
# JOIN SWARM

joined=1
retry=0
until [ $retry -ge 6 ]; do
  manager_host=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/host" | jq '.Parameters[0].Value // empty' -r)
  if [ "$manager_host" != '' ]; then
    join_token=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/$role_tag/token" | jq '.Parameters[0].Value // empty' -r)
    if [ "$join_token" != '' ]; then
      docker swarm join --token "$join_token" "$manager_host:2377"
      joined=$?
    fi
  fi
  if [ $joined == 0 ]; then
    break
  fi
  docker swarm leave
  retry=$[$retry+1]
  sleep $retry
done

##########
# INIT SWARM

if [ "$role_tag" == 'manager' ]; then
  if [ $joined == 1 ]; then
    # SWARM
    docker swarm init
    # REMOTE ADMIN
    remote_admin_password=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/remote/admin/password" | jq '.Parameters[0].Value // empty' -r)
    if [ "$remote_admin_password" == '' ]; then
      remote_admin_password=$(openssl rand -base64 14)
      aws ssm put-parameter --region "$region" --name "/swarm/$cluster_tag/manager/remote/admin/password" --value "$remote_admin_password" --type String
      remote_admin_password=$(aws ssm get-parameters --region "$region" --names "/swarm/$cluster_tag/manager/remote/admin/password" | jq '.Parameters[0].Value // empty' -r)
    fi
    remote_admin_password_hash=$(docker run --rm httpd:2.4-alpine htpasswd -nbB admin "$remote_admin_password" | cut -d ":" -f 2)
    # PORTAINER
    docker service create \
      --name portainer \
      --constraint=node.role==manager \
      --publish 8000:8000 --publish 9000:9000 \
      --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
      portainer/portainer:1.22.1 \
        --admin-password="$remote_admin_password_hash"
    # TRAEFIK
    docker service create \
      --name traefik \
      --constraint=node.role==manager \
      --publish 80:80 --publish 8080:8080 \
      traefik:v2.0 \
        --providers.docker.swarmMode=true \
        --providers.docker.endpoint='tcp://127.0.0.1:2377' \
        --providers.docker.exposedbydefault=false \
        --api.insecure=true
  fi
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
