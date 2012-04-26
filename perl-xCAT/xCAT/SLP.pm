package xCAT::SLP;
use Carp;
use IO::Select;
use strict;
my $ip6support = eval {
	require IO::Socket::INET6;
	require Socket6;
	1;
};
use Socket;
unless ($ip6support) {
	require IO::Socket::INET;
}

#TODO: somehow get at system headers to get the value, put in linux's for now
use constant IPV6_MULTICAST_IF => 17;
use constant IP_MULTICAST_IF => 32;
my %xid_to_srvtype_map;
my $xid;

sub getmulticasthash {
	my $hash=0;
	my @nums = unpack("C*",shift);
	foreach my $num (@nums) {
		$hash *= 33;
		$hash += $num;
		$hash &= 0xffff;
	}
	$hash &= 0x3ff;
	$hash |= 0x1000;
	return sprintf("%04x",$hash);
}
			
	
sub dodiscover {
	my %args = @_;
	$xid = int(rand(16384))+1;
	unless ($args{'socket'}) {
		if ($ip6support) {
			$args{'socket'} = IO::Socket::INET6->new(Proto => 'udp');
		} else {
			$args{'socket'} = IO::Socket::INET->new(Proto => 'udp');
		}
		#make an extra effort to request biggest receive buffer OS is willing to give us
		if (-r "/proc/sys/net/core/rmem_max") { # we can detect the maximum allowed socket, read it.
			my $sysctl;
			open ($sysctl,"<","/proc/sys/net/core/rmem_max");
			my $maxrcvbuf=<$sysctl>;
			my $rcvbuf = $args{'socket'}->sockopt(SO_RCVBUF);
			if ($maxrcvbuf > $rcvbuf) {
				$args{'socket'}->sockopt(SO_RCVBUF,$maxrcvbuf/2);
			}
		}
	}
	unless ($args{SrvTypes}) { croak "SrvTypes argument is required for xCAT::SLP::Dodiscover"; }
	setsockopt($args{'socket'},SOL_SOCKET,SO_BROADCAST,1); #allow for broadcasts to be sent, we know what we are doing
	my @srvtypes;
	if (ref $args{SrvTypes}) {
		@srvtypes = @{$args{SrvTypes}};
	} else {
		@srvtypes = split /,/,$args{SrvTypes};
	}
	my $interfaces = get_interfaces(%args);
    if ($args{Ip}) {
        my @ips = split /,/, $args{Ip};
            foreach my $ip (@ips) {
                foreach my $nic (keys %$interfaces) {
                        unless (${${$interfaces->{$nic}}{ipv4addrs}}[0] =~ $ip) {
                                delete $interfaces->{$nic};
                            }
                    }
            }
    }
	foreach my $srvtype (@srvtypes) {
		send_service_request_single(%args,ifacemap=>$interfaces,SrvType=>$srvtype);
	}
	unless ($args{NoWait}) { #in nowait, caller owns the responsibility..
		#by default, report all respondants within 3 seconds:
		my %rethash;
		my $waitforsocket = IO::Select->new();
		$waitforsocket->add($args{'socket'});
		my $retrytime = ($args{Retry}>0)?$args{Retry}+1:1;
		for(my $i = 0; $i < $retrytime; $i++){
		    my $deadline=time()+3;
		    while ($deadline > time()) {
		    	while ($waitforsocket->can_read(1)) {
		    		my $slppacket;
		    		my $peer = $args{'socket'}->recv($slppacket,1400);
		    		my( $port,$flow,$ip6n,$ip4n,$scope);
		    		my $peername;
		    		if ($ip6support) {
		    			( $port,$flow,$ip6n,$scope) = Socket6::unpack_sockaddr_in6_all($peer);
		    			$peername = Socket6::inet_ntop(Socket6::AF_INET6(),$ip6n);
		    		} else {
		    			($port,$ip4n) = sockaddr_in($peer);
		    			$peername = inet_ntoa($ip4n);
		    		}
		    		if ($rethash{$peername}) {
		    			next; #got a dupe, discard
		    		}
		    		my $result = process_slp_packet(packet=>$slppacket,sockaddr=>$peer,'socket'=>$args{'socket'});
		    		if ($result) {
		    			if ($peername =~ /\./) { #ipv4
		    				$peername =~ s/::ffff://;
		    			}
		    			$result->{peername} = $peername;
		    			$result->{scopeid} = $scope;
		    			$result->{sockaddr} = $peer;
		    			my $hashkey;
		    			if ($peername =~ /fe80/) {
		    				$peername .= '%'.$scope;
		    			}
		    			$rethash{$peername} = $result;
		    			if ($args{Callback}) {
		    				$args{Callback}->($result);
		    			}
		    		}
		    	}
		    	foreach my $srvtype (@srvtypes) {
		    		send_service_request_single(%args,ifacemap=>$interfaces,SrvType=>$srvtype);
		    	}
		    }
		}	
		return \%rethash;
	}
}

sub process_slp_packet {
	my %args = @_;
	my $sockaddy = $args{sockaddr};
	my $socket = $args{'socket'};
	my $packet = $args{packet};
	my $parsedpacket = removeslpheader($packet);
	if ($parsedpacket->{FunctionId} == 2) {#Service Reply
		parse_service_reply($parsedpacket->{payload},$parsedpacket);
		unless (ref $parsedpacket->{service_urls} and scalar @{$parsedpacket->{service_urls}}) { return undef; }
		#send_attribute_request('socket'=>$socket,url=>$parsedpacket->{service_urls}->[0],sockaddr=>$sockaddy);
		if ($parsedpacket->{attributes}) { #service reply had ext
			return $parsedpacket; #don't bother sending attrrequest, already got it in first packet
		}
		my $srvtype = $xid_to_srvtype_map{$parsedpacket->{Xid}};
		my $packet = generate_attribute_request(%args,SrvType=>$srvtype);
		$socket->send($packet,0,$sockaddy);
		return undef;
	} elsif ($parsedpacket->{FunctionId} == 7) { #attribute reply
		$parsedpacket->{SrvType} = $xid_to_srvtype_map{$parsedpacket->{Xid}};
		$parsedpacket->{attributes} = parse_attribute_reply($parsedpacket->{payload});
		delete $parsedpacket->{payload};
		return $parsedpacket;
	} else {
		return undef;
	}
}

sub parse_attribute_reply {
	my $contents = shift;
	my @payload = unpack("C*",$contents);
	if ($payload[0] != 0 or $payload[1] != 0) {
		return {};
	}
	splice (@payload,0,2);
	return parse_attribute_list(\@payload);
}
sub parse_attribute_list {
	my $payload = shift;
	my $attrlength = ($payload->[0]<<8)+$payload->[1];
	splice(@$payload,0,2);
	my @attributes = splice(@$payload,0,$attrlength);
	my $attrstring = pack("C*",@attributes);
	my %attribs;
	#now we have a string...
	my $lastattrstring;
	while ($attrstring) {
		if ($lastattrstring eq $attrstring) { #infinite loop
			$attribs{unparsed_attribdata}=$attrstring;
			last;
		}
		$lastattrstring=$attrstring;
		if ($attrstring =~ /^\(/) {
			$attrstring =~ s/([^)]*\)),?//;
			my $attrib = $1;
			$attrib =~ s/^\(//;
			$attrib =~ s/\),?$//;
			$attrib =~ s/=(.*)$//;
			$attribs{$attrib}=[];
            my $valstring = $1;
            if (defined $valstring) {
				foreach(split /,/,$valstring) {
					push @{$attribs{$attrib}},$_;
				}
			}
		} else {
			$attrstring =~ s/([^,]*),?//;
			$attribs{$1}=[];
		} 
	}
	return \%attribs;
}
sub generate_attribute_request {
	my %args = @_;
	my $srvtype = $args{SrvType};
	my $scope = "DEFAULT";
	if ($args{Scopes}) { $scope = $args{Scopes}; }
	my $packet  = pack("C*",0,0); #no prlist
	my $service = $srvtype;
	$service =~ s!://.*!!;
	my $length = length($service);
	$packet .= pack("C*",($length>>8),($length&0xff));
	$length = length($scope);
	$packet .= $service.pack("C*",($length>>8),($length&0xff)).$scope;
	$packet .= pack("C*",0,0,0,0);
	my $header = genslpheader($packet,FunctionId=>6);
	$xid_to_srvtype_map{$xid++}=$srvtype;
	return $header.$packet;
#	$args{'socket'}->send($header.$packet,0,$args{sockaddry});
}
	

sub parse_service_reply {
	my $packet = shift;
	my $parsedpacket = shift;
	my @reply = unpack("C*",$packet);
	if ($reply[0] != 0 or $reply[1] != 0) {
		return ();
	}
	if ($parsedpacket->{extoffset}) {
		my @extdata = splice(@reply,$parsedpacket->{extoffset}-$parsedpacket->{currentoffset});
		$parsedpacket->{currentoffset} = $parsedpacket->{extoffset};
		parse_extension(\@extdata,$parsedpacket);
	}
	my $numurls = ($reply[2]<<8)+$reply[3];
	splice (@reply,0,4);
	while ($numurls--) {
		push @{$parsedpacket->{service_urls}},extract_next_url(\@reply);
	}
	return;
}

sub parse_extension {
	my $extdata = shift;
	my $parsedpacket = shift;
	my $extid = ($extdata->[0]<<8)+$extdata->[1];
	my $nextext = (($extdata->[2])<<16)+(($extdata->[3])<<8)+$extdata->[4];
	if ($nextext) {
		my @nextext = splice(@$extdata,$nextext-$parsedpacket->{currentoffset});
		$parsedpacket->{currentoffset} = $nextext;
		parse_extension(\@nextext,$parsedpacket);
	}
	splice(@$extdata,0,5);
	if ($extid == 2) {
		#this is defined in RFC 3059, attribute list extension
		#employed by AMM for one...
		my $urllen = ((shift @$extdata)<<8)+(shift @$extdata);
		splice @$extdata,0,$urllen; #throw this out for now..
		$parsedpacket->{attributes} = parse_attribute_list($extdata);
	}
}
	

sub extract_next_url { #section 4.3 url entries
	my $payload = shift;
	splice (@$payload,0,3); # discard reserved and lifetime which we will not bother using
	my $urllength = ((shift @$payload)<<8)+(shift @$payload);
	my @url = splice(@$payload,0,$urllength);
	my $authblocks = shift @$payload;
	unless ($authblocks == 0) { 
		$payload = []; #TODO: skip/use auth blocks if needed to get at more URLs
	}
	return pack("C*",@url);
}
		
sub send_service_request_single {
	my %args = @_;
	my $packet = generate_service_request(%args);
	my $interfaces = $args{ifacemap}; #get_interfaces(%args);
	my $socket = $args{'socket'};
	my $v6addr;
	if ($ip6support) {
		my $hash=getmulticasthash($args{SrvType});
		my $target = "ff02::1:$hash";
		my ($fam, $type, $proto, $name);
		($fam, $type, $proto, $v6addr, $name) = 
		   Socket6::getaddrinfo($target,"svrloc",Socket6::AF_INET6(),SOCK_DGRAM,0);
	}
	my $ipv4mcastaddr = inet_aton("239.255.255.253"); #per rfc 2608
	my $ipv4sockaddr  = sockaddr_in(427,$ipv4mcastaddr);
	foreach my $iface (keys %{$interfaces}) {
		if ($ip6support) {
			setsockopt($socket,Socket6::IPPROTO_IPV6(),IPV6_MULTICAST_IF,pack("I",$interfaces->{$iface}->{scopeidx}));
			$socket->send($packet,0,$v6addr);
		}
		foreach my $sip (@{$interfaces->{$iface}->{ipv4addrs}}) {
			my $ip = $sip;
			$ip =~ s/\/(.*)//;
			my $maskbits = $1;
			my $ipn = inet_aton($ip); #we are ipv4 only, this is ok
			my $ipnum=unpack("N",$ipn);
			$ipnum= $ipnum | (2**(32-$maskbits))-1;
			my $bcastn = pack("N",$ipnum);
			my $bcastaddr = sockaddr_in(427,$bcastn);
			setsockopt($socket,0,IP_MULTICAST_IF,$ipn);
			$socket->send($packet,0,$ipv4sockaddr);
			$socket->send($packet,0,$bcastaddr);
		}
	}
}

sub get_interfaces {
	#TODO: AIX tolerance, no subprocess, include/exclude interface(s)
	my @ipoutput = `ip addr`;
	my %ifacemap;
	my $payingattention=0;
	my $interface;
	my $keepcurrentiface;
	foreach my $line (@ipoutput) {
		if ($line =~ /^\d/) { # new interface, new context..
			if ($interface and not $keepcurrentiface) {
				#don't bother reporting unusable nics
				delete $ifacemap{$interface};
			}
			$keepcurrentiface=0;
			unless ($line =~ /MULTICAST/) { #don't care if it isn't multicast capable
				$payingattention=0;
				next;
			}
			$payingattention=1;
			$line =~ /^([^:]*): ([^:]*):/;
			$interface=$2;
			$ifacemap{$interface}->{scopeidx}=$1;
		}
		unless ($payingattention) { next; } #don't think about lines unless in context of paying attention.
		if ($line =~ /inet/) {
			$keepcurrentiface=1;
		}
		if ($line =~ /\s+inet\s+(\S+)\s/) { #got an ipv4 address, store it
			push @{$ifacemap{$interface}->{ipv4addrs}},$1;
		}
	}
	return \%ifacemap;
}
# discovery is "service request", rfc 2608 
#     0                   1                   2                   3
#     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |       Service Location header (function = SrvRqst = 1)        |
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |      length of <PRList>       |        <PRList> String        \
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |   length of <service-type>    |    <service-type> String      \
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |    length of <scope-list>     |     <scope-list> String       \
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |  length of predicate string   |  Service Request <predicate>  \
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |  length of <SLP SPI> string   |       <SLP SPI> String        \
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
sub generate_service_request {
	my %args = @_;
	my $srvtype = $args{SrvType};
	my $scope = "DEFAULT";
	if ($args{Scopes}) { $scope = $args{Scopes}; }
	my $prlist="";
	my $packet = pack("C*",0,0); #start with PRList, we have no prlist so zero
	#TODO: actually accumulate PRList, particularly between IPv4 and IPv6 runs
	my $length = length($srvtype);
	$packet .= pack("C*",($length>>8),($length&0xff));
	$packet .= $srvtype;
	$length = length($scope);
	$packet .= pack("C*",($length>>8),($length&0xff));
	$packet .= $scope;
	#no ldap predicates, and no auth, so zeroes..
	$packet .= pack("C*",0,0,0,0);
	$packet .= pack("C*",0,2,0,0,0,0,0,0,0,0);
	my $extoffset = length($srvtype)+length($scope)+length($prlist)+10;
	my $header = genslpheader($packet,Multicast=>1,FunctionId=>1,ExtOffset=>$extoffset);
	$xid_to_srvtype_map{$xid++}=$srvtype;
	return $packet = $header.$packet;
}
# SLP header from RFC 2608
#     0                   1                   2                   3
#     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |    Version    |  Function-ID  |            Length             |
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    | Length, contd.|O|F|R|       reserved          |Next Ext Offset|
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |  Next Extension Offset, contd.|              XID              |
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#    |      Language Tag Length      |         Language Tag          \
#    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
sub removeslpheader {
	my $packet = shift;
	my %parsedheader;
	my @payload = unpack("C*",$packet);
	$parsedheader{Version} = shift @payload;
	$parsedheader{FunctionId} = shift @payload;
	splice(@payload,0,3); #remove length
	splice(@payload,0,2); #TODO: parse flags
	my $nextoffset = ((shift @payload)<<16)+((shift @payload)<<8)+(shift @payload); 
	$parsedheader{Xid} = ((shift @payload)<<8)+(shift @payload);
	my $langlen = ((shift @payload)<<8)+(shift @payload);
	$parsedheader{lang} = pack("C*",splice(@payload,0,$langlen)); 
	$parsedheader{payload} = pack("C*",@payload);
	if ($nextoffset != 0) {
		#correct offset since header will be removed
		$parsedheader{currentoffset} = 14+$langlen;
		$parsedheader{extoffset}=$nextoffset;
	}
	return \%parsedheader;
}
	
	
	
sub genslpheader {
	my $packet = shift;
	my %args = @_;
	my $flaghigh=0;
	my $flaglow=0; #this will probably never ever ever change
	if ($args{Multicast}) { $flaghigh |= 0x20; }
	my $extoffset=0;
	if ($args{ExtOffset}) {
		$extoffset = $args{ExtOffset}+16;
	}
	my @extoffset=(($extoffset>>16),(($extoffset>>8)&0xff),($extoffset&0xff));
	my $length = length($packet)+16; #our header is 16 bytes due to lang tag invariance
	if ($length > 1400) { die "Overflow not supported in xCAT SLP"; }
	return pack("C*",2, $args{FunctionId}, ($length >> 16), ($length >> 8)&0xff, $length&0xff, $flaghigh, $flaglow,@extoffset,$xid>>8,$xid&0xff,0,2)."en";
}
		
unless (caller) { 
	#time to provide unit testing/example usage
	#somewhat fancy invocation with multiple services and callback for
	#results on-the-fly
	require Data::Dumper;
	Data::Dumper->import();
	my $srvtypes = ["service:management-hardware.IBM:chassis-management-module","service:management-hardware.IBM:integrated-management-module2","service:management-hardware.IBM:management-module","service:management-hardware.IBM:cec-service-processor"];
	xCAT::SLP::dodiscover(SrvTypes=>$srvtypes,Callback=>sub { print Dumper(@_) });
	#example 2: simple invocation of a single service type
	$srvtypes = "service:management-hardware.IBM:chassis-management-module";
	print Dumper(xCAT::SLP::dodiscover(SrvTypes=>$srvtypes));
	#TODO: pass-in socket and not wait inside SLP.pm example
}
1;
