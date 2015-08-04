#!/bin/bash -ex

usage() {
    echo "Usage: $(basename $0) ORIG_ID SEED_ID"
}

. `dirname $(readlink -f $0)`/env

[ -z "$1" ] && die "$(usage)"
[ -z "$2" ] && die "$(usage)"

update_swift_bind() {
    ssh root@${SEED_CIC} "set -x && sed -re 's%^bind_ip = .*%bind_ip = 0.0.0.0%' \
        -i /etc/swift/proxy-server.conf && restart swift-proxy"
}

restore_swift_bind() {
    ssh root@${SEED_CIC} "set -x && sed -re 's%^bind_ip = 0.0.0.0%bind_ip = ${MGMT_IP}%' \
        -i /etc/swift/proxy-server.conf && restart swift-proxy"
}

get_glance_password() {
    ssh root@$1 "python -c \"import yaml;
with open('/etc/astute.yaml') as f:
    cfg = yaml.safe_load(f)
print cfg['glance']['user_password']\"" || die "Can't find password for user 'glance'"
}

get_service_tenant() {
    ssh root@${SEED_CIC} "set -x;
        . /root/openrc;
        keystone tenant-get services" \
        | grep ' id ' | cut -d \| -f 3 | tr -d " "
}

get_seed_auth_token() {
    local password=$(get_glance_password $SEED_CIC)
    ssh root@$ORIG_CIC keystone --os-auth-url=http://${STORAGE_IP}:5000/v2.0 \
        --os-username=glance --os-password=$password --os-tenant-name=services \
        token-get \
        | grep ' id ' | cut -d \| -f 3 | tr -d " "
}

get_orig_auth_token() {
    local password=$(get_glance_password $ORIG_CIC)
    ssh root@$ORIG_CIC "set -x;
    . openrc;
    keystone --os-username=glance --os-password=$password \
        --os-tenant-name=services token-get" \
        | grep ' id ' | cut -d \| -f 3 | tr -d " "
}

copy_swift_object() {
    local filename="$1"
    local seed_token="$(get_seed_auth_token)"
    local orig_token="$(get_orig_auth_token)"
    ssh root@${ORIG_CIC} "set -x;
        . /root/openrc;
        swift --os-auth-token $orig_token \
            download $CONTAINER $filename;
        swift --os-auth-token $seed_token \
            --os-storage-url http://${STORAGE_IP}:8080/v1/AUTH_${TENANT_ID} \
            upload $CONTAINER $filename"
}

sync_glance_container() {
    local token="$(get_orig_auth_token)"
    local images=$(ssh root@$ORIG_CIC "set -x;
    . /root/openrc &&
    swift --os-auth-token $token \
          list ${CONTAINER}")
    for image in $images; do
        copy_swift_object $image
    done
}

main() {
    sync_glance_container
}

export CONTAINER="glance"
export ORIG_CIC=$(list_nodes $1 controller | head -1)
export SEED_CIC=$(list_nodes $2 controller | head -1)
export STORAGE_IP=$(ssh root@$SEED_CIC ip addr show dev br-storage \
    | grep ' inet ' | sed -re 's%.*inet ([^/]+)/.*%\1%')
export MGMT_IP=$(ssh root@$SEED_CIC ip addr show dev br-mgmt \
    | grep ' inet ' | sed -re 's%.*inet ([^/]+)/.*%\1%')
export TENANT_ID=$(get_service_tenant)

update_swift_bind
main
restore_swift_bind
