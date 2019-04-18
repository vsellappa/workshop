#!/usr/bin/env bash
##
##
## Launch Centos/RHEL 7 Vm  with at least 4 cores / 16Gb mem / 60Gb disk
## Then run this script.
##
##
export ambari_password=${ambari_password:-StrongPassword}
export db_password=${db_password:-StrongPassword}
export nifi_password=${nifi_password:-StrongPassword}
export ambari_services="ZOOKEEPER STREAMLINE NIFI KAFKA STORM REGISTRY NIFI_REGISTRY KNOX AMBARI_METRICS"
export cluster_name=${cluster_name:-hdf}
export create_image=${create_image:-true}
export host_count=${host_count:-1}

export ambari_version=2.7.3.0
export mpack_url="http://public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.4.0.0/tars/hdf_ambari_mp/hdf-ambari-mpack-3.4.0.0-155.tar.gz"  

export ambari_stack_version=3.4
export ambari_stack_name=HDF

#service user for Ambari to start services on boot
export service_user="demokitadmin"
export service_password="BadPass#1"


if [ "${create_image}" = true  ]; then
  echo "updating /etc/hosts with demo.hortonworks.com entry pointing to VMs ip, hostname..."
  curl -sSL https://gist.github.com/abajwa-hw/9d7d06b8d0abf705ae311393d2ecdeec/raw | sudo -E sh 
  sleep 5
fi

export host=$(hostname -f)
echo "Hostname is: ${host}"

echo Installing Packages...
sudo yum localinstall -y https://dev.mysql.com/get/mysql57-community-release-el7-8.noarch.rpm
sudo yum install -y git python-argparse epel-release mysql-connector-java* mysql-community-server nc

# MySQL Setup to keep the new services separate from the originals
echo Database setup...
sudo systemctl enable mysqld.service
sudo systemctl start mysqld.service
#extract system generated Mysql password
oldpass=$( grep 'temporary.*root@localhost' /var/log/mysqld.log | tail -n 1 | sed 's/.*root@localhost: //' )
#create sql file that
# 1. reset Mysql password to temp value and create druid/superset/registry/streamline schemas and users
# 2. sets passwords for druid/superset/registry/streamline users to ${db_password}
cat << EOF > mysql-setup.sql
ALTER USER 'root'@'localhost' IDENTIFIED BY 'Secur1ty!'; 
uninstall plugin validate_password;
CREATE DATABASE registry DEFAULT CHARACTER SET utf8; CREATE DATABASE streamline DEFAULT CHARACTER SET utf8; 
CREATE USER 'registry'@'%' IDENTIFIED BY '${db_password}'; CREATE USER 'streamline'@'%' IDENTIFIED BY '${db_password}'; 
GRANT ALL PRIVILEGES ON registry.* TO 'registry'@'%' WITH GRANT OPTION ; GRANT ALL PRIVILEGES ON streamline.* TO 'streamline'@'%' WITH GRANT OPTION ; 
commit; 
EOF
#execute sql file
mysql -h localhost -u root -p"$oldpass" --connect-expired-password < mysql-setup.sql
#change Mysql password to ${db_password}
mysqladmin -u root -p'Secur1ty!' password ${db_password}
#test password and confirm dbs created
mysql -u root -p${db_password} -e 'show databases;'
# Install Ambari
echo Installing Ambari

export install_ambari_server=true
#curl -sSL https://raw.githubusercontent.com/seanorama/ambari-bootstrap/master/ambari-bootstrap.sh | sudo -E sh
curl -sSL https://raw.githubusercontent.com/abajwa-hw/ambari-bootstrap/master/ambari-bootstrap.sh | sudo -E sh
sleep 15
sudo ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar
sudo ambari-server install-mpack --verbose --mpack=${mpack_url}

# Hack to fix a current bug in Ambari Blueprints
sudo sed -i.bak "s/\(^    total_sinks_count = \)0$/\11/" /var/lib/ambari-server/resources/stacks/HDP/2.0.6/services/stack_advisor.py

echo "Creating Storm View..."
curl -u admin:admin -H "X-Requested-By:ambari" -X POST -d '{"ViewInstanceInfo":{"instance_name":"Storm_View","label":"Storm View","visible":true,"icon_path":"","icon64_path":"","description":"storm view","properties":{"storm.host":"'${host}'","storm.port":"8744","storm.sslEnabled":"false"},"cluster_type":"NONE"}}' http://${host}:8080/api/v1/views/Storm_Monitoring/versions/0.1.0/instances/Storm_View

#create demokitadmin user
curl -iv -u admin:admin -H "X-Requested-By: blah" -X POST -d "{\"Users/user_name\":\"${service_user}\",\"Users/password\":\"${service_password}\",\"Users/active\":\"true\",\"Users/admin\":\"true\"}" http://localhost:8080/api/v1/users

echo "Updating admin password..."
curl -iv -u admin:admin -H "X-Requested-By: blah" -X PUT -d "{ \"Users\": { \"user_name\": \"admin\", \"old_password\": \"admin\", \"password\": \"${ambari_password}\" }}" http://localhost:8080/api/v1/users/admin

sudo ambari-server restart
while ! echo exit | nc ${host} 8080; do echo "waiting for Ambari to be fully up..."; sleep 10; done

echo "Deploying HDP and HDF services..."
curl -ssLO https://github.com/seanorama/ambari-bootstrap/archive/master.zip
unzip -q master.zip -d  /tmp

echo "downloading Blueprint configs template..."
cd /tmp/ambari-bootstrap-master/deploy

cat << EOF > configuration-custom.json
{
  "configurations": {
    "ams-grafana-env": {
      "metrics_grafana_password": "${ambari_password}"
    },
    "kafka-broker": {
      "offsets.topic.replication.factor": "1"
    },      
    "streamline-common": {
      "jar.storage.type": "local",
      "streamline.storage.type": "mysql",
      "streamline.storage.connector.connectURI": "jdbc:mysql://$(hostname -f):3306/streamline",
      "registry.url" : "http://localhost:7788/api/v1",
      "streamline.dashboard.url" : "http://localhost:9089",
      "streamline.storage.connector.password": "${db_password}"
    },
    "registry-common": {
      "jar.storage.type": "local",
      "registry.storage.connector.connectURI": "jdbc:mysql://$(hostname -f):3306/registry",
      "registry.storage.type": "mysql",
      "registry.storage.connector.password": "${db_password}"
    },
    "nifi-registry-ambari-config": {
      "nifi.registry.security.encrypt.configuration.password": "${nifi_password}"
    },
    "nifi-registry-properties": {
      "nifi.registry.db.password": "${nifi_password}"
    },    
    "nifi-ambari-config": {
      "nifi.security.encrypt.configuration.password": "${nifi_password}"
    }
  }
}
EOF

#sed -i.bak "s/\[security\]/\[security\]\nforce_https_protocol=PROTOCOL_TLSv1_2/"   /etc/ambari-agent/conf/ambari-agent.ini
#bash -c "nohup ambari-agent restart" || true

echo "Waiting for 30s before deploying cluster with services: ${ambari_services}"
sleep 30
sudo -E /tmp/ambari-bootstrap-master/deploy/deploy-recommended-cluster.bash

echo Now open your browser to http://$(curl -s icanhazptr.com):8080 and login as admin/${ambari_password} to observe the cluster install

echo "Waiting for cluster to be installed..."
sleep 5

ambari_pass="${ambari_password}" source /tmp/ambari-bootstrap-master/extras/ambari_functions.sh
ambari_configs
ambari_wait_request_complete 1

#add minifi
#MiNiFi install (HDF 3.4) - this is a manual download/install

echo "Installing MiniFI..."
mkdir -p /tmp/minifi

wget -P /tmp/minifi http://public-repo-1.hortonworks.com/HDF/3.4.0.0/minifi-0.6.0.3.4.0.0-155-bin.tar.gz
wget -P /tmp/minifi http://public-repo-1.hortonworks.com/HDF/3.4.0.0/minifi-toolkit-0.6.0.3.4.0.0-155-bin.tar.gz

cd /usr/hdf/3.4.0.0-155

tar zxvf /tmp/minifi-0.*-bin.tar.gz
tar zxvf /tmp/minifi-toolkit-0.*-bin.tar.gz

cd /usr/hdf/current
ln -s /usr/hdf/3.4.0.0-155/minifi-0.* minifi
ln -s /usr/hdf/3.4.0.0-155/minifi-toolkit-0.* minifi-toolkit

##
## Tools for workshop usage
##
sudo yum install -y tmux

if [ "${create_image}" = true  ]; then
  echo "Setting up auto start of services on boot"
  curl -sSL https://gist.github.com/abajwa-hw/408134e032c05d5ff7e592cd0770d702/raw | sudo -E sh
fi

echo "Done!"
