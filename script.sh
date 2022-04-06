#!/usr/bin/bash

function add_virtual_interface
{
	sid=$1
	nid=$2
	# add the network namespace
	ip netns add "ramjet-s$sid-n$nid"
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
