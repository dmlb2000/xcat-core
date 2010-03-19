package xCAT_plugin::dns;
use strict;
use Getopt::Long;
use Net::DNS;
use xCAT::Table;
use Sys::Hostname;
use Socket;
use Fcntl qw/:flock/;
#This is a rewrite of DNS management using nsupdate rather than direct zone mangling

my $callback;

sub handled_commands
{
    return {"makedns" => "dns"};
}
sub get_reverse_zone_for_entity {
    my $ctx = shift;
    my $node = shift;
    my $net;
    if ($ctx->{hoststab} and $ctx->{hoststab}->{$node} and $ctx->{hoststab}->{$node}->[0]->{ip}) {
        $node = $ctx->{hoststab}->{$node}->[0]->{ip};
    }
    my $tvar;
    if ($tvar = inet_aton($node)) { #This is an assignment, we are testing and storing the value in one shot
        $tvar = unpack("N",$tvar);
        foreach my $net (keys %{$ctx->{nets}}) {
            if ($ctx->{nets}->{$net}->{netn} == ($tvar & $ctx->{nets}->{$net}->{mask})) {
                my $maskstr = unpack("B32",pack("N",$ctx->{nets}->{$net}->{mask}));
                my $maskcount = ($maskstr =~ tr/1//);
                $maskcount+=((8-($maskcount%8))%8); #round to the next octet
                my $newmask = 2**$maskcount -1 << (32 - $maskcount);
                my $rev = inet_ntoa(pack("N",($tvar & $newmask)));
                my @zone;
                my @orig=split /\./,$rev;
                while ($maskcount) {
                    $maskcount-=8;
                    unshift(@zone,(shift @orig));
                }
                $rev = join('.',@zone);
                $rev .= '.IN-ADDR.ARPA';
                return $rev;
            }
        }
    }
    return undef;
}

sub process_request {
    my $request = shift;
    $callback = shift;
    umask 0007;
    my $ctx = {};
    my @nodes=();
    my $hadargs=0;
    my $allnodes;
    my $zapfiles;
    if ($request->{arg}) {
        $hadargs=1;
        @ARGV=@{$request->{arg}};
        if (!GetOptions(
            'a|all' => \$allnodes,
            'n|new' => \$zapfiles,
            )) {
            sendmsg([1,"TODO: makedns Usage message"]);
            return;
        }
    }
        
    my $sitetab = xCAT::Table->new('site');
    my $stab = $sitetab->getAttribs({key=>'domain'},['value']);
    unless ($stab and $stab->{value}) {
        sendmsg([1,"domain not defined in site table"]);
        return;
    }
    $ctx->{domain} = $stab->{value};

    if ($request->{node}) { #we have a noderange to process
        @nodes = @{$request->{node}};
    } elsif ($allnodes) {
        #read all nodelist specified nodes
    } else { 
        #legacy behavior, read from /etc/hosts
        my $hostsfile;
        open($hostsfile,"<","/etc/hosts");
        flock($hostsfile,LOCK_SH);
        my @contents = <$hostsfile>;
        flock($hostsfile,LOCK_UN);
        close($hostsfile);
        my $domain = $ctx->{domain};
        unless ($domain =~ /^\./) { $domain = '.'.$domain; }
        my $addr;
        my $name;
        my $canonical;
        my $aliasstr;
        my @aliases;
        my $names;
        foreach (@contents) {
            chomp; #no newline
            s/#.*//; #strip comments;
            s/^[ \t\n]*//; #remove leading whitespace
            next unless ($_); #skip empty lines
            ($addr,$names) = split /[ \t]+/,$_,2;
            if ($addr !~ /^\d+\.\d+\.\d+\.\d+$/) {
                sendmsg(":Ignoring line $_ in /etc/hosts, only IPv4 format entries are supported currently");
                next;
            }
            unless ($names =~ /^[a-z0-9\. \t\n-]+$/i) {
                sendmsg(":Ignoring line $_ in /etc/hosts, names  $names contain invalid characters (valid characters include a through z, numbers and the '-', but not '_'");
                next;
            }
            ($canonical,$aliasstr)  = split /[ \t]+/,$names,2;
            if ($aliasstr) {
                @aliases= split /[ \t]+/,$aliasstr;
            } else {
                @aliases = ();
            }
            my %names = ();
            my $node = $canonical;
            unless ($canonical =~ /$domain/) {
                $canonical.=$domain;
            }
            unless ($canonical =~ /\.\z/) { $canonical .= '.' } #for only the sake of comparison, ensure consistant dot suffix
            foreach my $alias (@aliases) {
                unless ($alias =~ /$domain/) {
                    $alias .= $domain;
                }
                unless ($alias =~ /\.\z/) {
                    $alias .= '.';
                }
                if ($alias eq $canonical) {
                    next;
                }
                $ctx->{aliases}->{$node}->{$alias}=1; #remember alias for CNAM records later
            }
            push @nodes,$node;
            $ctx->{nodeips}->{$node}->{$addr}=1;
        }
    }
    my $hoststab = xCAT::Table->new('hosts',-create=>0);
    if ($hoststab) {
        $ctx->{hoststab} = $hoststab->getNodesAttribs(\@nodes,['ip']);
    }
    $ctx->{nodes} = \@nodes;
    my $networkstab = xCAT::Table->new('networks',-create=>0);
    unless ($networkstab) { sendmsg([1,'Unable to enumerate networks, try to run makenetworks']); }
    my @networks = $networkstab->getAllAttribs('net','mask');
    foreach (@networks) {
        my $maskn = unpack("N",inet_aton($_->{mask}));
        $ctx->{nets}->{$_->{net}}->{mask} = $maskn;
        $ctx->{nets}->{$_->{net}}->{netn} = unpack("N",inet_aton($_->{net}));
    }
    my $passtab = xCAT::Table->new('passwd');
    my $pent = $passtab->getAttribs({key=>'omapi',username=>'xcat_key'},['password']);
    if ($pent and $pent->{password}) { 
        $ctx->{privkey} = $pent->{password};
    } #do not warn/error here yet, if we can't generate or extract, we'll know later
    $stab =  $sitetab->getAttribs({key=>'forwarders'},['value']);
    if ($stab and $stab->{value}) {
        my @forwarders = split /[ ,]/,$stab->{value};
        $ctx->{forwarders}=\@forwarders;
    }
    $ctx->{zonestotouch}->{$ctx->{domain}}=1;
    foreach (@nodes) {
        my $revzone =  get_reverse_zone_for_entity($ctx,$_);;
        unless ($revzone) { next; }
        $ctx->{revzones}->{$_} = $revzone;
        $ctx->{zonestotouch}->{$ctx->{revzones}->{$_}}=1;
    }
    if (1) { #TODO: function to detect and return 1 if the master server is DNS SOA for all the zones we care about
        #here, we are examining local files to assure that our key is in named.conf, the zones we care about are there, and that if
        #active directory is in use, allow the domain controllers to update specific zones
        $stab =$sitetab->getAttribs({key=>'directoryprovider'},['value']);
        if ($stab and $stab->{value} and $stab->{value} eq 'activedirectory') {
            $stab =$sitetab->getAttribs({key=>'directoryservers'},['value']);
            if ($stab and $stab->{value} and $stab->{value}) {
                my @dservers = split /[ ,]/,$stab->{value};
                $ctx->{adservers} = \@dservers;
                $ctx->{adzones} = {
                    "_msdcs.". $ctx->{domain} => 1,
                    "_sites.". $ctx->{domain} => 1,
                    "_tcp.". $ctx->{domain} => 1,
                    "_udp.". $ctx->{domain} => 1,
                };
            }
        }
        $stab =$sitetab->getAttribs({key=>'dnsupdaters'},['value']); #allow unsecure updates from these
        if ($stab and $stab->{value} and $stab->{value}) {
                my @nservers = split /[ ,]/,$stab->{value};
                $ctx->{dnsupdaters} = \@nservers;
        }
        if ($zapfiles) { #here, we unlink all the existing files to start fresh
            unlink "/etc/named.conf";
            foreach (</var/named/db.*>) {
                unlink $_;
            }
            foreach (</var/lib/named/db.*>) {
                unlink $_;
            }
        }
        #We manipulate local namedconf
        $ctx->{dbdir} = get_dbdir();
        update_namedconf($ctx); 
        update_zones($ctx);
        if ($ctx->{restartneeded}) {
            sendmsg("Restarting named");
            system("/sbin/service named start");
            system("/sbin/service named reload");
            sendmsg("Restarting named complete");
        }
    } else {
        unless ($ctx->{privkey}) {
            sendmsg([1,"Unable to update DNS due to lack of credentials in passwd to communicate with remote server"]);
        }
    }
    #now we stick to Net::DNS style updates, with TSIG if possible.  TODO: kerberized (i.e. Windows) DNS server support, maybe needing to use nsupdate -g....
    $ctx->{resolver} = Net::DNS::Resolver->new();
    add_records($ctx);
}

sub get_dbdir {
    if (-d "/var/named") {
        return "/var/named/";
    } elsif (-d "/var/lib/named") {
        return "/var/lib/named/";
    } else {
        use File::Path;
        mkpath "/var/named/";
        chown(scalar(getpwnam('named')),scalar(getgrnam('named')),"/var/named");
        return "/var/named/";
    }
}

sub update_zones {
    my $ctx = shift;
    my $currzone;
    my $dbdir = $ctx->{dbdir};
    my $domain = $ctx->{domain};
    my $name = hostname;
    my $node = $name;
    unless ($domain =~ /^\./) {
        $domain = '.'.$domain;
    }
    unless ($name =~ /\./) {
        $name .= $domain;
    }
    unless ($name =~ /\.\z/) {
        $name .= '.';
    }
    my $ip=$node;
    if ($ctx->{hoststab} and $ctx->{hoststab}->{$node} and $ctx->{hoststab}->{$node}->[0]->{ip}) {
        $ip = $ctx->{hoststab}->{$node}->[0]->{ip};
    } else {
        unless ($ip = inet_aton($ip)) {
            print "Unable to find an IP for $node in hosts table or via system lookup (i.e. /etc/hosts";
            sendmsg([1,"Unable to find an IP for $node in hosts table or via system lookup (i.e. /etc/hosts"]);
            next;
        }
        $ip = inet_ntoa($ip);
    }
    my @neededzones = keys %{$ctx->{zonestotouch}};
    push @neededzones,keys %{$ctx->{adzones}};
    my ($sec, $min, $hour, $mday, $mon, $year, $rest) = localtime(time);
    my $serial = ($mday * 100) + (($mon + 1) * 10000) + (($year + 1900) * 1000000);
    foreach $currzone (@neededzones) {
        if ($currzone =~ /IN-ADDR\.ARPA/) {
            $currzone =~ s/\.IN-ADDR\.ARPA.*//;
            my @octets = split/\./,$currzone;
            $currzone = join('.',reverse(@octets));
        }
        unless (-f $dbdir."/db.$currzone") {
            my $zonehdl;
            open($zonehdl,">>",$dbdir."/db.$currzone");
            flock($zonehdl,LOCK_EX);
            seek($zonehdl,0,0);
            truncate($zonehdl,0);
            print $zonehdl '$TTL 86400'."\n";
            print $zonehdl '@ IN SOA '.$name." root.$name ( $serial 10800 3600 604800 86400 )\n";
            print $zonehdl "  IN NS  $name\n";
            if ($name =~ /$currzone/) { #Must guarantee an A record for the DNS server
                print $zonehdl "$name  IN A  $ip\n";
            }
            flock($zonehdl,LOCK_UN);
            close($zonehdl);
            chown(scalar(getpwnam('named')),scalar(getgrnam('named')),$dbdir."/db.$currzone");
            $ctx->{restartneeded}=1;
        }
    }
}



sub update_namedconf {
    my $ctx = shift;
    my $namedlocation = '/etc/named.conf';
    my $nameconf;
    my @newnamed;
    my $gotoptions=0;
    my $gotkey=0;
    my %didzones;
    if (-r $namedlocation) {
        my @currnamed=();
        open($nameconf,"<",$namedlocation);
        flock($nameconf,LOCK_SH);
        @currnamed=<$nameconf>;
        flock($nameconf,LOCK_UN);
        close($nameconf);
        my $i = 0;
        for ($i=0;$i<scalar(@currnamed);$i++) {
            my $line = $currnamed[$i];
            if ($line =~ /^options +\{/) {
                $gotoptions=1;
                my $skip=0;
                do {
                    if ($ctx->{forwarders} and $line =~ /forwarders {/) {
                        push @newnamed,"\tforwarders \{\n";
                        $skip=1;
                        foreach (@{$ctx->{forwarders}}) {
                            push  @newnamed,"\t\t".$_.";\n";
                        }
                        push @newnamed,"\t};\n";
                    } elsif ($skip) {
                        if ($line =~ /};/) {
                            $skip = 0;
                        }
                    } else {
                        push @newnamed,$line;
                    }
                    $i++;
                    $line = $currnamed[$i];
                } while ($line !~ /^\};/);
                push @newnamed,$line;
            } elsif ($line =~ /^zone "([^"]*)" in \{/) {
                my $currzone = $1;
                if ($ctx->{zonestotouch}->{$currzone} or $ctx->{adzones}->{$currzone}) {
                    $didzones{$currzone}=1;
                    my @candidate = ($line);
                    my $needreplace=1;
                    do {
                        $i++;
                        $line =  $currnamed[$i];
                        push @candidate,$line;
                        if ($line =~ /key xcat_key/) {
                            $needreplace=0;
                        }
                    } while ($line !~ /^\};/); #skip the old file zone
                    unless ($needreplace) {
                        push @newnamed,@candidate;
                        next;
                    }
                    $ctx->{restartneeded}=1;
                    push @newnamed,"zone \"$currzone\" in {\n","\ttype master;\n","\tallow-update {\n","\t\tkey xcat_key;\n";
                    my @list;
                    if (not $ctx->{adzones}->{$currzone}) {
                        if ($ctx->{dnsupdaters}) {
                            @list = @{$ctx->{dnsupdaters}};
                        }
                    } else {
                        if ($ctx->{adservers}) {
                            @list = @{$ctx->{adservers}};
                        }
                    }
                    foreach (@list) {
                        push @newnamed,"\t\t$_;\n";
                    }
                    if ($currzone =~ /IN-ADDR\.ARPA/) {
                        my $net = $currzone;
                        $net =~ s/.IN-ADDR\.ARPA.*//;
                        my @octets = split/\./,$net;
                        $net = join('.',reverse(@octets));
                        push @newnamed,"\t};\n","\tfile \"db.$net\";\n","};\n";

                    } else {
                        push @newnamed,"\t};\n","\tfile \"db.$currzone\";\n","};\n";
                    }
                } else {
                    push @newnamed,$line;
                    do {
                        $i++;
                        $line =  $currnamed[$i];
                        push @newnamed,$line;
                    } while ($line !~ /^\};/);
                }

            } elsif ($line =~ /^key xcat_key/) {
                $gotkey=1;
                if ($ctx->{privkey}) {
                    #for now, assume the field is correct
                    #push @newnamed,"key xcat_key {\n","\talgorithm hmac-md5;\n","\tsecret \"".$ctx->{privkey}."\";\n","};\n\n";
                    push @newnamed,$line;
                    do {
                        $i++;
                        $line =  $currnamed[$i];
                        push @newnamed,$line;
                    } while ($line !~ /^\};/);
                } else {
                    push @newnamed,$line;
                    while ($line !~ /^\};/) { #skip the old file zone
                        if ($line =~ /secret \"([^"]*)\"/) {
                            my $passtab = xCAT::Table->new("passwd",-create=>1);
                            $passtab->setAttribs({key=>"omapi",user=>"xcat_key"},{password=>$1});
                        }
                        $i++;
                        $line =  $currnamed[$i];
                        push @newnamed,$line;
                    }
                }
            } else {
                push @newnamed,$line;
            }
        }
    }
    unless ($gotoptions) {
        push @newnamed,"options {\n","\tdirectory \"".$ctx->{dbdir}."\";\n";
        if ($ctx->{forwarders}) {
            push @newnamed,"\tforwarders {\n";
            foreach (@{$ctx->{forwarders}}) {
                push @newnamed,"\t\t$_;\n";
            }
            push @newnamed,"\t};\n";
        }
        push @newnamed,"};\n\n";
    }
    unless ($gotkey) {
        unless ($ctx->{privkey}) { #need to generate one
            $ctx->{privkey} = encode_base64(genpassword(32));
        }
        push @newnamed,"key xcat_key {\n","\talgorithm hmac-md5;\n","\tsecret \"".$ctx->{privkey}."\";\n","};\n\n";
        $ctx->{restartneeded}=1;
    }
    my $zone;
    foreach $zone (keys %{$ctx->{zonestotouch}}) {
        if ($didzones{$zone}) { next; }
        $ctx->{restartneeded}=1; #have to add a zone, a restart will be needed
        push @newnamed,"zone \"$zone\" in {\n","\ttype master;\n","\tallow-update {\n","\t\tkey xcat_key;\n";
        foreach (@{$ctx->{dnsupdaters}}) {
            push @newnamed,"\t\t$_;\n";
        }
        if ($zone =~ /IN-ADDR\.ARPA/) {
            my $net = $zone;
            $net =~ s/.IN-ADDR\.ARPA.*//;
            my @octets = split/\./,$net;
            $net = join('.',reverse(@octets));
            push @newnamed,"\t};\n","\tfile \"db.$net\";\n","};\n";

        } else {
            push @newnamed,"\t};\n","\tfile \"db.$zone\";\n","};\n";
        }
    }
    foreach $zone (keys %{$ctx->{adzones}}) {
        if ($didzones{$zone}) { next; }
        $ctx->{restartneeded}=1; #have to add a zone, a restart will be needed
        push @newnamed,"zone \"$zone\" in {\n","\ttype master;\n","\tallow-update {\n","\t\tkey xcat_key;\n";
        foreach (@{$ctx->{adservers}}) {
            push @newnamed,"\t\t$_;\n";
        }
        push @newnamed,"\t};\n","\tfile \"db.$zone\";\n","};\n\n";
    }
    my $newnameconf;
    open($newnameconf,">>",$namedlocation);
    flock($newnameconf,LOCK_EX);
    seek($newnameconf,0,0);
    truncate($newnameconf,0);
    for my $l  (@newnamed) { print $newnameconf $l; }
    flock($newnameconf,LOCK_UN);
    close($newnameconf);
    chown (scalar(getpwnam('root')),scalar(getgrnam('named')),$namedlocation);
}

sub add_records {
    my $ctx = shift;
    unless ($ctx->{privkey}) {
        my $passtab = xCAT::Table->new('passwd');
        my $pent = $passtab->getAttribs({key=>'omapi',username=>'xcat_key'},['password']);
        if ($pent and $pent->{password}) { 
            $ctx->{privkey} = $pent->{password};
        } else {
            sendmsg([1,"Unable to find omapi key in passwd table"]);
        }
    }
    my $node;
    my $ip;
    my $domain = $ctx->{domain}; # store off for lazy typing and possible local mangling
    unless ($domain =~ /^\./) { $domain = '.'.$domain; } #example.com becomes .example.com for consistency
    $ctx->{nsmap} = {}; #will store a map to known NS records to avoid needless redundant queries to sort nodes into domains
    $ctx->{updatesbyzone}={}; #sort all updates into their respective zones for bulk update for fewer DNS transactions
    foreach $node (@{$ctx->{nodes}}) {
        $ip = $node;
        my $name = $node;
        unless ($name =~ /$domain/) { $name .= $domain } # $name needs to represent fqdn, but must preserve $node as a nodename for cfg lookup
        #if (domaintab->{$node}->[0]->{domain) { $domain = domaintab->{$node}->[0]->{domain) }  
        #above is TODO draft of how multi-domain support could come into play
        if ($ctx->{hoststab} and $ctx->{hoststab}->{$node} and $ctx->{hoststab}->{$node}->[0]->{ip}) {
            $ip = $ctx->{hoststab}->{$node}->[0]->{ip};
        } else {
            unless ($ip = inet_aton($ip)) {
                sendmsg([1,"Unable to find an IP for $node in hosts table or via system lookup (i.e. /etc/hosts"]);
                next;
            }
            $ip = inet_ntoa($ip);
        }
        $ctx->{currip}=$ip;
        #time to update, A and PTR records, IPv6 still TODO
        $ip = join('.',reverse(split(/\./,$ip)));
        $ip .= '.IN-ADDR.ARPA.';
        #ok, now it is time to identify which zones should actually hold the forward (A) and reverse (PTR) records and a nameserver to handle the request
        my $revzone = $ip;
        $ctx->{currnode}=$node;
        $ctx->{currname}=$name;
        $ctx->{currrevname}=$ip;
        find_nameserver_for_dns($ctx,$revzone);
        find_nameserver_for_dns($ctx,$domain);
    }
    my $zone;
    foreach $zone (keys %{$ctx->{updatesbyzone}}) {
        my $resolver = Net::DNS::Resolver->new(nameservers=>[$ctx->{nsmap}->{$zone}]);
        my $entry;
        my $update = Net::DNS::Update->new($zone);
        foreach $entry (@{$ctx->{updatesbyzone}->{$zone}}) {
            $update->push(update=>rr_add($entry));
        }
        $update->sign_tsig("xcat_key",$ctx->{privkey});
        my $reply = $resolver->send($update);
    }
}
sub find_nameserver_for_dns {
    my $ctx = shift;
    my $zone = shift;
    my $node = $ctx->{currnode};
    my $ip = $ctx->{currip};
    my $rname = $ctx->{currrevname};
    my $name = $ctx->{currname};
    unless ($name =~ /\.\z/) { $name .= '.' }
    my @rrcontent = ( "$name IN A $ip" );
    foreach (keys %{$ctx->{nodeips}->{$node}}) {
        unless ($_ eq $ip) {
            push @rrcontent,"$name IN A $_";
        }
    }
    if ($zone =~ /IN-ADDR.ARPA/) { #reverse style
        @rrcontent = ("$rname IN PTR $name");
    }
    while ($zone) {
       unless (defined $ctx->{nsmap}->{$zone}) { #ok, we already thought about this zone and made a decision
           if ($zone =~ /^\.*192.IN-ADDR.ARPA\.*/ or $zone =~ /^\.*172.IN-ADDR.ARPA\.*/ or $zone =~ /127.IN-ADDR.ARPA\.*/ or $zone =~ /^\.*IN-ADDR.ARPA\.*/ or $zone =~ /^\.*ARPA\.*/) {
                $ctx->{nsmap}->{$zone} = 0; #ignore zones that are likely to appear, but probably not ours
           } else {
               my $reply = $ctx->{resolver}->query($zone,'NS');
               if ($reply)  {
                    foreach my $record ($reply->answer) {
                        if ( $record->nsdname =~ /blackhole.*\.iana\.org/) {
                            $ctx->{nsmap}->{$zone} = 0; 
                        } else {
                            $ctx->{nsmap}->{$zone} = $record->nsdname;
                        }
                    }
               } else { 
                   $ctx->{nsmap}->{$zone} = 0; 
               }
           }
       }
       if ($ctx->{nsmap}->{$zone}) {  #we have a nameserver for this zone, therefore this zone is one to update
           push @{$ctx->{updatesbyzone}->{$zone}},@rrcontent;
           last;
       } else { #we have it defined, but zero, means search higher domains.  Possible to shortcut further by pointing to the right domain, maybe later
            if ($zone !~ /\./) {
               sendmsg([1,"Unable to find reverse zone to hold $node"],$node);
               last;
            }

           $zone =~ s/^[^\.]*\.//; #strip all up to and including first dot
           unless ($zone) {
               sendmsg([1,"Unable to find zone to hold $node"],$node);
               last;
           }
       }
    }
}
sub sendmsg {
#    my $callback = $output_handler;
    my $text = shift;
    my $node = shift;
    my $descr;
    my $rc;
    if (ref $text eq 'HASH') {
        die "not right now";
    } elsif (ref $text eq 'ARRAY') {
        $rc = $text->[0];
        $text = $text->[1];
    }
    if ($text =~ /:/) {
        ($descr,$text) = split /:/,$text,2;
    }
    $text =~ s/^ *//;
    $text =~ s/ *$//;
    my $msg;
    my $curptr;
    if ($node) {
        $msg->{node}=[{name => [$node]}];
        $curptr=$msg->{node}->[0];
    } else {
        $msg = {};
        $curptr = $msg;
    }
    if ($rc) {
        $curptr->{errorcode}=[$rc];
        $curptr->{error}=[$text];
        $curptr=$curptr->{error}->[0];
    } else {
        $curptr->{data}=[{contents=>[$text]}];
        $curptr=$curptr->{data}->[0];
        if ($descr) { $curptr->{desc}=[$descr]; }
    }
#        print $outfd freeze([$msg]);
#        print $outfd "\nENDOFFREEZE6sK4ci\n";
#        yield;
#        waitforack($outfd);
    $callback->($msg);
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
