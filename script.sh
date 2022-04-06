#!/usr/bin/bash

function id_to_ip
{
	sid=$1
	nid=$2
	ipc=$(($nid / 256))
	ipd=$(($nid - $ipc * 256))
	echo "10.$sid.$ipc.$ipd/32"
}

function add_virtual_interface
{
	sid=$1
	nid=$2

	# add the network namespace
	nsname="ramjet-s$sid-n$nid"
	ip netns add $nsname
	rootportname="s${sid}n${nid}"
	ip link add eth0 netns $nsname type veth peer name $rootportname 

	# construct the node IP address and give it
	nodeip=`id_to_ip $sid $nid`
	ip -n $nsname addr add $nodeip dev eth0
	ip -n $nsname link set eth0 up
	ip link set $rootportname up
	ip route add $nodeip dev $rootportname
	ip -n $nsname route add default dev eth0
}

case $1 in
	add)
		add_virtual_interface $2 $3 ;;
	stop)
		ip -all netns del ;;
	*)
		cat <<- EOF
Helper script to manage RamJet testbed.

    add sid nid		Add a node with server ID sid and node ID nid.
    stop		Tear down the network.
EOF
	;;
esac
