# IBM(c) 2010 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::dhcp;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";

use strict;
use xCAT::Table;
use Data::Dumper;
use MIME::Base64;
use Getopt::Long;
Getopt::Long::Configure("bundling");
Getopt::Long::Configure("pass_through");
use Socket;
my $candoipv6 = eval {
    require Socket6;
    1;
};
use Sys::Syslog;
use IPC::Open2;
use xCAT::NetworkUtils qw/getipaddr/;
use xCAT::Utils;
use xCAT::NodeRange;
use Fcntl ':flock';

my @aixcfg;  # hold AIX entries created by NIM
my @dhcpconf; #Hold DHCP config file contents to be written back.
my @dhcp6conf; #ipv6 equivalent
my @nrn;      # To hold output of networks table to be consulted throughout process
my @nrn6; #holds ip -6 route output on Linux, yeah, name doesn't make much sense now..
my $domain;
my $omshell;
my $omshell6; #separate session to DHCPv6 instance of dhcp
my $statements;    #Hold custom statements to be slipped into host declarations
my $callback;
my $restartdhcp;
my $restartdhcp6;
my $sitenameservers;
my $sitentpservers;
my $sitelogservers;
my $nrhash;
my $machash;
my $vpdhash;
my $iscsients;
my $nodetypeents;
my $chainents;
my $tftpdir = xCAT::Utils->getTftpDir();
use Math::BigInt;
my $dhcpconffile = $^O eq 'aix' ? '/etc/dhcpsd.cnf' : '/etc/dhcpd.conf'; 
my %dynamicranges; #track dynamic ranges defined to see if a host that resolves is actually a dynamic address
my %netcfgs;
my $distro = xCAT::Utils->osver();

# dhcp 4.x will use /etc/dhcp/dhcpd.conf as the config file
my $dhcp6conffile;
if ( $^O ne 'aix' and -d "/etc/dhcp" ) {
    $dhcpconffile = '/etc/dhcp/dhcpd.conf';
    $dhcp6conffile = '/etc/dhcp/dhcpd6.conf'; 
}
my $usingipv6;

# is this ubuntu ?
if ( $distro =~ /ubuntu*/ ){
	$dhcpconffile = '/etc/dhcp3/dhcpd.conf';	
}

sub check_uefi_support {
	my $ntent = shift;
	my %blacklist = (
		"win2k3.*" => 1,
		"winxp.*" => 1,
		"SL5.*" => 1,
		"rhels5.*" => 1,
		"centos5.*" => 1,
		"sl5.*" => 1,
		"sles10.*" => 1,
		"esxi4.*" => 1);
	if ($ntent and $ntent->{os}) {
		 foreach (keys %blacklist) {
			if ($ntent->{os} =~ /$_/) {
				return 0;
			}
		}
	}
	if ($ntent->{os} =~ /win/) { #UEFI support is a tad different, need to punt..
		return 2;
	}
	return 1;
}


sub ipIsDynamic { 
	#meant to be v4/v6 agnostic.  DHCPv6 however takes some care to allow a dynamic range to overlap static reservations
    #xCAT will for now continue to advise people to keep their nodes out of the dynamic range
    my $ip = shift;
    my $number = getipaddr($ip,GetNumber=>1);
    unless ($number) { # shouldn't be possible, but pessimistically presume it dynamically if so
        return 1;
    }
    foreach (values %dynamicranges) {
        if ($_->[0] <= $number and $_->[1] >= $number) {
            return 1;
        } 
    }
    return 0; #it isn't in any of the dynamic ranges we are aware of
}

sub handled_commands
{
    return {makedhcp => "dhcp",};
}

sub delnode
{
    my $node  = shift;
    my $inetn = inet_aton($node);

    my $mactab = xCAT::Table->new('mac');
    my $ent;
    if ($machash) { $ent = $machash->{$node}->[0]; }
    if ($ent and $ent->{mac})
    {
        my @macs = split(/\|/, $ent->{mac});
        my $mace;
        foreach $mace (@macs)
        {
            my $mac;
            my $hname;
            ($mac, $hname) = split(/!/, $mace);
            unless ($hname) { $hname = $node; }
            print $omshell "new host\n";
            print $omshell
              "set name = \"$hname\"\n";    #Find and destroy conflict name
            print $omshell "open\n";
            print $omshell "remove\n";
            print $omshell "close\n";

            if ($mac)
            {
                print $omshell "new host\n";
                print $omshell "set hardware-address = " . $mac
                  . "\n";                   #find and destroy mac conflict
                print $omshell "open\n";
                print $omshell "remove\n";
                print $omshell "close\n";
            }
            if ($inetn)
            {
                my $ip;
                if (inet_aton($hname))
                {
                    $ip = inet_ntoa(inet_aton($hname));
                }
                if ($ip)
                {
                    print $omshell "new host\n";
                    print $omshell
                      "set ip-address = $ip\n";    #find and destroy ip conflict
                    print $omshell "open\n";
                    print $omshell "remove\n";
                    print $omshell "close\n";
                }
            }
        }
    }
    print $omshell "new host\n";
    print $omshell "set name = \"$node\"\n";    #Find and destroy conflict name
    print $omshell "open\n";
    print $omshell "remove\n";
    print $omshell "close\n";
    if ($inetn)
    {
        my $ip = inet_ntoa(inet_aton($node));
        unless ($ip) { return; }
        print $omshell "new host\n";
        print $omshell "set ip-address = $ip\n";   #find and destroy ip conflict
        print $omshell "open\n";
        print $omshell "remove\n";
        print $omshell "close\n";
    }
}

sub addnode6 {
    #omshell to add host dynamically
    my $node = shift;
    unless ($vpdhash) { 
        $callback->({node=>{name=>[$node],warning => ["Skipping DHCPv6 setup due to missing vpd.uuid information."]}});
        return;
    }
    my $ent = $vpdhash->{$node}->[0]; #tab->getNodeAttribs($node, [qw(mac)]);
    unless ($ent and $ent->{uuid})
    {
        $callback->({node=>{name=>[$node],warning => ["Skipping DHCPv6 setup due to missing vpd.uuid information."]}});
        return;
    }
    #phase 1, dynamic and static addresses, hopefully ddns-hostname works, may be tricky to do 'send hostname'
    #since FQDN is the only thing to be sent down, and that RFC clearly suggests that the client
    #assembles that data, not host
    #tricky for us since the client wouldn't know it's hostname/fqdn in advance
    #unless acquired via IPv4 first
    #don't think dhclient is smart enough to assemble advertised domain with it's own name and then
    #request FQDN update
    #goal is simple enough, we want `hostname` to look sane *and* we want DNS to look right
    my $uuid = $ent->{uuid};
    $uuid =~ s/-//g;
    $uuid =~ s/(..)/$1:/g;
    $uuid =~ s/:\z//;
    $uuid =~ s/^/00:04:/;
    my $ip = getipaddr($node);
    if ($ip and $ip =~ /:/ and not ipIsDynamic($ip)) {
        $ip = getipaddr($ip,GetNumber=>1);
        $ip = $ip->as_hex;
        $ip =~ s/^0x//;
        $ip =~ s/(..)/$1:/g;
        $ip =~ s/:\z//;
        print $omshell6 "set ip-address = $ip\n";
    } else {
        $ip=0;
    }
    print $omshell6 "new host\n";
    print $omshell6 "set name = \"$node\"\n";    #Find and destroy conflict name
    print $omshell6 "open\n";
    print $omshell6 "remove\n";
    print $omshell6 "close\n";
    if ($ip) {
        print $omshell6 "new host\n";
        print $omshell6 "set ip-address = $ip\n";   #find and destroy ip conflict
        print $omshell6 "open\n";
        print $omshell6 "remove\n";
        print $omshell6 "close\n";
    }
    print $omshell6 "new host\n";
    print $omshell6 "set dhcp-client-identifier = " . $uuid . "\n";    #find and destroy DUID-UUID conflict
    print $omshell6 "open\n";
    print $omshell6 "remove\n";
    print $omshell6 "close\n";
    print $omshell6 "new host\n";
    print $omshell6 "set name = \"$node\"\n";
    print $omshell6 "set dhcp-client-identifier = $uuid\n";
    print $omshell6 'set statements = "ddns-hostname \"'.$node.'\";";'."\n";
    if ($ip) {
        print $omshell6 "set ip-address = $ip\n";
    }
    print $omshell6 "create\n";
    print $omshell6 "close\n";

}

sub addnode
{

    #Use omshell to add the node.
    #the process used is blind typing commands that should work
    #it tries to delet any conflicting entries matched by name and
    #hardware address and ip address before creating a brand now one
    #unfortunate side effect: dhcpd.leases can look ugly over time, when
    #doing updates would keep it cleaner, good news, dhcpd restart cleans
    #up the lease file the way we would want anyway.
    my $node = shift;
    my $ent;
    my $nrent;
    my $chainent;
    my $ient;
    my $ntent;
    my $tftpserver;
    if ($chainents and $chainents->{$node}) {
        $chainent = $chainents->{$node}->[0];
    }
    if ($iscsients and $iscsients->{$node}) {
        $ient = $iscsients->{$node}->[0];
    }
    if ($nodetypeents and $nodetypeents->{$node}) {
	$ntent = $nodetypeents->{$node}->[0];
    }
    my $lstatements       = $statements;
    my $guess_next_server = 0;
    my $nxtsrv;
    if ($nrhash)
    {
        $nrent = $nrhash->{$node}->[0];
        if ($nrent and $nrent->{tftpserver})
        {
            #check the value of inet_ntoa(inet_aton("")),if the hostname cannot be resolved,
            #the value of inet_ntoa() will be "undef", which will cause fatal error
            my $tmp_name = inet_aton($nrent->{tftpserver});
            unless($tmp_name) {
                #tell the reason to the user
                $callback->(
                    { error => ["Unable to resolve the tftpserver for node"], errorcode => [1]}
                );
                return;
            }
            $tftpserver = inet_ntoa($tmp_name);
            $nxtsrv = $tftpserver;
            $lstatements =
                'next-server '
              . $tftpserver . ';'
              . $statements;
        }
        else
        {
            $guess_next_server = 1;
        }

        #else {
        # $nrent = $nrtab->getNodeAttribs($node,['servicenode']);
        # if ($nrent and $nrent->{servicenode}) {
        #  $statements = 'next-server  = \"'.inet_ntoa(inet_aton($nrent->{servicenode})).'\";'.$statements;
        # }
        #}
    }
    else
    {
        $guess_next_server = 1;
    }
    unless ($machash)
    {
        $callback->(
                   {
                    warning => ["Unable to open mac table, it may not exist yet"]
                   }
                   );
        return;
    }
    $ent = $machash->{$node}->[0]; #tab->getNodeAttribs($node, [qw(mac)]);
    unless ($ent and $ent->{mac})
    {
        $callback->(
                    {
                     warning => ["Unable to find mac address for $node"]
                    }
                    );
        return;
    }
    my @macs = split(/\|/, $ent->{mac});
    my $mace;
    my $deflstaments=$lstatements;
    my $count = 0;
    foreach $mace (@macs)
    {
        $lstatements=$deflstaments; #force recalc on every entry
        my $mac;
        my $hname;
        $hname = "";
        ($mac, $hname) = split(/!/, $mace);
        unless ($hname)
        {
            $hname = $node;
        }    #Default to hostname equal to nodename
        unless ($mac) { next; }    #Skip corrupt format
        my $ip = getipaddr($hname,OnlyV4=>1);
        if ($hname eq '*NOIP*') {
            $hname = $node . "-noip".$mac;
            $hname =~ s/://g;
            $ip='DENIED';
#        } #if 'guess_next_server', inherit from the network provided value... see how this pans out
#       if ($guess_next_server and $ip and $ip ne "DENIED")
#       {
#           $nxtsrv = xCAT::Utils->my_ip_facing($hname);
#           if ($nxtsrv)
#           {
#               $tftpserver = $nxtsrv;
#               $lstatements = "next-server $nxtsrv;$statements";
#           } #of course, we set the xNBA variable to let that propogation carry forward into filename uri interpolation
        } elsif ($guess_next_server) {
            $nxtsrv='${next-server}'; #if floating IP support, cause gPXE command-line expansion patch to drive inheritence from network
        }
        my $doiscsi=0;
        if ($ient and $ient->{server} and $ient->{target}) {
            $doiscsi=1;
            unless (defined ($ient->{lun})) { #Some firmware fails to properly implement the spec, so we must explicitly say zero for such firmware
                $ient->{lun} = 0;
            }
            my $iscsirootpath ='iscsi:'.$ient->{server}.':6:3260:'.$ient->{lun}.':'.$ient->{target};
            if (defined ($ient->{iname})) { #Attempt to use gPXE or IBM iSCSI formats to specify the initiator
                #This all goes on one line, but will break it out to at least be readable in here
                $lstatements = 'if option vendor-class-identifier = \"ISAN\" { ' #This is declared by IBM iSCSI initiators, will call it 'ISAN' mode
                                   .'option isan.iqn \"'.$ient->{iname}.'\"; '  #Use vendor-spcefic option to declare the expected Initiator name
                                   .'option isan.root-path \"'.$iscsirootpath.'\"; ' #We must *not* use standard root-path if using ISAN style options
                              .'} else { '
                                   .'option root-path \"'.$iscsirootpath.'\"; ' #For everything but ISAN, use standard, RFC defined behavior for root
                                   .'if exists gpxe.bus-id { '  #Since our iscsi-initiator-iqn is in no way a standardized thing, only use it for gPXE
                                       . ' option iscsi-initiator-iqn \"'.$ient->{iname}.'\";' #gPXE will consider option 203 for initiator IQN
                                   . '}'
                             . '}'
                             .$lstatements;
                print $lstatements;
            } else { #We stick to the good old RFC defined behavior, ISAN, gPXE, everyone should be content with this so long as no initiator name need be specified
                $lstatements = 'option root-path \"'.$iscsirootpath.'\";'.$lstatements;
            }
        }
        my $douefi=check_uefi_support($ntent);
        if ($nrent and $nrent->{netboot} and $nrent->{netboot} eq 'xnba' and $lstatements !~ /filename/) {
            if (-f "$tftpdir/xcat/xnba.kpxe") {
                if ($doiscsi and $chainent and $chainent->{currstate} and ($chainent->{currstate} eq 'iscsiboot' or $chainent->{currstate} eq 'boot')) {
                    $lstatements = 'if option client-architecture = 00:00 and not gpxe.bus-id { filename = \"xcat/xnba.kpxe\"; } else { filename = \"\"; } '.$lstatements;
                } else {
			#TODO: if windows uefi, do vendor-class-identifier of "PXEClient" to bump it over to proxydhcp.c
		    if (($douefi == 2 and $chainent->{currstate} =~ /^install/) or $chainent->{currstate} =~ /^winshell/) { #proxy dhcp required in uefi invocation
                        $lstatements = 'if option user-class-identifier = \"xNBA\" and option client-architecture = 00:00 { always-broadcast on; filename = \"http://'.$nxtsrv.'/tftpboot/xcat/xnba/nodes/'.$node.'\"; } else if option client-architecture = 00:07 or option client-architecture = 00:09 { filename = \"\"; option vendor-class-identifier \"PXEClient\"; } else if option client-architecture = 00:00 { filename = \"xcat/xnba.kpxe\"; } else { filename = \"\"; }'.$lstatements; #Only PXE compliant clients should ever receive xNBA
		    } elsif ($douefi and $chainent->{currstate} ne "boot" and $chainent->{currstate} ne "iscsiboot") {
                        $lstatements = 'if option user-class-identifier = \"xNBA\" and option client-architecture = 00:00 { always-broadcast on; filename = \"http://'.$nxtsrv.'/tftpboot/xcat/xnba/nodes/'.$node.'\"; } else if option user-class-identifier = \"xNBA\" and option client-architecture = 00:09 { filename = \"http://'.$nxtsrv.'/tftpboot/xcat/xnba/nodes/'.$node.'.uefi\"; } else if option client-architecture = 00:07 { filename = \"xcat/xnba.efi\"; } else if option client-architecture = 00:00 { filename = \"xcat/xnba.kpxe\"; } else { filename = \"\"; }'.$lstatements; #Only PXE compliant clients should ever receive xNBA
		    } else {
                        $lstatements = 'if option user-class-identifier = \"xNBA\" and option client-architecture = 00:00 { filename = \"http://'.$nxtsrv.'/tftpboot/xcat/xnba/nodes/'.$node.'\"; } else if option client-architecture = 00:00 { filename = \"xcat/xnba.kpxe\"; } else { filename = \"\"; }'.$lstatements; #Only PXE compliant clients should ever receive xNBA
		   }
                } 
            } #TODO: warn when windows
        } elsif ($nrent and $nrent->{netboot} and $nrent->{netboot} eq 'pxe' and $lstatements !~ /filename/) {
            if (-f "$tftpdir/xcat/xnba.kpxe") {
                if ($doiscsi and $chainent and $chainent->{currstate} and ($chainent->{currstate} eq 'iscsiboot' or $chainent->{currstate} eq 'boot')) {
                    $lstatements = 'if exists gpxe.bus-id { filename = \"\"; } else if exists client-architecture { filename = \"xcat/xnba.kpxe\"; } '.$lstatements;
                } else {
                    $lstatements = 'if option vendor-class-identifier = \"ScaleMP\" { filename = \"vsmp/pxelinux.0\"; } else { filename = \"pxelinux.0\"; }'.$lstatements;
                }
            }
        }


        if ( $^O eq 'aix')
        {
            addnode_aix( $ip, $mac, $hname, $tftpserver);
        }
        else
        {
            if ( !grep /:/,$mac ) {
                $mac = lc($mac);
                $mac =~ s/(\w{2})/$1:/g;
                $mac =~ s/:$//;
            }
            my $hostname = $hname;
            my $hardwaretype = 1;
            my %client_nethash = xCAT::DBobjUtils->getNetwkInfo( [$node] );
            if ( $client_nethash{$node}{mgtifname} =~ /hf/ )
            {
                $hardwaretype = 37;
                if ( scalar(@macs) > 1 ) {
                    if ( $hname !~ /^(.*)-hf(.*)$/ ) {
                        $hostname = $hname . "-hf" . $count;
                    } else {
                        $hostname = $1 . "-hf" . $count;
                    }
                }
            }

            #syslog("local4|err", "Setting $node ($hname|$ip) to " . $mac);
            print $omshell "new host\n";
            print $omshell
                "set name = \"$hostname\"\n";    #Find and destroy conflict name
                print $omshell "open\n";
            print $omshell "remove\n";
            print $omshell "close\n";
            if ($ip and $ip ne 'DENIED') {
                print $omshell "new host\n";
                print $omshell "set ip-address = $ip\n";   #find and destroy ip conflict
                    print $omshell "open\n";
                print $omshell "remove\n";
                print $omshell "close\n";
            }
            print $omshell "new host\n";
            print $omshell "set hardware-address = " . $mac
                . "\n";    #find and destroy mac conflict
                print $omshell "open\n";
            print $omshell "remove\n";
            print $omshell "close\n";
            print $omshell "new host\n";
            print $omshell "set name = \"$hostname\"\n";
            print $omshell "set hardware-address = " . $mac . "\n";
            print $omshell "set hardware-type = $hardwaretype\n";

            if ($ip eq "DENIED")
            { #Blacklist this mac to preclude confusion, give best shot at things working
                print $omshell "set statements = \"deny booting;\"\n";
            }
            else
            {
                if ($ip and not ipIsDynamic($ip)) {
                    print $omshell "set ip-address = $ip\n";
                }
                if ($lstatements)
                {
                    $lstatements = 'ddns-hostname \"'.$node.'\"; send host-name \"'.$node.'\";'.$lstatements;

                } else {
                    $lstatements = 'ddns-hostname \"'.$node.'\"; send host-name \"'.$node.'\";';
                }
                print $omshell "set statements = \"$lstatements\"\n";
            }

            print $omshell "create\n";
            print $omshell "close\n";
            unless (grep /#definition for host $node aka host $hostname/, @dhcpconf)
            {
                push @dhcpconf,
                     "#definition for host $node aka host $hostname can be found in the dhcpd.leases file\n";
            }
        }
        $count = $count + 2;
    }
}

sub addrangedetection {
    my $net = shift;
    my $tranges = $net->{dynamicrange}; #temp range, the dollar sign makes it look strange
    my $trange;
    my $begin;
    my $end;
    my $myip;
    $myip = xCAT::Utils->my_ip_facing($net->{net});
    
    # convert <xcatmaster> to nameserver IP
    if ($net->{nameservers} eq '<xcatmaster>')
    {
        $netcfgs{$net->{net}}->{nameservers} = $myip;
    }
    else
    {
        $netcfgs{$net->{net}}->{nameservers} = $net->{nameservers};
    }
    
    $netcfgs{$net->{net}}->{ddnsdomain} = $net->{ddnsdomain};
    $netcfgs{$net->{net}}->{domain} = $domain; #TODO: finer grained domains
    unless ($netcfgs{$net->{net}}->{nameservers}) {
        # convert <xcatmaster> to nameserver IP
        if ($::XCATSITEVALS{nameservers} eq '<xcatmaster>')
        {
            $netcfgs{$net->{net}}->{nameservers} = $myip;
        }
        else
        {
            $netcfgs{$net->{net}}->{nameservers} = $::XCATSITEVALS{nameservers};
        }
    }
    foreach $trange (split /;/,$tranges) {
        if ($trange =~ /[ ,-]/) { #a range of one number to another..
           $trange =~ s/[,-]/ /g;
           $netcfgs{$net->{net}}->{range}=$trange; 
           ($begin,$end) = split / /,$trange;
           $dynamicranges{$trange}=[getipaddr($begin,GetNumber=>1),getipaddr($end,GetNumber=>1)];
        } elsif ($trange =~ /\//) { #a CIDR style specification for a range that could be described in subnet rules
            #we are going to assume that this is a subset of the network (it really ought to be) and therefore all zeroes or all ones is good to include
            my $prefix;
            my $suffix;
            ($prefix,$suffix) = split /\//,$trange;
            my $numbits;
            if ($prefix =~ /:/) { #ipv6
                $netcfgs{$net->{net}}->{range}=$trange; #we can put in dhcpv6 ranges verbatim as CIDR
                $numbits=128;
            } else {
                $numbits=32;
            }
            my $number = getipaddr($prefix,GetNumber=>1);
            my $highmask=Math::BigInt->new("0b".("1"x$suffix).("0"x($numbits-$suffix)));
            my $lowmask=Math::BigInt->new("0b".("1"x($numbits-$suffix)));
            $number &= $highmask; #remove any errant high bits beyond the mask.
            $begin = $number->copy();
            $number |= $lowmask; #get the highest number in the range, 
            $end=$number->copy();
            $dynamicranges{$trange}=[$begin,$end];
            if ($prefix !~ /:/) { #ipv4, must convert CIDR subset to range
                my $lowip = inet_ntoa(pack("N*",$begin));
                my $highip = inet_ntoa(pack("N*",$end));
                $netcfgs{$net->{net}}->{range} = "$lowip $highip";
    
            }
        }
    }
}
######################################################
# Add nodes into dhcpsd.cnf. For AIX only
######################################################
sub addnode_aix
{
    my $ip          = shift;
    my $mac         = shift;
    my $hname       = shift;
    my $tftpserver  = shift;

    $restartdhcp = 1;

    # Format the mac address to aix
    $mac =~ s/://g;
    $mac = lc($mac);

    delnode_aix ( $hname);

#Find the location to insert node
    my $isSubnetFound = 0;
    my $i;
    my $netmask;
    for ($i = 0; $i < scalar(@dhcpconf); $i++)
    {
        if ( $dhcpconf[$i] =~ / ([\d\.]+)\/(\d+) ip configuration end/)
        {
            if (xCAT::Utils::isInSameSubnet( $ip, $1, $2, 1))
            {
                $isSubnetFound = 1;
                $netmask = $2;
                last;
            }
        }
    }

# Format the netmask from AIX format (24) to Linux format (255.255.255.0)
    my $netmask_linux = xCAT::Utils::formatNetmask( $netmask,1,0);

    # Create node section
    my @node_section = ();
    push @node_section, "        client 1 $mac $ip #node $hname start\n";
    push @node_section, "        {\n";
    push @node_section, "            option 1 $netmask_linux\n";
    push @node_section, "            option 12 $hname\n";
#    push @node_section, "            option sa $tftpserver\n";
#    push @node_section, "            option bf \"/tftpboot/$hname\"\n";
    push @node_section, "        } # node $hname end\n";
    

    if ( $isSubnetFound)
    {
        splice @dhcpconf, $i, 0, @node_section;
    }
}

###################################################
# Delete nodes in dhcpsd.cnf. For AIX only
###################################################
sub delnode_aix
{
    my $hname = shift;
    my $i;
    my $node_start = 0;
    my $node_end   = 0;
    for ($i = 0; $i < scalar(@dhcpconf); $i++)
    {
        if ( $dhcpconf[$i] =~ /node $hname start/)
        {
            $node_start = $i;
        }
        elsif ( $dhcpconf[$i] =~ /node $hname end/)
        {
            $node_end = $i;
            last;
        }
    }
    if ( $node_start && $node_end)
    {
        $restartdhcp = 1;
        splice @dhcpconf, $node_start, ($node_end - $node_start + 1);
        return 1;
    }
    else
    {
        return 0;
    }
}

sub preprocess_request
{
    my $req = shift;
    $callback = shift;
    my $localonly;
    #Exit if the packet has been preprocessed
    if ($req->{_xcatpreprocessed}->[0] == 1) { return [$req]; }

    if (ref $req->{arg}) {
        @ARGV       = @{$req->{arg}};
        GetOptions('l' => \$localonly);
    }

   if(grep /-h/,@{$req->{arg}}) {
        my $usage="Usage: makedhcp -n\n\tmakedhcp -a\n\tmakedhcp -a -d\n\tmakedhcp -d noderange\n\tmakedhcp <noderange> [-s statements]\n\tmakedhcp [-h|--help]";
        $callback->({data => [$usage]});
        return;
    }  
    
    unless (($req->{arg} and (@{$req->{arg}}>0)) or $req->{node})
    {
	my $usage="Usage: makedhcp -n\n\tmakedhcp -a\n\tmakedhcp -a -d\n\tmakedhcp -d noderange\n\tmakedhcp <noderange> [-s statements]\n\tmakedhcp [-h|--help]";
        $callback->({data => [$usage]});
        return;
    }

  
    my $snonly=0;
    my $sitetab = xCAT::Table->new('site');
    if ($sitetab)
    {
        my $href;
        ($href) = $sitetab->getAttribs({key => 'disjointdhcps'}, 'value');
        if ($href and $href->{value}) {
	    $snonly=$href->{value};
	}
    }
    my @requests=();
    my $hasHierarchy=0;

    my @nodes=();
    if (! grep /-n/,@{$req->{arg}}) {
	if ($req->{node}) {
	    @nodes=@{$req->{node}};
	}
	elsif(grep /-a/,@{$req->{arg}}) {
	    if (grep /-d$/, @{$req->{arg}})
	    {
			my $nodelist = xCAT::Table->new('nodelist');
			my @entries  = ($nodelist->getAllNodeAttribs([qw(node)]));
			foreach (@entries)
			{
		    	push @nodes, $_->{node};
			}
	    }
	    else
	    {
			my $mactab  = xCAT::Table->new('mac');
			my @entries=();
			if ($mactab) {
		    	@entries = ($mactab->getAllNodeAttribs([qw(mac)]));
			}
			foreach (@entries)
			{
		    	push @nodes, $_->{node};
			}
	    }	    
	} # end - if -a

	# don't put compute node entries in for AIX nodes
    # this is handled by NIM - duplicate entires will cause
    # an error
	if ($^O eq 'aix') {
		my @tmplist;
		my $Imsg;
		foreach my $n (@nodes)
		{
			# get the nodetype for each node
			#my $ntype = xCAT::DBobjUtils->getnodetype($n);
            my $ntable = xCAT::Table->new('nodetype');
            if ($ntable) {
                my $mytype = $ntable->getNodeAttribs($n,['nodetype']);
			    if ($mytype =~ /osi/) {
				$Imsg++;
			    }
			    unless ($mytype =~ /osi/) {
				    push @tmplist, $n;
			    }
            }
		}
		@nodes = @tmplist;

		if ($Imsg) {
			my $rsp;
			push @{$rsp->{data}}, "AIX nodes with a nodetype of \'osi\' will not be added to the dhcp configuration file.  This is handled by NIM.\n";
			xCAT::MsgUtils->message("I", $rsp, $callback);
		}
	}
	}


    if (($snonly == 1) && (! grep /-n/,@{$req->{arg}})) {
        if (@nodes > 0) {
	    my $sn_hash =xCAT::Utils->getSNformattedhash(\@nodes,"xcat","MN"); 
	    if ($localonly) {
		#check if this node is the service node for any input node
		my @hostinfo=xCAT::Utils->determinehostname();
		my %iphash=();
		foreach(@hostinfo) {$iphash{$_}=1;}
		foreach(keys %$sn_hash) {
		    if (exists($iphash{$_})) {
			my $reqcopy = {%$req};
			$reqcopy->{'node'}=$sn_hash->{$_};
			$reqcopy->{'_xcatdest'} = $_;
			$reqcopy->{_xcatpreprocessed}->[0] = 1;
			push @requests, $reqcopy;
		    }
		}
	    } else {
		my @sn = xCAT::Utils->getSNList('dhcpserver');
		if (@sn > 0) { $hasHierarchy=1;}

		foreach(keys %$sn_hash) {
		    my $reqcopy = {%$req};
		    $reqcopy->{'node'}=$sn_hash->{$_};
		    $reqcopy->{'_xcatdest'} = $_;
		    $reqcopy->{_xcatpreprocessed}->[0] = 1;
		    push @requests, $reqcopy;
		}
	    }
	}
    } else { #send the request to every dhservers
	@requests = ({%$req});    #Start with a straight copy to reflect local instance
	unless ($localonly) {
	    my @sn = xCAT::Utils->getSNList('dhcpserver');
	    if (@sn > 0) { $hasHierarchy=1; }

	    foreach my $s (@sn)
	    {
		if (scalar @nodes == 1 and $nodes[0] eq $s) { next; }
		my $reqcopy = {%$req};
		$reqcopy->{'_xcatdest'} = $s;
		$reqcopy->{_xcatpreprocessed}->[0] = 1;
		push @requests, $reqcopy;
	    }
	}
    }

    if ( $hasHierarchy)
    {  
        #hierarchy detected, enforce more rigorous sanity
	my $ntab = xCAT::Table->new('networks');
	if ($ntab)
	{
	    foreach (@{$ntab->getAllEntries()})
	    {
		if ($_->{dynamicrange} and not $_->{dhcpserver})
		{
		    $callback->({error=>["Hierarchy requested, therefore networks.dhcpserver must be set for net=".$_->{net}.""],errorcode=>[1]});
		    return [];
		}
	    }
	}
    }
    #print Dumper(@requests);
    return \@requests;

}

sub process_request
{
    my $oldmask = umask 0077;
    $restartdhcp=0;
    my $req = shift;
    $callback = shift;
    #print Dumper($req);

    #if current node is a servicenode, make sure that it is also a dhcpserver
    my $isok=1;
    if (xCAT::Utils->isServiceNode()) {
	$isok=0;
	my @hostinfo=xCAT::Utils->determinehostname();
	my %iphash=();
	foreach(@hostinfo) {$iphash{$_}=1;}
	my @sn = xCAT::Utils->getSNList('dhcpserver');
	foreach my $s (@sn)
	{
	    if (exists($iphash{$s})) {
		$isok=1;
	    }
	}
    }
    
    if($isok == 0) { #do nothing if it is a service node, but not dhcpserver
	print "Do nothing\n";
	return;  
    }

    my $sitetab = xCAT::Table->new('site');
    my %activenics;
    my $querynics = 1;
    if ($sitetab)
    {
        my $href;
        ($href) = $sitetab->getAttribs({key => 'dhcpinterfaces'}, 'value');
        unless ($href and $href->{value})
        {    #LEGACY: singular keyname for old style site value
            ($href) = $sitetab->getAttribs({key => 'dhcpinterface'}, 'value');
        }
        if ($href and $href->{value})
        #syntax should be like host|ifname1,ifname2;host2|ifname3,ifname2 etc or simply ifname,ifname2
        #depending on complexity of network wished to be described
        {
           my $dhcpinterfaces = $href->{value};
           my $dhcpif;
           INTF: foreach $dhcpif (split /;/,$dhcpinterfaces) {
              my $host;
              my $savehost;
              my $foundself=1;
              if ($dhcpif =~ /\|/) {
                 $foundself=0;
                 
                 (my $ngroup,$dhcpif) = split /\|/,$dhcpif;
                 foreach $host (noderange($ngroup)) {
                    $savehost=$host;
                    unless (xCAT::Utils->thishostisnot($host)) {
                        $foundself=1;
                        last;
                    }
                 }
                 if (!defined($savehost)) { # host not defined in db,
                                 # probably management node
                    unless (xCAT::Utils->thishostisnot($ngroup)) {
                        $foundself=1;
                    }
                 }
              }
              unless ($foundself) {
                  next INTF;
              }
              foreach (split /[,\s]+/, $dhcpif)
              {
                 $activenics{$_} = 1;
                 $querynics = 0;
              }
           }
        }
        ($href) = $sitetab->getAttribs({key => 'nameservers'}, 'value');
        if ($href and $href->{value}) {
            $sitenameservers = $href->{value};
        }
        ($href) = $sitetab->getAttribs({key => 'ntpservers'}, 'value');
        if ($href and $href->{value}) {
            $sitentpservers = $href->{value};
        }
        ($href) = $sitetab->getAttribs({key => 'logservers'}, 'value');
        if ($href and $href->{value}) {
            $sitelogservers = $href->{value};
        }
        #($href) = $sitetab->getAttribs({key => 'domain'}, 'value');
        ($href) = $sitetab->getAttribs({key => 'domain'}, 'value');
        unless ($href and $href->{value})
        {
            $callback->(
                 {error => ["No domain defined in site tabe"], errorcode => [1]}
                 );
            return;
        }
        $domain = $href->{value};
    }

    @dhcpconf = ();
    @dhcp6conf = ();
    
   my $dhcplockfd;
   open($dhcplockfd,">","/tmp/xcat/dhcplock");
   flock($dhcplockfd,LOCK_EX);
   if (grep /^-n$/, @{$req->{arg}})
    {
        if (-e $dhcpconffile)
        {
			if ($^O eq 'aix')
    		{
				# save NIM aix entries - to be restored later
				my $aixconf;
        		open($aixconf, $dhcpconffile); 
        		if ($aixconf)
        		{
					my $save=0;
            		while (<$aixconf>)
            		{
						if ($save) {	
                			push @aixcfg, $_;
						}

						if ($_ =~ /#Network configuration end\n/) {
							$save++;
						}
            		}
            		close($aixconf);
        		}
				$restartdhcp=1;  
        		@dhcpconf = ();
			}

			my $rsp;
            push @{$rsp->{data}}, "Renamed existing dhcp configuration file to  $dhcpconffile.xcatbak\n";
            xCAT::MsgUtils->message("I", $rsp, $callback);

            my $bakname = "$dhcpconffile.xcatbak";
            rename("$dhcpconffile", $bakname);
        }
    }
    else
    {
        my $rconf;
        open($rconf, $dhcpconffile);    # Read file into memory
        if ($rconf)
        {
            while (<$rconf>)
            {
                push @dhcpconf, $_;
            }
            close($rconf);
        }
        unless ($dhcpconf[0] =~ /^#xCAT/)
        {    #Discard file if not xCAT originated, like 1.x did
            $restartdhcp=1;
            @dhcpconf = ();
        }
        if ($dhcp6conffile and -e $dhcp6conffile) {
            open($rconf, $dhcp6conffile);
            while (<$rconf>) { push @dhcp6conf, $_; }
            close($rconf);
        }
        unless ($dhcp6conf[0] =~ /^#xCAT/)
        {    #Discard file if not xCAT originated
            $restartdhcp6=1;
            @dhcp6conf = ();
        }
    }
	my $nettab = xCAT::Table->new("networks");
	my @vnets = $nettab->getAllAttribs('net','mgtifname','mask','dynamicrange','nameservers','ddnsdomain');
    foreach (@vnets) {
        if ($_->{net} =~ /:/) { #IPv6 detected
            $usingipv6=1;
        }
        addrangedetection($_); #add to hash for remembering whether a node has a static address or just happens to live dynamically
    }
    if ($^O eq 'aix')
    {
        @nrn = xCAT::Utils::get_subnet_aix();
    }
    else
    {
        my @nsrnoutput = split /\n/,`/bin/netstat -rn`;
        splice @nsrnoutput, 0, 2;
        foreach (@nsrnoutput) { #scan netstat
            my @parts = split  /\s+/;
            push @nrn,$parts[0].":".$parts[7].":".$parts[2].":".$parts[3];
        }
        my @ip6routes = `ip -6 route`;
        foreach (@ip6routes) {
            #TODO: filter out multicast?  Don't know if multicast groups *can* appear in ip -6 route...
            if (/^fe80::\/64/ or /^unreachable/ or /^[^ ]+ via/) { #ignore link-local, junk, and routed networks
                next;
            }
            my @parts = split /\s+/;
            push @nrn6,{net=>$parts[0],iface=>$parts[2]};
        }
    }

	foreach(@vnets){
        #TODO: v6 relayed networks?
		my $n = $_->{net};
		my $if = $_->{mgtifname};
		my $nm = $_->{mask};
		#$callback->({data => ["array of nets $n : $if : $nm"]});
        if ($if =~ /!remote!/ and $n !~ /:/) { #only take in networks with special interface, but only v4 for now
    		push @nrn, "$n:$if:$nm";
        }
	}
    if ($querynics)
    {    #Use netstat to determine activenics only when no site ent.
        #TODO: IPv6 auto-detect, or just really really insist people define dhcpinterfaces or suffer doom?
        foreach (@nrn)
        {
            my @ent = split /:/;
            my $firstoctet = $ent[0];
            $firstoctet =~ s/^(\d+)\..*/$1/;
            if ($ent[0] eq "169.254.0.0" or ($firstoctet >= 224 and $firstoctet <= 239) or $ent[0] eq "127.0.0.0" or $ent[0] eq '127')
            {
                next;
            }
            if ($ent[1] =~ m/(remote|ipoib|ib|vlan|bond|eth|myri|man|wlan|en\d+)/)
            {    #Mask out many types of interfaces, like xCAT 1.x
                $activenics{$ent[1]} = 1;
            }
        }
    }
    
    if ( $^O ne 'aix')
    {
#add the active nics to /etc/sysconfig/dhcpd or /etc/default/dhcp3-server(ubuntu)
        my $dhcpver;
	my %missingfiles = ( "dhcpd"=>1, "dhcpd6"=>1, "dhcp3-server"=>1 );
        foreach $dhcpver ("dhcpd","dhcpd6","dhcp3-server") {
        if (-e "/etc/sysconfig/$dhcpver") {
		if ($dhcpver eq "dhcpd") {
		    delete($missingfiles{dhcpd});
		    delete($missingfiles{"dhcp3-server"});
		} else {
			delete($missingfiles{$dhcpver});
		}
            open DHCPD_FD, "/etc/sysconfig/$dhcpver";
            my $syscfg_dhcpd = "";
            my $found = 0;
            my $dhcpd_key = "DHCPDARGS";
            my $os = xCAT::Utils->osver();
            if ($os =~ /sles/i) {
                $dhcpd_key = "DHCPD_INTERFACE";
            }

            my $ifarg = "$dhcpd_key=\"";
            foreach (keys %activenics) {
                if (/!remote!/) { next; }
                $ifarg .= " $_";
            }
            $ifarg =~ s/^ //;
            $ifarg .= "\"\n";

            while (<DHCPD_FD>) {
                if ($_ =~ m/^$dhcpd_key/) {
                    $found = 1;
                    $syscfg_dhcpd .= $ifarg;
                }else {
                    $syscfg_dhcpd .= $_;
                }
            }

            if ( $found eq 0 ) {
                $syscfg_dhcpd .= $ifarg;
            }
            close DHCPD_FD; 

            open DBG_FD, '>', "/etc/sysconfig/$dhcpver";
            print DBG_FD $syscfg_dhcpd;
            close DBG_FD;
        }elsif (-e "/etc/default/$dhcpver") { #ubuntu
	    delete($missingfiles{dhcpd});
	    delete($missingfiles{"dhcp3-server"});
        	 open DHCPD_FD, "/etc/default/$dhcpver";
            my $syscfg_dhcpd = "";
            my $found = 0;
            my $dhcpd_key = "INTERFACES";
            my $os = xCAT::Utils->osver();

            my $ifarg = "$dhcpd_key=\"";
            foreach (keys %activenics) {
                if (/!remote!/) { next; }
                $ifarg .= " $_";
            }
            $ifarg =~ s/^ //;
            $ifarg .= "\"\n";

            while (<DHCPD_FD>) {
                if ($_ =~ m/^$dhcpd_key/) {
                    $found = 1;
                    $syscfg_dhcpd .= $ifarg;
                }else {
                    $syscfg_dhcpd .= $_;
                }
            }

            if ( $found eq 0 ) {
                $syscfg_dhcpd .= $ifarg;
            }
            close DHCPD_FD; 

            open DBG_FD, '>', "/etc/default/$dhcpver";
            print DBG_FD $syscfg_dhcpd;
            close DBG_FD;
        	
        }
        }
	if ($usingipv6 and $missingfiles{dhcpd6}) {
            $callback->({error=>"The file /etc/sysconfig/dhcpd6 doesn't exist, check the dhcp server"});
	}
	if ($missingfiles{dhcpd}) {
            $callback->({error=>"The file /etc/sysconfig/dhcpd doesn't exist, check the dhcp server"});
	}
		
    }
    
    unless ($dhcpconf[0])
    {            #populate an empty config with some starter data...
        $restartdhcp=1;
        newconfig();
    }
    if ($usingipv6 and not $dhcp6conf[0]) {
        $restartdhcp6=1;
        newconfig6();
    }
    if ( $^O ne 'aix')
    {
        foreach (keys %activenics)
        {
            addnic($_,\@dhcpconf);
            if ($usingipv6) {
                addnic($_,\@dhcp6conf);
            }
        }
    }
    #need to transfer CEC/Frame to FSPs/BPAs
    my @inodes = ();
    my @validnodes = ();
    my $pnode;
    my $cnode;
    if ($req->{node})
    {
        #@inodes = split /,/,${$req->{noderange}};
        foreach $pnode(@{$req->{node}})
        {
            my $ntype = xCAT::DBobjUtils->getnodetype($pnode);
                if ($ntype =~ /^(cec|frame)$/)
                {
                    $cnode = xCAT::DBobjUtils->getchildren($pnode);
                    foreach (@$cnode)
                    {
                        push @validnodes, $_;
                    }
                } else
                {
                    push @validnodes, $pnode;
                }
        }
        $req->{node} = \@validnodes;
    }
	
    if ((!$req->{node}) && (grep /^-a$/, @{$req->{arg}}))
    {
        if (grep /-d$/, @{$req->{arg}}) #delete all entries
        {
            $req->{node} = [];
            my $nodelist = xCAT::Table->new('nodelist');
            my @entries  = ($nodelist->getAllNodeAttribs([qw(node)]));
            foreach (@entries)
            {
                #delete the CEC and Frame node
                my $ntype = xCAT::DBobjUtils->getnodetype($_->{node});
                unless ($ntype =~ /^(cec|frame)$/)
                {
                    push @{$req->{node}}, $_->{node};
                }
            }
        }
        else #add all entries
        {
            $req->{node} = [];
            my $mactab  = xCAT::Table->new('mac');

            my @entries=();
            if ($mactab) {
                @entries = ($mactab->getAllNodeAttribs([qw(mac)]));
            }

            foreach (@entries)
            {
                push @{$req->{node}}, $_->{node};
            }

			# don't put compute node entries in for AIX nodes
			# this is handled by NIM - duplicate entires will cause
			# an error
			if ($^O eq 'aix') {
				my @tmplist;
				foreach my $n (@{$req->{node}})
				{
					# get the nodetype for each node
					#my $ntype = xCAT::DBobjUtils->getnodetype($n);
                    my $ntable = xCAT::Table->new('nodetype');
                    if ($ntable) {
                        my $ntype = $ntable->getNodeAttribs($n,['nodetype']);

					    # don't add if it is type "osi"
					    unless ($ntype =~ /osi/) {
						push @tmplist, $n;
					    }
                    }    
				}
				@{$req->{node}} = @tmplist;
			}
        }
    }

    foreach (@nrn)
    {
        my @line = split /:/;
        my $firstoctet = $line[0];
        $firstoctet =~ s/^(\d+)\..*/$1/;
        if ($line[0] eq "169.254.0.0" or ($firstoctet >= 224 and $firstoctet <= 239))
        {
            next;
        }
        if ($activenics{$line[1]} and $line[3] !~ /G/)
        {
            addnet($line[0], $line[2]);
        }
    }
    foreach (@nrn6) { #do the ipv6 networks
        addnet6($_); #already did all the filtering before putting into nrn6
    }

    if ($req->{node})
    {
        my $ip_hash;
        foreach my $node ( @{$req->{node}} ) {
            #need to change the way of finding IP for nodes
            my $ifip = xCAT::Utils->isIpaddr($node);
            if ($ifip)
            {
                $ip_hash->{ $node} = $node;
            }
            else
            {
                my $hoststab  = xCAT::Table->new('hosts');
                my $ent = $hoststab->getNodeAttribs( $node, ['ip'] );
                if ( $ent->{ip} ) {
                    if ( $ip_hash->{ $ent->{ip} } ) {
                        $callback->({error=>["Duplicated IP addresses in hosts table for following nodes: $node," . $ip_hash->{ $ent->{ip} }],errorcode=>[1]});
                        return;
                    }
                    $ip_hash->{ $ent->{ip} } = $node;
                }
            }
        }

        @ARGV       = @{$req->{arg}};
        $statements = "";
        GetOptions('s|statements=s' => \$statements);

        if ($^O ne 'aix')
        {
            my $passtab = xCAT::Table->new('passwd');
            my $ent;
            ($ent) = $passtab->getAttribs({key => "omapi"}, qw(username password));
            unless ($ent->{username} and $ent->{password})
            {
                $callback->({error=>["Unable to access omapi key from passwd table, add the key from dhcpd.conf or makedhcp -n to create a new one"],errorcode=>[1]});
                syslog("local4|err","Unable to access omapi key from passwd table, unable to update DHCP configuration");
                return;
            }    # TODO sane err
#Have nodes to update
#open2($omshellout,$omshell,"/usr/bin/omshell");
            open($omshell, "|/usr/bin/omshell > /dev/null");
            print $omshell "key "
                . $ent->{username} . " \""
                . $ent->{password} . "\"\n";
            print $omshell "connect\n";
            if ($usingipv6) {
                open($omshell6, "|/usr/bin/omshell > /dev/null");
                print $omshell6 "port 7912\n";
                print $omshell6 "key "
                    . $ent->{username} . " \""
                    . $ent->{password} . "\"\n";
                print $omshell6 "connect\n";
            }
        }
        
        my $nrtab = xCAT::Table->new('noderes');
        my $chaintab = xCAT::Table->new('chain');
        if ($chaintab) {
            $chainents = $chaintab->getNodesAttribs($req->{node},['currstate']);
        } else {
            $chainents = undef;
        }
        $nrhash = $nrtab->getNodesAttribs($req->{node}, ['tftpserver','netboot']);
        my $nodetypetab;
	$nodetypetab = xCAT::Table->new('nodetype',-create=>0);
	if ($nodetypetab) {
            $nodetypeents = $nodetypetab->getNodesAttribs($req->{node},[qw(os)]);
	}
        my $iscsitab = xCAT::Table->new('iscsi',-create=>0);
        if ($iscsitab) {
            $iscsients = $iscsitab->getNodesAttribs($req->{node},[qw(server target lun iname)]);
        }
        my $mactab = xCAT::Table->new('mac');
        $machash = $mactab->getNodesAttribs($req->{node},['mac']);
        my $vpdtab = xCAT::Table->new('vpd');
        $vpdhash = $vpdtab->getNodesAttribs($req->{node},['uuid']);
        foreach (@{$req->{node}})
        {
            if (grep /^-d$/, @{$req->{arg}})
            {
                if ( $^O eq 'aix')
                {
                    delnode_aix $_;
                }
                else
                {
                    delnode $_;
                }
            }
            else
            {
                if  (xCAT::NetworkUtils->getipaddr($_) and not xCAT::Utils->nodeonmynet($_))
                {
                    next;
                }
                addnode $_;
                if ($usingipv6) {
                    addnode6 $_;
                }
            }
        }
        close($omshell) if ($^O ne 'aix');
        close($omshell6) if ($omshell6 and $^O ne 'aix');
        foreach my $node (@{$req->{node}})
        {
            unless ($machash)
            {
                $callback->(
                       {
                        error => ["Unable to open mac table, it may not exist yet"],
                        errorcode => [1]
                       }
                       );
                return;
            }
            my $ent = $machash->{$node}->[0]; #tab->getNodeAttribs($node, [qw(mac)]);
            unless ($ent and $ent->{mac})
            {
                $callback->(
                        {
                         warning     => ["Unable to find mac address for $node"]
                        }
                        );
                next;
            }
        }
    }
    writeout();
    if ($restartdhcp) {
        if ( $^O eq 'aix')
        {
            restart_dhcpd_aix();
        }
        elsif ( $distro =~ /ubuntu*/)
        {
        	#ubuntu config
            system("chmod a+r /etc/dhcp3/dhcpd.conf");
            system("/etc/init.d/dhcp3-server restart");
        }
        else
        {
            system("/etc/init.d/dhcpd restart");
            system("chkconfig dhcpd on");
        }
    }
    flock($dhcplockfd,LOCK_UN);
    umask $oldmask;
}
# Restart dhcpd on aix
sub restart_dhcpd_aix
{
    #Check if dhcpd is running
    my @res = xCAT::Utils->runcmd('lssrc -s dhcpsd',0);
    if ( $::RUNCMD_RC != 0)
    {
        xCAT::MsgUtils->message("E", "Failed to check dhcpsd status\n");
    }
    if ( grep /\sactive/, @res)
    {
        xCAT::Utils->runcmd('refresh -s dhcpsd',0);
        xCAT::MsgUtils->message("E", "Failed to refresh dhcpsd configuration\n") if ( $::RUNCMD_RC);
    }
    else
    {
        xCAT::Utils->runcmd('startsrc -s dhcpsd',0);
        xCAT::MsgUtils->message("E", "Failed to start dhcpsd\n" ) if ( $::RUNCMD_RC);
    }
    return 1;
}

sub getzonesfornet {
    my $net = shift;
    my $mask = shift;
    my @zones = ();
    if ($net =~ /:/) {#ipv6, for now do the simple stuff under the assumption we won't have a mask indivisible by 4
        $net =~ s/\/(.*)//;
        my $maskbits=$1;
        if ($mask) {
            die "Not supporting having a mask like $mask on an ipv6 network like $net";
        }
        my $netnum= getipaddr($net,GetNumber=>1);
        unless ($netnum) { return (); }
        $netnum->brsft(128-$maskbits);
        my $prefix=$netnum->as_hex();
        my $nibbs=$maskbits/4;
        $prefix =~ s/^0x//;
        my $rev;
        foreach (reverse(split //,$prefix)) {
            $rev .= $_.".";
            $nibbs--;
        }
        while ($nibbs) { 
            $rev .= "0.";
            $nibbs--;
        }
        $rev.="ip6.arpa.";
        return ($rev);
    }
    #return all in-addr reverse zones for a given mask and net
    #for class a,b,c, the answer is easy
    #for classless, identify the partial byte, do $netbyte | (0xff&~$maskbyte) to get the highest value
    #return sequence from $net to value calculated above
    #since old bind.pm only went as far as class c, we will carry that over for now (more people with smaller than class c complained
    #and none hit the theoretical conflict.  FYI, the 'official' method in RFC 2317 seems cumbersome, but maybe one day it makes sense
    #since this is dhcpv4 for now, we'll use the inet_aton, ntop functions to generate the answers (dhcpv6 omapi would be nice...)
    my $netn = inet_aton($net);
    my $maskn = inet_aton($mask);
    unless ($netn and $mask) { return (); }
    my $netnum = unpack('N',$netn);
    my $masknum = unpack('N',$maskn);
    if ($masknum >= 0xffffff00) { #treat all netmasks higher than 255.255.255.0 as class C
        $netnum = $netnum & 0xffffff00;
        $netn = pack('N',$netnum);
        $net = inet_ntoa($netn);
        $net =~ s/\.[^\.]*$//;
        return (join('.',reverse(split('\.',$net))).'.IN-ADDR.ARPA.');
    } elsif ($masknum > 0xffff0000) { #class b (/16) to /23
        my $tempnumber = ($netnum >> 8);
        $masknum = $masknum >> 8;
        my $highnet = $tempnumber | (0xffffff & ~$masknum);
        foreach ($tempnumber..$highnet) {
            $netnum = $_ << 8;
            $net = inet_ntoa(pack('N',$netnum));
            $net =~ s/\.[^\.]*$//;
            push @zones,join('.',reverse(split('\.',$net))).'.IN-ADDR.ARPA.';
        }
        return @zones;
    } elsif ($masknum > 0xff000000) { #class a (/8) to /15, could have made it more flexible, for for only two cases, not worth in
        my $tempnumber = ($netnum >> 16); #the last two bytes are insignificant, shift them off to make math easier
        $masknum = $masknum >> 16;
        my $highnet = $tempnumber | (0xffff & ~$masknum);
        foreach ($tempnumber..$highnet) {
            $netnum = $_ << 16; #convert back to the real network value
            $net = inet_ntoa(pack('N',$netnum));
            $net =~ s/\.[^\.]*$//;
            $net =~ s/\.[^\.]*$//;
            push @zones,join('.',reverse(split('\.',$net))).'.IN-ADDR.ARPA.';
        }
        return @zones;
    } else { #class a (theoretically larger, but those shouldn't exist)
        my $tempnumber = ($netnum >> 24); #the last two bytes are insignificant, shift them off to make math easier
        $masknum = $masknum >> 24;
        my $highnet = $tempnumber | (0xff & ~$masknum);
        foreach ($tempnumber..$highnet) {
            $netnum = $_ << 24; #convert back to the real network value
            $net = inet_ntoa(pack('N',$netnum));
            $net =~ s/\.[^\.]*$//;
            $net =~ s/\.[^\.]*$//;
            $net =~ s/\.[^\.]*$//;
            push @zones,join('.',reverse(split('\.',$net))).'.IN-ADDR.ARPA.';
        }
        return @zones;
    }
}

sub putmyselffirst {
    my $srvlist = shift;
            if ($srvlist =~ /,/) { #TODO: only reshuffle when requested, or allow opt out of reshuffle?
                my @dnsrvs = split /,/,$srvlist;
                my @reordered;
                foreach (@dnsrvs) {
                    if (xCAT::Utils->thishostisnot($_)) {
                        push @reordered,$_;
                    } else {
                        unshift @reordered,$_;
                    }
                }
                $srvlist = join(', ',@reordered);
            }
            return $srvlist;
}
sub addnet6
{
    my $netentry = shift;
    my $net = $netentry->{net};
    my $iface = $netentry->{iface};
    my $idx = 0;
    if (grep /\} # $net subnet_end/,@dhcp6conf) { #need to add to dhcp6conf
        return;
    } else { #need to add to dhcp6conf
	$restartdhcp6=1;
        while ($idx <= $#dhcp6conf)
        {
            if ($dhcp6conf[$idx] =~ /\} # $iface nic_end/) {
                last;
            }
            $idx++;
        }
        unless ($dhcp6conf[$idx] =~ /\} # $iface nic_end\n/) {
                return 1;    #TODO: this is an error condition
        }

    }
    my @netent = (
                   "  subnet6 $net {\n",
                   "    max-lease-time 43200;\n",
                   "    min-lease-time 43200;\n",
                   "    default-lease-time 43200;\n",
                   );
    #for now, just do address allocatios (phase 1)
    #phase 2 (by 2.6 presumably) will include the various things like DNS server and other options allowed by dhcpv6
    #gateway is *not* currently allowed to be DHCP designated, router advertises its own self indpendent of dhcp.  We'll just keep it that way
    #domain search list is allowed (rfc 3646)
        #nis domain is also an alloed option (rfc 3898)
    #sntp server list (rfc 4075)
    #ntp server rfc 5908
    #fqdn rfc 4704
    #posix timezone rfc 4833/tzdb timezone
    #phase 3 will include whatever is required to do Netboot6.  That might be in the october timeframe for lack of implementations to test
    #boot url/param (rfc 59070)
    push @netent, "    option domain-name \"".$netcfgs{$net}->{domain}."\";\n";
    my $nameservers = $netcfgs{$net}->{nameservers};
    if ($nameservers and $nameservers =~ /:/) {
        push @netent,"    nameservers ".$netcfgs{$net}->{nameservers}.";\n";
    }
    my $ddnserver = $nameservers;
    $ddnserver =~ s/,.*//;
    my $ddnsdomain;
    if ($netcfgs{$net}->{ddnsdomain}) {
        $ddnsdomain = $netcfgs{$net}->{ddnsdomain};
    }
    if ($::XCATSITEVALS{dnshandler} =~ /ddns/) {
        if ($ddnsdomain) {
            push @netent, "    ddns-domainname \"".$ddnsdomain."\";\n";
            push @netent, "    zone $ddnsdomain. {\n";
        } else {
    push @netent, "    zone $domain. {\n";
        }
    push @netent, "       primary $ddnserver; key xcat_key; \n";
    push @netent, "    }\n";
    foreach (getzonesfornet($net)) {
       push @netent, "    zone $_ {\n";
       push @netent, "       primary $ddnserver; key xcat_key; \n";
       push @netent, "    }\n";
    }
    }
    if ($netcfgs{$net}->{range}) {
        push @netent,"    range6 ".$netcfgs{$net}->{range}.";\n";
    } else {
        $callback->({warning => ["No dynamic range specified for $net. Hosts with no static address will receive no addresses on this subnet."]});
    }
    push @netent, "  } # $net subnet_end\n";
    splice(@dhcp6conf, $idx, 0, @netent);
}
sub addnet
{
    my $net  = shift;
    my $mask = shift;
    my $nic;
    my $firstoctet = $net;
    $firstoctet =~ s/^(\d+)\..*/$1/;
    if ($net eq "169.254.0.0" or ($firstoctet >= 224 and $firstoctet <= 239)) {
        return;
    }
    unless (grep /\} # $net\/$mask subnet_end/, @dhcpconf)
    {
        $restartdhcp=1;
        foreach (@nrn)
        {    # search for relevant NIC
            my @ent = split /:/;
            $firstoctet = $ent[0];
            $firstoctet =~ s/^(\d+)\..*/$1/;
            if ($ent[0] eq "169.254.0.0" or ($firstoctet >= 224 and $firstoctet <= 239))
            {
                next;
            }
            if ($ent[0] eq $net and $ent[2] eq $mask)
            {
                $nic = $ent[1];
            }
        }
        #print " add $net $mask under $nic\n";
        my $idx = 0;
        if ( $^O ne 'aix')
        {
            while ($idx <= $#dhcpconf)
            {
                if ($dhcpconf[$idx] =~ /\} # $nic nic_end\n/)
            {
                last;
            }
            $idx++;
            }
            unless ($dhcpconf[$idx] =~ /\} # $nic nic_end\n/)
            {
                return 1;    #TODO: this is an error condition
            }
        }

        # if here, means we found the idx before which to insert
        my $nettab = xCAT::Table->new("networks");
        my $nameservers;
        my $ntpservers;
        my $logservers;
        my $gateway;
        my $tftp;
        my $range;
        my $myip;
        $myip = xCAT::Utils->my_ip_facing($net);
        if ($nettab)
        {
            my $mask_formated = $mask;
            if ( $^O eq 'aix')
            {
                $mask_formated = inet_ntoa(pack("N", 2**$mask - 1 << (32 - $mask)));
            }
            my ($ent) =
              $nettab->getAttribs({net => $net, mask => $mask_formated},
                    qw(tftpserver nameservers ntpservers logservers gateway dynamicrange dhcpserver));
            if ($ent and $ent->{ntpservers}) {
                $ntpservers = $ent->{ntpservers};
            } elsif ($sitentpservers) {
                $ntpservers = $sitentpservers;
            }
            if ($ent and $ent->{logservers}) {
                $logservers = $ent->{logservers};
            } elsif ($sitelogservers) {
                $logservers = $sitelogservers;
            }
            if ($ent and $ent->{nameservers})
            {
                $nameservers = $ent->{nameservers};
            }
            else
            {
                if ($sitenameservers) {
                    $nameservers = $sitenameservers;
                } else {
                $callback->(
                    {
                     warning => [
                         "No $net specific entry for nameservers, and no nameservers defined in site table."
                     ]
                    }
                    );
                }
            }

            # convert <xcatmaster> to nameserver IP
            if ($nameservers eq '<xcatmaster>')
            {
                $nameservers = $myip;
            }
            
            $nameservers=putmyselffirst($nameservers);
            $ntpservers=putmyselffirst($ntpservers);
            $logservers=putmyselffirst($logservers);


            if ($ent and $ent->{tftpserver})
            {
                $tftp = $ent->{tftpserver};
            }
            else
            {    #presume myself to be it, dhcp no longer does this for us
                $tftp = $myip;
            }
            if ($ent and $ent->{gateway})
            {
                $gateway = $ent->{gateway};

                if ($gateway eq '<xcatmaster>')
                {
                    if(xCAT::NetworkUtils->ip_forwarding_enabled())
                    {
                        $gateway = $myip;
                    }
                    else
                    {
                        $gateway = '';
                    }
                }
            }
            if ($ent and $ent->{dynamicrange})
            {
                unless ($ent->{dhcpserver}
                        and xCAT::Utils->thishostisnot($ent->{dhcpserver}))
                {    #If specific, only one dhcp server gets a dynamic range
                    $range = $ent->{dynamicrange};
                    $range =~ s/[,-]/ /g;
                }
            }
            else
            {
                $callback->(
                    {
                     warning => [
                         "No dynamic range specified for $net. If hardware discovery is being used, a dynamic range is required."
                     ]
                    }
                    );
            }
        }
        else
        {
            $callback->(
                  {
                   error =>
                     ["Unable to open networks table, please run makenetworks"],
                   errorcode => [1]
                  }
                  );
            return 1;
        }

        if ( $^O eq 'aix')
        {
            return gen_aix_net( $myip, $net, $mask, $gateway, $tftp, 
                                $logservers, $ntpservers, $domain,
                                $nameservers, $range);
        }
        my @netent;
                         
        my $maskn = unpack("N", inet_aton($mask));
        my $netn  = unpack("N", inet_aton($net));
        @netent = (
                   "  subnet $net netmask $mask {\n",
                   "    max-lease-time 43200;\n",
                   "    min-lease-time 43200;\n",
                   "    default-lease-time 43200;\n"
                   );
        if ($gateway)
        {
            my $gaten = unpack("N", inet_aton($gateway));
            if (($gaten & $maskn) == ($maskn & $netn))
            {
                push @netent, "    option routers  $gateway;\n";
            }
            else
            {
                $callback->(
                    {
                     error => [
                         "Specified gateway $gateway is not valid for $net/$mask, must be on same network"
                     ],
                     errorcode => [1]
                    }
                    );
            }
        }
        if ($tftp)
        {
            push @netent, "    next-server  $tftp;\n";
        }
        if ($logservers) {
        	push @netent, "    option log-servers $logservers;\n";
        } elsif ($myip){
        	push @netent, "    option log-servers $myip;\n";
        }
        if ($ntpservers) {
        	push @netent, "    option ntp-servers $ntpservers;\n";
        } elsif ($myip){
        	push @netent, "    option ntp-servers $myip;\n";
        }
        if ($nameservers)
        {
            push @netent, "    option domain-name \"$domain\";\n";
            push @netent, "    option domain-name-servers  $nameservers;\n";
        }
        my $ddnserver = $nameservers;
        $ddnserver =~ s/,.*//;
        my $ddnsdomain;
        if ($netcfgs{$net}->{ddnsdomain}) {
            $ddnsdomain = $netcfgs{$net}->{ddnsdomain};
        }
    if ($::XCATSITEVALS{dnshandler} =~ /ddns/) {
        if ($ddnsdomain) {
            push @netent, "    ddns-domainname \"".$ddnsdomain."\";\n";
            push @netent, "    zone $ddnsdomain. {\n";
        } else {
            push @netent, "    zone $domain. {\n";
        }
        if ($ddnserver)
        {
            push @netent, "   primary $ddnserver; key xcat_key; \n";
        }
        push @netent, " }\n";
        foreach (getzonesfornet($net,$mask)) {
            push @netent, "zone $_ {\n";
            if ($ddnserver)
            {
                push @netent, "   primary $ddnserver; key xcat_key; \n";
            }
            push @netent, " }\n";
        }
        }

        my $tmpmaskn = unpack("N", inet_aton($mask));
        my $maskbits = 32;
        while (not ($tmpmaskn & 1)) {
            $maskbits--;
            $tmpmaskn=$tmpmaskn>>1;
        }

                       # $lstatements = 'if exists gpxe.bus-id { filename = \"\"; } else if exists client-architecture { filename = \"xcat/xnba.kpxe\"; } '.$lstatements;
        push @netent, "    if option user-class-identifier = \"xNBA\" and option client-architecture = 00:00 { #x86, xCAT Network Boot Agent\n";
        push @netent, "       filename = \"http://$tftp/tftpboot/xcat/xnba/nets/".$net."_".$maskbits."\";\n";
        push @netent, "    } else if option user-class-identifier = \"xNBA\" and option client-architecture = 00:09 { #x86, xCAT Network Boot Agent\n";
        push @netent, "       filename = \"http://$tftp/tftpboot/xcat/xnba/nets/".$net."_".$maskbits.".uefi\";\n";
        push @netent, "    } else if option client-architecture = 00:00  { #x86\n";
        push @netent, "      filename \"xcat/xnba.kpxe\";\n";
        push @netent, "    } else if option vendor-class-identifier = \"Etherboot-5.4\"  { #x86\n";
        push @netent, "      filename \"xcat/xnba.kpxe\";\n";
        push @netent,
          "    } else if option client-architecture = 00:07 { #x86_64 uefi\n ";
        push @netent, "      filename \"xcat/xnba.efi\";\n";
        push @netent,
          "    } else if option client-architecture = 00:09 { #x86_64 uefi alternative id\n ";
        push @netent, "      filename \"xcat/xnba.efi\";\n";
        push @netent,
          "    } else if option client-architecture = 00:02 { #ia64\n ";
        push @netent, "      filename \"elilo.efi\";\n";
        push @netent,
          "    } else if substring(filename,0,1) = null { #otherwise, provide yaboot if the client isn't specific\n ";
        push @netent, "      filename \"/yaboot\";\n";
        push @netent, "    }\n";
        if ($range) { 
            foreach  my $singlerange (split /;/,$range) {
                push @netent, "    range dynamic-bootp $singlerange;\n" 
            }
        }
        push @netent, "  } # $net\/$mask subnet_end\n";
        splice(@dhcpconf, $idx, 0, @netent);
    }
}

######################################################
# Generate network configuration for aix
######################################################
sub gen_aix_net
{
    my $myip        = shift;
    my $net         = shift; 
    my $mask        = shift;
    my $gateway     = shift;
    my $tftp        = shift;
    my $logservers  = shift;
    my $ntpservers  = shift;
    my $domain      = shift;
    my $nameservers = shift;
    my $range       = shift;

    my $idx = 0;
    while ( $idx <= $#dhcpconf)
    {
        if ($dhcpconf[$idx] =~ /#Network configuration end\n/)
        {
            last;
        }
        $idx++;
    }
    
    unless ($dhcpconf[$idx] =~ /#Network configuration end\n/)
    {
        return 1;    #TODO: this is an error condition
    }

    $range =~ s/ /-/;
    my @netent = ( "network $net $mask\n{\n");
    if ( $gateway)
    {
        if ($gateway eq '<xcatmaster>')
        {
            if(xCAT::NetworkUtils->ip_forwarding_enabled())
            {
                $gateway = $myip;
            }
            else
            {
                $gateway = '';
            }
        }
        if (xCAT::Utils::isInSameSubnet($gateway,$net,$mask,1))
        {
            push @netent, "    option 3 $gateway\n";
        }
        else
        {
            $callback->(
                    {
                    error => [
                    "Specified gateway $gateway is not valid for $net/$mask, must be on same network"
                    ],
                    errorcode => [1]
                    }
                    );
        }
    } 
#    if ($tftp)
#    {
#        push @netent, "    option 66 $tftp\n";
#    }
    if ($logservers) {
        $logservers =~ s/,/ /g;
        push @netent, "    option 7 $logservers\n";
    } elsif ($myip){
        push @netent, "    option 7 $myip\n";
    }
    if ($ntpservers) {
        $ntpservers =~ s/,/ /g;
        push @netent, "    option 42 $ntpservers\n";
    } elsif ($myip){
        push @netent, "    option 42 $myip\n";
    }
    push @netent, "    option 15 \"$domain\"\n";
    if ($nameservers)
    {
        $nameservers =~ s/,/ /g;
        push @netent, "    option 6 $nameservers\n";
    }
    push @netent, "    subnet $net $range\n    {\n";
    push @netent, "    } # $net/$mask ip configuration end\n";
    push @netent, "} # $net/$mask subnet_end\n\n";

    splice(@dhcpconf, $idx, 0, @netent);
}

sub addnic
{
    my $nic        = shift;
    my $conf       = shift;
    my $firstindex = 0;
    my $lastindex  = 0;
    unless (grep /} # $nic nic_end/, @$conf)
    {    #add a section if not there
        #$restartdhcp=1;
        #print "Adding NIC $nic\n";
        if ($nic =~ /!remote!/) {
            push @$conf, "#shared-network $nic {\n";
            push @$conf, "#\} # $nic nic_end\n";
        } else {
            push @$conf, "shared-network $nic {\n";
            push @$conf, "\} # $nic nic_end\n";
        }

    }

    #return; #Don't touch it, it should already be fine..
    #my $idx=0;
    #while ($idx <= $#dhcpconf) {
    #  if ($dhcpconf[$idx] =~ /^shared-network $nic {/) {
    #    $firstindex = $idx; # found the first place to chop...
    #  } elsif ($dhcpconf[$idx] =~ /} # $nic network_end/) {
    #    $lastindex=$idx;
    #  }
    #  $idx++;
    #}
    #print Dumper(\@dhcpconf);
    #if ($firstindex and $lastindex) {
    #  splice @dhcpconf,$firstindex,($lastindex-$firstindex+1);
    #}
    #print Dumper(\@dhcpconf);
}

sub writeout
{

	# add the new entries to the dhcp config file
    my $targ;
    open($targ, '>', $dhcpconffile);
    my $idx;
    my $skipone;
    foreach $idx (0..$#dhcpconf)
    {
        #avoid writing out empty shared network declarations
        if ($dhcpconf[$idx] =~ /^shared-network/ and $dhcpconf[$idx+1] =~ /^} .* nic_end/) {
            $skipone=1;
            next;
        } elsif ($skipone) {
            $skipone=0;
            next;
        }
        print $targ $dhcpconf[$idx];
    }

	if ($^O eq 'aix')
	{
		# add back any NIM entries that were saved earlier
		if (@aixcfg) {
			foreach $idx (0..$#aixcfg)
			{
				print $targ $aixcfg[$idx];
			}
		}
	}
    close($targ);
    @dhcpconf=(); #dispose of the file contents in memory, no longer needed
    @aixcfg=();


    if (@dhcp6conf) {
    open($targ, '>', $dhcp6conffile);
    foreach $idx (0..$#dhcp6conf)
    {
        if ($dhcp6conf[$idx] =~ /^shared-network/ and $dhcp6conf[$idx+1] =~ /^} .* nic_end/) {
            $skipone=1;
            next;
        } elsif ($skipone) {
            $skipone=0;
            next;
        }
        print $targ $dhcp6conf[$idx];
    }
    close($targ);
    @dhcp6conf=();
    }
}

sub newconfig6 {
    #phase 1, basic working
    #phase 2, ddns too, evaluate other stuff from dhcpv4 as applicable
    push @dhcp6conf, "#xCAT generated dhcp configuration\n";
    push @dhcp6conf, "\n";
    push @dhcp6conf, "ddns-update-style interim;\n";
    push @dhcp6conf, "ignore client-updates;\n";
#    push @dhcp6conf, "update-static-leases on;\n";
    push @dhcp6conf, "omapi-port 7912;\n";        #Enable omapi...
    push @dhcp6conf, "key xcat_key {\n";
    push @dhcp6conf, "  algorithm hmac-md5;\n";
    my $passtab = xCAT::Table->new('passwd', -create => 1);
    (my $passent) =
      $passtab->getAttribs({key => 'omapi', username => 'xcat_key'}, 'password');
    my $secret = encode_base64(genpassword(32));    #Random from set of  62^32
    chomp $secret;
    if ($passent->{password}) { $secret = $passent->{password}; }
    else
    {
        $callback->(
             {
              data =>
                ["The dhcp server must be restarted for OMAPI function to work"]
             }
             );
        $passtab->setAttribs({key => 'omapi'},
                             {username => 'xcat_key', password => $secret});
    }

    push @dhcp6conf, "  secret \"" . $secret . "\";\n";
    push @dhcp6conf, "};\n";
    push @dhcp6conf, "omapi-key xcat_key;\n";
    #that is all for pristine ipv6 config
}

sub newconfig
{
    return newconfig_aix() if ( $^O eq 'aix');

    # This function puts a standard header in and enough to make omapi work.
    my $passtab = xCAT::Table->new('passwd', -create => 1);
    push @dhcpconf, "#xCAT generated dhcp configuration\n";
    push @dhcpconf, "\n";
    push @dhcpconf, "authoritative;\n";
    push @dhcpconf, "option space isan;\n";
    push @dhcpconf, "option isan-encap-opts code 43 = encapsulate isan;\n";
    push @dhcpconf, "option isan.iqn code 203 = string;\n";
    push @dhcpconf, "option isan.root-path code 201 = string;\n";
    push @dhcpconf, "option space gpxe;\n";
    push @dhcpconf, "option gpxe-encap-opts code 175 = encapsulate gpxe;\n";
    push @dhcpconf, "option gpxe.bus-id code 177 = string;\n";
    push @dhcpconf, "option user-class-identifier code 77 = string;\n";
    push @dhcpconf, "option gpxe.no-pxedhcp code 176 = unsigned integer 8;\n";
    push @dhcpconf, "option tcode code 101 = text;\n";
	
    push @dhcpconf, "option iscsi-initiator-iqn code 203 = string;\n"; #Only via gPXE, not a standard
    push @dhcpconf, "ddns-update-style interim;\n";
    push @dhcpconf, "ignore client-updates;\n"; #Windows clients like to do all caps, very un xCAT-like
#    push @dhcpconf, "update-static-leases on;\n"; #makedns rendered optional
    push @dhcpconf,
      "option client-architecture code 93 = unsigned integer 16;\n";
    if ($::XCATSITEVALS{timezone}) {
    push @dhcpconf, "option tcode \"".$::XCATSITEVALS{timezone}."\";\n";
    }
    push @dhcpconf, "option gpxe.no-pxedhcp 1;\n";
    push @dhcpconf, "\n";
    push @dhcpconf, "omapi-port 7911;\n";        #Enable omapi...
    push @dhcpconf, "key xcat_key {\n";
    push @dhcpconf, "  algorithm hmac-md5;\n";
    (my $passent) =
      $passtab->getAttribs({key => 'omapi', username => 'xcat_key'}, 'password');
    my $secret = encode_base64(genpassword(32));    #Random from set of  62^32
    chomp $secret;
    if ($passent->{password}) { $secret = $passent->{password}; }
    else
    {
        $callback->(
             {
              data =>
                ["The dhcp server must be restarted for OMAPI function to work"]
             }
             );
        $passtab->setAttribs({key => 'omapi'},
                             {username => 'xcat_key', password => $secret});
    }

    push @dhcpconf, "  secret \"" . $secret . "\";\n";
    push @dhcpconf, "};\n";
    push @dhcpconf, "omapi-key xcat_key;\n";
    push @dhcpconf, ('class "pxe" {'."\n","   match if substring (option vendor-class-identifier, 0, 9) = \"PXEClient\";\n","   ddns-updates off;\n","    max-lease-time 600;\n","}\n");
}

sub newconfig_aix
{
    push @dhcpconf, "#xCAT generated dhcp configuration\n";
    push @dhcpconf, "\n";
#push @dhcpconf, "numLogFiles 4\n";
#push @dhcpconf, "logFileSize 100\n";
#push @dhcpconf, "logFileName /var/log/dhcpsd.log\n";
#push @dhcpconf, "logItem SYSERR\n";
#push @dhcpconf, "logItem OBJERR\n";
#push @dhcpconf, "logItem PROTERR\n";
#push @dhcpconf, "logItem WARNING\n";
#push @dhcpconf, "logItem EVENT\n";
#push @dhcpconf, "logItem ACTION\n";
#push @dhcpconf, "logItem INFO\n";
#push @dhcpconf, "logItem ACNTING\n";
#push @dhcpconf, "logItem TRACE\n";
    
    push @dhcpconf, "leaseTimeDefault 43200 seconds\n";
    push @dhcpconf, "#Network configuration begin\n";
    push @dhcpconf, "#Network configuration end\n";
}


sub genpassword
{

    #Generate a pseudo-random password of specified length
    my $length     = shift;
    my $password   = '';
    my $characters =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01234567890';
    srand;    #have to reseed, rand is not rand otherwise
    while (length($password) < $length)
    {
        $password .= substr($characters, int(rand 63), 1);
    }
    return $password;
}

1;
