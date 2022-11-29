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

function id_to_hexnodeip
{
	sid=$1
	nid=$(($2 * 2))
	ipc=$(($sid / 256))
	ipd=$(($sid - $ipc * 256))
	printf "0a%02x%02x%02x" $ipc $ipd $nid
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
	
	# enable packet forwarding
	sysctl -w net.ipv4.ip_forward=1 > /dev/null

	# add the network namespace
	nsname="ramjet-s$sid-n$nid"
	ip netns add $nsname
	rootportname="s${sid}n${nid}"
	ip link add veth0 netns $nsname type veth peer name $rootportname 

	# construct the IP address for the node and the host (physical machine)
	# we need IP addresses on the host side because the node needs it as the gateway
	nodeip=`id_to_nodeip $sid $nid`
	hostip=`id_to_hostip $sid $nid`
	ip -n $nsname addr add "$nodeip/31" dev veth0
	ip addr add "$hostip/31" dev $rootportname

	# bring up both ends of the tunnel
	ip -n $nsname link set veth0 up
	ip link set $rootportname up

	# add routes to/from the node
	ip route add $nodeip dev $rootportname
	ip -n $nsname route add 10.0.0.0/8 via $hostip dev veth0

	# add htb for us to classify traffic into later
	ip netns exec $nsname tc qdisc add dev veth0 handle 1: root htb default 2
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
	ip netns exec $nsname tc class add dev veth0 parent 1: classid 1:1 htb rate "${kbps}kbit" ceil "${kbps}kbit" burst 1540
	ip netns exec $nsname tc class add dev veth0 parent 1:1 classid 1:2 htb rate 1kbit ceil 10gbit burst 1540
	# ingress rate limiting at the interface from the global to the node namespace
	tc class add dev $rootportname parent 1: classid 1:1 htb rate "${kbps}kbit" ceil "${kbps}kbit" burst 1540
	tc class add dev $rootportname parent 1:1 classid 1:2 htb rate 1kbit ceil 20gbit burst 1540
	# force use bbr so that we do not need to worry about queues
	sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null
	ip netns exec $nsname sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null
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
	largest_class=`ip netns exec $nsname tc class show dev veth0 | grep 'htb 1:' | sed -n 's/.*htb 1:\([0-9][0-9]*\) .*/\1/p' | sort -nr | head -n1`
	next_class=$(($largest_class + 1))

	# add a new class
	ip netns exec $nsname tc class add dev veth0 parent 1:1 classid 1:$next_class htb rate 1kbit ceil 10gbit burst 1540
	ip netns exec $nsname tc filter add dev veth0 parent 1: u32 match ip dst $dstip/32 flowid 1:$next_class
	ip netns exec $nsname tc qdisc add dev veth0 parent 1:$next_class netem delay "${ms}ms"
}

function add_route_to
{
	our_sid=$1
	our_ip=$2
	peer_sid=$3
	peer_ip=$4

	# create gre tunnel to peer
	lsmod | grep gre > /dev/null
	if [ "$?" -ne 0 ]; then
		modprobe ip_gre
	fi
	ip tunnel add ramjet-gre$peer_sid mode gre remote $peer_ip local $our_ip ttl 255
	ip link set ramjet-gre$peer_sid up
	ip addr add `id_to_hostip $our_sid 0`/24 dev ramjet-gre$peer_sid peer `id_to_hostip $peer_sid 0`/24
}

function stop_net
{
	ip -all netns del
	gre_devices=`ip addr | grep ramjet-gre |  sed -n 's/.*\(ramjet-gre[0-9][0-9]*\).*/\1/p' | sort | uniq`
	for dev in $gre_devices; do
		ip link set $dev down
		ip tunnel del $dev
	done
	modprobe -r ip_gre
}

function set_loss
{
	src_sid=$1
	src_nid=$2
	dst_sid=$3
	dst_nid=$4
	targetloss=$5
	nsname="ramjet-s$src_sid-n$src_nid"

	# find the qdisc we configured for this node
	hexip=`id_to_hexnodeip $dst_sid $dst_nid`
	filterline=`ip netns exec $nsname tc filter show dev veth0 | grep -B1 $hexip`
	# if there is no such qdisc, report an error
	if [ "$?" -ne 0 ]; then
		echo "error: no delay set from ($src_sid, $src_nid) to ($dst_sid, $dst_nid)"
		exit 1
	fi
	classid=`echo $filterline | sed -n 's/.*flowid \([0-9]*:[0-9]*\).*/\1/p'`
	classline=`ip netns exec $nsname tc class show dev veth0 classid $classid`
	qdiscline=`ip netns exec $nsname tc qdisc show dev veth0 parent $classid`
	currentdelay=`echo $qdiscline | sed -n 's/.*delay \([0-9]*[a-z]*\).*/\1/p'`
	ip netns exec $nsname tc qdisc change dev veth0 parent $classid netem delay $currentdelay loss $targetloss
}

case $1 in
	add)
		add_virtual_interface $2 $3
		rate_limit $2 $3 $4 ;;
	stop)
		stop_net ;;
	delay)
		add_artf_delay $2 $3 $4 $5 $6 ;;
	tunnel)
		add_route_to $2 $3 $4 $5  ;;
	cut)
		set_loss $2 $3 $4 $5 100 ;;
	uncut)
		set_loss $2 $3 $4 $5 0 ;;
	*)
		cat <<- EOF
Helper script to manage RamJet testbed.

    add NODE BW                  Add a node with the identifier NODE and bandwidth BW. 
    delay NODE NODE DL           Inject artificial delay of DL from the first NODE to the
                                 second NODE.
    { cut | uncut } NODE NODE    Cut or uncut the link from the first NODE to the second
                                 NODE.
    tunnel SERVER SERVER         Bridge the local server (identified by the first SERVER)
                                 to a peer server (identified by the second SERVER).
    stop                         Tear down the network.
    
    SERVER := SID IP
    NODE := SID NID
    IP := ipv4 address
    SID := an integer between 1 to 65535
    NID := an integer between 1 to 127
    BW := integer in kbps
    DL := integer in ms
EOF
	;;
esac
