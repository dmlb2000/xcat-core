# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::destiny;
use xCAT::NodeRange;
use Data::Dumper;
use xCAT::Utils;
use Sys::Syslog;
use xCAT::GlobalDef;
use xCAT_monitoring::monitorctrl;
use strict;

my $request;
my $callback;
my $subreq;
my $errored = 0;

#DESTINY SCOPED GLOBALS
my $chaintab;
my $iscsitab;
my $bptab;
my $typetab;
my $restab;
my $sitetab;
my $hmtab;

sub handled_commands {
  return {
    setdestiny => "destiny",
    getdestiny => "destiny",
    nextdestiny => "destiny"
  }
}
sub process_request {
  $request = shift;
  $callback = shift;
  $subreq = shift;
  if ($request->{command}->[0] eq 'getdestiny') {
    getdestiny();
  }
  if ($request->{command}->[0] eq 'nextdestiny') {
    nextdestiny($request);
  }
  if ($request->{command}->[0] eq 'setdestiny') {
    setdestiny($request);
  }
}

sub relay_response {
    my $resp = shift;
    $callback->($resp);
    if ($resp and ($resp->{errorcode} and $resp->{errorcode}->[0]) or ($resp->{error} and $resp->{error}->[0])) {
        $errored=1;
    }
    foreach (@{$resp->{node}}) {
       if ($_->{error} or $_->{errorcode}) {
          $errored=1;
       }
    }
}

sub setdestiny {
  my $req=shift;
  $chaintab = xCAT::Table->new('chain',-create=>1);
  my @nodes=@{$req->{node}};
  my $state = $req->{arg}->[0];
  my %nstates;
  if ($state eq "next") {
    return nextdestiny();
  } elsif ($state eq "iscsiboot") {
     my $iscsitab=xCAT::Table->new('iscsi');
     unless ($iscsitab) {
        $callback->({error=>"Unable to open iscsi table to get iscsiboot parameters",errorcode=>[1]});
     }
     my $bptab = xCAT::Table->new('bootparams',-create=>1);
     my $ients = $iscsitab->getNodesAttribs($req->{node},[qw(kernel kcmdline initrd)]);
     foreach (@{$req->{node}}) {
      my $ient = $ients->{$_}->[0]; #$iscsitab->getNodeAttribs($_,[qw(kernel kcmdline initrd)]);
      unless ($ient and $ient->{kernel}) {
         $callback->({error=>"$_: No iscsi boot data available",errorcode=>[1]});
         next;
      }
      my $hash;
      $hash->{kernel} = $ient->{kernel};
      if ($ient->{initrd}) { $hash->{initrd} = $ient->{initrd} }
      if ($ient->{kcmdline}) { $hash->{kcmdline} = $ient->{kcmdline} }
      $bptab->setNodeAttribs($_,$hash);
     }
  } elsif ($state =~ /^install$/ or $state eq "install" or $state eq "netboot" or $state eq "image" or $state eq "winshell") {
    chomp($state);
    $subreq->({command=>["mk$state"],
              node=>$req->{node}}, \&relay_response);
    if ($errored) { return; }
    my $nodetype = xCAT::Table->new('nodetype');
    my $ntents = $nodetype->getNodesAttribs($req->{node},[qw(os arch profile)]);
    foreach (@{$req->{node}}) {
      $nstates{$_} = $state; #local copy of state variable for mod
      my $ntent = $ntents->{$_}->[0]; #$nodetype->getNodeAttribs($_,[qw(os arch profile)]);
      if ($ntent and $ntent->{os}) {
        $nstates{$_} .= " ".$ntent->{os};
      } else { $errored =1; $callback->({error=>"nodetype.os not defined for $_"}); }
      if ($ntent and $ntent->{arch}) {
        $nstates{$_} .= "-".$ntent->{arch};
      } else { $errored =1; $callback->({error=>"nodetype.arch not defined for $_"}); }
      if ($ntent and $ntent->{profile}) {
        $nstates{$_} .= "-".$ntent->{profile};
      } else { $errored =1; $callback->({error=>"nodetype.profile not defined for $_"}); }
      if ($errored) {return;}
      unless ($state =~ /^netboot/) { $chaintab->setNodeAttribs($_,{currchain=>"boot"}); };
    }
  } elsif ($state eq "shell" or $state eq "standby" or $state =~ /^runcmd/ or $state =~ /^runimage/) {
    $restab=xCAT::Table->new('noderes',-create=>1);
    my $bootparms=xCAT::Table->new('bootparams',-create=>1);
    my $nodetype = xCAT::Table->new('nodetype');
    my $sitetab = xCAT::Table->new('site');
    my $nodehm = xCAT::Table->new('nodehm');
    my $hments = $nodehm->getNodesAttribs(\@nodes,['serialport','serialspeed','serialflow']);
    (my $portent) = $sitetab->getAttribs({key=>'xcatdport'},'value');
    (my $mastent) = $sitetab->getAttribs({key=>'master'},'value');
    my $enthash = $nodetype->getNodesAttribs(\@nodes,[qw(arch)]);
    my $resents = $restab->getNodeAttribs(\@nodes,[qw(xcatmaster)]);
    foreach (@nodes) {
      my $ent = $enthash->{$_}->[0]; #$nodetype->getNodeAttribs($_,[qw(arch)]);
      unless ($ent and $ent->{arch}) {
        $callback->({error=>["No archictecture defined in nodetype table for $_"],errorcode=>[1]});
        return;
      }
      my $arch = $ent->{arch};
      my $ent = $resents->{$_}->[0]; #$restab->getNodeAttribs($_,[qw(xcatmaster)]);
      my $master;
      my $kcmdline = "quiet ";
      if ($mastent and $mastent->{value}) {
          $master = $mastent->{value};
      }
      if ($ent and $ent->{xcatmaster}) {
          $master = $ent->{xcatmaster};
      }
      $ent = $hments->{$_}->[0]; #$nodehm->getNodeAttribs($_,['serialport','serialspeed','serialflow']);
      if ($ent and defined($ent->{serialport})) {
         $kcmdline .= "console=ttyS".$ent->{serialport};
         #$ent = $nodehm->getNodeAttribs($_,['serialspeed']);
         unless ($ent and defined($ent->{serialspeed})) {
            $callback->({error=>["Serial port defined in noderes, but no nodehm.serialspeed set for $_"],errorcode=>[1]});
            return;
         }
         $kcmdline .= ",".$ent->{serialspeed};
         #$ent = $nodehm->getNodeAttribs($_,['serialflow']);
         if ($ent and ($ent->{serialflow} eq 'hard' or $ent->{serialflow} eq 'rtscts')) {
            $kcmdline .= "n8r";
         }
         $kcmdline .= " ";
      }

      unless ($master) {
          $callback->({error=>["No master in site table nor noderes table for $_"],errorcode=>[1]});
          return;
      }
      my $xcatdport="3001";
      if ($portent and $portent->{value}) {
          $xcatdport = $portent->{value};
      }
      $bootparms->setNodeAttribs($_,{kernel => "xcat/nbk.$arch",
                                   initrd => "xcat/nbfs.$arch.gz",
                                   kcmdline => $kcmdline."xcatd=$master:$xcatdport"});
    }
  } elsif (!($state eq "boot")) { 
      $callback->({error=>["Unknown state $state requested"],errorcode=>[1]});
      return;
  }
  foreach (@nodes) {
    my $lstate = $state;
    if ($nstates{$_}) {
        $lstate = $nstates{$_};
    } 
    $chaintab->setNodeAttribs($_,{currstate=>$lstate});
  }
  return getdestiny();
}


sub nextdestiny {
  my $callnodeset=0;
  if (scalar(@_)) {
     $callnodeset=1;
  }
  my @nodes;
  if ($request and $request->{node}) {
    if (ref($request->{node})) {
      @nodes = @{$request->{node}};
    } else {
      @nodes = ($request->{node});
    }
    #TODO: service third party getdestiny..
  } else { #client asking to move along its own chain
    #TODO: SECURITY with this, any one on a node could advance the chain, for node, need to think of some strategy to deal with...
    unless ($request->{'_xcat_clienthost'}->[0]) {
      #ERROR? malformed request
      return; #nothing to do here...
    }
    my $node = $request->{'_xcat_clienthost'}->[0];
    ($node) = noderange($node);
    unless ($node) {
      #not a node, don't trust it
      return;
    }
    @nodes=($node);
  }

  my $node;
  $chaintab = xCAT::Table->new('chain');
  my $chainents = $chaintab->getNodesAttribs(\@nodes,[qw(currstate currchain chain)]);
  my %node_status=();
  foreach $node (@nodes) {
    unless($chaintab) {
      syslog("local1|err","ERROR: $node requested destiny update, no chain table");
      return; #nothing to do...
    }
    my $ref =  $chainents->{$node}->[0]; #$chaintab->getNodeAttribs($node,[qw(currstate currchain chain)]);
    unless ($ref->{chain} or $ref->{currchain}) {
      syslog ("local1|err","ERROR: node requested destiny update, no path in chain.currchain");
      return; #Can't possibly do anything intelligent..
    }
    unless ($ref->{currchain}) { #If no current chain, copy the default
      $ref->{currchain} = $ref->{chain};
    }
    my @chain = split /[,;]/,$ref->{currchain};

    $ref->{currstate} = shift @chain;
    $ref->{currchain}=join(',',@chain);
    unless ($ref->{currchain}) { #If we've gone off the end of the chain, have currchain stick
      $ref->{currchain} = $ref->{currstate};
    }
    $chaintab->setNodeAttribs($node,$ref); #$ref is in a state to commit back to db

    #collect node status for certain states
    if ($ref->{currstate} =~ /^boot/) {
      my $stat="booting";
      if (exists($node_status{$stat})) {
        my $pa=$node_status{$stat};
        push(@$pa, $node);
      }
      else {
        $node_status{$stat}=[$node];
      }
    }

    my %requ;
    $requ{node}=[$node];
    $requ{arg}=[$ref->{currstate}];
    setdestiny(\%requ);
  }
  
  #setup the nodelist.status
  xCAT_monitoring::monitorctrl::setNodeStatusAttributes(\%node_status, 1);

  if ($callnodeset) {
     $subreq->({command=>['nodeset'],
               node=> \@nodes,
               arg=>['enact']});
  }

}


sub getdestiny {
  my @args;
  my @nodes;
  if ($request->{node}) {
    if (ref($request->{node})) {
      @nodes = @{$request->{node}};
    } else {
      @nodes = ($request->{node});
    }
  } else { # a client asking for it's own destiny.
    unless ($request->{'_xcat_clienthost'}->[0]) {
      $callback->({destiny=>[ 'discover' ]});
      return;
    }
    my ($node) = noderange($request->{'_xcat_clienthost'}->[0]);
    unless ($node) { # it had a valid hostname, but isn't a node
      $callback->({destiny=>[ 'discover' ]}); 
      return;
    }
    @nodes=($node);
  }
  my $node;
  $restab = xCAT::Table->new('noderes');
  my $chaintab = xCAT::Table->new('chain');
  my $chainents = $chaintab->getNodesAttribs(\@nodes,[qw(currstate chain)]);
  my $nrents = $restab->getNodesAttribs(\@nodes,[qw(tftpserver xcatmaster)]);
  $bptab = xCAT::Table->new('bootparams',-create=>1);
  my $bpents = $bptab->getNodesAttribs(\@nodes,[qw(kernel initrd kcmdline xcatmaster)]);
  my $sitetab= xCAT::Table->new('site');
  (my $sent) = $sitetab->getAttribs({key=>'master'},'value');
  foreach $node (@nodes) {
    unless ($chaintab) { #Without destiny, have the node wait with ssh hopefully open at least
      $callback->({node=>[{name=>[$node],data=>['standby'],destiny=>[ 'standby' ]}]});
      return;
    }
    my $ref = $chainents->{$node}->[0]; #$chaintab->getNodeAttribs($node,[qw(currstate chain)]);
    unless ($ref) {
      $callback->({node=>[{name=>[$node],data=>['standby'],destiny=>[ 'standby' ]}]});
      return;
    }
    unless ($ref->{currstate}) { #Has a record, but not yet in a state...
      my @chain = split /,/,$ref->{chain};
      $ref->{currstate} = shift @chain;
      $chaintab->setNodeAttribs($node,{currstate=>$ref->{currstate}});
    }
    my %response;
    $response{name}=[$node];
    $response{data}=[$ref->{currstate}];
    $response{destiny}=[$ref->{currstate}];
    my $nrent = $nrents->{$node}->[0]; #$noderestab->getNodeAttribs($node,[qw(tftpserver xcatmaster)]);
    my $bpent = $bpents->{$node}->[0]; #$bptab->getNodeAttribs($node,[qw(kernel initrd kcmdline xcatmaster)]);
    if (defined $bpent->{kernel}) {
        $response{kernel}=$bpent->{kernel};
    }
    if (defined $bpent->{initrd}) {
        $response{initrd}=$bpent->{initrd};
    }
    if (defined $bpent->{kcmdline}) {
        $response{kcmdline}=$bpent->{kcmdline};
    }
    if (defined $nrent->{tftpserver}) {
        $response{imgserver}=$nrent->{tftpserver};
    } elsif (defined $nrent->{xcatmaster}) {
        $response{imgserver}=$nrent->{xcatmaster};
    } elsif (defined($sent->{value})) {
        $response{imgserver}=$sent->{value};
    } else {
       $response{imgserver} = xCAT::Utils->my_ip_facing($node);
    }
    
    $callback->({node=>[\%response]});
  }  
}


1;
