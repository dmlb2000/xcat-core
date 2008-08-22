#!/usr/bin/perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::MacMap;
use xCAT::Table;
use xCAT::Utils;
use xCAT::MsgUtils;
use IO::Select;
use IO::Handle;
use Sys::Syslog;
use Data::Dumper;
use SNMP; 
my %cisco_vlans; #Special hash structure to reflect discovered VLANS on Cisco equip
#use IF-MIB (1.3.6.1.2.1.2) for all switches
#   1.3.6.1.2.1.31.1.1 - ifXtable
#       1.3.6.1.2.1.31.1.1.1.1.N = name - ifName
#Using BRIDGE-MIB for most switches( 1.3.6.1.2.1.17 )
#   1.3.6.1.2.1.17.1.4 - dot1dBasePortTable
#       1.3.6.1.2.1.17.1.4.1.1.X = N - dot1dBasePort
#   1.3.6.1.2.1.17.4.3 - dot1dTpFdbTable #FAILS on FORCE10,
#       
#If particular result fails, fallback to Q-BRIDGE-MIB for Force10 (1.3.6.1.2.1.17.7)
#   1.3.6.1.2.1.17.7.1.2.2 - dot1qTpFdbTable 


sub namesmatch {
=pod

MacMap attempts to do it's best to determine whether or not a particular SNMP description of
a port matches the user specified value in the configuration.  Generally, if the configuration
consists of non-stacked switches without line cards, the user should only need to specify the
port number without any characters or / characters.  If the configuration contains line cards 
or stacked switches, use of that particular switch's appropriate / syntax in generally called 
for.  The exception being stacked SMC 8848 switches, in which all ports are still single 
numbers, and the ports on the second switch begin at 57.

If difficulty is encountered, or a switch is attempted with a format that doesn't match any 
existing rule, it is recommended to use snmpwalk on the switch with the .1.3.6.1.2.1.31.1.1.1.1
OID, and have the switch table port value match exactly the format suggested by that OID. 

=cut
  my $namepercfg = shift;
  my $namepersnmp = shift;
  if ($namepercfg eq $namepersnmp) {
    return 1; # They matched perfectly
  }
  #Begin guessing, first off, all tested scenarios have likely correct guesses ending
  #in the cfg string, with some non-numeric prefix before it.
  unless ($namepersnmp =~ /[^0123456789]$namepercfg\z/)  {
    #Most common case, won't match at all
    return 0;
  }
  #stop contemplating vlan, Nu, and console interfaces
  if (($namepersnmp =~ /vl/i) or ($namepersnmp =~ /Nu/) or ($namepersnmp =~ /onsole/))  {
    return 0;
  }
  #broken up for code readablitiy, don't check port channel numbers or CPU
  #have to distinguish betweer Port and Po and PortChannel
  if (($namepersnmp !~ /Port #/) and ($namepersnmp !~ /Port\d/) and ($namepersnmp =~ /Po/) or ($namepersnmp =~ /LAG/) or ($namepersnmp =~ /CPU/)) {
    return 0;
  }
  #don't contemplate ManagementEthernet
  if (($namepersnmp =~ /Management/)) {
    return 0;
  }
  #The blacklist approach has been exhausted.  For now, assuming that means good,
  #if something ambiguous happens, the whitelist would have been:
  #'Port','Port #','/' (if namepercfg has no /, then / would be...),
  #'Gi','Te','GigabitEthernet','TenGigabitEthernet'
  return 1;
}

sub new {
  my $self = {};
  my $proto = shift;
  my $class = ref($proto) || $proto;

  bless ($self, $class);
  return $self;
}

sub find_mac {
# This function is given a mac address, checks for given mac address
# and returns undef if unable to find the node, and the nodename otherwise
  my $self = shift;
  my $mac = shift;
  my $cachedonly = shift;
# For now HARDCODE (TODO, configurable?) a cache as stale after five minutes
# Also, if things are changed in the config, our cache could be wrong, 
# invalidate on switch table write?
  if ($self->{mactable}->{lc($mac)} and ($self->{timestamp} > (time() - 300))) { 
    my $reftbl = 0;
    foreach (keys %{$self->{mactable}}) {
      if ((lc($mac) ne $_) and ($self->{mactable}->{lc($mac)} eq $self->{mactable}->{$_})) {
        #$reftbl = 1;
        #Delete *possibly* stale data, without being heavy handed..
        delete $self->{mactable}->{$_};
      }
    }
    unless ($reftbl) { return $self->{mactable}->{lc($mac)};}
  }
  #If requesting a cache only check or the cache is a mere 20 seconds old
  #don't bother querying switches
  if ($cachedonly or ($self->{timestamp} > (time() - 20))) { return undef; }
  $self->refresh_table; #not cached or stale cache, refresh
  if ($self->{mactable}->{lc($mac)}) {
    return $self->{mactable}->{lc($mac)};
  }
  return undef;
}

sub refresh_table {
  my $self = shift;
  $self->{mactable}={};
  $self->{switchtab} = xCAT::Table->new('switch', -create => 1);
  $self->{sitetab} = xCAT::Table->new('site');
  my $community = "public";
  my $tmp = $self->{sitetab}->getAttribs({key=>'snmpc'},'value');
  if ($tmp and $tmp->{value}) { $community = $tmp->{value} }
  else { #Would warn here.. 
  }
  my %checked_pairs;
  my @entries = $self->{switchtab}->getAllNodeAttribs(['node','port','switch']);
  #Build hash of switch port names per switch
  $self->{switches} = {};
  foreach $entry (@entries) {
    if (defined($entry->{switch}) and $entry->{switch} ne "" and defined($entry->{port}) and $entry->{port} ne "") {
    	$self->{switches}->{$entry->{switch}}->{$entry->{port}}=$entry->{node};
    } else {
        xCAT::MsgUtils->message("S","xCAT Table error:".$entry->{node}."Has missing or invalid switch.switch and/or switch.port fields");
    }
  } 
  my $children = 0;
  my $inputs = new IO::Select;
  $SIG{CHLD}= sub { while(waitpid(-1,WNOHANG) > 0) { $children-- } };
  foreach $entry (@entries) {
    if ($checked_pairs{$entry->{switch}}) {
      next;
    }
    $checked_pairs{$entry->{switch}}=1;
    pipe my $child,my $parent;
    $child->autoflush(1);
    $parent->autoflush(1);
    $children++;
    $cpid = xCAT::Utils->xfork;
    unless (defined $cpid) { die "Cannot fork" };
    if ($cpid == 0) {
      close($child);
      $self->refresh_switch($parent,$community,$entry->{switch});
      exit(0);
    }
    close($parent);
    $inputs->add($child);
  }
  while($children) {
    $self->handle_output($inputs);
  }
  while ($self->handle_output($inputs)) {}; #Drain the pipes
  $self->{timestamp}=time;
}

sub handle_output {
  my $self = shift;
  my $inputs = shift;
  my @readied = $inputs->can_read(1);
  my $rc = @readied;
  my $ready;
  foreach $ready (@readied) {
    my $line = <$ready>;
    unless ($line) {
      $inputs->remove($ready);
      close($ready);
      next;
    }
    $line =~ m/^([^|]*)\|(.*)/;
    $self->{mactable}->{$1}=$2;
  }
  return $rc;
}

sub walkoid {
  my $session = shift;
  my $oid = shift;
  my $retmap = undef; 
  my $varbind = new SNMP::Varbind([$oid,'']);
  $session->getnext($varbind);
  if ($session->{ErrorStr}) {
   xCAT::MsgUtils->message("S","Error communicating with ".$session->{DestHost}.": ".$session->{ErrorStr});
    return undef;
  }
  my $count=0;
  while ($varbind->[0] =~ /^$oid\.?(.*)/) {
    $count++;
    if ($1) { 
      $retmap->{$1.".".$varbind->[1]}=$varbind->[2]; #If $1 is set, means key should 
    } else {
      $retmap->{$varbind->[1]}=$varbind->[2]; #If $1 is set, means key should 
    }

    $session->getnext($varbind);
  }
  return $retmap;
}


sub refresh_switch {
  my $self = shift;
  my $output = shift;
  my $community = shift;
  my $switch = shift;
  $session = new SNMP::Session(
                  DestHost => $switch,
                  Version => '1',
                  Community => $community,
                  UseNumeric => 1
             );
  #if ($error) { die $error; }
  unless ($session) { xCAT::MsgUtils->message("S","Failed to communicate with $switch"); return; }
  my $namemap = walkoid($session,'.1.3.6.1.2.1.31.1.1.1.1');
  if ($namemap) {
     my $ifnamesupport=0; #Assume broken ifnamesupport until proven good... (Nortel switch)
     foreach (keys %{$namemap}) {
        if ($namemap->{$_}) {
           $ifnamesupport=1;
           last;
        }
     }
     unless ($ifnamesupport) {
        $namemap=0;
     }
  }
  unless ($namemap) { #Failback to ifDescr.  ifDescr is close, but not perfect on some switches
     $namemap = walkoid($session,'.1.3.6.1.2.1.2.2.1.2');
  }
  unless ($namemap) {
    return;
  }
  #Above is valid without community string indexing, on cisco, we need it on the next one and onward
  my $iftovlanmap = walkoid($session,'.1.3.6.1.4.1.9.9.68.1.2.2.1.2');
  my %vlans_to_check;
  if (defined($iftovlanmap)) { #We have a cisco, the intelligent thing is to do SNMP gets on the ports 
# that we can verify are populated per switch table
    my $portid;
    foreach $portid (keys %{$namemap}) {
      my $portname;
      my $switchport = $namemap->{$portid};
      foreach $portname (keys %{$self->{switches}->{$switch}}) {
        unless (namesmatch($portname,$switchport)) { next }
        $vlans_to_check{$iftovlanmap->{$portid}} = 1;
      }
    }
  } else {
    $vlans_to_check{'NA'}=1;
  }

  my $vlan;
  foreach $vlan (keys %vlans_to_check) {
    unless ($vlan eq 'NA') { 
      $session = new SNMP::Session(
                  DestHost => $switch,
                  Version => '1',
                  Community => $community."@".$vlan,
                  UseNumeric => 1
             );
    }
    unless ($session) { return; } 
    my $bridgetoifmap = walkoid($session,'.1.3.6.1.2.1.17.1.4.1.2'); # Good for all switches
    # my $mactoindexmap = walkoid($session,'.1.3.6.1.2.1.17.4.3.1.2'); 
    my $mactoindexmap = walkoid($session,'.1.3.6.1.2.1.17.7.1.2.2.1.2');
    unless (defined($mactoindexmap)) { #if no qbridge defined, try bridge mib, probably cisco
      #$mactoindexmap = walkoid($session,'.1.3.6.1.2.1.17.7.1.2.2.1.2');
      $mactoindexmap = walkoid($session,'.1.3.6.1.2.1.17.4.3.1.2'); 
    } #Ok, time to process the data
    foreach my $oid (keys %$namemap) {
    #$oid =~ m/1.3.6.1.2.1.31.1.1.1.1.(.*)/;
      my $ifindex = $oid;
      my $portname;
      my $switchport = $namemap->{$oid};
      foreach $portname (keys %{$self->{switches}->{$switch}}) { # a little redundant, but 
                                                                 # computationally trivial
        unless (namesmatch($portname,$switchport)) { next }
        #if still running, we have match
        foreach my $boid (keys %$bridgetoifmap) {
          unless ($bridgetoifmap->{$boid} == $ifindex) { next; }
          my $bridgeport = $boid;
          foreach (keys %$mactoindexmap) { 
            if ($mactoindexmap->{$_} == $bridgeport) {
              my @tmp = split /\./, $_;
              my @mac = @tmp[-6 .. -1];
              printf $output  "%02x:%02x:%02x:%02x:%02x:%02x|%s\n",@mac,$self->{switches}->{$switch}->{$portname};
            }
          }
        }
      }
    }
  }
}
                



1;
