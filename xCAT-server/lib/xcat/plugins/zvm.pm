# IBM(c) 2012 EPL license http://www.eclipse.org/legal/epl-v10.html
#-------------------------------------------------------

=head1

	xCAT plugin to support z/VM (s390x)
	
=cut

#-------------------------------------------------------
package xCAT_plugin::zvm;
use xCAT::Client;
use xCAT::zvmUtils;
use xCAT::zvmCPUtils;
use xCAT::MsgUtils;
use Sys::Hostname;
use xCAT::Table;
use xCAT::Utils;
use xCAT::NetworkUtils;
use Getopt::Long;
use strict;

# If the following line is not included, you get:
# /opt/xcat/lib/perl/xCAT_plugin/zvm.pm did not return a true value
1;

#-------------------------------------------------------

=head3  handled_commands

	Return list of commands handled by this plugin

=cut

#-------------------------------------------------------
sub handled_commands {
	return {
		rpower   => 'nodehm:power,mgt',
		rinv     => 'nodehm:mgt',
		mkvm     => 'nodehm:mgt',
		rmvm     => 'nodehm:mgt',
		lsvm     => 'nodehm:mgt',
		chvm     => 'nodehm:mgt',
		rscan    => 'nodehm:mgt',
		nodeset  => 'noderes:netboot',
		getmacs  => 'nodehm:getmac,mgt',
		rnetboot => 'nodehm:mgt',
	};
}

#-------------------------------------------------------

=head3  preprocess_request

	Check and setup for hierarchy

=cut

#-------------------------------------------------------
sub preprocess_request {
	my $req      = shift;
	my $callback = shift;

	# Hash array
	my %sn;

	# Scalar variable
	my $sn;

	# Array
	my @requests;

	# If already preprocessed, go straight to request
	if ( $req->{_xcatpreprocessed}->[0] == 1 ) {
		return [$req];
	}
	my $nodes   = $req->{node};
	my $service = "xcat";

	# Find service nodes for requested nodes
	# Build an individual request for each service node
	if ($nodes) {
		$sn = xCAT::Utils->get_ServiceNode( $nodes, $service, "MN" );

		# Build each request for each service node
		foreach my $snkey ( keys %$sn ) {
			my $n = $sn->{$snkey};
			print "snkey=$snkey, nodes=@$n\n";
			my $reqcopy = {%$req};
			$reqcopy->{node}                   = $sn->{$snkey};
			$reqcopy->{'_xcatdest'}            = $snkey;
			$reqcopy->{_xcatpreprocessed}->[0] = 1;
			push @requests, $reqcopy;
		}

		return \@requests;
	}
	else {

		# Input error
		my %rsp;
		my $rsp;
		$rsp->{data}->[0] = "Input noderange missing. Useage: zvm <noderange> \n";
		xCAT::MsgUtils->message( "I", $rsp, $callback, 0 );
		return 1;
	}
}

#-------------------------------------------------------

=head3  process_request

	Process the command.  This is the main call.

=cut

#-------------------------------------------------------
sub process_request {
	my $request  = shift;
	my $callback = shift;
	my $nodes    = $request->{node};
	my $command  = $request->{command}->[0];
	my $args     = $request->{arg};
	my $envs     = $request->{env};
	my %rsp;
	my $rsp;
	my @nodes = @$nodes;
	my $host  = hostname();

	# Directory where executables are on zHCP
	$::DIR = "/opt/zhcp/bin";

	# Process ID for xfork()
	my $pid;

	# Child process IDs
	my @children;

	#*** Power on or off a node ***
	if ( $command eq "rpower" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				powerVM( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

			# Handle 10 nodes at a time, else you will get errors
			if ( !( @children % 10 ) ) {

				# Wait for all processes to end
				foreach (@children) {
					waitpid( $_, 0 );
				}

				# Clear children
				@children = ();
			}
		}    # End of foreach
	}    # End of case

	#*** Hardware and software inventory ***
	elsif ( $command eq "rinv" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				inventoryVM( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

		}    # End of foreach
	}    # End of case

	#*** Create a virtual server ***
	elsif ( $command eq "mkvm" ) {

		# Determine if the argument is a node
		my $clone = 'FALSE';
		if ( $args->[0] ) {
			$clone = xCAT::zvmUtils->isZvmNode( $args->[0] );
		}

		#*** Clone virtual server ***
		if ( $clone eq 'TRUE' ) {
			cloneVM( $callback, \@nodes, $args );
		}

		#*** Create user entry ***
		# Create node based on directory entry
		# or create a NOLOG if no entry is provided
		else {
			foreach (@nodes) {
				$pid = xCAT::Utils->xfork();

				# Parent process
				if ($pid) {
					push( @children, $pid );
				}

				# Child process
				elsif ( $pid == 0 ) {

					makeVM( $callback, $_, $args );

					# Exit process
					exit(0);
				}    # End of elsif
				else {

					# Ran out of resources
					die "Error: Could not fork\n";
				}
			}    # End of foreach
		}    # End of else
	}    # End of case

	#*** Remove a virtual server ***
	elsif ( $command eq "rmvm" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				removeVM( $callback, $_ );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

			# Handle 10 nodes at a time, else you will get errors
			if ( !( @children % 10 ) ) {

				# Wait for all processes to end
				foreach (@children) {
					waitpid( $_, 0 );
				}

				# Clear children
				@children = ();
			}
		}    # End of foreach
	}    # End of case

	#*** Print the user entry ***
	elsif ( $command eq "lsvm" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				listVM( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

			# Handle 10 nodes at a time, else you will get errors
			if ( !( @children % 10 ) ) {

				# Wait for all processes to end
				foreach (@children) {
					waitpid( $_, 0 );
				}

				# Clear children
				@children = ();
			}
		}    # End of foreach
	}    # End of case

	#*** Change the user entry ***
	elsif ( $command eq "chvm" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				changeVM( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

			# Handle 10 nodes at a time, else you will get errors
			if ( !( @children % 10 ) ) {

				# Wait for all processes to end
				foreach (@children) {
					waitpid( $_, 0 );
				}

				# Clear children
				@children = ();
			}
		}    # End of foreach
	}    # End of case

	#*** Collect node information from zHCP ***
	elsif ( $command eq "rscan" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				scanVM( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

		}    # End of foreach
	}    # End of case

	#*** Set the boot state for a node ***
	elsif ( $command eq "nodeset" ) {
		foreach (@nodes) {

			# Only one file can be punched to reader at a time
			# Forking this process is not possible
			nodeSet( $callback, $_, $args );

		}    # End of foreach
	}    # End of case

	#*** Get the MAC address of a node ***
	elsif ( $command eq "getmacs" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				getMacs( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

		}    # End of foreach
	}    # End of case

	#*** Boot from network ***
	elsif ( $command eq "rnetboot" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				netBoot( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

			# Handle 10 nodes at a time, else you will get errors
			if ( !( @children % 10 ) ) {

				# Wait for all processes to end
				foreach (@children) {
					waitpid( $_, 0 );
				}

				# Clear children
				@children = ();
			}
		}    # End of foreach
	}    # End of case

	#*** Update the node (no longer supported) ***
	elsif ( $command eq "updatenode" ) {
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {
				updateNode( $callback, $_, $args );

				# Exit process
				exit(0);
			}
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

		}    # End of foreach
	}    # End of case

	# Wait for all processes to end
	foreach (@children) {
		waitpid( $_, 0 );
	}

	return;
}

#-------------------------------------------------------

=head3   removeVM

	Description	: Delete the user entry from user directory
    Arguments	: Node to remove
    Returns		: Nothing
    Example		: removeVM($callback, $node);
    
=cut

#-------------------------------------------------------
sub removeVM {

	# Get inputs
	my ( $callback, $node ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get HCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Power off user ID
	my $out = `ssh $hcp "$::DIR/stopvs $userId"`;
	xCAT::zvmUtils->printLn( $callback, "$node: $out" );

	# Delete user entry
	$out = `ssh $hcp "$::DIR/deletevs $userId"`;
	xCAT::zvmUtils->printLn( $callback, "$node: $out" );

	# Check for errors
	my $rc = xCAT::zvmUtils->checkOutput( $callback, $out );
	if ( $rc == -1 ) {
		return;
	}

	# Remove node from 'zvm', 'nodelist', 'nodetype', 'noderes', and 'nodehm' tables
	# Save node entry in 'mac' table
	xCAT::zvmUtils->delTabEntry( 'zvm',      'node', $node );
	xCAT::zvmUtils->delTabEntry( 'nodelist', 'node', $node );
	xCAT::zvmUtils->delTabEntry( 'nodetype', 'node', $node );
	xCAT::zvmUtils->delTabEntry( 'noderes',  'node', $node );
	xCAT::zvmUtils->delTabEntry( 'nodehm',   'node', $node );

	# Remove old hostname from known_hosts
	$out = `ssh-keygen -R $node`;

	return;
}

#-------------------------------------------------------

=head3   changeVM

 	Description	: Change a virtual machine's configuration
 	Arguments	: 	Node
 					Option
 		
 	Options supported:
 		* add3390 [disk pool] [device address] [cylinders] [mode]	[read password] [write password] [multi password]
		* add3390active [device address] [mode]
		* add9336 [disk pool] [virtual device] [block size] [mode] [blocks] [read password] [write password] [multi password]
		* addnic [address] [type] [device count]
		* addprocessor [address]
		* addvdisk [userID] [device address] [size]
		* connectnic2guestlan [address] [lan] [owner]
		* connectnic2vswitch [address] [vswitch]
		* copydisk [target address] [source node] [source address]
		* dedicatedevice [virtual device] [real device] [mode]
		* deleteipl
		* formatdisk [disk address] [multi password]
		* disconnectnic [address]
		* grantvswitch [VSwitch]
		* removedisk [virtual device]
		* removenic [address]
		* removeprocessor [address]
		* replacevs [user directory entry]
		* setipl [ipl target] [load parms] [parms]
		* setpassword [password]
	 	
	Returns		: Nothing
 	Example		: changeVM($callback, $node, $args);
 		
=cut

#-------------------------------------------------------
sub changeVM {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get HCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Output string
	my $out = "";

	# add3390 [disk pool] [device address] [cylinders] [mode] [read password] [write password] [multi password]
	# [read password] [write password] [multi password] are optional
	if ( $args->[0] eq "--add3390" ) {
		my $pool    = $args->[1];
		my $addr    = $args->[2];
		my $cyl     = $args->[3];
		my $mode    = $args->[4];
		my $readPw  = $args->[5];
		my $writePw = $args->[6];
		my $multiPw = $args->[7];

		# Add to directory entry
		$out = `ssh $hcp "$::DIR/add3390 $userId $pool $addr $cyl $mode $readPw $writePw $multiPw"`;
		
		# Add to active configuration
		my $ping = `pping $node`;
		if ($ping =~ m/ping/i) {
			$out .= `ssh $hcp "$::DIR/add3390active $userId $addr $mode"`;
		}		
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# add3390active [device address] [mode]
	elsif ( $args->[0] eq "--add3390active" ) {
		my $addr = $args->[1];
		my $mode = $args->[2];

		$out = `ssh $hcp "$::DIR/add3390active $userId $addr $mode"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# add9336 [disk pool] [virtual device address] [block size] [blocks] [mode] [read password] [write password] [multi password]
	# [read password] [write password] [multi password] are optional
	elsif ( $args->[0] eq "--add9336" ) {
		my $pool    = $args->[1];
		my $addr    = $args->[2];
		my $blksize = $args->[3];
		my $blks    = $args->[4];
		my $mode    = $args->[5];
		my $readPw  = $args->[6];
		my $writePw = $args->[7];
		my $multiPw = $args->[8];

		$out = `ssh $hcp "$::DIR/add9336 $userId $pool $addr $blksize $blks $mode $readPw $writePw $multiPw"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# adddisk2pool [function] [region] [volume] [group]
	elsif ( $args->[0] eq "--adddisk2pool" ) {
		my $funct   = $args->[1];
		my $region  = $args->[2];
		my $volume 	= "";
		my $group   = "";
		
		# Define region as full volume and add to group
		if ($funct eq "4") {
			$volume = $args->[3];
			$group  = $args->[4];
			$out = `ssh $hcp "$::DIR/adddisk2pool $funct $region $volume $group"`;
		}
		
		# Add existing region to group
		elsif($funct eq "5") {
			$group = $args->[3];
			$out = `ssh $hcp "$::DIR/adddisk2pool $funct $region $group"`;
		}
		
		# Exit
		else {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Option not supported" );
			return;
		}
		
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}
	
	# addnic [address] [type] [device count]
	elsif ( $args->[0] eq "--addnic" ) {
		my $addr     = $args->[1];
		my $type     = $args->[2];
		my $devcount = $args->[3];

		# Add to active configuration
		my $ping = `pping $node`;
		if ($ping =~ m/ping/i) {
			$out = `ssh $node "vmcp define nic $addr type $type"`;
		}

		# Add to directory entry
		$out .= `ssh $hcp "$::DIR/addnic $userId $addr $type $devcount"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# addprocessor [type] address]
	elsif ( $args->[0] eq "--addprocessor" ) {
		my $type = $args->[1];
		my $addr = $args->[2];

		$out = `ssh $hcp "$::DIR/addprocessor $userId $type $addr"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# addprocessoractive [address] [type]
	elsif ( $args->[0] eq "--addprocessoractive" ) {
		my $addr = $args->[1];
		my $type = $args->[2];

		$out = xCAT::zvmCPUtils->defineCpu( $node, $addr, $type );
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# addvdisk [device address] [size]
	elsif ( $args->[0] eq "--addvdisk" ) {
		my $addr = $args->[1];
		my $size = $args->[2];

		$out = `ssh $hcp "$::DIR/addvdisk $userId $addr $size"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# connectnic2guestlan [address] [lan] [owner]
	elsif ( $args->[0] eq "--connectnic2guestlan" ) {
		my $addr  = $args->[1];
		my $lan   = $args->[2];
		my $owner = $args->[3];
				
		# Connect to LAN in active configuration
		my $ping = `pping $node`;
		if ($ping =~ m/ping/i) {
			$out = `ssh $node "vmcp couple $addr to $owner $lan"`;
		}
		
		$out .= `ssh $hcp "$::DIR/connectnic2guestlan $userId $addr $lan $owner"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# connectnic2vswitch [address] [vswitch]
	elsif ( $args->[0] eq "--connectnic2vswitch" ) {
		my $addr    = $args->[1];
		my $vswitch = $args->[2];

		# Grant access to VSWITCH for Linux user
		$out = "Granting access to VSWITCH for $userId\n  ";
		$out .= `ssh $hcp "vmcp set vswitch $vswitch grant $userId"`;

		# Connect to VSwitch in active configuration
		my $ping = `pping $node`;
		if ($ping =~ m/ping/i) {
			$out .= `ssh $node "vmcp couple $addr to system $vswitch"`;
		}
		
		# Connect to VSwitch in directory entry
		$out .= `ssh $hcp "$::DIR/connectnic2vswitch $userId $addr $vswitch"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );	
	}

	# copydisk [target address] [source node] [source address]
	elsif ( $args->[0] eq "--copydisk" ) {
		my $tgtNode   = $node;
		my $tgtUserId = $userId;
		my $tgtAddr   = $args->[1];
		my $srcNode   = $args->[2];
		my $srcAddr   = $args->[3];

		# Get source userID
		@propNames = ( 'hcp', 'userid' );
		$propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $srcNode, @propNames );
		my $sourceId = $propVals->{'userid'};

		#*** Link and copy disk ***
		my $rc;
		my $try;
		my $srcDevNode;
		my $tgtDevNode;

		# Link source disk to HCP
		my $srcLinkAddr;
		$try = 5;
		while ( $try > 0 ) {
			# New disk address
			$srcLinkAddr = $srcAddr + 1000;

			# Check if new disk address is used (source)
			$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $srcLinkAddr );

			# If disk address is used (source)
			while ( $rc == 0 ) {

				# Generate a new disk address
				# Sleep 5 seconds to let existing disk appear
				sleep(5);
				$srcLinkAddr = $srcLinkAddr + 1;
				$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $srcLinkAddr );
			}

			# Link source disk
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Linking source disk ($srcAddr) as ($srcLinkAddr)" );
			$out = `ssh -o ConnectTimeout=5 $hcp "vmcp link $sourceId $srcAddr $srcLinkAddr MR"`;

			# If link fails
			if ( $out =~ m/not linked/i ) {

				# Wait before trying again
				sleep(5);

				$try = $try - 1;
			} else {
				last;
			}
		}    # End of while ( $try > 0 )

		# Link target disk to HCP
		my $tgtLinkAddr;
		$try = 5;
		while ( $try > 0 ) {

			# New disk address
			$tgtLinkAddr = $tgtAddr + 2000;

			# Check if new disk address is used (target)
			$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $tgtLinkAddr );

			# If disk address is used (target)
			while ( $rc == 0 ) {

				# Generate a new disk address
				# Sleep 5 seconds to let existing disk appear
				sleep(5);
				$tgtLinkAddr = $tgtLinkAddr + 1;
				$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $tgtLinkAddr );
			}

			# Link target disk
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Linking target disk ($tgtAddr) as ($tgtLinkAddr)" );
			$out = `ssh -o ConnectTimeout=5 $hcp "vmcp link $tgtUserId $tgtAddr $tgtLinkAddr MR"`;

			# If link fails
			if ( $out =~ m/not linked/i ) {

				# Wait before trying again
				sleep(5);

				$try = $try - 1;
			} else {
				last;
			}
		}    # End of while ( $try > 0 )

		# If target disk is not linked
		if ( $out =~ m/not linked/i ) {
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Failed to link target disk ($tgtAddr)" );
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Failed" );

			# Exit
			return;
		}

		# If source disk is not linked
		if ( $out =~ m/not linked/i ) {
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Failed to link source disk ($srcAddr)" );
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Failed" );

			# Exit
			return;
		}

		#*** Use flashcopy ***
		# Flashcopy only supports ECKD volumes
		my $ddCopy = 0;
		$out = `ssh $hcp "vmcp flashcopy"`;
		if ( $out =~ m/HCPNFC026E/i ) {

			# Flashcopy is supported
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Copying source disk ($srcLinkAddr) to target disk ($tgtLinkAddr) using FLASHCOPY" );

			# Check for flashcopy lock
			my $wait = 0;
			while ( `ssh $hcp "ls /tmp/.flashcopy_lock"` && $wait < 90 ) {

				# Wait until the lock dissappears
				# 90 seconds wait limit
				sleep(2);
				$wait = $wait + 2;
			}

			# If flashcopy locks still exists
			if (`ssh $hcp "ls /tmp/.flashcopy_lock"`) {

				# Detatch disks from HCP
				$out = `ssh $hcp "vmcp det $tgtLinkAddr"`;
				$out = `ssh $hcp "vmcp det $srcLinkAddr"`;

				xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Flashcopy lock is enabled" );
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Solution) Remove lock by deleting /tmp/.flashcopy_lock on the zHCP. Use caution!" );
				return;
			} else {

				# Enable lock
				$out = `ssh $hcp "touch /tmp/.flashcopy_lock"`;

				# Flashcopy source disk
				$out = xCAT::zvmCPUtils->flashCopy( $hcp, $srcLinkAddr, $tgtLinkAddr );
				$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
				if ( $rc == -1 ) {
					xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );

					# Detatch disks from HCP
					$out = `ssh $hcp "vmcp det $tgtAddr"`;
					$out = `ssh $hcp "vmcp det $srcLinkAddr"`;

					# Remove lock
					$out = `ssh $hcp "rm -f /tmp/.flashcopy_lock"`;
					return;
				}

				# Remove lock
				$out = `ssh $hcp "rm -f /tmp/.flashcopy_lock"`;
			}
		} else {
			$ddCopy = 1;	
		}

		# Flashcopy not supported, use Linux dd
		if ($ddCopy) {
			#*** Use Linux dd to copy ***
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: FLASHCOPY not working.  Using Linux DD" );

			# Enable disks
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", $tgtLinkAddr );
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", $srcLinkAddr );

			# Determine source device node
			$srcDevNode = xCAT::zvmUtils->getDeviceNode($hcp, $srcLinkAddr);

			# Determine target device node
			$tgtDevNode = xCAT::zvmUtils->getDeviceNode($hcp, $tgtLinkAddr);

			# Format target disk
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Formating target disk ($tgtDevNode)" );
			$out = `ssh $hcp "dasdfmt -b 4096 -y -f /dev/$tgtDevNode"`;

			# Check for errors
			$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
			if ( $rc == -1 ) {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );
				return;
			}

			# Sleep 2 seconds to let the system settle
			sleep(2);

			# Copy source disk to target disk (4096 block size)
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Copying source disk ($srcDevNode) to target disk ($tgtDevNode)" );
			$out = `ssh $hcp "dd if=/dev/$srcDevNode of=/dev/$tgtDevNode bs=4096"`;

			# Disable disks
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-d", $tgtLinkAddr );
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-d", $srcLinkAddr );

			# Check for error
			$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
			if ( $rc == -1 ) {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );

				# Detatch disks from HCP
				$out = `ssh $hcp "vmcp det $tgtLinkAddr"`;
				$out = `ssh $hcp "vmcp det $srcLinkAddr"`;

				return;
			}

			# Sleep 2 seconds to let the system settle
			sleep(2);
		}

		# Detatch disks from HCP
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: Detatching target disk ($tgtLinkAddr)" );
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: Detatching source disk ($srcLinkAddr)" );
		$out = `ssh $hcp "vmcp det $tgtLinkAddr"`;
		$out = `ssh $hcp "vmcp det $srcLinkAddr"`;

		$out = "$tgtNode: Done";
	}

	# dedicatedevice [virtual device] [real device] [mode]
	elsif ( $args->[0] eq "--dedicatedevice" ) {
		my $vaddr = $args->[1];
		my $raddr = $args->[2];
		my $mode  = $args->[3];

		$out = `ssh $hcp "$::DIR/dedicatedevice $userId $vaddr $raddr $mode"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# deleteipl
	elsif ( $args->[0] eq "--deleteipl" ) {
		$out = `ssh $hcp "$::DIR/deleteipl $userId"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# formatdisk [address] [multi password]
	elsif ( $args->[0] eq "--formatdisk" ) {
		my $tgtNode   = $node;
		my $tgtUserId = $userId;
		my $tgtAddr   = $args->[1];

		#*** Link and format disk ***
		my $rc;
		my $try;
		my $tgtDevNode;

		# Link target disk to zHCP
		my $tgtLinkAddr;
		$try = 5;
		while ( $try > 0 ) {

			# New disk address
			$tgtLinkAddr = $tgtAddr + 1000;

			# Check if new disk address is used (target)
			$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $tgtLinkAddr );

			# If disk address is used (target)
			while ( $rc == 0 ) {

				# Generate a new disk address
				# Sleep 5 seconds to let existing disk appear
				sleep(5);
				$tgtLinkAddr = $tgtLinkAddr + 1;
				$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $tgtLinkAddr );
			}

			# Link target disk
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Linking target disk ($tgtAddr) as ($tgtLinkAddr)" );
			$out = `ssh -o ConnectTimeout=5 $hcp "vmcp link $tgtUserId $tgtAddr $tgtLinkAddr MR"`;

			# If link fails
			if ( $out =~ m/not linked/i ) {

				# Wait before trying again
				sleep(5);

				$try = $try - 1;
			}
			else {
				last;
			}
		}    # End of while ( $try > 0 )

		# If target disk is not linked
		if ( $out =~ m/not linked/i ) {
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Failed to link target disk ($tgtAddr)" );
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Failed" );

			# Exit
			return;
		}

		#*** Format disk ***
		my @words;
		if ( $rc == -1 ) {

			# Enable disk
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", $tgtLinkAddr );

			# Determine target device node
			$tgtDevNode = xCAT::zvmUtils->getDeviceNode($hcp, $tgtLinkAddr);

			# Format target disk
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Formating target disk ($tgtDevNode)" );
			$out = `ssh $hcp "dasdfmt -b 4096 -y -f /dev/$tgtDevNode"`;

			# Check for errors
			$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
			if ( $rc == -1 ) {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );
				return;
			}

			# Sleep 2 seconds to let the system settle
			sleep(2);
		}

		# Disable disk
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-d", $tgtLinkAddr );

		# Detatch disk from HCP
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: Detatching target disk ($tgtLinkAddr)" );
		$out = `ssh $hcp "vmcp det $tgtLinkAddr"`;

		$out = "$tgtNode: Done";
	}

	# grantvswitch [VSwitch]
	elsif ( $args->[0] eq "--grantvswitch" ) {
		my $vsw = $args->[1];

		$out = xCAT::zvmCPUtils->grantVSwitch( $callback, $hcp, $userId, $vsw );
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# disconnectnic [address]
	elsif ( $args->[0] eq "--disconnectnic" ) {
		my $addr = $args->[1];

		$out = `ssh $hcp "$::DIR/disconnectnic $userId $addr"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# removediskfrompool [function] [region] [group]
	elsif ( $args->[0] eq "--removediskfrompool" ) {
		my $funct  = $args->[1];
		my $region = $args->[2];
		my $group  = "";

		# Remove region from group | Remove entire group		
		if ($funct eq "2" || $funct eq "7") {
			$group  = $args->[3];
			$out = `ssh $hcp "$::DIR/removediskfrompool $funct $region $group"`;
		} 
		
		# Remove region | Remove region from all groups
		elsif ($funct eq "1" || $funct eq "3") {
			$out = `ssh $hcp "$::DIR/removediskfrompool $funct $region"`;
		}
		
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}
	
	# removedisk [virtual device address]
	elsif ( $args->[0] eq "--removedisk" ) {
		my $addr = $args->[1];

		$out = `ssh $hcp "$::DIR/removemdisk $userId $addr"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# removenic [address]
	elsif ( $args->[0] eq "--removenic" ) {
		my $addr = $args->[1];

		$out = `ssh $hcp "$::DIR/removenic $userId $addr"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# removeprocessor [address]
	elsif ( $args->[0] eq "--removeprocessor" ) {
		my $addr = $args->[1];

		$out = `ssh $hcp "$::DIR/removeprocessor $userId $addr"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# replacevs [file]
	elsif ( $args->[0] eq "--replacevs" ) {
		my $file = $args->[1];

		# Target system (HCP), e.g. root@gpok2.endicott.ibm.com
		my $target = "root@";
		$target .= $hcp;
		if ($file) {

			# SCP file over to zHCP
			$out = `scp $file $target:$file`;

			# Replace user directory entry
			$out = `ssh $hcp "$::DIR/replacevs $userId $file"`;
			$out = xCAT::zvmUtils->appendHostname( $node, $out );
		}
		else {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) No directory entry file specified" );
			xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Specify a text file containing the updated directory entry" );
			return;
		}
	}

	# resetsmapi
	elsif ( $args->[0] eq "--resetsmapi" ) {
		# Assuming zVM 6.1 or older	
		# Force each worker machine off
		my @workers = ('VSMWORK1', 'VSMWORK2', 'VSMWORK3', 'VSMREQIN', 'VSMREQIU');
		foreach ( @workers ) {
			$out = `ssh $hcp "vmcp force $_ logoff immediate"`;
		}
				
		# Log on VSMWORK1
		$out = `ssh $hcp "vmcp xautolog VSMWORK1"`;
		
		$out = "$node: Resetting SMAPI... Done";
	}
	
	# setipl [ipl target] [load parms] [parms]
	elsif ( $args->[0] eq "--setipl" ) {
		my $trgt      = $args->[1];
		my $loadparms = $args->[2];
		my $parms     = $args->[3];

		$out = `ssh $hcp "$::DIR/setipl $userId $trgt $loadparms $parms"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# setpassword [password]
	elsif ( $args->[0] eq "--setpassword" ) {
		my $pw = $args->[1];

		$out = `ssh $hcp "$::DIR/setpassword $userId $pw"`;
		$out = xCAT::zvmUtils->appendHostname( $node, $out );
	}

	# Otherwise, print out error
	else {
		$out = "$node: (Error) Option not supported";
	}

	xCAT::zvmUtils->printLn( $callback, "$out" );
	return;
}

#-------------------------------------------------------

=head3   powerVM

	Description	: Power on or off a given node
    Arguments	: 	Node 
    				Option [on|off|reset|stat]
    Returns		: Nothing
    Example		: powerVM($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub powerVM {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get HCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;
	
	# Output string
	my $out;

	# Power on virtual server
	if ( $args->[0] eq 'on' ) {
		$out = `ssh $hcp "$::DIR/startvs $userId"`;
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );
	}

	# Power off virtual server
	elsif ( $args->[0] eq 'off' ) {
		$out = `ssh $hcp "$::DIR/stopvs $userId"`;
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );
	}
	
	# Power off virtual server (gracefully)
	elsif ( $args->[0] eq 'softoff' ) {
		$out = `ssh -o ConnectTimeout=10 $node "shutdown -h now"`;
		sleep(90);	# Wait 1.5 minutes before logging user off
		
		$out = `ssh $hcp "$::DIR/stopvs $userId"`;
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );
	}

	# Get the status (on|off)
	elsif ( $args->[0] eq 'stat' ) {
		$out = `ssh $hcp "vmcp q user $userId 2>/dev/null" | sed 's/HCPCQU045E.*/off/' | sed 's/$userId.*/on/'`;

		# Wait for output
		my $max = 0;
		while ( !$out && $max < 10 ) {
			$out = `ssh $hcp "vmcp q user $userId 2>/dev/null" | sed 's/HCPCQU045E.*/off/' | sed 's/$userId.*/on/'`;
			$max++;
		}

		xCAT::zvmUtils->printLn( $callback, "$node: $out" );
	}

	# Reset a virtual server
	elsif ( $args->[0] eq 'reset' ) {

		$out = `ssh $hcp "$::DIR/stopvs $userId"`;
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );

		# Wait for output
		while ( `vmcp q user $userId 2>/dev/null | sed 's/HCPCQU045E.*/Done/'` != "Done" ) {
			# Do nothing
		}

		$out = `ssh $hcp "$::DIR/startvs $userId"`;
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );
	}
	else {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Option not supported" );
	}
	return;
}

#-------------------------------------------------------

=head3   scanVM

	Description	: Get node information from zHCP
    Arguments	: zHCP
    Returns		: Nothing
    Example		: scanVM($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub scanVM {

	# Get inputs
	my ( $callback, $node, $args ) = @_;
	my $write2db = '';
	if ($args) {
		@ARGV = @$args;
		
		# Parse options
		GetOptions(	'w' => \$write2db );
	}
	
	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;
	
	# Exit if node is not a HCP
	if ( !( $hcp =~ m/$node/i ) ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) $node is not a hardware control point" );
		return;
	}

	# Print output string
	# [Node name]:
	#	objtype=node
	#   id=[userID]
	#   arch=[Architecture]
	#   hcp=[HCP node name]
	#   groups=[Group]
	#   mgt=zvm
	#
	# gpok123:
	#	objtype=node
	#   id=LINUX123
	#   arch=s390x
	#   hcp=gpok456.endicott.ibm.com
	#   groups=all
	#   mgt=zvm

	# Output string
	my $str = "";

	# Get nodes managed by this zHCP
	# Look in 'zvm' table
	my $tab = xCAT::Table->new( 'zvm', -create => 1, -autocommit => 0 );
	my @entries = $tab->getAllAttribsWhere( "hcp like '%" . $hcp . "%'", 'node', 'userid' );

	my $out;
	my $node;
	my $id;
	my $os;
	my $arch;
	my $groups;
	
	# Get node hierarchy from /proc/sysinfo
	my $hierarchy;
	my $host = xCAT::zvmCPUtils->getHost($hcp);
	my $sysinfo = `ssh -o ConnectTimeout=5 $hcp "cat /proc/sysinfo"`;

	# Get node CEC
	my $cec = `echo "$sysinfo" | grep "Sequence Code"`;
	my @args = split( ':', $cec );
	# Remove leading spaces and zeros
	$args[1] =~ s/^\s*0*//;
	$cec = xCAT::zvmUtils->trimStr($args[1]);
	
	# Get node LPAR
	my $lpar = `echo "$sysinfo" | grep "LPAR Name"`;
	@args = split( ':', $lpar );
	$lpar = xCAT::zvmUtils->trimStr($args[1]);
	
	# Save CEC, LPAR, and zVM to 'zvm' table
	my %propHash;
	if ($write2db) {
		# Save CEC to 'zvm' table
		%propHash = (
			'nodetype'	=> 	'cec',
			'parent'	=> 	''
		);
		xCAT::zvmUtils->setNodeProps( 'zvm', $cec, \%propHash );
	
		# Save LPAR to 'zvm' table
		%propHash = (
			'nodetype'	=> 	'lpar',
			'parent'	=> 	$cec
		);
		xCAT::zvmUtils->setNodeProps( 'zvm', $lpar, \%propHash );
		
		# Save zVM to 'zvm' table
		%propHash = (
			'nodetype'	=> 	'zvm',
			'parent'	=> 	$lpar
		);
		xCAT::zvmUtils->setNodeProps( 'zvm', $host, \%propHash );
	}
		
	# Search for nodes managed by given zHCP
	# Get 'node' and 'userid' properties
	%propHash = ();
	foreach (@entries) {
		$node = $_->{'node'};

		# Get groups
		@propNames = ('groups');
		$propVals  = xCAT::zvmUtils->getNodeProps( 'nodelist', $node, @propNames );
		$groups    = $propVals->{'groups'};

		# Load VMCP module
		xCAT::zvmCPUtils->loadVmcp($node);

		# Get user ID
		@propNames = ('userid');
		$propVals  = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );
		$id = $propVals->{'userid'};
		if (!$id) {
			$id = xCAT::zvmCPUtils->getUserId($node);
		}		

		# Get architecture
		$arch = `ssh -o ConnectTimeout=2 $node "uname -p"`;
		$arch = xCAT::zvmUtils->trimStr($arch);
		if (!$arch) {
			# Assume arch is s390x
			$arch = 's390x';
		}
		
		# Get OS
		$os = xCAT::zvmUtils->getOsVersion($node);
		
		# Save node attributes
		if ($write2db) {
			# Save to 'zvm' table
			%propHash = (
				'hcp' 		=> 	$hcp,
				'userid'	=>	$id,
				'nodetype'	=> 	'vm',
				'parent'	=> 	$host
			);						
			xCAT::zvmUtils->setNodeProps( 'zvm', $node, \%propHash );
			
			# Save to 'nodetype' table
			%propHash = (
				'arch' 	=> 	$arch,
				'os'	=>	$os
			);						
			xCAT::zvmUtils->setNodeProps( 'nodetype', $node, \%propHash );
		}
		
		# Create output string
		$str .= "$node:\n";
		$str .= "  objtype=node\n";
		$str .= "  arch=$arch\n";
		$str .= "  os=$os\n";
		$str .= "  hcp=$hcp\n";
		$str .= "  userid=$id\n";
		$str .= "  nodetype=vm\n";
		$str .= "  parent=$host\n";
		$str .= "  groups=$groups\n";
		$str .= "  mgt=zvm\n\n";
	}

	xCAT::zvmUtils->printLn( $callback, "$str" );
	return;
}

#-------------------------------------------------------

=head3   inventoryVM

	Description	: Get hardware and software inventory of a given node
    Arguments	: 	Node 
    				Type of inventory (config|all)
    Returns		: Nothing
    Example		: inventoryVM($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub inventoryVM {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Output string
	my $str = "";

	# Load VMCP module
	xCAT::zvmCPUtils->loadVmcp($node);

	# Get configuration
	if ( $args->[0] eq 'config' ) {

		# Get z/VM host for specified node
		my $host = xCAT::zvmCPUtils->getHost($node);

		# Get architecture
		my $arch = xCAT::zvmUtils->getArch($node);

		# Get operating system
		my $os = xCAT::zvmUtils->getOs($node);

		# Get privileges
		my $priv = xCAT::zvmCPUtils->getPrivileges($node);

		# Get memory configuration
		my $memory = xCAT::zvmCPUtils->getMemory($node);

		# Get processors configuration
		my $proc = xCAT::zvmCPUtils->getCpu($node);

		$str .= "z/VM UserID: $userId\n";
		$str .= "z/VM Host: $host\n";
		$str .= "Operating System: $os\n";
		$str .= "Architecture:	$arch\n";
		$str .= "HCP: $hcp\n";
		$str .= "Privileges: \n$priv\n";
		$str .= "Total Memory:	$memory\n";
		$str .= "Processors: \n$proc\n";
	}
	elsif ( $args->[0] eq 'all' ) {

		# Get z/VM host for specified node
		my $host = xCAT::zvmCPUtils->getHost($node);

		# Get architecture
		my $arch = xCAT::zvmUtils->getArch($node);

		# Get operating system
		my $os = xCAT::zvmUtils->getOs($node);

		# Get privileges
		my $priv = xCAT::zvmCPUtils->getPrivileges($node);

		# Get memory configuration
		my $memory = xCAT::zvmCPUtils->getMemory($node);

		# Get processors configuration
		my $proc = xCAT::zvmCPUtils->getCpu($node);

		# Get disks configuration
		my $storage = xCAT::zvmCPUtils->getDisks($node);

		# Get NICs configuration
		my $nic = xCAT::zvmCPUtils->getNic($node);

		# Create output string
		$str .= "z/VM UserID: $userId\n";
		$str .= "z/VM Host: $host\n";
		$str .= "Operating System: $os\n";
		$str .= "Architecture:	$arch\n";
		$str .= "HCP: $hcp\n";
		$str .= "Privileges: \n$priv\n";
		$str .= "Total Memory:	$memory\n";
		$str .= "Processors: \n$proc\n";
		$str .= "Disks: \n$storage\n";
		$str .= "NICs:	\n$nic\n";
	}
	else {
		$str = "$node: (Error) Option not supported";
		xCAT::zvmUtils->printLn( $callback, "$str" );
		return;
	}

	# Append hostname (e.g. gpok3) in front
	$str = xCAT::zvmUtils->appendHostname( $node, $str );

	xCAT::zvmUtils->printLn( $callback, "$str" );
	return;
}

#-------------------------------------------------------

=head3   listVM

	Description	: Show the info for a given node
    Arguments	: 	Node
 					Option
 	
 	Options supported:
 		* getnetworknames
 		* getnetwork [networkname]
 		* diskpoolnames
 		* diskpool [pool name] [space (free or used)]
		
    Returns		: Nothing
    Example		: listVM($callback, $node);
    
=cut

#-------------------------------------------------------
sub listVM {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Set cache directory
	my $cache = '/var/opt/zhcp/cache';

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	my $out;

	# Get disk pool names
	if ( $args->[0] eq "--diskpoolnames" ) {
		# If the cache directory does not exist
		if (!(`ssh $hcp "test -d $cache && echo Exists"`)) {
			# Create cache directory
			$out = `ssh $hcp "mkdir -p $cache"`;
		}
		
		my $file = "$cache/diskpoolnames";
		
		# If a cache for disk pool names exists
		if (`ssh $hcp "ls $file"`) {
			# Get current Epoch
			my $curTime = time();
			# Get time of last change as seconds since Epoch
			my $fileTime = xCAT::zvmUtils->trimStr(`ssh $hcp "stat -c %Z $file"`);
			
			# If the current time is greater than 5 minutes of the file timestamp
			my $interval = 300;		# 300 seconds = 5 minutes * 60 seconds/minute
			if ($curTime > $fileTime + $interval) {
				# Get disk pool names and save it in a file
				$out = `ssh $hcp "$::DIR/getdiskpoolnames $userId > $file"`;
			}
		} else {
			# Get disk pool names and save it in a file
			$out = `ssh $hcp "$::DIR/getdiskpoolnames $userId > $file"`;
		}
		
		# Print out the file contents
		$out = `ssh $hcp "cat $file"`;
	}

	# Get disk pool configuration
	elsif ( $args->[0] eq "--diskpool" ) {
		my $pool  = $args->[1];
		my $space = $args->[2];

		$out = `ssh $hcp "$::DIR/getdiskpool $userId $pool $space"`;
	}

	# Get network names
	elsif ( $args->[0] eq "--getnetworknames" ) {
		$out = xCAT::zvmCPUtils->getNetworkNames($hcp);
	}

	# Get network
	elsif ( $args->[0] eq "--getnetwork" ) {
		my $netName = $args->[1];

		$out = xCAT::zvmCPUtils->getNetwork( $hcp, $netName );
	}

	# Get user entry
	elsif ( !$args->[0] ) {
		$out = `ssh $hcp "$::DIR/getuserentry $userId"`;
	}

	else {
		$out = "$node: (Error) Option not supported";
	}

	# Append hostname (e.g. gpok3) in front
	$out = xCAT::zvmUtils->appendHostname( $node, $out );
	xCAT::zvmUtils->printLn( $callback, "$out" );

	return;
}

#-------------------------------------------------------

=head3   makeVM

	Description	: Create a virtual machine 
				  	* A unique MAC address will be assigned
    Arguments	: 	Node
    				Directory entry text file (optional)
    Returns		: Nothing
    Example		: makeVM($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub makeVM {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get HCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Get user entry file (if any)
	my $userEntry = $args->[0];

	# Create virtual server
	my $out;
	my @lines;
	my @words;
	my $target = "root@" . $hcp;
	if ($userEntry) {
		
		# Copy user entry
		$out = `cp $userEntry /tmp/$node.txt`;
		$userEntry = "/tmp/$node.txt";

		# Get MAC address in 'mac' table
		my $macId;
		my $generateNew = 1;
		@propNames = ('mac');
		$propVals = xCAT::zvmUtils->getNodeProps( 'mac', $node, @propNames );
		
		# If MAC address exists
		if ( $propVals->{'mac'} ) {

			# Get MAC suffix (MACID)
			$macId = $propVals->{'mac'};
			$macId = xCAT::zvmUtils->replaceStr( $macId, ":", "" );
			$macId = substr( $macId, 6 );
		} else {
				
			# Get zHCP MAC address
			# The MAC address prefix is the same for all network devices
			xCAT::zvmCPUtils->loadVmcp($hcp);
			$out   = `ssh -o ConnectTimeout=5 $hcp "vmcp q v nic" | grep "MAC:"`;
			if ($out) {
				@lines = split( "\n", $out );
				@words = split( " ", $lines[0] );

				# Extract MAC prefix
				my $prefix = $words[1];
				$prefix = xCAT::zvmUtils->replaceStr( $prefix, "-", "" );
				$prefix = substr( $prefix, 0, 6 );

				# Generate MAC address
				my $mac;
				while ($generateNew) {
					
					# If no MACID is found, get one
					$macId = xCAT::zvmUtils->getMacID($hcp);
					if ( !$macId ) {
						xCAT::zvmUtils->printLn( $callback, "$node: (Error) Could not generate MACID" );
						return;
					}

					# Create MAC address
					$mac = $prefix . $macId;
						
					# If length is less than 12, append a zero
					if ( length($mac) != 12 ) {
						$mac = "0" . $mac;
					}
		
					# Format MAC address
					$mac =
					    substr( $mac, 0, 2 ) . ":"
					  . substr( $mac, 2,  2 ) . ":"
					  . substr( $mac, 4,  2 ) . ":"
					  . substr( $mac, 6,  2 ) . ":"
					  . substr( $mac, 8,  2 ) . ":"
					  . substr( $mac, 10, 2 );
					
					# Check 'mac' table for MAC address
					my $tab = xCAT::Table->new( 'mac', -create => 1, -autocommit => 0 );
					my @entries = $tab->getAllAttribsWhere( "mac = '" . $mac . "'", 'node' );
					
					# If MAC address exists
					if (@entries) {
						# Generate new MACID
						$out = xCAT::zvmUtils->generateMacId($hcp);
						$generateNew = 1;
					} else {
						$generateNew = 0;
						
						# Save MAC address in 'mac' table
						xCAT::zvmUtils->setNodeProp( 'mac', $node, 'mac', $mac );
					}
				} # End of while ($generateNew)
				
				# Generate new MACID
				$out = xCAT::zvmUtils->generateMacId($hcp);
			} else {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) Could not find the MAC address of the zHCP" );
				xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Verify that the node's zHCP($hcp) is correct, the node is online, and the SSH keys are setup for the zHCP" );
			}
		}

		# If the directory entry contains a NICDEF statement, append MACID to the end
		# User must select the right one (layer) based on template chosen
		my $line;
		$out = `cat $userEntry | egrep -i "NICDEF"`;
		if ($out) {

			# Get the networks used by the zHCP
			my @hcpNets = xCAT::zvmCPUtils->getNetworkNamesArray($hcp);
			
			# Search user entry for network name
			my $netName = '';
			foreach (@hcpNets) {
				if ( $out =~ m/ $_/i ) {
					$netName = $_;
					last;
				}
			}
			
			# Find NICDEF statement
			my $oldNicDef = `cat $userEntry | egrep -i "NICDEF" | egrep -i "$netName"`;
			if ($oldNicDef) {
				$oldNicDef = xCAT::zvmUtils->trimStr($oldNicDef);
				my $nicDef = xCAT::zvmUtils->replaceStr( $oldNicDef, $netName, "$netName MACID $macId" );

				# Append MACID at the end
				$out = `sed --in-place -e "s,$oldNicDef,$nicDef,i" $userEntry`;
			}
		}
		
		# Open user entry
		$out = `cat $userEntry`;
		@lines = split( '\n', $out );
		
		# Get the userID in user entry
		$line = xCAT::zvmUtils->trimStr( $lines[0] );
		@words = split( ' ', $line );
		my $id = $words[1];
		
		# Change userID in user entry to match userID defined in xCAT
		$out = `sed --in-place -e "s,$id,$userId,i" $userEntry`;

		# SCP file over to zHCP
		$out = `scp $userEntry $target:$userEntry`;
		
		# Remove user entry
		$out = `rm $userEntry`;

		# Create virtual server
		$out = `ssh $hcp "$::DIR/createvs $userId $userEntry"`;
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );

		# Check output
		my $rc = xCAT::zvmUtils->checkOutput( $callback, $out );
		if ( $rc == 0 ) {

			# Get VSwitch of zHCP (if any)
			my @vswId = xCAT::zvmCPUtils->getVswitchId($hcp);

			# Grant access to VSwitch for Linux user
			# GuestLan do not need permissions
			foreach (@vswId) {
				xCAT::zvmUtils->printLn( $callback, "$node: Granting VSwitch ($_) access for $userId" );
				$out = xCAT::zvmCPUtils->grantVSwitch( $callback, $hcp, $userId, $_ );
				xCAT::zvmUtils->printLn( $callback, "$node: $out" );
			}

			# Remove user entry file (on zHCP)
			$out = `ssh -o ConnectTimeout=5 $hcp "rm $userEntry"`;
		}
	}
	else {

		# Create NOLOG virtual server
		$out = `ssh $hcp "$::DIR/createvs $userId"`;
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );
	}

	return;
}

#-------------------------------------------------------

=head3   cloneVM

	Description	: Clone a virtual server
    Arguments	: 	Node 
    				Disk pool
    				Disk password
    Returns		: Nothing
    Example		: cloneVM($callback, $targetNode, $args);
    
=cut

#-------------------------------------------------------
sub cloneVM {

	# Get inputs
	my ( $callback, $nodes, $args ) = @_;

	# Get nodes
	my @nodes = @$nodes;

	# Return code for each command
	my $rc;
	my $out;

	# Child process IDs
	my @children;

	# Process ID for xfork()
	my $pid;

	# Get source node
	my $sourceNode = $args->[0];
	my @propNames  = ( 'hcp', 'userid' );
	my $propVals   = xCAT::zvmUtils->getNodeProps( 'zvm', $sourceNode, @propNames );

	# Get zHCP
	my $srcHcp = $propVals->{'hcp'};

	# Get node user ID
	my $sourceId = $propVals->{'userid'};
	# Capitalize user ID
	$sourceId =~ tr/a-z/A-Z/;

	foreach (@nodes) {
		xCAT::zvmUtils->printLn( $callback, "$_: Cloning $sourceNode" );

		# Exit if missing source node
		if ( !$sourceNode ) {
			xCAT::zvmUtils->printLn( $callback, "$_: (Error) Missing source node" );
			return;
		}

		# Exit if missing source HCP
		if ( !$srcHcp ) {
			xCAT::zvmUtils->printLn( $callback, "$_: (Error) Missing source node HCP" );
			return;
		}

		# Exit if missing source user ID
		if ( !$sourceId ) {
			xCAT::zvmUtils->printLn( $callback, "$_: (Error) Missing source user ID" );
			return;
		}

		# Get target node
		@propNames = ( 'hcp', 'userid' );
		$propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $_, @propNames );

		# Get target HCP
		my $tgtHcp = $propVals->{'hcp'};

		# Get node userID
		my $tgtId = $propVals->{'userid'};
		# Capitalize userID
		$tgtId =~ tr/a-z/A-Z/;

		# Exit if missing target zHCP
		if ( !$tgtHcp ) {
			xCAT::zvmUtils->printLn( $callback, "$_: (Error) Missing target node HCP" );
			return;
		}

		# Exit if missing target user ID
		if ( !$tgtId ) {
			xCAT::zvmUtils->printLn( $callback, "$_: (Error) Missing target user ID" );
			return;
		}

		# Exit if source and target zHCP are not equal
		if ( $srcHcp ne $tgtHcp ) {
			xCAT::zvmUtils->printLn( $callback, "$_: (Error) Source and target HCP are not equal" );
			xCAT::zvmUtils->printLn( $callback, "$_: (Solution) Set the source and target HCP appropriately in the zvm table" );
			return;
		}

		#*** Get MAC address ***
		my $targetMac;
		my $macId;
		my $generateNew = 0;    # Flag to generate new MACID
		@propNames = ('mac');
		$propVals = xCAT::zvmUtils->getNodeProps( 'mac', $_, @propNames );
		if ( !$propVals->{'mac'} ) {

			# If no MACID is found, get one
			$macId = xCAT::zvmUtils->getMacID($tgtHcp);
			if ( !$macId ) {
				xCAT::zvmUtils->printLn( $callback, "$_: (Error) Could not generate MACID" );
				return;
			}

			# Create MAC address (target)
			$targetMac = xCAT::zvmUtils->createMacAddr( $_, $macId );

			# Save MAC address in 'mac' table
			xCAT::zvmUtils->setNodeProp( 'mac', $_, 'mac', $targetMac );

			# Generate new MACID
			$out = xCAT::zvmUtils->generateMacId($tgtHcp);
		}
	}

	#*** Link source disks ***
	# Get MDisk statements of source node
	my @words;
	my $addr;
	my $type;
	my $srcMultiPw;
	my $linkAddr;

	# Load vmcp module
	xCAT::zvmCPUtils->loadVmcp($sourceNode);

	# Hash table of source disk addresses
	# $srcLinkAddr[$addr] = $linkAddr
	my %srcLinkAddr;
	my %srcDiskSize;

	# Hash table of source disk type
	# $srcLinkAddr[$addr] = $type
	my %srcDiskType;

	my @srcDisks = xCAT::zvmUtils->getMdisks( $callback, $sourceNode );
	foreach (@srcDisks) {

		# Get disk address
		@words      = split( ' ', $_ );
		$addr       = $words[1];
		$type       = $words[2];
		$srcMultiPw = $words[9];

		# Add 0 in front if address length is less than 4
		while (length($addr) < 4) {
			$addr = '0' . $addr;
		}
		
		# Get disk type
		$srcDiskType{$addr} = $type;

		# Get disk size (cylinders or blocks)
		# ECKD or FBA disk
		if ( $type eq '3390' || $type eq '9336' ) {
			$out                = `ssh -o ConnectTimeout=5 $sourceNode "vmcp q v dasd" | grep "DASD $addr"`;
			@words              = split( ' ', $out );
			$srcDiskSize{$addr} = xCAT::zvmUtils->trimStr( $words[5] );
		}

		# If source disk is not linked
		my $try = 5;
		while ( $try > 0 ) {

			# New disk address
			$linkAddr = $addr + 1000;

			# Check if new disk address is used (source)
			$rc = xCAT::zvmUtils->isAddressUsed( $srcHcp, $linkAddr );

			# If disk address is used (source)
			while ( $rc == 0 ) {

				# Generate a new disk address
				# Sleep 5 seconds to let existing disk appear
				sleep(5);
				$linkAddr = $linkAddr + 1;
				$rc = xCAT::zvmUtils->isAddressUsed( $srcHcp, $linkAddr );
			}

			$srcLinkAddr{$addr} = $linkAddr;

			# Link source disk to HCP
			foreach (@nodes) {
				xCAT::zvmUtils->printLn( $callback, "$_: Linking source disk ($addr) as ($linkAddr)" );
			}
			$out = `ssh -o ConnectTimeout=5 $srcHcp "vmcp link $sourceId $addr $linkAddr RR $srcMultiPw"`;

			if ( $out =~ m/not linked/i ) {
				# Do nothing
			} else {
				last;
			}

			$try = $try - 1;

			# Wait before next try
			sleep(5);
		}    # End of while ( $try > 0 )

		# If source disk is not linked
		if ( $out =~ m/not linked/i ) {
			foreach (@nodes) {
				xCAT::zvmUtils->printLn( $callback, "$_: Failed" );
			}

			# Exit
			return;
		}

		# Enable source disk
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $srcHcp, "-e", $linkAddr );

	}    # End of foreach (@srcDisks)

	# Get the networks the HCP is on
	my @hcpNets = xCAT::zvmCPUtils->getNetworkNamesArray($srcHcp);
	
	# Get the NICDEF address of the network on the source node
	my @tmp;
	my $i;
	my $hcpNicAddr = '';
	my $hcpNetName = '';

	# Find the NIC address
	xCAT::zvmCPUtils->loadVmcp($sourceNode);
	$out = `ssh $sourceNode "vmcp q v nic"`;
	my @lines = split( '\n', $out );
	
	# Loop through each line
	my $line;
	for ( $i = 0 ; $i < @lines ; $i++ ) {
		# Loop through each network name
		foreach (@hcpNets) {
			# If the network is found
			if ( $lines[$i] =~ m/ $_/i ) {
				# Save network name
				$hcpNetName = $_;
				
				# Get NIC address
				$line       = xCAT::zvmUtils->trimStr( $lines[ $i - 1 ] );
				@words      = split( ' ', $line );
				@tmp        = split( /\./, $words[1] );
				$hcpNicAddr = $tmp[0];
				last;
			}
		}
	}
		
	# If no network name is found, exit
	if (!$hcpNetName || !$hcpNicAddr) {
		foreach (@nodes) {
			xCAT::zvmUtils->printLn( $callback, "$_: (Error) No suitable network device found in user directory entry" );
			xCAT::zvmUtils->printLn( $callback, "$_: (Solution) Verify that the node has one of the following network devices: @hcpNets" );
		}
		return;
	}

	# Get VSwitch of source node (if any)
	my @srcVswitch = xCAT::zvmCPUtils->getVswitchId($sourceNode);

	# Get device address that is the root partition (/)
	my $srcRootPartAddr = xCAT::zvmUtils->getRootDeviceAddr($sourceNode);

	# Get source node OS
	my $srcOs = xCAT::zvmUtils->getOs($sourceNode);

	# Get source MAC address in 'mac' table
	my $srcMac;
	@propNames = ('mac');
	$propVals = xCAT::zvmUtils->getNodeProps( 'mac', $sourceNode, @propNames );
	if ( $propVals->{'mac'} ) {

		# Get MAC address
		$srcMac = $propVals->{'mac'};
	}

	# Get network configuration file
	# Location of this file depends on the OS
	my $srcIfcfg = xCAT::zvmUtils->getIfcfgByNic( $sourceNode, "0.0." . $hcpNicAddr );

	# Get source hardware configuration (SUSE only)
	my $srcHwcfg = '';
	if ( $srcOs =~ m/SUSE/i ) {
		$srcHwcfg = xCAT::zvmUtils->getHwcfg($sourceNode);
	}

	# Get user entry of source node
	my $srcUserEntry = "/tmp/$sourceNode.txt";
	$out = `rm $srcUserEntry`;
	$out = xCAT::zvmUtils->getUserEntryWODisk( $callback, $sourceNode, $srcUserEntry );

	# Check if user entry is valid
	$out = `cat $srcUserEntry`;

	# If output contains USER LINUX123, then user entry is good
	if ( $out =~ m/USER $sourceId/i ) {

		# Turn off source node
		$out = `ssh -o ConnectTimeout=10 $sourceNode "shutdown -h now"`;
		sleep(90);	# Wait 1.5 minutes before logging user off
		
		$out = `ssh $srcHcp "$::DIR/stopvs $sourceId"`;
		foreach (@nodes) {
			xCAT::zvmUtils->printLn( $callback, "$_: $out" );
		}

		#*** Clone source node ***
		# Remove flashcopy lock (if any)
		$out = `ssh $srcHcp "rm -f /tmp/.flashcopy_lock"`;
		foreach (@nodes) {
			$pid = xCAT::Utils->xfork();

			# Parent process
			if ($pid) {
				push( @children, $pid );
			}

			# Child process
			elsif ( $pid == 0 ) {

				clone(
					$callback, $_, $args, \@srcDisks, \%srcLinkAddr, \%srcDiskSize, \%srcDiskType, 
					$hcpNicAddr, $hcpNetName, \@srcVswitch, $srcOs, $srcMac, $srcRootPartAddr, $srcIfcfg, 
					$srcHwcfg
				);

				# Exit process
				exit(0);
			}

			# End of elsif
			else {

				# Ran out of resources
				die "Error: Could not fork\n";
			}

			# Clone 4 nodes at a time
			# If you handle more than this, some nodes will not be cloned
			# You will get errors because SMAPI cannot handle many nodes
			if ( !( @children % 4 ) ) {

				# Wait for all processes to end
				foreach (@children) {
					waitpid( $_, 0 );
				}

				# Clear children
				@children = ();
			}
		}    # End of foreach

		# Handle the remaining nodes
		# Wait for all processes to end
		foreach (@children) {
			waitpid( $_, 0 );
		}

		# Remove source user entry
		$out = `rm $srcUserEntry`;
	}    # End of if

	#*** Detatch source disks ***
	for $addr ( keys %srcLinkAddr ) {
		$linkAddr = $srcLinkAddr{$addr};

		# Disable and detatch source disk
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $srcHcp, "-d", $linkAddr );
		$out = `ssh -o ConnectTimeout=5 $srcHcp "vmcp det $linkAddr"`;

		foreach (@nodes) {
			xCAT::zvmUtils->printLn( $callback, "$_: Detatching source disk ($addr) at ($linkAddr)" );
		}
	}

	# Turn back on source node
	$out = `ssh $srcHcp "$::DIR/startvs $sourceId"`;
	foreach (@nodes) {
		xCAT::zvmUtils->printLn( $callback, "$_: $out" );
	}

	#*** Done ***
	foreach (@nodes) {
		xCAT::zvmUtils->printLn( $callback, "$_: Done" );
	}

	return;
}

#-------------------------------------------------------

=head3   clone

	Description	: Clone a virtual server
    Arguments	: 	Target node
    				Disk pool
    				Disk password (optional)
    				Source disks
    				Source disk link addresses
    				Source disk sizes
    				NIC address
    				Network name
    				VSwitch names (if any)
    				Operating system
    				MAC address
    				Root parition device address
    				Path to network configuration file
    				Path to hardware configuration file (SUSE only)
    Returns		: Nothing
    Example		: clone($callback, $_, $args, \@srcDisks, \%srcLinkAddr, \%srcDiskSize, 
    				$hcpNicAddr, $hcpNetName, \@srcVswitch, $srcOs, $srcMac, 
    				$srcRootPartAddr, $srcIfcfg, $srcHwcfg);
    
=cut

#-------------------------------------------------------
sub clone {

	# Get inputs
	my (
		$callback, $tgtNode, $args, $srcDisksRef, $srcLinkAddrRef, $srcDiskSizeRef, $srcDiskTypeRef, 
		$hcpNicAddr, $hcpNetName, $srcVswitchRef, $srcOs, $srcMac, $srcRootPartAddr, $srcIfcfg, $srcHwcfg
	  )
	  = @_;

	# Get source node properties from 'zvm' table
	my $sourceNode = $args->[0];
	my @propNames  = ( 'hcp', 'userid' );
	my $propVals   = xCAT::zvmUtils->getNodeProps( 'zvm', $sourceNode, @propNames );

	# Get zHCP
	my $srcHcp = $propVals->{'hcp'};

	# Get node user ID
	my $sourceId = $propVals->{'userid'};
	# Capitalize user ID
	$sourceId =~ tr/a-z/A-Z/;

	# Get source disks
	my @srcDisks    = @$srcDisksRef;
	my %srcLinkAddr = %$srcLinkAddrRef;
	my %srcDiskSize = %$srcDiskSizeRef;
	my %srcDiskType = %$srcDiskTypeRef;
	my @srcVswitch  = @$srcVswitchRef;

	# Return code for each command
	my $rc;

	# Get node properties from 'zvm' table
	@propNames = ( 'hcp', 'userid' );
	$propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $tgtNode, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $tgtUserId = $propVals->{'userid'};
	if ( !$tgtUserId ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$tgtUserId =~ tr/a-z/A-Z/;

	# Exit if source node HCP is not the same as target node HCP
	if ( !( $srcHcp eq $hcp ) ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Source node HCP ($srcHcp) is not the same as target node HCP ($hcp)" );
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Solution) Set the source and target HCP appropriately in the zvm table" );
		return;
	}

	# Get target IP from /etc/hosts
	my $targetIp = xCAT::zvmUtils->getIp($tgtNode);
	if ( !$targetIp ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Missing IP for $tgtNode in /etc/hosts" );
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Solution) Verify that the node's IP address is specified in the hosts table and then run makehosts" );
		return;
	}

	my $out;
	my @lines;
	my @words;

	# Get disk pool and multi password
	my $i;
	my %inputs;
	foreach $i ( 1 .. 2 ) {
		if ( $args->[$i] ) {

			# Split parameters by '='
			@words = split( "=", $args->[$i] );

			# Create hash array
			$inputs{ $words[0] } = $words[1];
		}
	}

	# Get disk pool
	my $pool = $inputs{"pool"};
	if ( !$pool ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Missing disk pool. Please specify one." );
		return;
	}

	# Get multi password
	# It is Ok not have a password
	my $tgtPw = $inputs{"pw"};

	# Set IP address
	my $sourceIp = xCAT::zvmUtils->getIp($sourceNode);

	# Save user directory entry as /tmp/hostname.txt, e.g. /tmp/gpok3.txt
	# The source user entry is retrieved in cloneVM()
	my $userEntry    = "/tmp/$tgtNode.txt";
	my $srcUserEntry = "/tmp/$sourceNode.txt";

	# Remove existing user entry if any
	$out = `rm $userEntry`;
	$out = `ssh -o ConnectTimeout=5 $hcp "rm $userEntry"`;

	# Copy user entry of source node
	$out = `cp $srcUserEntry $userEntry`;

	# Replace source userID with target userID
	$out = `sed --in-place -e "s,$sourceId,$tgtUserId,i" $userEntry`;

	# Get target MAC address in 'mac' table
	my $targetMac;
	my $macId;
	my $generateNew = 0;    # Flag to generate new MACID
	@propNames = ('mac');
	$propVals = xCAT::zvmUtils->getNodeProps( 'mac', $tgtNode, @propNames );
	if ($propVals) {

		# Get MACID
		$targetMac = $propVals->{'mac'};
		$macId     = $propVals->{'mac'};
		$macId     = xCAT::zvmUtils->replaceStr( $macId, ":", "" );
		$macId     = substr( $macId, 6 );
	}
	else {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Missing target MAC address" );
		return;
	}

	# If the user entry contains a NICDEF statement
	$out = `cat $userEntry | egrep -i "NICDEF"`;
	if ($out) {

		# Get the networks used by the zHCP
		my @hcpNets = xCAT::zvmCPUtils->getNetworkNamesArray($hcp);
		
		# Search user entry for network name
		my $hcpNetName = '';
		foreach (@hcpNets) {
			if ( $out =~ m/ $_/i ) {
				$hcpNetName = $_;
				last;
			}
		}
		
		# If the user entry contains a MACID
		$out = `cat $userEntry | egrep -i "MACID"`;
		if ($out) {
			my $pos = rindex( $out, "MACID" );
			my $oldMacId = substr( $out, $pos + 6, 12 );
			$oldMacId = xCAT::zvmUtils->trimStr($oldMacId);

			# Replace old MACID
			$out = `sed --in-place -e "s,$oldMacId,$macId,i" $userEntry`;
		} else {

			# Find NICDEF statement
			my $oldNicDef = `cat $userEntry | egrep -i "NICDEF" | egrep -i "$hcpNetName"`;
			$oldNicDef = xCAT::zvmUtils->trimStr($oldNicDef);
			my $nicDef = xCAT::zvmUtils->replaceStr( $oldNicDef, $hcpNetName, "$hcpNetName MACID $macId" );

			# Append MACID at the end
			$out = `sed --in-place -e "s,$oldNicDef,$nicDef,i" $userEntry`;
		}
	}

	# SCP user entry file over to HCP
	xCAT::zvmUtils->sendFile( $hcp, $userEntry, $userEntry );

	#*** Create new virtual server ***
	my $try = 5;
	while ( $try > 0 ) {
		if ( $try > 4 ) {
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Creating user directory entry" );
		}
		else {
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Trying again ($try) to create user directory entry" );
		}
		$out = `ssh $hcp "$::DIR/createvs $tgtUserId $userEntry"`;

		# Check if user entry is created
		$out = `ssh $hcp "$::DIR/getuserentry $tgtUserId"`;
		$rc  = xCAT::zvmUtils->checkOutput( $callback, $out );

		if ( $rc == -1 ) {

			# Wait before trying again
			sleep(5);

			$try = $try - 1;
		}
		else {
			last;
		}
	}

	# Remove user entry
	$out = `rm $userEntry`;
	$out = `ssh -o ConnectTimeout=5 $hcp "rm $userEntry"`;

	# Exit on bad output
	if ( $rc == -1 ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Could not create user entry" );
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Solution) Verify that the node's zHCP and its zVM's SMAPI are both online" );
		return;
	}

	# Load VMCP module on HCP and source node
	xCAT::zvmCPUtils->loadVmcp($hcp);

	# Grant access to VSwitch for Linux user
	# GuestLan do not need permissions
	foreach (@srcVswitch) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: Granting VSwitch ($_) access for $tgtUserId" );
		$out = xCAT::zvmCPUtils->grantVSwitch( $callback, $hcp, $tgtUserId, $_ );

		# Check for errors
		$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
		if ( $rc == -1 ) {

			# Exit on bad output
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );
			return;
		}
	}    # End of foreach (@vswitchId)

	#*** Add MDisk to target user entry ***
	my $addr;
	my @tgtDisks;
	my $type;
	my $mode;
	my $cyl;
	my $srcMultiPw;
	foreach (@srcDisks) {

		# Get disk address
		@words = split( ' ', $_ );
		$addr = $words[1];
		push( @tgtDisks, $addr );
		$type       = $words[2];
		$mode       = $words[6];
		$srcMultiPw = $words[9];
		
		# Add 0 in front if address length is less than 4
		while (length($addr) < 4) {
			$addr = '0' . $addr;
		}

		# Add ECKD disk
		if ( $type eq '3390' ) {

			# Get disk size (cylinders)
			$cyl = $srcDiskSize{$addr};

			$try = 5;
			while ( $try > 0 ) {

				# Add ECKD disk
				if ( $try > 4 ) {
					xCAT::zvmUtils->printLn( $callback, "$tgtNode: Adding minidisk ($addr)" );
				}
				else {
					xCAT::zvmUtils->printLn( $callback, "$tgtNode: Trying again ($try) to add minidisk ($addr)" );
				}
				$out = `ssh $hcp "$::DIR/add3390 $tgtUserId $pool $addr $cyl $mode $tgtPw $tgtPw $tgtPw"`;

				# Check output
				$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
				if ( $rc == -1 ) {

					# Wait before trying again
					sleep(5);

					# One less try
					$try = $try - 1;
				}
				else {

					# If output is good, exit loop
					last;
				}
			}    # End of while ( $try > 0 )

			# Exit on bad output
			if ( $rc == -1 ) {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Could not add minidisk ($addr)" );
				return;
			}
		}    # End of if ( $type eq '3390' )

		# Add FBA disk
		elsif ( $type eq '9336' ) {

			# Get disk size (blocks)
			my $blkSize = '512';
			my $blks    = $srcDiskSize{$addr};

			$try = 10;
			while ( $try > 0 ) {

				# Add FBA disk
				if ( $try > 9 ) {
					xCAT::zvmUtils->printLn( $callback, "$tgtNode: Adding minidisk ($addr)" );
				}
				else {
					xCAT::zvmUtils->printLn( $callback, "$tgtNode: Trying again ($try) to add minidisk ($addr)" );
				}
				$out = `ssh $hcp "$::DIR/add9336 $tgtUserId $pool $addr $blkSize $blks $mode $tgtPw $tgtPw $tgtPw"`;

				# Check output
				$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
				if ( $rc == -1 ) {

					# Wait before trying again
					sleep(5);

					# One less try
					$try = $try - 1;
				}
				else {

					# If output is good, exit loop
					last;
				}
			}    # End of while ( $try > 0 )

			# Exit on bad output
			if ( $rc == -1 ) {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Could not add minidisk ($addr)" );
				return;
			}
		}    # End of elsif ( $type eq '9336' )
	}

	# Check if the number of disks in target user entry
	# is equal to the number of disks added
	my @disks;
	$try = 10;
	while ( $try > 0 ) {

		# Get disks within user entry
		$out = `ssh $hcp "$::DIR/getuserentry $tgtUserId" | grep "MDISK"`;
		@disks = split( '\n', $out );
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: Disks added (" . @tgtDisks . "). Disks in user entry (" . @disks . ")" );

		if ( @disks != @tgtDisks ) {
			$try = $try - 1;

			# Wait before trying again
			sleep(5);
		}
		else {
			last;
		}
	}

	# Exit if all disks are not present
	if ( @disks != @tgtDisks ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Disks not present in user entry" );
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Solution) Verify disk pool($pool) has free disks" );
		return;
	}

	#*** Link, format, and copy source disks ***
	my $srcAddr;
	my $tgtAddr;
	my $srcDevNode;
	my $tgtDevNode;
	my $tgtDiskType;
	foreach (@tgtDisks) {

		#*** Link target disk ***
		$try = 10;
		while ( $try > 0 ) {
			
			# Add 0 in front if address length is less than 4
			while (length($_) < 4) {
				$_ = '0' . $_;
			}
			
			# New disk address
			$srcAddr = $srcLinkAddr{$_};
			$tgtAddr = $_ + 2000;

			# Check if new disk address is used (target)
			$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $tgtAddr );

			# If disk address is used (target)
			while ( $rc == 0 ) {

				# Generate a new disk address
				# Sleep 5 seconds to let existing disk appear
				sleep(5);
				$tgtAddr = $tgtAddr + 1;
				$rc = xCAT::zvmUtils->isAddressUsed( $hcp, $tgtAddr );
			}

			# Link target disk
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Linking target disk ($_) as ($tgtAddr)" );
			$out = `ssh -o ConnectTimeout=5 $hcp "vmcp link $tgtUserId $_ $tgtAddr MR $tgtPw"`;

			# If link fails
			if ( $out =~ m/not linked/i ) {

				# Wait before trying again
				sleep(5);

				$try = $try - 1;
			}
			else {
				last;
			}
		}    # End of while ( $try > 0 )

		# If target disk is not linked
		if ( $out =~ m/not linked/i ) {
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Failed to link target disk ($_)" );
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Failed" );

			# Exit
			return;
		}
		
		# Get disk type (3390 or 9336)
		$tgtDiskType = $srcDiskType{$_};
		
		#*** Use flashcopy ***
		# Flashcopy only supports ECKD volumes
		my $ddCopy = 0;
		$out = `ssh $hcp "vmcp flashcopy"`;
		if ( ($out =~ m/HCPNFC026E/i) && ($tgtDiskType eq '3390')) {

			# Flashcopy is supported
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Copying source disk ($srcAddr) to target disk ($tgtAddr) using FLASHCOPY" );

			# Check for flashcopy lock
			my $wait = 0;
			while ( `ssh $hcp "ls /tmp/.flashcopy_lock"` && $wait < 90 ) {

				# Wait until the lock dissappears
				# 90 seconds wait limit
				sleep(2);
				$wait = $wait + 2;
			}

			# If flashcopy locks still exists
			if (`ssh $hcp "ls /tmp/.flashcopy_lock"`) {

				# Detatch disks from HCP
				$out = `ssh $hcp "vmcp det $tgtAddr"`;
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Flashcopy lock is enabled" );
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Solution) Remove lock by deleting /tmp/.flashcopy_lock on the zHCP. Use caution!" );
				return;
			}
			else {

				# Enable lock
				$out = `ssh $hcp "touch /tmp/.flashcopy_lock"`;

				# Flashcopy source disk
				$out = xCAT::zvmCPUtils->flashCopy( $hcp, $srcAddr, $tgtAddr );
				$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
				if ( $rc == -1 ) {
					xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );

					# Try Linux dd
					$ddCopy = 1;
				}

				# Wait a while for flashcopy to completely finish
				sleep(10);

				# Remove lock
				$out = `ssh $hcp "rm -f /tmp/.flashcopy_lock"`;
			}
		} else {
			$ddCopy = 1;
		}
		
		# Flashcopy not supported, use Linux dd
		if ($ddCopy) {			

			#*** Use Linux dd to copy ***
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: FLASHCOPY not working.  Using Linux DD" );

			# Enable target disk
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", $tgtAddr );

			# Determine source device node
			$srcDevNode = xCAT::zvmUtils->getDeviceNode($hcp, $srcAddr);

			# Determine target device node
			$tgtDevNode = xCAT::zvmUtils->getDeviceNode($hcp, $tgtAddr);

			# Format target disk
			# Only ECKD disks need to be formated
			if ($tgtDiskType eq '3390') {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: Formating target disk ($tgtAddr)" );
				$out = `ssh $hcp "dasdfmt -b 4096 -y -f /dev/$tgtDevNode"`;

				# Check for errors
				$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
				if ( $rc == -1 ) {
					xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );
					return;
				}
	
				# Sleep 2 seconds to let the system settle
				sleep(2);
			
				# Copy source disk to target disk
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: Copying source disk ($srcAddr) to target disk ($tgtAddr)" );
				$out = `ssh $hcp "dd if=/dev/$srcDevNode of=/dev/$tgtDevNode bs=4096"`;
			} else {
				# Copy source disk to target disk
				# Block size = 512
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: Copying source disk ($srcAddr) to target disk ($tgtAddr)" );
				$out = `ssh $hcp "dd if=/dev/$srcDevNode of=/dev/$tgtDevNode bs=512"`;
				
				# Force Linux to re-read partition table
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: Forcing Linux to re-read partition table" );
				$out = 
`ssh $hcp "cat<<EOM | fdisk /dev/$tgtDevNode
p
w
EOM"`;
			}
						
			# Check for error
			$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
			if ( $rc == -1 ) {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );
				return;
			}

			# Sleep 2 seconds to let the system settle
			sleep(2);
		}

		# Disable and enable target disk
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-d", $tgtAddr );
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", $tgtAddr );

		# Determine target device node (it might have changed)
		$tgtDevNode = xCAT::zvmUtils->getDeviceNode($hcp, $tgtAddr);

		# Get disk address that is the root partition (/)
		if ( $_ eq $srcRootPartAddr ) {

			# Mount target disk
			my $cloneMntPt = "/mnt/$tgtUserId";
			$tgtDevNode .= "1";

			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Mounting /dev/$tgtDevNode to $cloneMntPt" );

			# Check the disk is mounted
			$try = 10;
			while ( !(`ssh $hcp "ls $cloneMntPt/etc/"`) && $try > 0 ) {
				$out = `ssh $hcp "mkdir -p $cloneMntPt"`;
				$out = `ssh $hcp "mount /dev/$tgtDevNode $cloneMntPt"`;

				# Wait before trying again
				sleep(10);
				$try = $try - 1;
			}

			# If the disk is not mounted
			if ( !(`ssh $hcp "ls $cloneMntPt/etc/"`) ) {
				xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Could not mount /dev/$tgtDevNode" );

				# Flush disk
				$out = `ssh $hcp "sync"`;

				# Unmount disk
				$out = `ssh $hcp "umount $cloneMntPt"`;

				# Remove mount point
				$out = `ssh $hcp "rm -rf $cloneMntPt"`;

				# Disable disks
				$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-d", $tgtAddr );

				# Detatch disks from HCP
				$out = `ssh $hcp "vmcp det $tgtAddr"`;

				return;
			}

			#*** Set network configuration ***
			# Set hostname
			xCAT::zvmUtils->printLn( $callback, "$tgtNode: Setting network configuration" );
			$out = `ssh $hcp sed --in-place -e "s/$sourceNode/$tgtNode/i" $cloneMntPt/etc/HOSTNAME`;

			# If Red Hat - Set hostname in /etc/sysconfig/network
			if ( $srcOs =~ m/Red Hat/i ) {
				$out = `ssh $hcp sed --in-place -e "s/$sourceNode/$tgtNode/i" $cloneMntPt/etc/sysconfig/network`;
			}

			# Get network configuration file
			# Location of this file depends on the OS
			my $ifcfgPath = $cloneMntPt;
			$ifcfgPath .= $srcIfcfg;
			$out = `ssh $hcp sed --in-place -e "s/$sourceNode/$tgtNode/i" \ -e "s/$sourceIp/$targetIp/i" $cloneMntPt/etc/hosts`;
			$out = `ssh $hcp sed --in-place -e "s/$sourceIp/$targetIp/i" \ -e "s/$sourceNode/$tgtNode/i" $ifcfgPath`;

			# Get network layer
			my $layer = xCAT::zvmCPUtils->getNetworkLayer( $hcp, $hcpNetName );
			
			# Set MAC address
			my $networkFile = $tgtNode . "NetworkConfig";
			if ( $srcOs =~ m/Red Hat/i ) {

				# Red Hat only
				$out = `ssh $hcp "cat $ifcfgPath" | grep -v "MACADDR" > /tmp/$networkFile`;
				$out = `echo "MACADDR='$targetMac'" >> /tmp/$networkFile`;
			}
			else {

				# SUSE only
				$out = `ssh $hcp "cat $ifcfgPath" | grep -v "LLADDR" | grep -v "UNIQUE" > /tmp/$networkFile`;
				
				# Set to MAC address (only for layer 2)
				if ( $layer == 2 ) {
					$out = `echo "LLADDR='$targetMac'" >> /tmp/$networkFile`;
					$out = `echo "UNIQUE=''" >> /tmp/$networkFile`;
				}
			}
			xCAT::zvmUtils->sendFile( $hcp, "/tmp/$networkFile", $ifcfgPath );

			# Remove network file from /tmp
			$out = `rm /tmp/$networkFile`;

			# Set to hardware configuration (only for layer 2)
			if ( $layer == 2 ) {

				#*** Red Hat ***
				if ( $srcOs =~ m/Red Hat/i ) {
					my $srcMac;

					# Get source MAC address in 'mac' table
					@propNames = ('mac');
					$propVals = xCAT::zvmUtils->getNodeProps( 'mac', $sourceNode, @propNames );
					if ($propVals) {

						# Get MAC address
						$srcMac = $propVals->{'mac'};
					}
					else {
						xCAT::zvmUtils->printLn( $callback, "$tgtNode: (Error) Could not find MAC address of $sourceNode" );

						# Unmount disk
						$out = `ssh $hcp "umount $cloneMntPt"`;

						# Disable disks
						$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-d", $tgtAddr );

						# Detatch disks from HCP
						$out = `ssh $hcp "vmcp det $tgtAddr"`;

						return;
					}

					# Set MAC address
					$out = `ssh $hcp sed --in-place -e "s/$srcMac/$targetMac/i" $ifcfgPath`;
				}

				#*** SUSE ***
				else {

					# Get hardware configuration
					my $hwcfgPath = $cloneMntPt;

					# Set layer 2 support
					$hwcfgPath .= $srcHwcfg;
					my $hardwareFile = $tgtNode . "HardwareConfig";
					$out = `ssh $hcp "cat $hwcfgPath" | grep -v "QETH_LAYER2_SUPPORT" > /tmp/$hardwareFile`;
					$out = `echo "QETH_LAYER2_SUPPORT='1'" >> /tmp/$hardwareFile`;
					xCAT::zvmUtils->sendFile( $hcp, "/tmp/$hardwareFile", $hwcfgPath );

					# Remove hardware file from /tmp
					$out = `rm /tmp/$hardwareFile`;
				}
			}    # End of if ( $layer == 2 )

			# Remove old SSH keys
			$out = `ssh $hcp "rm -f $cloneMntPt/etc/ssh/ssh_host_*"`;

			# Flush disk
			$out = `ssh $hcp "sync"`;

			# Unmount disk
			$out = `ssh $hcp "umount $cloneMntPt"`;

			# Remove mount point
			$out = `ssh $hcp "rm -rf $cloneMntPt"`;
		}

		# Disable disks
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-d", $tgtAddr );

		# Detatch disks from HCP
		$out = `ssh $hcp "vmcp det $tgtAddr"`;

		sleep(5);
	}    # End of foreach (@tgtDisks)

	# Update DHCP
	$out = `makedhcp -a`;

	# Power on target virtual server
	xCAT::zvmUtils->printLn( $callback, "$tgtNode: Powering on" );
	$out = `ssh $hcp "$::DIR/startvs $tgtUserId"`;

	# Check for error
	$rc = xCAT::zvmUtils->checkOutput( $callback, $out );
	if ( $rc == -1 ) {
		xCAT::zvmUtils->printLn( $callback, "$tgtNode: $out" );
		return;
	}
}

#-------------------------------------------------------

=head3   nodeSet

	Description	: Set the boot state for a node 
					* Punch initrd, kernel, and parmfile to node reader
					* Layer 2 and 3 VSwitch/Lan supported
    Arguments	: Node
    Returns		: Nothing
    Example		: nodeSet($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub nodeSet {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Get install directory and domain from site table
	my $siteTab        = xCAT::Table->new('site');
	my $installDirHash = $siteTab->getAttribs( { key => "installdir" }, 'value' );
	my $installDir     = $installDirHash->{'value'};
	my $domainHash     = $siteTab->getAttribs( { key => "domain" }, 'value' );
	my $domain         = $domainHash->{'value'};
	my $masterHash     = $siteTab->getAttribs( { key => "master" }, 'value' );
	my $master         = $masterHash->{'value'};
	my $xcatdPortHash  = $siteTab->getAttribs( { key => "xcatdport" }, 'value' );
	my $xcatdPort      = $xcatdPortHash->{'value'};

	# Get node OS, arch, and profile from 'nodetype' table
	@propNames = ( 'os', 'arch', 'profile' );
	$propVals = xCAT::zvmUtils->getNodeProps( 'nodetype', $node, @propNames );

	my $os      = $propVals->{'os'};
	my $arch    = $propVals->{'arch'};
	my $profile = $propVals->{'profile'};

	# If no OS, arch, or profile is found
	if ( !$os || !$arch || !$profile ) {

		# Exit
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node OS, arch, and profile in nodetype table" );
		return;
	}

	# Get action
	my $action = $args->[0];
	my $out;
	if ( $action eq "install" ) {

		# Get node root password
		@propNames = ('password');
		$propVals = xCAT::zvmUtils->getTabPropsByKey( 'passwd', 'key', 'system', @propNames );
		my $passwd = $propVals->{'password'};
		if ( !$passwd ) {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing root password for this node" );
			return;
		}

		# Get node OS base
		my @tmp;
		if ( $os =~ m/sp/i ) {
			@tmp = split( /sp/, $os );
		} else {
			@tmp = split( /\./, $os );
		}
		my $osBase = $tmp[0];
		
		# Get node distro
		my $distro = "";
		if ( $os =~ m/sles/i ) {
			$distro = "sles";
		} elsif ( $os =~ m/rhel/i ) {
			$distro = "rh";
		} else {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Unable to determine node Linux distribution" );
			xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Verify the node Linux distribution is either sles* or rh*" );
			return;
		}

		# Get autoyast/kickstart template
		my $tmpl;
				
		# Check for $profile.$os.$arch.tmpl
		if ( -e "$installDir/custom/install/$distro/$profile.$os.$arch.tmpl" ) {
			$tmpl = "$profile.$os.$arch.tmpl";
		} 
		# Check for $profile.$osBase.$arch.tmpl
		elsif ( -e "$installDir/custom/install/$distro/$profile.$osBase.$arch.tmpl" ) {
			$tmpl = "$profile.$osBase.$arch.tmpl";
		}  
		# Check for $profile.$arch.tmpl
		elsif ( -e "$installDir/custom/install/$distro/$profile.$arch.tmpl" ) {
			$tmpl = "$profile.$arch.tmpl";
		}
		# Check for $profile.tmpl second
		elsif ( -e "$installDir/custom/install/$distro/$profile.tmpl" ) {
			$tmpl = "$profile.tmpl";
		}
		else {
			# No template exists
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing autoyast/kickstart template" );
			xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Create a template under $installDir/custom/install/$distro/" );
			return;
		}

		# Get host IP and hostname from /etc/hosts
		$out = `cat /etc/hosts | grep "$node "`;
		my @words    = split( ' ', $out );
		my $hostIP   = $words[0];
		my $hostname = $words[2];
		if ( !$hostIP || !$hostname ) {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing IP for $node in /etc/hosts" );
			xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Verify that the nodes IP address is specified in the hosts table and then run makehosts" );
			return;
		}

		# Check template if DHCP is used
		my $dhcp = 0;
		if ($distro eq "sles") {
			# Check autoyast template
			if ( -e "$installDir/custom/install/sles/$tmpl" ) {
				$out = `cat $installDir/custom/install/sles/$tmpl | egrep -i "<bootproto>"`;
				if ($out =~ m/dhcp/i) {
					$dhcp = 1;
				}
			}
		} elsif ($distro eq "rh") {
			# Check kickstart template
			if ( -e "$installDir/custom/install/rh/$tmpl" ) {
				$out = `cat $installDir/custom/install/rh/$tmpl | egrep -i "--bootproto dhcp"`;
				if ($out =~ m/dhcp/i) {
					$dhcp = 1;
				}
			}
		}
		
		# Get the networks used by the zHCP
		my @hcpNets = xCAT::zvmCPUtils->getNetworkNamesArray($hcp);
		
		my $hcpNetName = '';
		my $channel;
		my $layer;
		my $i;
		
		# Search directory entry for network name
		my $userEntry = `ssh $hcp "$::DIR/getuserentry $userId"`;
		$out = `echo "$userEntry" | grep "NICDEF"`;
		my @lines = split( '\n', $out );
		
		# Go through each line
		for ( $i = 0 ; $i < @lines ; $i++ ) {
			# Go through each network device attached to zHCP
			foreach (@hcpNets) {
				
				# If network device is found
				if ( $lines[$i] =~ m/ $_/i ) {					
					# Get network layer
					$layer = xCAT::zvmCPUtils->getNetworkLayer($hcp, $_);
					
					# If template using DHCP, layer must be 2
					if ((!$dhcp && $layer != 2) || (!$dhcp && $layer == 2) || ($dhcp && $layer == 2)) {
						# Save network name
						$hcpNetName = $_;
						
						# Get network virtual address
						@words = split( ' ',  $lines[$i] );
						
						# Get virtual address (channel)
						# Convert subchannel to decimal
						$channel = sprintf('%d', hex($words[1]));
						
						last;
					} else {
						# Go to next network available
						$hcpNetName = ''
					}
				}
			}
		}
		
		# If network device is not found
		if (!$hcpNetName) {
			
			# Check for user profile
			my $profileName = `echo "$userEntry" | grep "INCLUDE"`;
			if ($profileName) {
				@words = split( ' ', xCAT::zvmUtils->trimStr($profileName) );
				
				# Get user profile
				my $userProfile = xCAT::zvmUtils->getUserProfile($hcp, $words[1]);
				
				# Get the NICDEF statement containing the HCP network
				$out = `echo "$userProfile" | grep "NICDEF"`;
				@lines = split( '\n', $out );
				
				# Go through each line
				for ( $i = 0 ; $i < @lines ; $i++ ) {
					# Go through each network device attached to zHCP
					foreach (@hcpNets) {
						
						# If network device is found
						if ( $lines[$i] =~ m/ $_/i ) {
							# Get network layer
							$layer = xCAT::zvmCPUtils->getNetworkLayer($node, $_);
					
							# If template using DHCP, layer must be 2
							if ((!$dhcp && $layer != 2) || (!$dhcp && $layer == 2) || ($dhcp && $layer == 2)) {
								# Save network name
								$hcpNetName = $_;
								
								# Get network virtual address
								@words = split( ' ',  $lines[$i] );
								
								# Get virtual address (channel)
								# Convert subchannel to decimal
								$channel = sprintf('%d', hex($words[1]));
								
								last;
							} else {
								# Go to next network available
								$hcpNetName = ''
							}
						}
					} # End of foreach
				} # End of for
			} # End of if
		}
		
		# Exit if no suitable network found 
		if (!$hcpNetName) {
			if ($dhcp) {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) The template selected uses DHCP. A layer 2 VSWITCH or GLAN is required. None were found." );
				xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Modify the template to use <bootproto>static</bootproto> or change the network device attached to virtual machine" );
			} else {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) No suitable network device found in user directory entry" );
				xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Verify that the node has one of the following network devices: @hcpNets" );	
			}
			
			return;
		}
		
		# Generate read, write, and data channels
		my $readChannel = "0.0." . ( sprintf('%X', $channel + 0) );
		if ( length($readChannel) < 8 ) {

			# Prepend a zero
			$readChannel = "0.0.0" . ( sprintf('%X', $channel + 0) );
		}

		my $writeChannel = "0.0." . ( sprintf('%X', $channel + 1) );
		if ( length($writeChannel) < 8 ) {

			# Prepend a zero
			$writeChannel = "0.0.0" . ( sprintf('%X', $channel + 1) );
		}

		my $dataChannel = "0.0." . ( sprintf('%X', $channel + 2) );
		if ( length($dataChannel) < 8 ) {

			# Prepend a zero
			$dataChannel = "0.0.0" . ( sprintf('%X', $channel + 2) );
		}

		# Get MAC address (Only for layer 2)
		my $mac = "";
		my @propNames;
		my $propVals;
		if ( $layer == 2 ) {

			# Search 'mac' table for node
			@propNames = ('mac');
			$propVals  = xCAT::zvmUtils->getTabPropsByKey( 'mac', 'node', $node, @propNames );
			$mac       = $propVals->{'mac'};

			# If no MAC address is found, exit
			# MAC address should have been assigned to the node upon creation
			if ( !$mac ) {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing MAC address of node" );
				return;
			}
		}
		
		# Get networks in 'networks' table
		my $entries = xCAT::zvmUtils->getAllTabEntries('networks');

		# Go through each network
		my $network = "";
		my $mask;
		foreach (@$entries) {

			# Get network and mask
			$network = $_->{'net'};
			$mask = $_->{'mask'};
			
			# If the host IP address is in this subnet, return
			if (xCAT::NetworkUtils->ishostinsubnet($hostIP, $mask, $network)) {

				# Exit loop
				last;
			}
			else {
				$network = "";
			}
		}
		
		# If no network found
		if ( !$network ) {

			# Exit
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Node does not belong to any network in the networks table" );
			xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Specify the subnet in the networks table. The mask, gateway, tftpserver, and nameservers must be specified for the subnet." );
			return;
		}

		@propNames = ( 'mask', 'gateway', 'tftpserver', 'nameservers' );
		$propVals = xCAT::zvmUtils->getTabPropsByKey( 'networks', 'net', $network, @propNames );
		my $mask       = $propVals->{'mask'};
		my $gateway    = $propVals->{'gateway'};
		my $ftp        = $propVals->{'tftpserver'};

		# Convert <xcatmaster> to nameserver IP
		my $nameserver;
		if ($propVals->{'nameservers'} eq '<xcatmaster>') {
		    $nameserver = xCAT::InstUtils->convert_xcatmaster();
		} else {
		    $nameserver = $propVals->{'nameservers'};
		}
    
		if ( !$network || !$mask || !$ftp || !$nameserver ) {

			# It is acceptable to not have a gateway
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing network information" );
			xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Specify the mask, gateway, tftpserver, and nameservers for the subnet in the networks table" );
			return;
		}

		# Get broadcast address of NIC
		my $ifcfg = xCAT::zvmUtils->getIfcfgByNic( $hcp, $readChannel );
		$out = `ssh $hcp "cat $ifcfg" | grep "BROADCAST"`;
		@words = split( '=', $out );
		my $broadcast = $words[1];
		$broadcast = xCAT::zvmUtils->trimStr($broadcast);
		$broadcast =~ s;"|';;g;

		# Load VMCP module on HCP
		xCAT::zvmCPUtils->loadVmcp($hcp);

		# Sample paramter file exists in installation CD (Use that as a guide)
		my $sampleParm;
		my $parmHeader;
		my $parms;
		my $parmFile;
		my $kernelFile;
		my $initFile;

		# If punch is successful - Look for this string
		my $searchStr = "created and transferred";

		# Default parameters - SUSE
		my $instNetDev   = "osa";     # Only OSA interface type is supported
		my $osaInterface = "qdio";    # OSA interface = qdio or lcs
		my $osaMedium    = "eth";     # OSA medium = eth (ethernet) or tr (token ring)

		# Default parameters - RHEL
		my $netType  = "qeth";
		my $portName = "FOOBAR";
		my $portNo   = "0";

		# Get postscript content
		my $postScript;
		if ( $os =~ m/sles10/i ) {
			$postScript = "/opt/xcat/share/xcat/install/scripts/post.sles10.s390x";
		} elsif ( $os =~ m/sles11/i ) {
			$postScript = "/opt/xcat/share/xcat/install/scripts/post.sles11.s390x";
		} elsif ( $os =~ m/rhel5/i ) {
			$postScript = "/opt/xcat/share/xcat/install/scripts/post.rhel5.s390x";
		} elsif ( $os =~ m/rhel6/i ) {
			$postScript = "/opt/xcat/share/xcat/install/scripts/post.rhel6.s390x";
		} else {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) No postscript available for $os" );
			return;
		}

		# SUSE installation
		my $customTmpl;
		my $pkglist;
		my $patterns = '';
		my $packages = '';
		if ( $os =~ m/sles/i ) {

			# Create directory in FTP root (/install) to hold template
			$out = `mkdir -p $installDir/custom/install/sles`;

			# Copy autoyast template
			$customTmpl = "$installDir/custom/install/sles/" . $node . "." . $profile . ".tmpl";
			if ( -e "$installDir/custom/install/sles/$tmpl" ) {
				$out = `cp $installDir/custom/install/sles/$tmpl $customTmpl`;
			}
			else {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) An autoyast template does not exist for $os in $installDir/custom/install/sles/. Please create one." );
				return;
			}
			
			# Get pkglist from /install/custom/install/sles/compute.sles11.s390x.otherpkgs.pkglist
			# Original one is in /opt/xcat/share/xcat/install/sles/compute.sles11.s390x.otherpkgs.pkglist
			$pkglist = "/install/custom/install/sles/" . $profile . "." . $osBase . "." . $arch . ".pkglist";
			if ( !(-e $pkglist) ) {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing package list for $os in /install/custom/install/sles/" );
				xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Please create one or copy default one from /opt/xcat/share/xcat/install/sles/" );
				return;
			}
			
			# Read in each software pattern or package
			open (FILE, $pkglist);
			while (<FILE>) { 
				chomp;
				
				# Create <xml> tags, e.g.
				# 	<package>apache</package>
				#	<pattern>directory_server</pattern>
				$_ = xCAT::zvmUtils->trimStr($_);
				if ($_ && $_ =~ /@/) {
					$_ =~ s/@//g;
					$patterns .= "<pattern>$_</pattern>";
				} elsif ($_) {
					$packages .= "<package>$_</package>";
				}
				
			}
			close (FILE);
			
			# Add appropriate software packages or patterns
			$out = `sed --in-place -e "s,replace_software_packages,$packages,g" \ -e "s,replace_software_patterns,$patterns,g" $customTmpl`;
						
			# Copy postscript into template
			$out = `sed --in-place -e "/<scripts>/r $postScript" $customTmpl`;

			# Edit template
			my $device;
			my $chanIds = "$readChannel $writeChannel $dataChannel";

			# SLES 11
			if ( $os =~ m/sles11/i ) {
				$device = "eth0";
			} else {
				# SLES 10
				$device = "qeth-bus-ccw-$readChannel";
			}

			$out =
`sed --in-place -e "s,replace_host_address,$hostIP,g" \ -e "s,replace_long_name,$hostname,g" \ -e "s,replace_short_name,$node,g" \ -e "s,replace_domain,$domain,g" \ -e "s,replace_hostname,$node,g" \ -e "s,replace_nameserver,$nameserver,g" \ -e "s,replace_broadcast,$broadcast,g" \ -e "s,replace_device,$device,g" \ -e "s,replace_ipaddr,$hostIP,g" \ -e "s,replace_lladdr,$mac,g" \ -e "s,replace_netmask,$mask,g" \ -e "s,replace_network,$network,g" \ -e "s,replace_ccw_chan_ids,$chanIds,g" \ -e "s,replace_ccw_chan_mode,FOOBAR,g" \ -e "s,replace_gateway,$gateway,g" \ -e "s,replace_root_password,$passwd,g" \ -e "s,replace_nic_addr,$readChannel,g" \ -e "s,replace_master,$master,g" \ -e "s,replace_install_dir,$installDir,g" $customTmpl`;

			# Read sample parmfile in /install/sles10.2/s390x/1/boot/s390x/
			$sampleParm = "$installDir/$os/s390x/1/boot/s390x/parmfile";
			open( SAMPLEPARM, "<$sampleParm" );

			# Search parmfile for -- ramdisk_size=65536 root=/dev/ram1 ro init=/linuxrc TERM=dumb
			while (<SAMPLEPARM>) {

				# If the line contains 'ramdisk_size'
				if ( $_ =~ m/ramdisk_size/i ) {
					$parmHeader = xCAT::zvmUtils->trimStr($_);
				}
			}

			# Close sample parmfile
			close(SAMPLEPARM);

			# Create parmfile -- Limited to 10 lines
			# End result should be:
			# 	ramdisk_size=65536 root=/dev/ram1 ro init=/linuxrc TERM=dumb
			# 	HostIP=10.0.0.5 Hostname=gpok5.endicott.ibm.com
			# 	Gateway=10.0.0.1 Netmask=255.255.255.0
			# 	Broadcast=10.0.0.0 Layer2=1 OSAHWaddr=02:00:01:FF:FF:FF
			# 	ReadChannel=0.0.0800  WriteChannel=0.0.0801  DataChannel=0.0.0802
			# 	Nameserver=10.0.0.1 Portname=OSAPORT Portno=0
			#	Install=ftp://10.0.0.1/sles10.2/s390x/1/
			#	UseVNC=1  VNCPassword=12345678
			#	InstNetDev=osa OsaInterface=qdio OsaMedium=eth Manual=0
			my $ay = "ftp://$ftp/custom/install/sles/" . $node . "." . $profile . ".tmpl";

			$parms = $parmHeader . "\n";
			$parms = $parms . "AutoYaST=$ay\n";
			$parms = $parms . "HostIP=$hostIP Hostname=$hostname\n";
			$parms = $parms . "Gateway=$gateway Netmask=$mask\n";

			# Set layer in autoyast profile
			if ( $layer == 2 ) {
				$parms = $parms . "Broadcast=$broadcast Layer2=1 OSAHWaddr=$mac\n";
			}
			else {
				$parms = $parms . "Broadcast=$broadcast Layer2=0\n";
			}

			$parms = $parms . "ReadChannel=$readChannel WriteChannel=$writeChannel DataChannel=$dataChannel\n";
			$parms = $parms . "Nameserver=$nameserver Portname=$portName Portno=0\n";
			$parms = $parms . "Install=ftp://$ftp/$os/s390x/1/\n";
			$parms = $parms . "UseVNC=1 VNCPassword=12345678\n";
			$parms = $parms . "InstNetDev=$instNetDev OsaInterface=$osaInterface OsaMedium=$osaMedium Manual=0\n";

			# Write to parmfile
			$parmFile = "/tmp/" . $node . "Parm";
			open( PARMFILE, ">$parmFile" );
			print PARMFILE "$parms";
			close(PARMFILE);

			# Send kernel, parmfile, and initrd to reader to HCP
			$kernelFile = "/tmp/" . $node . "Kernel";
			$initFile   = "/tmp/" . $node . "Initrd";
			$out        = `cp $installDir/$os/s390x/1/boot/s390x/vmrdr.ikr $kernelFile`;
			$out        = `cp $installDir/$os/s390x/1/boot/s390x/initrd $initFile`;
			xCAT::zvmUtils->sendFile( $hcp, $kernelFile, $kernelFile );
			xCAT::zvmUtils->sendFile( $hcp, $parmFile,   $parmFile );
			xCAT::zvmUtils->sendFile( $hcp, $initFile,   $initFile );

			# Set the virtual unit record devices online on HCP
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", "c" );
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", "d" );

			# Purge reader
			$out = xCAT::zvmCPUtils->purgeReader( $hcp, $userId );
			xCAT::zvmUtils->printLn( $callback, "$node: Purging reader... Done" );

			# Punch kernel to reader on HCP
			$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $kernelFile, "sles.kernel", "" );
			xCAT::zvmUtils->printLn( $callback, "$node: Punching kernel to reader... $out" );
			if ( $out =~ m/Failed/i ) {
				return;
			}

			# Punch parm to reader on HCP
			$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $parmFile, "sles.parm", "-t" );
			xCAT::zvmUtils->printLn( $callback, "$node: Punching parm to reader... $out" );
			if ( $out =~ m/Failed/i ) {
				return;
			}

			# Punch initrd to reader on HCP
			$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $initFile, "sles.initrd", "" );
			xCAT::zvmUtils->printLn( $callback, "$node: Punching initrd to reader... $out" );
			if ( $out =~ m/Failed/i ) {
				return;
			}

			# Remove kernel, parmfile, and initrd from /tmp
			$out = `rm $parmFile $kernelFile $initFile`;
			$out = `ssh -o ConnectTimeout=5 $hcp "rm $parmFile $kernelFile $initFile"`;

			xCAT::zvmUtils->printLn( $callback, "$node: Kernel, parm, and initrd punched to reader.  Ready for boot." );
		}

		# RHEL installation
		elsif ( $os =~ m/rhel/i ) {

			# Create directory in FTP root (/install) to hold template
			$out = `mkdir -p $installDir/custom/install/rh`;

			# Copy kickstart template
			$customTmpl = "$installDir/custom/install/rh/" . $node . "." . $profile . ".tmpl";
			if ( -e "$installDir/custom/install/rh/$tmpl" ) {
				$out = `cp $installDir/custom/install/rh/$tmpl $customTmpl`;
			}
			else {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) An kickstart template does not exist for $os in $installDir/custom/install/rh/" );
				return;
			}

			# Get pkglist from /install/custom/install/rh/compute.rhel6.s390x.otherpkgs.pkglist
			# Original one is in /opt/xcat/share/xcat/install/rh/compute.rhel6.s390x.otherpkgs.pkglist
			$pkglist = "/install/custom/install/rh/" . $profile . "." . $osBase . "." . $arch . ".pkglist";
			if ( !(-e $pkglist) ) {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing package list for $os in /install/custom/install/rh/" );
				xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Please create one or copy default one from /opt/xcat/share/xcat/install/rh/" );
				return;
			}
			
			# Read in each software pattern or package
			open (FILE, $pkglist);
			while (<FILE>) { 
				chomp;
				$_ = xCAT::zvmUtils->trimStr($_);
				$packages .= "$_\\n";
			}
			close (FILE);
			
			# Add appropriate software packages or patterns
			$out = `sed --in-place -e "s,replace_software_packages,$packages,g"  $customTmpl`;
														
			# Copy postscript into template
			$out = `sed --in-place -e "/%post/r $postScript" $customTmpl`;

			# Edit template
			my $url = "ftp://$ftp/$os/s390x/";
			$out =
`sed --in-place -e "s,replace_url,$url,g" \ -e "s,replace_ip,$hostIP,g" \ -e "s,replace_netmask,$mask,g" \ -e "s,replace_gateway,$gateway,g" \ -e "s,replace_nameserver,$nameserver,g" \ -e "s,replace_hostname,$hostname,g" \ -e "s,replace_rootpw,$passwd,g" \ -e "s,replace_master,$master,g" \ -e "s,replace_install_dir,$installDir,g" $customTmpl`;

			# Read sample parmfile in /install/rhel5.3/s390x/images
			$sampleParm = "$installDir/$os/s390x/images/generic.prm";
			open( SAMPLEPARM, "<$sampleParm" );

			# Search parmfile for -- root=/dev/ram0 ro ip=off ramdisk_size=40000
			while (<SAMPLEPARM>) {

				# If the line contains 'ramdisk_size'
				if ( $_ =~ m/ramdisk_size/i ) {
					$parmHeader = xCAT::zvmUtils->trimStr($_);
					
					# RHEL 6.1 needs cio_ignore in order to install
					if ( !($os =~ m/rhel6.1/i) ) {
						$parmHeader =~ s/cio_ignore=all,!0.0.0009//g;
					}
				}
			}

			# Close sample parmfile
			close(SAMPLEPARM);

			# Get mdisk address
			my @mdisks = xCAT::zvmUtils->getMdisks( $callback, $node );
			my $dasd   = "";
			my $i      = 0;
			foreach (@mdisks) {
				$i     = $i + 1;
				@words = split( ' ', $_ );

				# Do not put a comma at the end of the last disk address
				if ( $i == @mdisks ) {
					$dasd = $dasd . "0.0.$words[1]";
				}
				else {
					$dasd = $dasd . "0.0.$words[1],";
				}
			}

			# Create parmfile -- Limited to 80 characters/line, maximum of 11 lines
			# End result should be:
			#	ramdisk_size=40000 root=/dev/ram0 ro ip=off
			# 	ks=ftp://10.0.0.1/rhel5.3/s390x/compute.rhel5.s390x.tmpl
			#	RUNKS=1 cmdline
			#	DASD=0.0.0100 HOSTNAME=gpok4.endicott.ibm.com
			#	NETTYPE=qeth IPADDR=10.0.0.4
			#	SUBCHANNELS=0.0.0800,0.0.0801,0.0.0800
			#	NETWORK=10.0.0.0 NETMASK=255.255.255.0
			#	SEARCHDNS=endicott.ibm.com BROADCAST=10.0.0.255
			#	GATEWAY=10.0.0.1 DNS=9.0.2.11 MTU=1500
			#	PORTNAME=UNASSIGNED PORTNO=0 LAYER2=0
			#	vnc vncpassword=12345678
			my $ks = "ftp://$ftp/custom/install/rh/" . $node . "." . $profile . ".tmpl";

			$parms = $parmHeader . "\n";
			$parms = $parms . "ks=$ks\n";
			$parms = $parms . "RUNKS=1 cmdline\n";
			$parms = $parms . "DASD=$dasd HOSTNAME=$hostname\n";
			$parms = $parms . "NETTYPE=$netType IPADDR=$hostIP\n";
			$parms = $parms . "SUBCHANNELS=$readChannel,$writeChannel,$dataChannel\n";
			$parms = $parms . "NETWORK=$network NETMASK=$mask\n";
			$parms = $parms . "SEARCHDNS=$domain BROADCAST=$broadcast\n";
			$parms = $parms . "GATEWAY=$gateway DNS=$nameserver MTU=1500\n";

			# Set layer in kickstart profile
			if ( $layer == 2 ) {
				$parms = $parms . "PORTNAME=$portName PORTNO=$portNo LAYER2=1 MACADDR=$mac\n";
			}
			else {
				$parms = $parms . "PORTNAME=$portName PORTNO=$portNo LAYER2=0\n";
			}

			$parms = $parms . "vnc vncpassword=12345678\n";

			# Write to parmfile
			$parmFile = "/tmp/" . $node . "Parm";
			open( PARMFILE, ">$parmFile" );
			print PARMFILE "$parms";
			close(PARMFILE);

			# Send kernel, parmfile, conf, and initrd to reader to HCP
			$kernelFile = "/tmp/" . $node . "Kernel";
			$initFile   = "/tmp/" . $node . "Initrd";

			$out = `cp $installDir/$os/s390x/images/kernel.img $kernelFile`;
			$out = `cp $installDir/$os/s390x/images/initrd.img $initFile`;
			xCAT::zvmUtils->sendFile( $hcp, $kernelFile, $kernelFile );
			xCAT::zvmUtils->sendFile( $hcp, $parmFile,   $parmFile );
			xCAT::zvmUtils->sendFile( $hcp, $initFile,   $initFile );

			# Set the virtual unit record devices online
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", "c" );
			$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", "d" );

			# Purge reader
			$out = xCAT::zvmCPUtils->purgeReader( $hcp, $userId );
			xCAT::zvmUtils->printLn( $callback, "$node: Purging reader... Done" );

			# Punch kernel to reader on HCP
			$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $kernelFile, "rhel.kernel", "" );
			xCAT::zvmUtils->printLn( $callback, "$node: Punching kernel to reader... $out" );
			if ( $out =~ m/Failed/i ) {
				return;
			}

			# Punch parm to reader on HCP
			$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $parmFile, "rhel.parm", "-t" );
			xCAT::zvmUtils->printLn( $callback, "$node: Punching parm to reader... $out" );
			if ( $out =~ m/Failed/i ) {
				return;
			}

			# Punch initrd to reader on HCP
			$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $initFile, "rhel.initrd", "" );
			xCAT::zvmUtils->printLn( $callback, "$node: Punching initrd to reader... $out" );
			if ( $out =~ m/Failed/i ) {
				return;
			}

			# Remove kernel, parmfile, and initrd from /tmp
			$out = `rm $parmFile $kernelFile $initFile`;
			$out = `ssh -o ConnectTimeout=5 $hcp "rm $parmFile $kernelFile $initFile"`;

			xCAT::zvmUtils->printLn( $callback, "$node: Kernel, parm, and initrd punched to reader.  Ready for boot." );
		}
	}
	elsif ( $action eq "statelite" ) {

		# Get node group from 'nodelist' table
		@propNames = ('groups');
		$propVals = xCAT::zvmUtils->getTabPropsByKey( 'nodelist', 'node', $node, @propNames );
		my $group = $propVals->{'groups'};

		# Get node statemnt (statelite mount point) from 'statelite' table
		@propNames = ('statemnt');
		$propVals = xCAT::zvmUtils->getTabPropsByKey( 'statelite', 'node', $node, @propNames );
		my $stateMnt = $propVals->{'statemnt'};
		if ( !$stateMnt ) {
			$propVals = xCAT::zvmUtils->getTabPropsByKey( 'statelite', 'node', $group, @propNames );
			$stateMnt = $propVals->{'statemnt'};

			if ( !$stateMnt ) {
				xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node statemnt in statelite table. Please specify one." );
				return;
			}
		}

		# Netboot directory
		my $netbootDir = "$installDir/netboot/$os/$arch/$profile";
		my $kernelFile = "$netbootDir/kernel";
		my $parmFile   = "$netbootDir/parm-statelite";
		my $initFile   = "$netbootDir/initrd-statelite.gz";

		# If parmfile exists
		if ( -e $parmFile ) {

			# Do nothing
		}
		else {
			xCAT::zvmUtils->printLn( $callback, "$node: Creating parmfile" );

			my $sampleParm;
			my $parmHeader;
			my $parms;
			if ( $os =~ m/sles/i ) {
				if ( -e "$installDir/$os/s390x/1/boot/s390x/parmfile" ) {
					# Read sample parmfile in /install/sles11.1/s390x/1/boot/s390x/
					$sampleParm = "$installDir/$os/s390x/1/boot/s390x/parmfile";
				} else {
					xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing $installDir/$os/s390x/1/boot/s390x/parmfile" );
					return;
				}
			}
			elsif ( $os =~ m/rhel/i ) {
				if ( -e "$installDir/$os/s390x/images/generic.prm" ) {
					# Read sample parmfile in /install/rhel5.3/s390x/images
					$sampleParm = "$installDir/$os/s390x/images/generic.prm";
				} else {
					xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing $installDir/$os/s390x/images/generic.prm" );
					return;
				}
			}

			open( SAMPLEPARM, "<$sampleParm" );

			# Search parmfile for -- ramdisk_size=65536 root=/dev/ram1 ro init=/linuxrc TERM=dumb
			while (<SAMPLEPARM>) {
				# If the line contains 'ramdisk_size'
				if ( $_ =~ m/ramdisk_size/i ) {
					$parmHeader = xCAT::zvmUtils->trimStr($_);
				}
			}

			# Close sample parmfile
			close(SAMPLEPARM);

			# Create parmfile
			# End result should be:
			# 	ramdisk_size=65536 root=/dev/ram1 ro init=/linuxrc TERM=dumb
			# 	NFSROOT=10.1.100.1:/install/netboot/sles11.1.1/s390x/compute
			# 	STATEMNT=10.1.100.1:/lite/state XCAT=10.1.100.1:3001
			$parms = $parmHeader . "\n";
			$parms = $parms . "NFSROOT=$master:$netbootDir\n";
			$parms = $parms . "STATEMNT=$stateMnt XCAT=$master:$xcatdPort\n";

			# Write to parmfile
			open( PARMFILE, ">$parmFile" );
			print PARMFILE "$parms";
			close(PARMFILE);
		}

		# Temporary kernel, parmfile, and initrd
		my $tmpKernelFile = "/tmp/$os-kernel";
		my $tmpParmFile   = "/tmp/$os-parm-statelite";
		my $tmpInitFile   = "/tmp/$os-initrd-statelite.gz";

		if (`ssh -o ConnectTimeout=5 $hcp "ls /tmp" | grep "$os-kernel"`) {
			# Do nothing
		} else {
			# Send kernel to reader to HCP
			xCAT::zvmUtils->sendFile( $hcp, $kernelFile, $tmpKernelFile );
		}

		if (`ssh -o ConnectTimeout=5 $hcp "ls /tmp" | grep "$os-parm-statelite"`) {
			# Do nothing
		} else {
			# Send parmfile to reader to HCP
			xCAT::zvmUtils->sendFile( $hcp, $parmFile, $tmpParmFile );
		}

		if (`ssh -o ConnectTimeout=5 $hcp "ls /tmp" | grep "$os-initrd-statelite.gz"`) {
			# Do nothing
		} else {
			# Send initrd to reader to HCP
			xCAT::zvmUtils->sendFile( $hcp, $initFile, $tmpInitFile );
		}

		# Set the virtual unit record devices online
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", "c" );
		$out = xCAT::zvmUtils->disableEnableDisk( $callback, $hcp, "-e", "d" );

		# Purge reader
		$out = xCAT::zvmCPUtils->purgeReader( $hcp, $userId );
		xCAT::zvmUtils->printLn( $callback, "$node: Purging reader... Done" );

		# Kernel, parm, and initrd are in /install/netboot/<os>/<arch>/<profile>
		# Punch kernel to reader on HCP
		$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $tmpKernelFile, "sles.kernel", "" );
		xCAT::zvmUtils->printLn( $callback, "$node: Punching kernel to reader... $out" );
		if ( $out =~ m/Failed/i ) {
			return;
		}

		# Punch parm to reader on HCP
		$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $tmpParmFile, "sles.parm", "-t" );
		xCAT::zvmUtils->printLn( $callback, "$node: Punching parm to reader... $out" );
		if ( $out =~ m/Failed/i ) {
			return;
		}

		# Punch initrd to reader on HCP
		$out = xCAT::zvmCPUtils->punch2Reader( $hcp, $userId, $tmpInitFile, "sles.initrd", "" );
		xCAT::zvmUtils->printLn( $callback, "$node: Punching initrd to reader... $out" );
		if ( $out =~ m/Failed/i ) {
			return;
		}

		xCAT::zvmUtils->printLn( $callback, "$node: Kernel, parm, and initrd punched to reader.  Ready for boot." );
	}
	else {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Option not supported" );
		return;
	}

	return;
}

#-------------------------------------------------------

=head3   getMacs

	Description	: Get the MAC address of a given node
					* Requires the node be online
					* Saves MAC address in 'mac' table
    Arguments	: Node
    Returns		: Nothing
    Example		: getMacs($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub getMacs {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Get MAC address in 'mac' table
	@propNames = ('mac');
	$propVals = xCAT::zvmUtils->getNodeProps( 'mac', $node, @propNames );
	my $mac;
	if ( $propVals->{'mac'} ) {

		# Get MAC address
		$mac = $propVals->{'mac'};
		xCAT::zvmUtils->printLn( $callback, "$node: $mac" );
		return;
	}

	# If MAC address is not in the 'mac' table, get it using VMCP
	xCAT::zvmCPUtils->loadVmcp($node);

	# Get xCat MN Lan/VSwitch name
	my $out = `vmcp q v nic | egrep -i "VSWITCH|LAN"`;
	my @lines = split( '\n', $out );
	my @words;

	# Go through each line and extract VSwitch and Lan names
	# and create search string
	my $searchStr = "";
	my $i;
	for ( $i = 0 ; $i < @lines ; $i++ ) {

		# Extract VSwitch name
		if ( $lines[$i] =~ m/VSWITCH/i ) {
			@words = split( ' ', $lines[$i] );
			$searchStr = $searchStr . "$words[4]";
		}

		# Extract Lan name
		elsif ( $lines[$i] =~ m/LAN/i ) {
			@words = split( ' ', $lines[$i] );
			$searchStr = $searchStr . "$words[4]";
		}

		if ( $i != ( @lines - 1 ) ) {
			$searchStr = $searchStr . "|";
		}
	}

	# Get MAC address of node
	# This node should be on only 1 of the networks that the xCAT MN is on
	$out = `ssh -o ConnectTimeout=5 $node "vmcp q v nic" | egrep -i "$searchStr"`;
	if ( !$out ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Failed to find MAC address" );
		return;
	}

	@lines = split( '\n', $out );
	@words = split( ' ',  $lines[0] );
	$mac   = $words[1];

	# Replace - with :
	$mac = xCAT::zvmUtils->replaceStr( $mac, "-", ":" );
	xCAT::zvmUtils->printLn( $callback, "$node: $mac" );

	# Save MAC address and network interface into 'mac' table
	xCAT::zvmUtils->setNodeProp( 'mac', $node, 'mac', $mac );

	return;
}

#-------------------------------------------------------

=head3   netBoot

	Description	: Boot from network
    Arguments	: 	Node
    				Address to IPL from
    Returns		: Nothing
    Example		: netBoot($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub netBoot {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Get IPL
	my @ipl = split( '=', $args->[0] );
	if ( !( $ipl[0] eq "ipl" ) ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing IPL" );
		return;
	}

	# Boot node
	my $out = `ssh $hcp "$::DIR/startvs $userId"`;
	my $rc = xCAT::zvmUtils->checkOutput( $callback, $out );
	if ( $rc == -1 ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Boot failed" );
		return;
	}
	else {
		xCAT::zvmUtils->printLn( $callback, "$node: $out" );
	}

	# IPL when virtual server is online
	sleep(5);
	$out = xCAT::zvmCPUtils->sendCPCmd( $hcp, $userId, "IPL $ipl[1]" );
	xCAT::zvmUtils->printLn( $callback, "$node: Booting from $ipl[1]... Done" );

	return;
}

#-------------------------------------------------------

=head3   updateNode (No longer supported)

	Description	: Update node
    Arguments	: 	Node
    				Option
    				
    Options supported:
 		* release [updated version]
 		
    Returns		: Nothing
    Example		: updateNode($callback, $node, $args);
    
=cut

#-------------------------------------------------------
sub updateNode {

	# Get inputs
	my ( $callback, $node, $args ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ( 'hcp', 'userid' );
	my $propVals = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get zHCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing node HCP" );
		return;
	}

	# Get node user ID
	my $userId = $propVals->{'userid'};
	if ( !$userId ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing user ID" );
		return;
	}
	# Capitalize user ID
	$userId =~ tr/a-z/A-Z/;

	# Get install directory
	my $siteTab        = xCAT::Table->new('site');
	my $installDirHash = $siteTab->getAttribs( { key => "installdir" }, 'value' );
	my $installDir     = $installDirHash->{'value'};

	# Get host IP and hostname from /etc/hosts
	my $out      = `cat /etc/hosts | grep $node`;
	my @words    = split( ' ', $out );
	my $hostIP   = $words[0];
	my $hostname = $words[2];
	if ( !$hostIP || !$hostname ) {
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing IP for $node in /etc/hosts" );
		xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Verify that the node's IP address is specified in the hosts table and then run makehosts" );
		return;
	}

	# Get first 3 octets of node IP (IPv4)
	@words = split( /\./, $hostIP );
	my $octets = "$words[0].$words[1].$words[2]";

	# Get networks in 'networks' table
	my $entries = xCAT::zvmUtils->getAllTabEntries('networks');

	# Go through each network
	my $network;
	foreach (@$entries) {

		# Get network
		$network = $_->{'net'};

		# If networks contains the first 3 octets of the node IP
		if ( $network =~ m/$octets/i ) {

			# Exit loop
			last;
		}
		else {
			$network = "";
		}
	}

	# If no network found
	if ( !$network ) {

		# Exit
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Node does not belong to any network in the networks table" );
		xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Specify the subnet in the networks table. The mask, gateway, tftpserver, and nameservers must be specified for the subnet." );
		return;
	}

	# Get FTP server
	@propNames = ('tftpserver');
	$propVals = xCAT::zvmUtils->getTabPropsByKey( 'networks', 'net', $network, @propNames );
	my $ftp = $propVals->{'tftpserver'};
	if ( !$ftp ) {

		# It is acceptable to not have a gateway
		xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing FTP server" );
		xCAT::zvmUtils->printLn( $callback, "$node: (Solution) Specify the tftpserver for the subnet in the networks table" );
		return;
	}

	# Update node operating system
	if ( $args->[0] eq "--release" ) {
		my $version = $args->[1];

		if ( !$version ) {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Missing operating system release. Please specify one." );
			return;
		}

		# Get node operating system
		my $os = xCAT::zvmUtils->getOs($node);

		# Check node OS is the same as the version OS given
		# You do not want to update a SLES with a RHEL
		if ( ( ( $os =~ m/SUSE/i ) && !( $version =~ m/sles/i ) ) || ( ( $os =~ m/Red Hat/i ) && !( $version =~ m/rhel/i ) ) ) {
			xCAT::zvmUtils->printLn( $callback, "$node: (Error) Node operating system is different from the operating system given to upgrade to. Please correct." );
			return;
		}

		# Generate FTP path to operating system image
		my $path;
		if ( $version =~ m/sles/i ) {

			# The following only applies to SLES 10
			# SLES 11 requires zypper

			# SuSE Enterprise Linux path - ftp://10.0.0.1/sles10.3/s390x/1/
			$path = "ftp://$ftp/$version/s390x/1/";

			# Add installation source using rug
			$out = `ssh $node "rug sa -t zypp $path $version"`;
			xCAT::zvmUtils->printLn( $callback, "$node: $out" );

			# Subscribe to catalog
			$out = `ssh $node "rug sub $version"`;
			xCAT::zvmUtils->printLn( $callback, "$node: $out" );

			# Refresh services
			$out = `ssh $node "rug ref"`;
			xCAT::zvmUtils->printLn( $callback, "$node: $out" );

			# Update
			$out = `ssh $node "rug up -y"`;
			xCAT::zvmUtils->printLn( $callback, "$node: $out" );
		}
		else {

			# Red Hat Enterprise Linux path - ftp://10.0.0.1/rhel5.4/s390x/Server/
			$path = "ftp://$ftp/$version/s390x/Server/";

			# Check if file.repo already has this repository location
			$out = `ssh $node "cat /etc/yum.repos.d/file.repo"`;
			if ( $out =~ m/[$version]/i ) {

				# Send over release key
				my $key = "$installDir/$version/s390x/RPM-GPG-KEY-redhat-release";
				my $tmp = "/tmp/RPM-GPG-KEY-redhat-release";
				xCAT::zvmUtils->sendFile( $node, $key, $tmp );

				# Import key
				$out = `ssh $node "rpm --import /tmp/$key"`;

				# Upgrade
				$out = `ssh $node "yum upgrade -y"`;
				xCAT::zvmUtils->printLn( $callback, "$node: $out" );
			}
			else {

				# Create repository
				$out = `ssh $node "echo [$version] >> /etc/yum.repos.d/file.repo"`;
				$out = `ssh $node "echo baseurl=$path >> /etc/yum.repos.d/file.repo"`;
				$out = `ssh $node "echo enabled=1 >> /etc/yum.repos.d/file.repo"`;

				# Send over release key
				my $key = "$installDir/$version/s390x/RPM-GPG-KEY-redhat-release";
				my $tmp = "/tmp/RPM-GPG-KEY-redhat-release";
				xCAT::zvmUtils->sendFile( $node, $key, $tmp );

				# Import key
				$out = `ssh $node "rpm --import $tmp"`;

				# Upgrade
				$out = `ssh $node "yum upgrade -y"`;
				xCAT::zvmUtils->printLn( $callback, "$node: $out" );
			}
		}
	}

	# Otherwise, print out error
	else {
		$out = "$node: (Error) Option not supported";
	}

	xCAT::zvmUtils->printLn( $callback, "$out" );
	return;
}

#-------------------------------------------------------

=head3   listTree

	Description	: Show the nodes hierarchy tree
    Arguments	: Node range (zHCP)
    Returns		: Nothing
    Example		: listHierarchy($callback, $nodes, $args);
    
=cut

#-------------------------------------------------------
sub listTree {

	# Get inputs
	my ( $callback, $nodes, $args ) = @_;
	my @nodes = @$nodes;
	my $option = '';
	if ($args) {
		@ARGV = @$args;
		
		# Parse options
		GetOptions(	'o' => \$option );
	}
	
	# In order for this command to work, issue under /opt/xcat/bin: 
	# ln -s /opt/xcat/bin/xcatclient lstree
			
	my %tree;
	my $node;
	my $parent;
	my $found;
	
	# Create hierachy structure: CEC -> LPAR -> zVM -> VM
	# Get table
	my $tab = xCAT::Table->new( 'zvm', -create => 1, -autocommit => 0 );
	
	# Get CEC entries
	# There should be few of these nodes
	my @entries = $tab->getAllAttribsWhere( "nodetype = 'cec'", 'node', 'parent' );
	foreach (@entries) {
		$node = $_->{'node'};
		
		# Make CEC the tree root
		$tree{$node} = {};
	}

	# Get LPAR entries
	# There should be a couple of these nodes
	@entries = $tab->getAllAttribsWhere( "nodetype = 'lpar'", 'node', 'parent' );
	foreach (@entries) {
		$node = $_->{'node'};		# LPAR
		$parent = $_->{'parent'};	# CEC
		
		# Add LPAR branch
		$tree{$parent}{$node} = {};
	}
	
	# Get zVM entries
	# There should be a couple of these nodes
	$found = 0;
	@entries = $tab->getAllAttribsWhere( "nodetype = 'zvm'", 'node', 'parent' );
	foreach (@entries) {
		$node = $_->{'node'};		# zVM
		$parent = $_->{'parent'};	# LPAR
		
		# Find CEC root based on LPAR
		# CEC -> LPAR
		$found = 0;
		foreach my $cec(sort keys %tree) {
			foreach my $lpar(sort keys %{$tree{$cec}}) {
				if ($lpar eq $parent) {
					# Add LPAR branch
					$tree{$cec}{$parent}{$node} = {};
					$found = 1;
					last;
				}
				
				# Handle second level zVM
				foreach my $vm(sort keys %{$tree{$cec}{$lpar}}) {
					if ($vm eq $parent) {
						# Add VM branch
						$tree{$cec}{$lpar}{$parent}{$node} = {};
						$found = 1;
						last;
					}
				} # End of foreach zVM
			} # End of foreach LPAR
			
			# Exit loop if LPAR branch added
			if ($found) {
				last;
			}
		} # End of foreach CEC		
	}
	
	# Get VM entries
	# There should be many of these nodes
	$found = 0;
	@entries = $tab->getAllAttribsWhere( "nodetype = 'vm'", 'node', 'parent', 'userid' );
	foreach (@entries) {
		$node = $_->{'node'};		# VM
		$parent = $_->{'parent'};	# zVM
		
		# Skip node if it is not in noderange
		if (!xCAT::zvmUtils->inArray($node, @nodes)) {
			next;
		}
		
		# Find CEC/LPAR root based on zVM
		# CEC -> LPAR -> zVM
		$found = 0;
		foreach my $cec(sort keys %tree) {
			foreach my $lpar(sort keys %{$tree{$cec}}) {
				foreach my $zvm(sort keys %{$tree{$cec}{$lpar}}) {
					if ($zvm eq $parent) {
						# Add zVM branch
						$tree{$cec}{$lpar}{$parent}{$node} = $_->{'userid'};
						$found = 1;
						last;
					}
					
					# Handle second level zVM
					foreach my $vm(sort keys %{$tree{$cec}{$lpar}{$zvm}}) {
						if ($vm eq $parent) {
							# Add VM branch
							$tree{$cec}{$lpar}{$zvm}{$parent}{$node} = $_->{'userid'};
							$found = 1;
							last;
						}
					} # End of foreach VM
				} # End of foreach zVM
				
				# Exit loop if zVM branch added
				if ($found) {
					last;
				}
			} # End of foreach LPAR
			
			# Exit loop if zVM branch added
			if ($found) {
				last;
			}
		} # End of foreach CEC
	} # End of foreach VM node

	# Print tree
	# Loop through CECs
	foreach my $cec(sort keys %tree) {
		xCAT::zvmUtils->printLn( $callback, "CEC: $cec" );
		
		# Loop through LPARs
		foreach my $lpar(sort keys %{$tree{$cec}}) {
			xCAT::zvmUtils->printLn( $callback, "|__LPAR: $lpar" );
			
			# Loop through zVMs
			foreach my $zvm(sort keys %{$tree{$cec}{$lpar}}) {
				xCAT::zvmUtils->printLn( $callback, "   |__zVM: $zvm" );
				
				# Loop through VMs
				foreach my $vm(sort keys %{$tree{$cec}{$lpar}{$zvm}}) {
					# Handle second level zVM
					if (ref($tree{$cec}{$lpar}{$zvm}{$vm}) eq 'HASH') {
						xCAT::zvmUtils->printLn( $callback, "      |__zVM: $vm" );
						foreach my $vm2(sort keys %{$tree{$cec}{$lpar}{$zvm}{$vm}}) {
							xCAT::zvmUtils->printLn( $callback, "         |__VM: $vm2 ($tree{$cec}{$lpar}{$zvm}{$vm}{$vm2})" );
						}
					} else {
						xCAT::zvmUtils->printLn( $callback, "      |__VM: $vm ($tree{$cec}{$lpar}{$zvm}{$vm})" );
					}
				} # End of foreach VM
			} # End of foreach zVM
		} # End of foreach LPAR
	} # End of foreach CEC
	return;
}