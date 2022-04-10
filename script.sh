#!/usr/bin/bash

# A virtual node is identified by a tuple of server ID and node ID. The server ID
# must be globally unique, and the node ID must be unique within the server.

function id_to_nodeip
{
	sid=$1
	nid=$(($2 * 2))
	ipc=$(($sid / 256))
	ipd=$(($sid - $ipc * 256))
	echo "10.$ipc.$ipd.$nid"
}

function id_to_hostip
{
	sid=$1
	nid=$(($2 * 2 + 1))
	ipc=$(($sid / 256))
	ipd=$(($sid - $ipc * 256))
	echo "10.$ipc.$ipd.$nid"
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

	# add htb for us to classify traffic into later
	ip netns exec $nsname tc qdisc add dev eth0 handle 1: root htb default 2
	tc qdisc add dev $rootportname handle 1: root htb default 2
	echo "server $sid node $nid created at $nodeip"
}

# HTB tree: 1: -> 1:1 (rate limiting) -> 1:2 (default, no netem)
#                                     -> 1:3 (netem for peer 1)
#                                     -> 1:4 (netem for peer 2)
#                                     -> ... 
# Class 1:1 is an HTB with an assigned rate.
# Classes 1:2, 1:3, ... each has an assigned rate of 1kbps and a ceiling
# of 10gbps (i.e., practically unlimited), so that they behave like fair queuing.
# Classes 1:3, ... each has a netem qdisc attached to simulate delay.

function rate_limit
{
	sid=$1
	nid=$2
	kbps=$3

	nsname="ramjet-s$sid-n$nid"
	rootportname="s${sid}n${nid}"
	# egress rate limiting at the interface from the node to the global namespace
	ip netns exec $nsname tc class add dev eth0 parent 1: classid 1:1 htb rate "${kbps}kbit" ceil "${kbps}kbit" burst 1540
	ip netns exec $nsname tc class add dev eth0 parent 1:1 classid 1:2 htb rate 1kbit ceil 10gbit burst 1540
	# ingress rate limiting at the interface from the global to the node namespace
	tc class add dev $rootportname parent 1: classid 1:1 htb rate "${kbps}kbit" ceil "${kbps}kbit" burst 1540
	tc class add dev $rootportname parent 1:1 classid 1:2 htb rate 1kbit ceil 20gbit burst 1540
}

function add_artf_delay
{
	src_sid=$1
	src_nid=$2
	dst_sid=$3
	dst_nid=$4
	ms=$5
	dstip=`id_to_nodeip $dst_sid $dst_nid`
	nsname="ramjet-s$src_sid-n$src_nid"
	# figure out the next available class id
	largest_class=`ip netns exec ramjet-s1-n1 tc class show dev eth0 | grep 'htb 1:' | sed -n 's/.*htb 1:\([0-9][0-9]*\) .*/\1/p' | sort -r | head -n1`
	next_class=$(($largest_class + 1))

	# add a new class
	ip netns exec $nsname tc class add dev eth0 parent 1:1 classid 1:$next_class htb rate 1kbit ceil 10gbit burst 1540
	ip netns exec $nsname tc filter add dev eth0 parent 1: u32 match ip dst $dstip/32 flowid 1:$next_class
	ip netns exec $nsname tc qdisc add dev eth0 parent 1:$next_class netem delay "${ms}ms"
}

case $1 in
	add)
		add_virtual_interface $2 $3
		rate_limit $2 $3 $4 ;;
	stop)
		ip -all netns del ;;
	delay)
		add_artf_delay $2 $3 $4 $5 $6 ;;
	*)
		cat <<- EOF
Helper script to manage RamJet testbed.

    add sid nid c       Add a node with server ID sid, node ID nid, and c kbps of bw.
    delay src_sid src_nid dst_sid dst_nid d
                        Inject artificial delay of d ms from src to dst.
    stop		Tear down the network.
EOF
	;;
esac
