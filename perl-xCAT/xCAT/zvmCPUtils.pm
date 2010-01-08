# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#-------------------------------------------------------

=head1

	This is a CP utility plugin for z/VM.

=cut

#-------------------------------------------------------
package xCAT::zvmCPUtils;
use xCAT::zvmUtils;
use strict;
use warnings;
1;

#-------------------------------------------------------

=head3   getUserId

	Description	: Get userID of given node
    Arguments	: Node
    Returns		: UserID
    Example		: my $userID = xCAT::zvmCPUtils->getUserId($node);
    
=cut

#-------------------------------------------------------
sub getUserId {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get userId using VMCP
	my $out     = `ssh -o ConnectTimeout=5 $node "vmcp q userid"`;
	my @results = split( ' ', $out );

	return ( $results[0] );
}

#-------------------------------------------------------

=head3   getHost

	Description	: Get z/VM host for given node
    Arguments	: Node
    Returns		: z/VM host
    Example		: my $host = xCAT::zvmCPUtils->getHost($node);
    
=cut

#-------------------------------------------------------
sub getHost {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get host using VMCP
	my $out     = `ssh -o ConnectTimeout=5 $node "vmcp q userid"`;
	my @results = split( ' ', $out );
	my $host    = $results[2];

	return ($host);
}

#-------------------------------------------------------

=head3   getPrivileges

	Description	: Get privilege class of given node
    Arguments	: Node
    Returns		: Privilege class
    Example		: my $memory = xCAT::zvmCPUtils->getPrivileges($node);
    
=cut

#-------------------------------------------------------
sub getPrivileges {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get privilege class
	my $out = `ssh -o ConnectTimeout=5 $node "vmcp q priv"`;
	my @out = split( '\n', $out );
	$out[1] = xCAT::zvmUtils->trimStr( $out[1] );
	$out[2] = xCAT::zvmUtils->trimStr( $out[2] );
	my $str = "    $out[1]\n    $out[2]\n";

	return ($str);
}

#-------------------------------------------------------

=head3   getMemory

	Description	: Get memory of given node
    Arguments	: Node
    Returns		: Memory
    Example		: my $memory = xCAT::zvmCPUtils->getMemory($node);
    
=cut

#-------------------------------------------------------
sub getMemory {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get memory
	my $out = `ssh -o ConnectTimeout=5 $node "vmcp q virtual storage"`;
	my @out = split( '=', $out );

	return ( xCAT::zvmUtils->trimStr( $out[1] ) );
}

#-------------------------------------------------------

=head3   getCpu

	Description	: Get processor(s) of given node
    Arguments	: Node
    Returns		: Processor(s)
    Example		: my $proc = xCAT::zvmCPUtils->getCpu($node);
    
=cut

#-------------------------------------------------------
sub getCpu {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get processors
	my $out = `ssh -o ConnectTimeout=5 $node "vmcp q virtual cpus"`;
	my $str = xCAT::zvmUtils->tabStr($out);

	return ($str);
}

#-------------------------------------------------------

=head3   getNic

	Description	: Get network interface card (NIC) of given node
    Arguments	: Node
    Returns		: NIC(s)
    Example		: my $nic = xCAT::zvmCPUtils->getNic($node);
    
=cut

#-------------------------------------------------------
sub getNic {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get NIC
	my $out = `ssh -o ConnectTimeout=5 $node "vmcp q virtual nic"`;
	my $str = xCAT::zvmUtils->tabStr($out);

	return ($str);
}

#-------------------------------------------------------

=head3   getDisks

	Description	: Get disk(s) of given node
    Arguments	: Node
    Returns		: Disk(s)
    Example		: my $storage = xCAT::zvmCPUtils->getDisks($node);
    
=cut

#-------------------------------------------------------
sub getDisks {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get disks
	my $out = `ssh -o ConnectTimeout=5 $node "vmcp q virtual dasd"`;
	my $str = xCAT::zvmUtils->tabStr($out);

	return ($str);
}

#-------------------------------------------------------

=head3   loadVmcp

	Description	: Load VMCP module on specified node
    Arguments	: Node
    Returns		: Nothing
    Example		: xCAT::zvmCPUtils->loadVmcp($node);
    
=cut

#-------------------------------------------------------
sub loadVmcp {

	# Get inputs
	my ( $class, $node ) = @_;

	# Load Linux VMCP module
	my $out = `ssh -o ConnectTimeout=5 $node "modprobe vmcp"`;
	return;
}

#-------------------------------------------------------

=head3   getVswitchId

	Description	: Get VSWITCH ID of given node
    Arguments	: Node
    Returns		: VSwitch IDs
    Example		: my @vswitch = xCAT::zvmCPUtils->getVswitchId($node);
    
=cut

#-------------------------------------------------------
sub getVswitchId {

	# Get inputs
	my ( $class, $node ) = @_;

	# Get VSwitch
	my $out = `ssh -o ConnectTimeout=5 $node "vmcp q nic" | grep "VSWITCH"`;
	my @lines = split( '\n', $out );
	my @parms;
	my @vswitch;
	foreach (@lines) {
		@parms = split( ' ', $_ );
		push( @vswitch, $parms[4] );
	}

	return @vswitch;
}

#-------------------------------------------------------

=head3   grantVSwitch

	Description	: Grant access to virtual switch (VSWITCH) for given userID
    Arguments	: 	HCP node
    				User ID 
    				VSWITCH ID
    Returns		: Operation results (Done/Failed)
    Example		: my $out = xCAT::zvmCPUtils->grantVswitch($callback, $hcp, $userId, $vswitchId);
    
=cut

#-------------------------------------------------------
sub grantVSwitch {

	# Get inputs
	my ( $class, $callback, $hcp, $userId, $vswitchId ) = @_;

	# Grant VSwitch for specified userID
	my $out = `ssh $hcp "vmcp set vswitch $vswitchId grant $userId"`;
	$out = xCAT::zvmUtils->trimStr($out);

	# If return string contains 'Command complete' -- Operation was successful
	my $retStr;
	if ( $out =~ m/Command complete/i ) {
		$retStr = "Done\n";
	}
	else {
		$retStr = "Failed\n";
		return $retStr;
	}

	return $retStr;
}

#-------------------------------------------------------

=head3   flashCopy

	Description	: Flash copy (Class B users only)
    Arguments	: 	Node
    				Source address
    				Target address
    Returns		: Operation results (Done/Failed)
    Example		: my $results = xCAT::zvmCPUtils->flashCopy($node, $srcAddr, $targetAddr);
    
=cut

#-------------------------------------------------------
sub flashCopy {

	# Get inputs
	my ( $class, $node, $srcAddr, $targetAddr ) = @_;

	# Flash copy
	my $out = `ssh $node "vmcp flashcopy $srcAddr 0 end to $targetAddr 0 end"`;
	$out = xCAT::zvmUtils->trimStr($out);

	# If return string contains 'Command complete' -- Operation was successful
	my $retStr = "";
	if ( $out =~ m/Command complete/i ) {
		$retStr = "Done\n";
	}
	else {
		$retStr = "Failed\n";
	}

	return $retStr;
}

#-------------------------------------------------------

=head3   punch2Reader

	Description	: Write file to z/VM punch and transfer it to reader
    Arguments	: 	HCP node
    				UserID to receive file
    				Source file
    				Target file name and type to be created by punch (e.g. sles.parm)
    				Options (e.g. -t -- Convert EBCDIC to ASCII)
    Returns		: Operation results (Done/Failed)
    Example		: my $rc = xCAT::zvmCPUtils->punch2Reader($hcp, $userId, $srcFile, $trgtFile, $options);
    
=cut

#-------------------------------------------------------
sub punch2Reader {
	my ( $class, $hcp, $userId, $srcFile, $trgtFile, $options ) = @_;

	# Punch to reader
	my $out = `ssh -o ConnectTimeout=5 $hcp "vmur punch $options -u $userId -r $srcFile -N $trgtFile"`;

	# If punch is successful -- Look for this string
	my $searchStr = "created and transferred";
	if ( !( $out =~ m/$searchStr/i ) ) {
		$out = "Failed\n";
	}
	else {
		$out = "Done\n";
	}

	return $out;
}

#-------------------------------------------------------

=head3   purgeReader

	Description	: 	Purge reader (Class D users only)
    Arguments	: 	HCP node
    				UserID to purge reader for
    Returns		: 	Nothing
    Example		: my $rc = xCAT::zvmCPUtils->purgeReader($hcp, $userId);
    
=cut

#-------------------------------------------------------
sub purgeReader {
	my ( $class, $hcp, $userId ) = @_;

	# Purge reader
	my $out = `ssh -o ConnectTimeout=5 $hcp "vmcp purge $userId rdr all"`;

	return;
}

#-------------------------------------------------------

=head3   sendCPCmd

	Description	: 	Send CP command to given userID (Class C users only)
    Arguments	: 	HCP node
    				UserID to send CP command
    Returns		: 	Nothing
    Example		: xCAT::zvmCPUtils->sendCPCmd($hcp, $userId, $cmd);
    
=cut

#-------------------------------------------------------
sub sendCPCmd {
	my ( $class, $hcp, $userId, $cmd ) = @_;

	# Send CP command to given userID
	my $out = `ssh $hcp "vmcp send cp $userId $cmd"`;

	return;
}

#-------------------------------------------------------

=head3   getNetworkLayer

	Description	: 	Get the network layer for a given node
    Arguments	: 	Node
    				Network name (Optional)
    Returns		: 	2 	-- Layer 2
    				3 	-- Layer 3
    				-1 	-- Failed to get network layer
    Example		: my $layer = xCAT::zvmCPUtils->getNetworkLayer($node);
    
=cut

#-------------------------------------------------------
sub getNetworkLayer {
	my ( $class, $node, $netName ) = @_;

	# Get node properties from 'zvm' table
	my @propNames = ('hcp');
	my $propVals  = xCAT::zvmUtils->getNodeProps( 'zvm', $node, @propNames );

	# Get HCP
	my $hcp = $propVals->{'hcp'};
	if ( !$hcp ) {
		return -1;
	}

	# Get network name
	my $out   = `ssh -o ConnectTimeout=5 $node "vmcp q v nic" | egrep -i "VSWITCH|LAN"`;
	my @lines = split( '\n', $out );

	# Go through each line and extract VSwitch and Lan names
	# Get the first network name found
	if ( !$netName ) {
		my $i;
		my @vars;
		for ( $i = 0 ; $i < @lines ; $i++ ) {

			# Extract VSwitch name
			if ( $lines[$i] =~ m/VSWITCH/i ) {
				@vars = split( ' ', $lines[$i] );
				$netName = $vars[4];
				last;
			}

			# Extract Lan name
			elsif ( $lines[$i] =~ m/LAN/i ) {
				@vars = split( ' ', $lines[$i] );
				$netName = $vars[4];
				last;
			}
		}    # End of for
	}    # End of if ( !$netName )

	# If the network name could not be found
	if ( !$netName ) {
		return -1;
	}

	# Get network type (Layer 2 or 3)
	$out = `ssh -o ConnectTimeout=5 $hcp "vmcp q lan $netName"`;
	if ( !$out ) {
		return -1;
	}

	# Go through each line
	my $layer = 3;    # Default to layer 3
	@lines = split( '\n', $out );
	foreach (@lines) {

		# If the line contains ETHERNET, then it is a layer 2 network
		if ( $_ =~ m/ETHERNET/i ) {
			$layer = 2;
		}
	}

	return $layer;
}

#-------------------------------------------------------

=head3   getNetworkType

	Description	: 	Get the network type for a given network name
    Arguments	: 	HCP node
    				Name of network
    Returns		: 	Network type (VSWITCH/HIPERS/QDIO)
    Example		: my $netType = xCAT::zvmCPUtils->getNetworkType($hcp, $netName);
    
=cut

#-------------------------------------------------------
sub getNetworkType {
	my ( $class, $hcp, $netName ) = @_;

	# Get network details
	my $out = `ssh -o ConnectTimeout=5 $hcp "vmcp q lan $netName" | grep "Type"`;

	# Go through each line and determine network type
	my @lines = split( '\n', $out );
	my $netType = "";
	foreach (@lines) {

		# Virtual switch
		if ( $_ =~ m/VSWITCH/i ) {
			$netType = "VSWITCH";
		}

		# HiperSocket guest LAN
		elsif ( $_ =~ m/HIPERS/i ) {
			$netType = "HIPERS";
		}

		# QDIO guest LAN
		elsif ( $_ =~ m/QDIO/i ) {
			$netType = "QDIO";
		}
	}

	return $netType;
}
