# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::pxe;
use Sys::Syslog;
use Socket;
use File::Copy;
use File::Path;
use Getopt::Long;

my $addkcmdlinehandled;
my $request;
my $callback;
my $dhcpconf = "/etc/dhcpd.conf";
my $tftpdir = "/tftpboot";
#my $dhcpver = 3;

my %usage = (
    "nodeset" => "Usage: nodeset <noderange> [install|shell|boot|runcmd=bmcsetup|netboot|iscsiboot]",
);
sub handled_commands {
  return {
    nodeset => "noderes:netboot"
  }
}

sub check_dhcp {
  return 1;
  #TODO: omapi magic to do things right
  my $node = shift;
  my $dhcpfile;
  open ($dhcpfile,$dhcpconf);
  while (<$dhcpfile>) {
    if (/host $node\b/) {
      close $dhcpfile;
      return 1;
    }
  }
  close $dhcpfile;
  return 0;
}

sub getstate {
  my $node = shift;
  if (check_dhcp($node)) {
    if (-r $tftpdir . "/xcat/xnba/nodes/".$node) {
      my $fhand;
      open ($fhand,$tftpdir . "/xcat/xnba/nodes/".$node);
      my $headline = <$fhand>;
      $headline = <$fhand>; #second line is the comment now...
      close $fhand;
      $headline =~ s/^#//;
      chomp($headline);
      return $headline;
    } elsif (-r $tftpdir . "/pxelinux.cfg/".$node) {
      my $fhand;
      open ($fhand,$tftpdir . "/pxelinux.cfg/".$node);
      my $headline = <$fhand>;
      close $fhand;
      $headline =~ s/^#//;
      chomp($headline);
      return $headline;
    } else {
      return "boot";
    }
  } else {
    return "discover";
  }
}

sub setstate {
=pod

  This function will manipulate the pxelinux.cfg structure to match what the noderes/chain tables indicate the node should be booting.

=cut
  my $node = shift;
  my %bphash = %{shift()};
  my %chainhash = %{shift()};
  my %machash = %{shift()};
  my $kern = $bphash{$node}->[0]; #$bptab->getNodeAttribs($node,['kernel','initrd','kcmdline']);
  unless ($addkcmdlinehandled->{$node}) { #Tag to let us know the plugin had a special syntax implemented for addkcmdline
    if ($kern->{addkcmdline}) { #Implement the kcmdline append here for 
                              #most generic, least code duplication
      $kern->{kcmdline} .= " ".$kern->{addkcmdline};
    }
  }
  if ($kern->{kcmdline} =~ /!myipfn!/) {
      my $ipfn = xCAT::Utils->my_ip_facing($node);
      unless ($ipfn) {
        my @myself = xCAT::Utils->determinehostname();
        my $myname = $myself[(scalar @myself)-1];
         $callback->(
                {
                 error => [
                     "$myname: Unable to determine or reasonably guess the image server for $node"
                 ],
                 errorcode => [1]
                }
                );
      }
      $kern->{kcmdline} =~ s/!myipfn!/$ipfn/;
  }
  my $pcfg;
  unlink($tftpdir."/xcat/xnba/nodes/".$node.".pxelinux");
  open($pcfg,'>',$tftpdir."/xcat/xnba/nodes/".$node);
  my $cref=$chainhash{$node}->[0]; #$chaintab->getNodeAttribs($node,['currstate']);
  print $pcfg "#!gpxe\n";
  if ($cref->{currstate}) {
    print $pcfg "#".$cref->{currstate}."\n";
  }
  if ($cref and $cref->{currstate} eq "boot") {
    print $pcfg "hdboot\n";
    close($pcfg);
  } elsif ($kern and $kern->{kernel}) {
    if ($kern->{kernel} =~ /!/) { #TODO: deprecate this, do stateless Xen like stateless ESXi
    	my $hypervisor;
    	my $kernel;
    	($kernel,$hypervisor) = split /!/,$kern->{kernel};
    	print $pcfg " set 209:string xcat/xnba/nodes/$node.pxelinux\n";
    	print $pcfg " set 210:string http://".'${next-server}'."/tftpboot/\n";
    	print $pcfg " imgfetch -n pxelinux.0 http://".'${next-server}'."/tftpboot/pxelinux.0\n";
    	print $pcfg " imgload pxelinux.0\n";
    	print $pcfg " imgexec pxelinux.0\n";
        close($pcfg);
        open($pcfg,'>',$tftpdir."/xcat/xnba/nodes/".$node.".pxelinux");
        print $pcfg "DEFAULT xCAT\nLABEL xCAT\n   KERNEL mboot.c32\n";
	    print $pcfg " APPEND $hypervisor --- $kernel ".$kern->{kcmdline}." --- ".$kern->{initrd}."\n";
    } else {
        if ($kern->{kernel} =~ /\.c32\z/ or $kern->{kernel} eq 'memdisk') { #gPXE comboot support seems insufficient, chain pxelinux instead
        	print $pcfg " set 209:string xcat/xnba/nodes/$node.pxelinux\n";
        	print $pcfg " set 210:string http://".'${next-server}'."/tftpboot/\n";
        	print $pcfg " imgfetch -n pxelinux.0 http://".'${next-server}'."/tftpboot/pxelinux.0\n";
        	print $pcfg " imgload pxelinux.0\n";
        	print $pcfg " imgexec pxelinux.0\n";
            close($pcfg);
            open($pcfg,'>',$tftpdir."/xcat/xnba/nodes/".$node.".pxelinux");
           #It's time to set pxelinux for this node to boot the kernel..
            print $pcfg "DEFAULT xCAT\nLABEL xCAT\n";
            print $pcfg " KERNEL ".$kern->{kernel}."\n";
            if ($kern->{initrd} or $kern->{kcmdline}) {
              print $pcfg " APPEND ";
            }
            if ($kern and $kern->{initrd}) {
              print $pcfg "initrd=".$kern->{initrd}." ";
            }
            if ($kern and $kern->{kcmdline}) {
              print $pcfg $kern->{kcmdline}."\n";
            } else {
              print $pcfg "\n";
            }
        } else { #other than comboot/multiboot, we won't have need of pxelinux
            print $pcfg "imgfetch -n kernel http://".'${next-server}/tftpboot/'.$kern->{kernel}."\n";
            print $pcfg "imgload kernel\n";
            if ($kern->{kcmdline}) {
                print $pcfg "imgargs kernel ".$kern->{kcmdline}."\n";
            }
            if ($kern->{initrd}) {
                print $pcfg "imgfetch http://".'${next-server}'."/tftpboot/".$kern->{initrd}."\n";
            }
            print $pcfg "imgexec kernel\n";
        }
    }
    close($pcfg);
    my $inetn = inet_aton($node);
    unless ($inetn) {
     syslog("local1|err","xCAT unable to resolve IP for $node in pxe plugin");
     return;
    }
  } else { #TODO: actually, should possibly default to xCAT image?
    print $pcfg "LOCALBOOT 0\n";
    close($pcfg);
  }
  my $mactab = xCAT::Table->new('mac'); #to get all the hostnames
  my %ipaddrs;
  unless (inet_aton($node)) {
    syslog("local1|err","xCAT unable to resolve IP in pxe plugin");
    return;
  }
  my $ip = inet_ntoa(inet_aton($node));;
  unless ($ip) {
    syslog("local1|err","xCAT unable to resolve IP in pxe plugin");
    return;
  }
  $ipaddrs{$ip} = 1;
  if ($mactab) {
     my $ment = $machash{$node}->[0]; #$mactab->getNodeAttribs($node,['mac']);
     if ($ment and $ment->{mac}) {
         my @macs = split(/\|/,$ment->{mac});
         foreach (@macs) {
            if (/!(.*)/) {
               if (inet_aton($1)) {
                  $ipaddrs{inet_ntoa(inet_aton($1))} = 1;
               }
            }
         }
     }
  }
  my $hassymlink = eval { symlink("",""); 1 };
  foreach $ip (keys %ipaddrs) {
   my @ipa=split(/\./,$ip);
   my $pname = sprintf("%02X%02X%02X%02X",@ipa);
   unlink($tftpdir."/pxelinux.cfg/".$pname);
   if ($hassymlink) { 
    symlink($node,$tftpdir."/pxelinux.cfg/".$pname);
   } else {
    link($tftpdir."/pxelinux.cfg/".$node,$tftpdir."/pxelinux.cfg/".$pname);
   }
  }
}
  

    
my $errored = 0;
sub pass_along { 
    my $resp = shift;
    if ($resp and ($resp->{errorcode} and $resp->{errorcode}->[0]) or ($resp->{error} and $resp->{error}->[0])) {
        $errored=1;
    }
    foreach (@{$resp->{node}}) {
       if ($_->{error} or $_->{errorcode}) {
          $errored=1;
       }
       if ($_->{_addkcmdlinehandled}) {
           $addkcmdlinehandled->{$_->{name}->[0]}=1;
           return; #Don't send back to client this internal hint
       }
    }
    $callback->($resp);
}


sub preprocess_request {
    my $req = shift;
    if ($req->{_xcatpreprocessed}->[0] == 1) { return [$req]; }

    my $callback1 = shift;
    my $command  = $req->{command}->[0];
    my $sub_req = shift;
    my @args=();
    if (ref($req->{arg})) {
	@args=@{$req->{arg}};
    } else {
	@args=($req->{arg});
    }
    @ARGV = @args;

    #use Getopt::Long;
    Getopt::Long::Configure("bundling");
    Getopt::Long::Configure("pass_through");
    if (!GetOptions('h|?|help'  => \$HELP, 'v|version' => \$VERSION) ) {
      if($usage{$command}) {
          my %rsp;
          $rsp{data}->[0]=$usage{$command};
          $callback1->(\%rsp);
      }
      return;
    }

    if ($HELP) { 
	if($usage{$command}) {
	    my %rsp;
	    $rsp{data}->[0]=$usage{$command};
	    $callback1->(\%rsp);
	}
	return;
    }

    if ($VERSION) {
	my $ver = xCAT::Utils->Version();
	my %rsp;
	$rsp{data}->[0]="$ver";
	$callback1->(\%rsp);
	return; 
    }

    if (@ARGV==0) {
	if($usage{$command}) {
	    my %rsp;
	    $rsp{data}->[0]=$usage{$command};
	    $callback1->(\%rsp);
	}
	return;
    }


   #Assume shared tftp directory for boring people, but for cool people, help sync up tftpdirectory contents when 
   #they specify no sharedtftp in site table
   my $stab = xCAT::Table->new('site');
   my $sent = $stab->getAttribs({key=>'sharedtftp'},'value');
   if ($sent and ($sent->{value} == 0 or $sent->{value} =~ /no/i)) {
      $req->{'_disparatetftp'}=[1];
      if ($req->{inittime}->[0]) {
          return [$req];
      }
      return xCAT::Scope->get_broadcast_scope($req,@_);
   }
   return [$req];
}
#sub preprocess_request {
#   my $req = shift;
#   $callback = shift;
#   if ($req->{_xcatpreprocessed}->[0] == 1) { return [$req]; }
#   my @requests = ({%$req}); #Start with a straight copy to reflect local instance
#   my $sitetab = xCAT::Table->new('site');
#   (my $ent) = $sitetab->getAttribs({key=>'xcatservers'},'value');
#   $sitetab->close;
#   if ($ent and $ent->{value}) {
#      foreach (split /,/,$ent->{value}) {
#         if (xCAT::Utils->thishostisnot($_)) {
#            my $reqcopy = {%$req};
#            $reqcopy->{'_xcatdest'} = $_;
#            $reqcopy->{_xcatpreprocessed}->[0] = 1;
#            push @requests,$reqcopy;
#         }
#      }
#   }
#   return \@requests;
#}
#sub preprocess_request {
#   my $req = shift;
#   my $callback = shift;
#  my %localnodehash;
#  my %dispatchhash;
#  my $nrtab = xCAT::Table->new('noderes');
#  foreach my $node (@{$req->{node}}) {
#     my $nodeserver;
#     my $tent = $nrtab->getNodeAttribs($node,['tftpserver']);
#     if ($tent) { $nodeserver = $tent->{tftpserver} }
#     unless ($tent and $tent->{tftpserver}) {
#        $tent = $nrtab->getNodeAttribs($node,['servicenode']);
#        if ($tent) { $nodeserver = $tent->{servicenode} }
#     }
#     if ($nodeserver) {
#        $dispatchhash{$nodeserver}->{$node} = 1;
#     } else {
#        $localnodehash{$node} = 1;
#     }
#  }
#  my @requests;
#  my $reqc = {%$req};
#  $reqc->{node} = [ keys %localnodehash ];
#  if (scalar(@{$reqc->{node}})) { push @requests,$reqc }
#
#  foreach my $dtarg (keys %dispatchhash) { #iterate dispatch targets
#     my $reqcopy = {%$req}; #deep copy
#     $reqcopy->{'_xcatdest'} = $dtarg;
#     $reqcopy->{node} = [ keys %{$dispatchhash{$dtarg}}];
#     push @requests,$reqcopy;
#  }
#  return \@requests;
#}

sub process_request {
  $request = shift;
  $callback = shift;
  my $sub_req = shift;
  my @args;
  my @nodes;
  my @rnodes;
  if (ref($request->{node})) {
    @rnodes = @{$request->{node}};
  } else {
    if ($request->{node}) { @rnodes = ($request->{node}); }
  }

  unless (@rnodes) {
      if ($usage{$request->{command}->[0]}) {
          $callback->({data=>$usage{$request->{command}->[0]}});
      }
      return;
  }

  #if not shared, then help sync up
  if ($request->{'_disparatetftp'}->[0]) { #reading hint from preprocess_command
   @nodes = ();
   foreach (@rnodes) {
     if (xCAT::Utils->nodeonmynet($_)) {
        push @nodes,$_;
     }
   }
  } else {
     @nodes = @rnodes;
  }

  if (ref($request->{arg})) {
    @args=@{$request->{arg}};
  } else {
    @args=($request->{arg});
  }

  #now run the begin part of the prescripts
  unless ($args[0] eq 'stat') { # or $args[0] eq 'enact') {
      $errored=0;
      if ($request->{'_disparatetftp'}->[0]) {  #the call is distrubuted to the service node already, so only need to handles my own children
	  $sub_req->({command=>['runbeginpre'],
		      node=>\@nodes,
		      arg=>[$args[0], '-l']},\&pass_along);
      } else { #nodeset did not distribute to the service node, here we need to let runednpre to distribute the nodes to their masters
	  $sub_req->({command=>['runbeginpre'],   
		      node=>\@rnodes,
		      arg=>[$args[0]]},\&pass_along);
      }
      if ($errored) { return; }
  }  

  #back to normal business
  if (! -r "$tftpdir/pxelinux.0") {
    unless (-r "/usr/lib/syslinux/pxelinux.0" or -r "/usr/share/syslinux/pxelinux.0") {
       $callback->({error=>["Unable to find pxelinux.0 "],errorcode=>[1]});
       return;
    }
    if (-r "/usr/lib/syslinux/pxelinux.0") {
       copy("/usr/lib/syslinux/pxelinux.0","$tftpdir/pxelinux.0");
    } else {
       copy("/usr/share/syslinux/pxelinux.0","$tftpdir/pxelinux.0");
     }
     chmod(0644,"$tftpdir/pxelinux.0");
  }
  unless ( -r "$tftpdir/pxelinux.0" ) {
     $callback->({errror=>["Unable to find pxelinux.0 from syslinux"],errorcode=>[1]});
     return;
  }

      

  $errored=0;
  unless ($args[0] eq 'stat') { # or $args[0] eq 'enact') {
    $sub_req->({command=>['setdestiny'],
           node=>\@nodes,
         arg=>[$args[0]]},\&pass_along);
  }
  if ($errored) { return; }
  #Time to actually configure the nodes, first extract database data with the scalable calls
  my $bptab = xCAT::Table->new('bootparams',-create=>1);
  my $chaintab = xCAT::Table->new('chain');
  my $mactab = xCAT::Table->new('mac'); #to get all the hostnames
  my %bphash = %{$bptab->getNodesAttribs(\@nodes,[qw(kernel initrd kcmdline addkcmdline)])};
  my %chainhash = %{$chaintab->getNodesAttribs(\@nodes,[qw(currstate)])};
  my %machash = %{$mactab->getNodesAttribs(\@nodes,[qw(mac)])};
  mkpath($tftpdir."/xcat/xnba/nodes/");
  foreach (@nodes) {
    my %response;
    $response{node}->[0]->{name}->[0]=$_;
    if ($args[0] eq 'stat') {
      $response{node}->[0]->{data}->[0]= getstate($_);
      $callback->(\%response);
    } elsif ($args[0]) { #If anything else, send it on to the destiny plugin, then setstate
      ($rc,$errstr) = setstate($_,\%bphash,\%chainhash,\%machash);
      if ($rc) {
        $response{node}->[0]->{errorcode}->[0]= $rc;
        $response{node}->[0]->{errorc}->[0]= $errstr;
        $callback->(\%response);
      }
    }
  }

  my $inittime=0;
  if (exists($request->{inittime})) { $inittime= $request->{inittime}->[0];} 
  if (!$inittime) { $inittime=0;}

  #dhcp stuff -- inittime is set when xcatd on sn is started
  unless (($args[0] eq 'stat') || ($inittime)) {
      my $do_dhcpsetup=1;
      my $sitetab = xCAT::Table->new('site');
      if ($sitetab) {
          (my $ref) = $sitetab->getAttribs({key => 'dhcpsetup'}, 'value');
          if ($ref) {
             if ($ref->{value} =~ /0|n|N/) { $do_dhcpsetup=0; }
          }
      }
      
      if ($do_dhcpsetup) {
        if ($request->{'_disparatetftp'}->[0]) { #reading hint from preprocess_command
            $sub_req->({command=>['makedhcp'],arg=>['-l'],
                        node=>\@nodes},$callback);
        } else {
            $sub_req->({command=>['makedhcp'],
                       node=>\@nodes},$callback);
        }
     }  
  }

  #now run the end part of the prescripts
  unless ($args[0] eq 'stat') { # or $args[0] eq 'enact') 
      $errored=0;
      if ($request->{'_disparatetftp'}->[0]) {  #the call is distrubuted to the service node already, so only need to handles my own children
	  $sub_req->({command=>['runendpre'],
		      node=>\@nodes,
		      arg=>[$args[0], '-l']},\&pass_along);
      } else { #nodeset did not distribute to the service node, here we need to let runednpre to distribute the nodes to their masters
	  $sub_req->({command=>['runendpre'],   
		      node=>\@rnodes,
		      arg=>[$args[0]]},\&pass_along);
      }
      if ($errored) { return; }
  }

}


#----------------------------------------------------------------------------
=head3  getNodesetStates
       returns the nodeset state for the given nodes. The possible nodeset
           states are: netboot, install, boot and discover.
    Arguments:
        nodes  --- a pointer to an array of nodes
        states -- a pointer to a hash table. This hash will be filled by this
             function. The key is the nodeset status and the value is a pointer
             to an array of nodes. 
    Returns:
       (return code, error message)
=cut
#-----------------------------------------------------------------------------
sub getNodesetStates {
  my $noderef=shift;
  if ($noderef =~ /xCAT_plugin::pxe/) {
    $noderef=shift;
  }
  my @nodes=@$noderef;
  my $hashref=shift; 
  if (@nodes>0) {
    foreach my $node (@nodes) {
      my $tmp=getstate($node);
      my @a=split(' ', $tmp);
      $stat = $a[0];
      if (exists($hashref->{$stat})) {
	  my $pa=$hashref->{$stat};
	  push(@$pa, $node);
      }
      else {
	  $hashref->{$stat}=[$node];
      }
    }
  }
  return (0, "");
}

1;
