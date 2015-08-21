#!/bin/bash

if [[ -z $1 ]]; then
    echo "Wrong usage"
    exit 1
fi
src_path=$1
out_dir=$1
initial_branch=$(git branch -q HEAD)
initial_branch=${branch_name##refs/heads/}
cassandra_branch=cass-$RANDOM
master_branch=master-$RANDOM

if [ ! -d $1 ]; then
    mkdir -p $1
    cd $1
    git init
fi

keystone_token=$(keystone token-get | grep " id " | cut -f3 -d '|')


function setup_branches {
    cd $src_path
    git fetch https://github.com/anbu-enovance/contrail-neutron-plugin.git cassandra-modifications > /dev/null
    git checkout FETCH_HEAD -b $cassandra_branch

    git fetch https://github.com/juniper/contrail-neutron-plugin.git master > /dev/null
    git checkout FETCH_HEAD -b $master_branch
}

function stop_neutron {
    sudo stop neutron-server
}

function start_neutron {
    sudo start neutron-server
    until nc -z localhost 9696; do
        echo "Waiting for neutron-server"
        sleep 1
    done
}

function setup_v2_config {
    sed -i "s/neutron_plugin_contrail.plugins.opencontrail.contrail_plugin_v3.NeutronPluginContrailCoreV3/neutron_plugin_contrail.plugins.opencontrail.contrail_plugin.NeutronPluginContrailCoreV2/" /etc/neutron/neutron.conf
}

function setup_v3_config {
    sed -i "s/neutron_plugin_contrail.plugins.opencontrail.contrail_plugin.NeutronPluginContrailCoreV2/neutron_plugin_contrail.plugins.opencontrail.contrail_plugin_v3.NeutronPluginContrailCoreV3/" /etc/neutron/neutron.conf
}

function run_test {
    retries=0
    while [ $retries -lt 3 ]; do
        _start=$(date +%s.%N)
        list_res=$(curl -s http://localhost:9696/v2.0/$1.json -H "X-Auth-Token: $keystone_token")
        _end=$(date +%s.%N)
        num=$(echo $list_res | python -c "import sys
import json
x=json.load(sys.stdin)
print len(x[x.keys()[0]])
")
        retries=$((retries + 1))
        diff=$(echo "$_end - $_start" | bc)
        echo "A $retries: # $num: $diff S" >> $2
        printf "$1 $retries\r"
    done
    echo ""
}

function run_tests {
    out_file=$1
    resources="ports networks subnets security-groups security-group-rules floatingips routers"
    for r in $resources; do
        echo "Listing $r" >> $out_file
        run_test $r $out_file

        echo "----" >> $out_file
        echo "" >> $out_file
    done
}

function run_v2_v3 {
    stop_neutron
    cd $src_path 
    git checkout $master_branch
    sudo pip install -e . > /dev/null
    setup_v2_config
    start_neutron

    run_tests $out_dir/outfile_v2

    stop_neutron
    setup_v3_config
    start_neutron

    run_tests $out_dir/outfile_v3
}

function run_v3_cassandra {
    stop_neutron
    cd $src_path
    git checkout $cassandra_branch
    sudo pip install -e . > /dev/null
    setup_v3_config
    start_neutron

    run_tests $out_dir/outfile_v3_cassandra
}

setup_branches
run_v2_v3
run_v3_cassandra
