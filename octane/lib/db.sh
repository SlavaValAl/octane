#!/bin/bash -xe

disable_wsrep() {
    [ -z "$1" ] && die "No node ID provided, exiting, exiting"
    ssh root@$(get_host_ip_by_node_id $1) "echo \"SET GLOBAL wsrep_on='off';\" | mysql"
}

enable_wsrep() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    ssh root@$(get_host_ip_by_node_id $1) "echo \"SET GLOBAL wsrep_on='ON';\" | mysql"
}

xtrabackup_install() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    ssh root@$(get_host_ip_by_node_id $1) "apt-get -y install percona-xtrabackup"
}

xtrabackup_stream_from_node() {
    [ -z "$1" ] && die "No backup source node ID provided, exiting"
    ssh root@$(get_host_ip_by_node_id $1) "xtrabackup --backup --stream=tar ./ | gzip " \
        | cat - > /tmp/dbs.original.tar.gz
}

xtrabackup_from_env() {
    [ -z "$1" ] && die "No env ID provided, exiting"
    local node=$(list_nodes $1 controller | head -1)
    node=${node#node-}
    xtrabackup_install $node
    disable_wsrep $node
    xtrabackup_stream_from_node $node
    enable_wsrep $node
}

xtrabackup_restore_to_env() {
    [ -z "$1" ] && die "No env ID provided, exiting"
    local cic
    local cics="$(list_nodes $1 controller)"
    for cic in $(echo "$cics");
    do
         ssh root@$(get_host_ip_by_node_id ${cic#node-}) \
        "mv /var/lib/mysql/grastate.dat /var/lib/mysql/grastate.old"
    done
    local primary_cic=$(echo "$cics" | head -1)
    scp /tmp/dbs.original.tar.gz \
        root@$(get_host_ip_by_node_id ${primary_cic#node-}):/var/lib/mysql
    ssh root@$(get_host_ip_by_node_id ${primary_cic#node-}) \
        "cd /var/lib/mysql;
        tar -zxvf dbs.original.tar.gz;
        chown -R mysql:mysql /var/lib/mysql;
        export OCF_RESOURCE_INSTANCE=p_mysql;
        export OCF_ROOT=/usr/lib/ocf;
        export OCF_RESKEY_socket=/var/run/mysqld/mysqld.sock;
        export OCF_RESKEY_additional_parameters="\""--wsrep-new-cluster"\"";
        /usr/lib/ocf/resource.d/mirantis/mysql-wss start;"
    db_sync ${primary_cic#node-}
    for cic in $(echo "$cics" | grep -v $primary_cic);
    do
        ssh root@$(get_host_ip_by_node_id ${cic#node-}) \
        "export OCF_RESOURCE_INSTANCE=p_mysql;
        export OCF_ROOT=/usr/lib/ocf;
        export OCF_RESKEY_socket=/var/run/mysqld/mysqld.sock;
        /usr/lib/ocf/resource.d/mirantis/mysql-wss start;"
    done
}

db_sync() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    ssh root@$(get_host_ip_by_node_id $1) "keystone-manage db_sync;
nova-manage db sync;
heat-manage db_sync;
neutron-db-manage --config-file=/etc/neutron/neutron.conf upgrade head;
glance-manage db upgrade;
cinder-manage db sync"
}