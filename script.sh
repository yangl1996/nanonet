#!/usr/bin/bash

function id_to_nodeip
{
	sid=$1
	nid=$(($2 * 2))
	ipc=$(($nid / 256))
	ipd=$(($nid - $ipc * 256))
	echo "10.$sid.$ipc.$ipd"
}

function id_to_hostip
{
	sid=$1
	nid=$(($2 * 2 + 1))
	ipc=$(($nid / 256))
	ipd=$(($nid - $ipc * 256))
	echo "10.$sid.$ipc.$ipd"
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

	# construct the IP address for the node and the host (physical machine)
	# we need IP addresses on the host side because the node needs it as the gateway
	nodeip=`id_to_nodeip $sid $nid`
	hostip=`id_to_hostip $sid $nid`
	ip -n $nsname addr add "$nodeip/31" dev eth0
	ip addr add "$hostip/31" dev $rootportname

	# bring up both ends of the tunnel
	ip -n $nsname link set eth0 up
	ip link set $rootportname up

	# add routes to/from the node
	ip route add $nodeip dev $rootportname
	ip -n $nsname route add 10.0.0.0/8 via $hostip dev eth0

	echo "server $sid node $nid created at $nodeip"
}

function rate_limit_ingress
{
	sid=$1
	nid=$2
	kbps=$3

	nsname="ramjet-s$sid-n$nid"
	# egress filter at the interface from the node to the global namespace
	ip netns exec $nsname tc qdisc add dev eth0 root tbf rate "${kbps}kbit" burst 1540 latency 5ms
	#ip netns exec $nsname tc filter add dev eth0 parent ffff: u32 match u32 0 0 police rate "${kbps}kbit" burst 100k conform-exceed drop/ok
	# ingress filter at the interface from the global to the node namespace

}

case $1 in
	add)
		add_virtual_interface $2 $3 ;;
	stop)
		ip -all netns del ;;
	rl)
		rate_limit_ingress $2 $3 $4 ;;
	*)
		cat <<- EOF
Helper script to manage RamJet testbed.

    add sid nid	        Add a node with server ID sid and node ID nid.
    rl sid nid c        Limits the ingress rate to server ID sid and node ID nid to c kbps.
    stop		Tear down the network.
EOF
	;;
esac
