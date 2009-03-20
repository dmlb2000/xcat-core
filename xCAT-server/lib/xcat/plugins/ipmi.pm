# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#egan@us.ibm.com
#modified by jbjohnso@us.ibm.com
#(C)IBM Corp

package xCAT_plugin::ipmi;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use strict;
use warnings "all";
use xCAT::GlobalDef;
use xCAT_monitoring::monitorctrl;
use xCAT::SPD qw/decode_spd/;

use POSIX qw(ceil floor);
use Storable qw(store_fd retrieve_fd thaw freeze);
use xCAT::Utils;
use xCAT::SvrUtils;
use xCAT::Usage;
use Thread qw(yield);
use LWP 5.64;
use HTTP::Request::Common;
my $tfactor = 0;
my $vpdhash;
my %bmc_comm_pids;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(
	ipmiinit
	ipmicmd
);

sub handled_commands {
  return {
    rpower => 'nodehm:power,mgt',
    getipmicons => 'ipmi',
    rspconfig => 'nodehm:mgt',
    rvitals => 'nodehm:mgt',
    rinv => 'nodehm:mgt',
    rsetboot => 'nodehm:mgt',
    rbeacon => 'nodehm:mgt',
    reventlog => 'nodehm:mgt',
    rfrurewrite => 'nodehm:mgt',
    getrvidparms => 'nodehm:mgt'
  }
}

    
use Data::Dumper;
use POSIX "WNOHANG";
use IO::Handle;
use IO::Socket;
use IO::Select;
use Class::Struct;
use Digest::MD5 qw(md5);
use POSIX qw(WNOHANG mkfifo strftime);
use Fcntl qw(:flock);


#local to module
my @rmcp = (0x06,0x00,0xff,0x07);
my $auth;
my $rssa = 0x20;
my $rqsa = 0x81;
my $seqlun = 0x00;
my @session_id = (0,0,0,0);
my @challenge = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
my @seqnum = (0,0,0,0);
my $outfd; #File descriptor for children to send messages to parent
my $currnode; #string to describe current node, presumably nodename
my $globrc=0;
my $userid;
my $passwd;
my $ipmi_bmcipaddr;
my $timeout;
my $port;
my $debug;
my $ndebug = 0;
my @cmdargv;
my $sock;
my @user;
my @pass;
my $channel_number;
my %sdr_hash;
my %fru_hash;
my $ipmiv2=0;
my $authoffset=0;
my $enable_cache="yes";
my $cache_dir = "/var/cache/xcat";
#my $ibmledtab = $ENV{XCATROOT}."/lib/GUMI/ibmleds.tab";
use xCAT::data::ibmleds;
use xCAT::data::ipmigenericevents;
use xCAT::data::ipmisensorevents;
my $cache_version = 2;
my $frudex; #iterator for initfru to use

my $status_noop="XXXno-opXXX";

my %idpxthermprofiles = (
    '0z' => [0x37,0x41,0,0,0,0,5,0xa,0x3c,0xa,0xa,0x1e],
    '1a' => [0x30,0x3c,0,0,0,0,5,0xa,0x3c,0xa,0xa,0x1e], 
    '2b' => [0x30,0x3c,0,0,0,0,5,0xa,0x3c,0xa,0xa,0x1e], 
    '3c' => [0x30,0x3c,0,0,0,0,5,0xa,0x3c,0xa,0xa,0x1e], 
    '4d' => [0x37,0x44,0,0,0,0,5,0xa,0x3c,0xa,0xa,0x1e], 
    '5e' => [0x37,0x44,0,0,0,0,5,0xa,0x3c,0xa,0xa,0x1e], 
    '6f' => [0x35,0x44,0,0,0,0,5,0xa,0x3c,0xa,0xa,0x1e], 
);
my %codes = (
	0x00 => "Command Completed Normal",
	0xC0 => "Node busy, command could not be processed",
	0xC1 => "Invalid or unsupported command",
	0xC2 => "Command invalid for given LUN",
	0xC3 => "Timeout while processing command, response unavailable",
	0xC4 => "Out of space, could not execute command",
	0xC5 => "Reservation canceled or invalid reservation ID",
	0xC6 => "Request data truncated",
	0xC7 => "Request data length invalid",
	0xC8 => "Request data field length limit exceeded",
	0xC9 => "Parameter out of range",
	0xCA => "Cannot return number of requested data bytes",
	0xCB => "Requested Sensor, data, or record not present",
	0xCB => "Not present",
	0xCC => "Invalid data field in Request",
	0xCD => "Command illegal for specified sensor or record type",
	0xCE => "Command response could not be provided",
	0xCF => "Cannot execute duplicated request",
	0xD0 => "Command reqponse could not be provided. SDR Repository in update mode",
	0xD1 => "Command response could not be provided. Device in firmware update mode",
	0xD2 => "Command response could not be provided. BMC initialization or initialization agent in progress",
	0xD3 => "Destination unavailable",
	0xD4 => "Insufficient privilege level",
	0xD5 => "Command or request parameter(s) not supported in present state",
	0xFF => "Unspecified error",
);

my %units = (
	0 => "", #"unspecified",
	1 => "C",
	2 => "F",
	3 => "K",
	4 => "Volts",
	5 => "Amps",
	6 => "Watts",
	7 => "Joules",
	8 => "Coulombs",
	9 => "VA",
	10 => "Nits",
	11 => "lumen",
	12 => "lux",
	13 => "Candela",
	14 => "kPa",
	15 => "PSI",
	16 => "Newton",
	17 => "CFM",
	18 => "RPM",
	19 => "Hz",
	20 => "microsecond",
	21 => "millisecond",
	22 => "second",
	23 => "minute",
	24 => "hour",
	25 => "day",
	26 => "week",
	27 => "mil",
	28 => "inches",
	29 => "feet",
	30 => "cu in",
	31 => "cu feet",
	32 => "mm",
	33 => "cm",
	34 => "m",
	35 => "cu cm",
	36 => "cu m",
	37 => "liters",
	38 => "fluid ounce",
	39 => "radians",
	40 => "steradians",
	41 => "revolutions",
	42 => "cycles",
	43 => "gravities",
	44 => "ounce",
	45 => "pound",
	46 => "ft-lb",
	47 => "oz-in",
	48 => "gauss",
	49 => "gilberts",
	50 => "henry",
	51 => "millihenry",
	52 => "farad",
	53 => "microfarad",
	54 => "ohms",
	55 => "siemens",
	56 => "mole",
	57 => "becquerel",
	58 => "PPM",
	59 => "reserved",
	60 => "Decibels",
	61 => "DbA",
	62 => "DbC",
	63 => "gray",
	64 => "sievert",
	65 => "color temp deg K",
	66 => "bit",
	67 => "kilobit",
	68 => "megabit",
	69 => "gigabit",
	70 => "byte",
	71 => "kilobyte",
	72 => "megabyte",
	73 => "gigabyte",
	74 => "word",
	75 => "dword",
	76 => "qword",
	77 => "line",
	78 => "hit",
	79 => "miss",
	80 => "retry",
	81 => "reset",
	82 => "overflow",
	83 => "underrun",
	84 => "collision",
	85 => "packets",
	86 => "messages",
	87 => "characters",
	88 => "error",
	89 => "correctable error",
	90 => "uncorrectable error",
);

my %chassis_types = (
	0 => "Unspecified",
	1 => "Other",
	2 => "Unknown",
	3 => "Desktop",
	4 => "Low Profile Desktop",
	5 => "Pizza Box",
	6 => "Mini Tower",
	7 => "Tower",
	8 => "Portable",
	9 => "LapTop",
	10 => "Notebook",
	11 => "Hand Held",
	12 => "Docking Station",
	13 => "All in One",
	14 => "Sub Notebook",
	15 => "Space-saving",
	16 => "Lunch Box",
	17 => "Main Server Chassis",
	18 => "Expansion Chassis",
	19 => "SubChassis",
	20 => "Bus Expansion Chassis",
	21 => "Peripheral Chassis",
	22 => "RAID Chassis",
	23 => "Rack Mount Chassis",
);

my %MFG_ID = (
	2 => "IBM",
	343 => "Intel",
);

my %PROD_ID = (
	"2:34869" => "e325",
	"2:3" => "x346",
	"2:4" => "x336",
	"343:258" => "Tiger 2",
	"343:256" => "Tiger 4",
);

my $localtrys = 3;
my $localdebug = 0;

struct SDR_rep_info => {
	version		=> '$',
	rec_count	=> '$',
	resv_sdr	=> '$',
};

struct SDR => {
	rec_type			=> '$',
	sensor_owner_id		=> '$',
	sensor_owner_lun	=> '$',
	sensor_number		=> '$',
	entity_id			=> '$',
	entity_instance		=> '$',
	sensor_init			=> '$',
	sensor_cap			=> '$',
	sensor_type			=> '$',
	event_type_code		=> '$',
	ass_event_mask		=> '@',
	deass_event_mask	=> '@',
	dis_read_mask		=> '@',
	sensor_units_1		=> '$',
	sensor_units_2		=> '$',
	sensor_units_3		=> '$',
	linearization		=> '$',
	M					=> '$',
	tolerance			=> '$',
	B					=> '$',
	accuracy			=> '$',
	accuracy_exp		=> '$',
	R_exp				=> '$',
	B_exp				=> '$',
	analog_char_flag	=> '$',
	nominal_reading		=> '$',
	normal_max			=> '$',
	normal_min			=> '$',
	sensor_max_read		=> '$',
	sensor_min_read		=> '$',
	upper_nr_threshold	=> '$',
	upper_crit_thres	=> '$',
	upper_ncrit_thres	=> '$',
	lower_nr_threshold	=> '$',
	lower_crit_thres	=> '$',
	lower_ncrit_thres	=> '$',
	pos_threshold		=> '$',
	neg_threshold		=> '$',
	id_string_type		=> '$',
	id_string		=> '$',
	#LED id
	led_id		=> '$',
    fru_type  => '$',
    fru_subtype  => '$',
};

struct FRU => {
	rec_type			=> '$',
	desc				=> '$',
	value				=> '$',
};

sub decode_fru_locator { #Handle fru locator records
    my @locator = @_;
	my $sdr = SDR->new();
	$sdr->rec_type(0x11);
    $sdr->sensor_owner_id("FRU");
    $sdr->sensor_owner_lun("FRU");
    $sdr->sensor_number($locator[7]);
    unless ($locator[8] & 0x80 and ($locator[8] & 0x1f) == 0 and $locator[9] == 0) {
        #only logical devices at lun 0 supported for now
        return undef;
    }
    unless (($locator[16] & 0xc0) == 0xc0) { #Only unpacked ASCII for now, no unicode or BCD plus yet
        return undef;
    }
    my $idlen = $locator[16] & 0x3f;
    unless ($idlen > 1) { return undef; }
    $sdr->id_string(pack("C*",@locator[17..17+$idlen-1]));
    $sdr->fru_type($locator[11]);
    $sdr->fru_subtype($locator[12]);

    return $sdr;
}

sub waitforack {
    my $sock = shift;
    my $select = new IO::Select;
    $select->add($sock);
    my $str;
    if ($select->can_read(10)) { # Continue after 10 seconds, even if not acked...
        if ($str = <$sock>) {
        } else {
           $select->remove($sock); #Block until parent acks data
        }
    }
}
sub translate_sensor {
   my $reading = shift;
   my $sdr = shift;
   my $unitdesc;
   my $value;
   my $lformat;
   my $per;
   $unitdesc = $units{$sdr->sensor_units_2};
   if ($sdr->rec_type == 1) {
    $value = (($sdr->M * $reading) + ($sdr->B * (10**$sdr->B_exp))) * (10**$sdr->R_exp);
   } else {
    $value = $reading;
   }
   if($sdr->rec_type !=1 or $sdr->linearization == 0) {
      $reading = $value;
      if($value == int($value)) {
         $lformat = "%-30s%8d%-20s";
      } else {
         $lformat = "%-30s%8.3f%-20s";
      }
   } elsif($sdr->linearization == 7) {
      if($value > 0) {
         $reading = 1/$value;
      } else {
         $reading = 0;
      }
      $lformat = "%-30s%8d %-20s";
   } else {
      $reading = "RAW($sdr->linearization) $reading";
   }
   if($sdr->sensor_units_1 & 1) {
      $per = "% ";
   } else {
      $per = " ";
   }
   my $numformat = ($sdr->sensor_units_1 & 0b11000000) >> 6;
   if ($numformat) {
     if ($numformat eq 0b11)  {
        #Not sure what to do.. leave it alone for now
     } else {
        if ($reading & 0b10000000) {
          if ($numformat eq 0b01) {
             $reading = 0-((~($reading&0b01111111))&0b1111111);
          } elsif ($numformat eq 0b10) {
             $reading = 0-(((~($reading&0b01111111))&0b1111111)+1);
          }
        }
     }
   }
   if($unitdesc eq "Watts") {
      my $f = ($reading * 3.413);
      $unitdesc = "Watts (" . int($f + .5) . " BTUs/hr)";
      #$f = ($reading * 0.00134);
      #$unitdesc .= " $f horsepower)";
   }
   if($unitdesc eq "C") {
      my $f = ($reading * 9/5) + 32;
      $unitdesc = "C (" . int($f + .5) . " F)";
   }
   if($unitdesc eq "F") {
      my $c = ($reading - 32) * 5/9;
      $unitdesc = "F (" . int($c + .5) . " C)";
   }
   return "$reading $unitdesc";
}


sub ipmiinit {
	my $ipmimaxp = 80;
	my $ipmitimeout = 3;
	my $ipmitrys = 3;
	my $ipmiuser = 'USERID';
	my $ipmipass = 'PASSW0RD';
	my $tmp;

	
	my $table = xCAT::Table->new('site');
	if ($table) {
		($tmp)=$table->getAttribs({'key'=>'ipmimaxp'},'value');
		if (defined($tmp)) { $ipmimaxp=$tmp->{value}; }
		($tmp)=$table->getAttribs({'key'=>'ipmitimeout'},'value');
		if (defined($tmp)) { $ipmitimeout=$tmp->{value}; }
		($tmp)=$table->getAttribs({'key'=>'ipmiretries'},'value');
		if (defined($tmp)) { $ipmitrys=$tmp->{value}; }
		($tmp)=$table->getAttribs({'key'=>'ipmisdrcache'},'value');
	}
	$table = xCAT::Table->new('passwd');
	if ($table) {
		($tmp)=$table->getAttribs({'key'=>'ipmi'},'username','password');
		if (defined($tmp)) {
			$ipmiuser = $tmp->{username};
			$ipmipass = $tmp->{password};
		}	
	}
	return($ipmiuser,$ipmipass,$ipmimaxp,$ipmitimeout,$ipmitrys);
}

sub ipmicmd {
	my $node = shift;
	$port = shift;
	$userid = shift;
	$passwd = shift;
	$timeout = shift;
	$localtrys = shift;
	$debug = shift;
	$localdebug = $debug;

	if($userid eq "(null)") {
		$userid = "";
	}
	if($passwd eq "(null)") {
		$passwd = "";
	}

	@user = dopad16($userid);
	@pass = dopad16($passwd);

	$seqlun = 0x00;
	@session_id = (0,0,0,0);
	@challenge = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
	@seqnum = (0,0,0,0);
	$authoffset=0;

	my $command = shift;
    @cmdargv = @_;
	my $subcommand = shift;


	my $rc=0;
	my $text="";
	my $error="";
	my @output;
	my $noclose=0;

	my $packed_ip = gethostbyname($node);
	if(!defined($packed_ip)) {
		$text = "failed to get IP for $node";
		return(2,$text);
	}
    $ipmi_bmcipaddr=inet_ntoa($packed_ip);

	$sock = IO::Socket::INET->new(
		Proto => 'udp',
		PeerHost => $ipmi_bmcipaddr,
		PeerPort => $port,
	);
	if(!defined($sock)) {
		$text = "failed to get socket: $@\n";
		return(2,$text);
	}

	$error = getchanauthcap();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: gotchanauthcap\n";
	}

	if($command eq "ping") {
		return(0,"ping");
	}

	$error = getsessionchallenge();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: gotsessionchallenge\n";
	}

	$error = activatesession();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: active session\n";
	}

	$error = setprivlevel();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: priv level set\n";
	}

	if($command eq "rpower") {
		if($subcommand eq "stat" || $subcommand eq "state" || $subcommand eq "status") {
			($rc,$text) = power("stat");
		}
		elsif($subcommand eq "on") {
                   my ($oldrc,$oldtext) = power("stat");
		   ($rc,$text) = power("on");
                   if(($rc == 0) && ($text eq "on") && ($oldtext eq "on")) { $text .= " $status_noop"; }
		}
		elsif($subcommand eq "nmi") {
			($rc,$text) = power("nmi");
		}
		elsif($subcommand eq "off" or $subcommand eq "softoff") {
                        my ($oldrc,$oldtext) = power("stat");
			($rc,$text) = power($subcommand);
                         if(($rc == 0) && ($text eq "off") && ($oldtext eq "off")) { $text .= " $status_noop"; }
	
#			if($text0 ne "") {
#				$text = $text0 . " " . $text;
#			}
		}
		elsif($subcommand eq "reset") {
                        my ($oldrc,$oldtext) = power("stat");
			($rc,$text) = power("reset");
			$noclose = 0;
                        if(($rc == 0) && ($text eq "off") && ($oldtext eq "off")) { $text .= " $status_noop"; }
		}
		elsif($subcommand eq "cycle") {
			my $text2;

			($rc,$text) = power("stat");

			if($rc == 0 && $text eq "on") {
				($rc,$text) = power("off");
				if($rc == 0) {
					sleep(5);
				}
			}

			if($rc == 0 && $text eq "off") {
				($rc,$text2) = power("on");
			}

			if($rc == 0) {	
				$text = $text . " " . $text2
			}
		}
		elsif($subcommand eq "boot") {
			my $text2;

			($rc,$text) = power("stat");

			if($rc == 0) {
				if($text eq "on") {
					($rc,$text2) = power("reset");
					$noclose = 0;
				}
				elsif($text eq "off") {
					($rc,$text2) = power("on");
				}
				else {
					$rc = 1;
				}
			
				$text = $text . " " . $text2
			}
		}
		else {
			$rc = 1;
			$text = "unsupported command $command $subcommand";
		}
	}
	elsif($command eq "rbeacon") {
		($rc,$text) = beacon($subcommand);
	}
	elsif($command eq "getrvidparms") {
		($rc,@output) = getrvidparms($subcommand);
	}
#	elsif($command eq "info") {
#		if($subcommand eq "sensorname") {
#			($rc,$text) = initsdr();
#			if($rc == 0) {
#				my $key;
#				$text="";
#				foreach $key (keys %sdr_hash) {
#					my $sdr = $sdr_hash{$key};
#					if($sdr->sensor_number == @_) {
#						$text = $sdr_hash{$key}->id_string;
#						last;
#					}
#				}
##				if(defined $sdr_hash{@_}) {
##					$text = $sdr_hash{@_}->id_string;
##				}
#			}
#		}
#	}
	elsif($command eq "rvitals") {
		($rc,@output) = vitals($subcommand);
	}
	elsif($command eq "rspreset") {
		($rc,@output) = resetbmc();
		$noclose=1;
	}
	elsif($command eq "reventlog") {
		if($subcommand eq "decodealert") {
			($rc,$text) = decodealert(@_);
		}
		else {
			($rc,@output) = eventlog($subcommand);
		}
	}
	elsif($command eq "rinv") {
		($rc,@output) = inv($subcommand);
	}
	elsif($command eq "fru") {
		($rc,@output) = fru($subcommand);
	}
	elsif($command eq "sol.command") {
		my $dc=0;

		$@ = "";
		eval {
			my $cc=0;
			my $kid;
			my $pid=$$;

			$SIG{USR1} = sub {$cc=0;};
			$SIG{USR2} = sub {$dc++;};
			$SIG{CHLD} = sub {while(waitpid(-1,WNOHANG) > 0) { sleep(1); }};

			mkfifo("/tmp/.sol.$pid",0666);

			my $child = xCAT::Utils->xfork();
			if(!defined $child) {
				die;
			}

			if($child > 0) {
				$cc=1;
			}
			else {
				system("$subcommand /tmp/.sol.$pid");

				if($?/256 == 1) {
					kill(12,$pid);
				}
				if($?/256 == 2) {
					kill(12,$pid);
					sleep(1);
					kill(12,$pid);
				}

				kill(10,$pid);
				exit(0);
			}

			open(FH,"< /tmp/.sol.$pid");
			my $kpid = <FH>;
			close(FH);
			unlink("/tmp/.sol.$pid");

			while($cc == 1) {
				sleep(5);
				($rc,$text) = power("stat");
				$text="";
				if($rc != 0) {
					kill(15,$kpid);
					$cc=0;
				}
			}

			do {
				$kid = waitpid(-1,WNOHANG);
				sleep(1);
			} until($kid == -1);
		};
		if($@) {
			@output = $@;
		}

		$rc = $dc;
		if($rc == 1) {
			$noclose = 1;
		}
	}
	elsif($command eq "rgetnetinfo") {
      my @subcommands = ($subcommand);
		if($subcommand eq "all") {
			@subcommands = (
				"ip",
				"netmask",
				"gateway",
				"backupgateway",
				"snmpdest1",
				"snmpdest2",
				"snmpdest3",
				"snmpdest4",
				"community",
			);

			my @coutput;

			foreach(@subcommands) {
				$subcommand = $_;
				($rc,@output) = getnetinfo($subcommand);
				push(@coutput,@output);
			}

			@output = @coutput;
		}
		else {
			($rc,@output) = getnetinfo($subcommand);
		}
	}
	elsif($command eq "rspconfig") {
      foreach ($subcommand,@_) {
         my @coutput;
		   ($rc,@coutput) = setnetinfo($_);
		   if($rc == 0) {
			   ($rc,@coutput) = getnetinfo($_);
		   }
         push(@output,@coutput);
      }
	}
	elsif($command eq "sete325cli") {
		($rc,@output) = sete325cli($subcommand);
	}
	elsif($command eq "sete326cli") {
		($rc,@output) = sete325cli($subcommand);
	}
	elsif($command eq "generic") {
		($rc,@output) = generic($subcommand);
	}
	elsif($command eq "rfrurewrite") {
		($rc,@output) = writefru($subcommand,shift);
	}
	elsif($command eq "fru") {
		($rc,@output) = fru($subcommand);
	}
	elsif($command eq "rsetboot") {
        	($rc,@output) = setboot($subcommand);
	}

	else {
		$rc = 1;
		$text = "unsupported command $command $subcommand";
	}
	if($debug) {
		print "$node: command completed\n";
	}

	if($noclose == 0) {
		$error = closesession();
		if($error) {
			return(1,"$text, session close: $error");
		}
		if($debug) {
			print "$node: session closed.\n";
		}
	}

	if($text) {
		push(@output,$text);
	}

	$sock->close();
	return($rc,@output);
}

sub resetbmc {
	my $netfun = 0x18;
	my @cmd = (0x02);
	my @returnd = ();
	my $rc = 0;
	my $text;
	my $error;

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);
	if ($error) {
		$rc = 1;
		$text = $error;
	} else {
		if (0 == $returnd[36]) {
			$text = "BMC reset";
		} else {
            if ($codes{$returnd[36]}) {
                $text = $codes{$returnd[36]};
            } else {
			    $text = sprintf("BMC Responded with code %d",$returnd[36]);
            }
		}
	}
	return($rc,$text);
}

sub setnetinfo {
	my $subcommand = shift;
   my $argument;
   ($subcommand,$argument) = split(/=/,$subcommand);
	my @input = @_;

	my $netfun = 0x30;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;
	my $match;

	if($subcommand eq "snmpdest") {
		$subcommand = "snmpdest1";
	}
        

   unless(defined($argument)) { 
      return 0;
   }
   if ($subcommand eq "thermprofile") {
       return idpxthermprofile($argument);
   }
   if ($subcommand eq "alert" and $argument eq "on" or $argument =~ /^en/ or $argument =~ /^enable/) {
      $netfun = 0x10;
      @cmd = (0x12,0x9,0x1,0x18,0x11,0x00);
   } elsif ($subcommand eq "alert" and $argument eq "off" or $argument =~ /^dis/ or $argument =~ /^disable/) {
      $netfun = 0x10;
      @cmd = (0x12,0x9,0x1,0x10,0x11,0x00);
   }
	elsif($subcommand eq "garp") {
		my $halfsec = $argument * 2; #pop(@input) * 2;

		if($halfsec > 255) {
			$halfsec = 255;
		}
		if($halfsec < 4) {
			$halfsec = 4;
		}

		@cmd = (0x01,$channel_number,0x0b,$halfsec);
	}
   elsif($subcommand =~ m/community/ ) {
      my $cindex = 0;
      my @clist;
      foreach (0..17) {
         push @clist,0;
      }
      foreach (split //,$argument)  {
         $clist[$cindex++]=ord($_);
      }
      @cmd = (1,$channel_number,0x10,@clist);
   }
	elsif($subcommand =~ m/snmpdest(\d+)/ ) {
		my $dstip = $argument; #pop(@input);
		my @dip = split /\./, $dstip;
		@cmd = (0x01,$channel_number,0x13,$1,0x00,0x00,$dip[0],$dip[1],$dip[2],$dip[3],0,0,0,0,0,0);
	}
	#elsif($subcommand eq "alert" ) {
	#    my $action=pop(@input);
            #print "action=$action\n";
        #    $netfun=0x28; #TODO: not right
 
            # mapping alert action to number
        #    my $act_number=8;   
        #    if ($action eq "on") {$act_number=8;}  
        #    elsif ($action eq "off") { $act_number=0;}  
        #    else { return(1,"unsupported alert action $action");}    
	#    @cmd = (0x12, $channel_number,0x09, 0x01, $act_number+16, 0x11,0x00);
	#}
	else {
		return(1,"configuration of $subcommand is not implemented currently");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($subcommand eq "garp" or $subcommand =~ m/snmpdest\d+/ or $subcommand eq "alert" or $subcommand =~ /community/) {
			$code = $returnd[36];

			if($code == 0x00) {
				$text = "ok";
			}
		} 

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub getnetinfo {
	my $subcommand = shift;
   $subcommand =~ s/=.*//;
   if ($subcommand eq "thermprofile") {
       my $code;
       my @returnd;
       my $thermdata;
       my $netfun=0x2e<<2; #currently combined netfun & lun, to be simplified later
       my @cmd = (0x41,0x4d,0x4f,0x00,0x6f,0xff,0x61,0x00);
       my @bytes;
       my $error = docmd($netfun,\@cmd,\@bytes);
       @bytes=splice @bytes,36-$authoffset;
       @bytes=splice @bytes,16;
       my $validprofiles="";
       foreach (keys %idpxthermprofiles) {
           if (sprintf("%02x %02x %02x %02x %02x %02x %02x",@bytes) eq sprintf("%02x %02x %02x %02x %02x %02x %02x",@{$idpxthermprofiles{$_}})) {
               $validprofiles.="$_,";
           }
       }
       if ($validprofiles) {
           chop($validprofiles);
           return (0,"The following thermal profiles are in effect: ".$validprofiles);
       }
       return (1,sprintf("Unable to identify current thermal profile: \"%02x %02x %02x %02x %02x %02x %02x\"",@bytes));
   }

	my $netfun = 0x30;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;
	my $format = "%-25s";

	if ($subcommand eq "snmpdest") {
		$subcommand = "snmpdest1";
	}

   if ($subcommand eq "alert") {
      $netfun = 0x10;
      @cmd = (0x13,9,1,0);
   }
	elsif($subcommand eq "garp") {
		@cmd = (0x02,$channel_number,0x0b,0x00,0x00);
	}
	elsif ($subcommand =~ m/^snmpdest(\d+)/ ) {
		@cmd = (0x02,$channel_number,0x13,$1,0x00);
	}
	elsif ($subcommand eq "ip") {
		@cmd = (0x02,$channel_number,0x03,0x00,0x00);
	}
	elsif ($subcommand eq "netmask") {
		@cmd = (0x02,$channel_number,0x06,0x00,0x00);
	}
	elsif ($subcommand eq "gateway") {
		@cmd = (0x02,$channel_number,0x0C,0x00,0x00);
	}
	elsif ($subcommand eq "backupgateway") {
		@cmd = (0x02,$channel_number,0x0E,0x00,0x00);
	}
	elsif ($subcommand eq "community") {
		@cmd = (0x02,$channel_number,0x10,0x00,0x00);
	}
	else {
		return(1,"unsupported command getnetinfo $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);


	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
          # response format:
          # 4 bytes   (RMCP header)
          # 1 byte    (auth type)
          # 4 bytes   (session sequence)
          # 4 bytes   (session id)
          # 16 bytes  (message auth code, not present if auth type is 0, $authoffset=16)
          # 1 byte    (ipmi message length)
          # 1 byte    (requester's address
          # 1 byte    (netfun, req lun)
          # 1 byte    (checksum)
          # 1 byte    (Responder's slave address)
          # 1 byte    (Sequence number, generated by the requester)
          # 1 byte    (command)
          # 1 byte    (return code)
          # 1 byte    (param revision)
          # N bytes   (data)
          # 1 byte    (checksum)
		if($subcommand eq "garp") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$code = $returnd[38-$authoffset] / 2;
				$text = sprintf("$format %d","Gratuitous ARP seconds:",$code);
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
      elsif($subcommand eq "alert") {
         if ($returnd[39-$authoffset] & 0x8) { 
            $text = "SP Alerting: enabled";
         } else {
            $text = "SP Alerting: disabled";
         }
      }
		elsif($subcommand =~ m/^snmpdest(\d+)/ ) {
			$text = sprintf("$format %d.%d.%d.%d",
				"SP SNMP Destination $1:",
				$returnd[41-$authoffset],
				$returnd[42-$authoffset],
				$returnd[43-$authoffset],
				$returnd[44-$authoffset]);
		}
		elsif($subcommand eq "ip") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC IP:",
				$returnd[38-$authoffset],
				$returnd[39-$authoffset],
				$returnd[40-$authoffset],
				$returnd[41-$authoffset]);
		}
		elsif($subcommand eq "netmask") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC Netmask:",
				$returnd[38-$authoffset],
				$returnd[39-$authoffset],
				$returnd[40-$authoffset],
				$returnd[41-$authoffset]);
		}
		elsif($subcommand eq "gateway") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC Gateway:",
				$returnd[38-$authoffset],
				$returnd[39-$authoffset],
				$returnd[40-$authoffset],
				$returnd[41-$authoffset]);
		}
		elsif($subcommand eq "backupgateway") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC Backup Gateway:",
				$returnd[38-$authoffset],
				$returnd[39-$authoffset],
				$returnd[40-$authoffset],
				$returnd[41-$authoffset]);
		}
		elsif ($subcommand eq "community") {
			$text = sprintf("$format ","SP SNMP Community:");
			my $l = 38-$authoffset;
			while ($returnd[$l] ne 0) {
				$l = $l + 1;
			}
			my $i=38-$authoffset;
			while ($i<$l) {
				$text = $text . sprintf("%c",$returnd[$i]);
				$i = $i + 1;
			}
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub sete325cli {
	my $subcommand = shift;

	my $netfun = 0xc8;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	if($subcommand eq "disable") {
		@cmd = (0x00);
	}
	elsif($subcommand eq "cli") {
		@cmd = (0x02);
	}
	else {
		return(1,"unsupported command sete325cli $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($code == 0x00) {
			$rc = 0;
			$text = "$subcommand";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub setboot {
    my $subcommand=shift;
    my $netfun = 0x00;
    my @cmd = (0x08,0x3,0x8);
    my @returnd = ();
    my $error;
    my $rc = 0;
    my $text = "";
    my $code;
    my $skipset = 0;
    my %bootchoices = (
        0 => 'BIOS default',
        1 => 'Network',
        2 => 'Hard Drive',
        5 => 'CD/DVD',
        6 => 'BIOS Setup',
        15 => 'Floppy'
    );

    #This disables the 60 second timer
    $error = docmd(
        $netfun,
        \@cmd,
        \@returnd
    );
    if ($subcommand eq "net") {
        @cmd=(0x08,0x5,0x80,0x4,0x0,0x0,0x0);
    }
    elsif ($subcommand eq "hd" ) {
        @cmd=(0x08,0x5,0x80,0x8,0x0,0x0,0x0);
    }
    elsif ($subcommand eq "cd" ) {
        @cmd=(0x08,0x5,0x80,0x14,0x0,0x0,0x0);
    }
    elsif ($subcommand eq "floppy" ) {
        @cmd=(0x08,0x5,0x80,0x3c,0x0,0x0,0x0);
    }
    elsif ($subcommand =~ m/^def/) {
        @cmd=(0x08,0x5,0x0,0x0,0x0,0x0,0x0);
    }
    elsif ($subcommand eq "setup" ) { #Not supported by BMCs I've checked so far..
        @cmd=(0x08,0x5,0x18,0x0,0x0,0x0,0x0);
    }
    elsif ($subcommand =~ m/^stat/) {
        $skipset=1;
    }
    else {
        return(1,"unsupported command setboot $subcommand");
    }


    unless ($skipset) {
        $error = docmd(
            $netfun,
            \@cmd,
            \@cmd,
            \@returnd
        );
        if($error) {
            return(1,$error);
        }
        $code = $returnd[36-$authoffset];
        unless ($code == 0x00) {
                    return(1,$codes{$code});
            }
    }
    @cmd=(0x09,0x5,0x0,0x0);
    $error = docmd(
                $netfun,
                \@cmd,
                \@returnd
        );
    if($error) {
                return(1,$error);
        }
    $code = $returnd[36-$authoffset];
    unless ($code == 0x00) {
                return(1,$codes{$code});
        }
    unless ($returnd[39-$authoffset] & 0x80) {
        $text = "boot override inactive";
        return($rc,$text);
    }
    my $boot=($returnd[40-$authoffset] & 0x3C) >> 2;
    $text = $bootchoices{$boot};
    return($rc,$text);
}

sub idpxthermprofile {
    #iDataplex thermal profiles as of 6/10/2008
    my $subcommand = lc(shift);
    my @returnd;
    my $netfun = 0xb8;
    my @cmd = (0x41,0x4d,0x4f,0x00,0x6f,0xfe,0x60,0,0,0,0,0,0,0,0xff);
    if ($idpxthermprofiles{$subcommand}) {
        push @cmd,@{$idpxthermprofiles{$subcommand}};
    } else {
        return (1,"Not an understood thermal profile, expected a 2 hex digit value corresponding to chassis label on iDataplex server");
    }
    docmd(
        $netfun,
        \@cmd,
        \@returnd
    );
    return (0,"OK");
}


sub getrvidparms {
    my $netfun = 0x3a;
    my @mcinfo=getdevid();
    unless ($mcinfo[2] == 2) { #Only implemented for IBM servers
        return(1,"Remote video is not supported on this system");
    }
    #TODO: use get bmc capabilities to see if rvid is actually supported before bothering the client java app
    my @build_id;
    my $localerror = docmd(
        0xe8,
        [0x50],
        \@build_id
    );
    if ($localerror) {
        return(1,$localerror);
    }
    @build_id=splice @build_id,36-$authoffset;
    unless ($build_id[1]==0x59 and $build_id[2]==0x55 and $build_id[3]==0x4f and $build_id[4]==0x4f) { #Only know how to cope with yuoo builds
        return(1,"Remote video is not supported on this system");
    }
    #wvid should be a possiblity, time to do the http...
    my $browser = LWP::UserAgent->new();
    my $message = "$userid,$passwd";
    $browser->cookie_jar({});
    my $baseurl = "http://".$ipmi_bmcipaddr."/";
    my $response = $browser->request(POST $baseurl."/session/create",'Content-Type'=>"text/xml",Content=>$message);
    unless ($response->content eq "ok") {
        return (1,"Server returned unexpected data");
    }

    $response = $browser->request(GET $baseurl."/kvm/kvm/jnlp");
    my $jnlp = $response->content;
    if ($jnlp =~ /This advanced option requires the purchase and installation/) {
        return (1,"Node does not have feature key for remote video");
    }
    $jnlp =~ s!argument>title=.*Video Viewer</argument>!argument>title=$currnode wvid</argument>!;
    my @return=("method:imm","jnlp:$jnlp");
    if (grep /-m/,@cmdargv) {
        $response = $browser->request(GET $baseurl."/kvm/vm/jnlp");
        push @return,"mediajnlp:".$response->content;
    }
    return (0,@return);
}


sub power {
	my $subcommand = shift;

	my $netfun = 0x00;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	if($subcommand eq "stat") {
		@cmd = (0x01);
	}
	elsif($subcommand eq "on") {
		@cmd = (0x02,0x01);
	}
	elsif($subcommand eq "softoff") {
		@cmd = (0x02,0x05);
	}
	elsif($subcommand eq "off") {
		@cmd = (0x02,0x00);
	}
	elsif($subcommand eq "reset") {
		@cmd = (0x02,0x03);
	}
	elsif($subcommand eq "nmi") {
		@cmd = (0x02,0x04);
	}
	else {
		return(1,"unsupported command power $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($subcommand eq "stat") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$code = $returnd[37-$authoffset];

				if($code & 0b00000001) {
					$text = "on";
				}
				else {
					$text = "off";
				}
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "nmi") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="nmi";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "on") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="on";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "softoff") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="softoff";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "off") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="off";
			}
			elsif($code == 0xd5) {
				$text="off";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "reset") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="reset";
			}
			elsif($code == 0xd5) {
				$text="off";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub generic {
	my $subcommand = shift;
	my $netfun;
	my @args;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	($netfun,@args) = split(/-/,$subcommand);

	$netfun=oct($netfun);
	printf("netfun:  0x%02x\n",$netfun);

	print "command: ";
	foreach(@args) {
		push(@cmd,oct($_));
		printf("0x%02x ",oct($_));
	}
	print "\n\n";

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	printf("return code: 0x%02x\n\n",$code);

	print "return data:\n";
	my @rdata = @returnd[37-$authoffset..@returnd-2]; 
	hexadump(\@rdata);
	print "\n";

	print "full output:\n";
	hexadump(\@returnd);
	print "\n";

#	if(!$text) {
#		$rc = 1;
#		$text = sprintf("unknown response %02x",$code);
#	}

	return($rc,$text);
}

sub beacon {
	my $subcommand = shift;

	my $netfun = 0x00;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	if($subcommand eq "on") {
        if ($ipmiv2) {
		    @cmd = (0x04,0x0,0x01);
        } else {
		    @cmd = (0x04,0xFF);
        }
	}
	elsif($subcommand eq "off") {
        if ($ipmiv2) {
            @cmd = (0x04,0x0,0x00);
        } else {
		    @cmd = (0x04,0x00);
        }
	}
	else {
		return(1,"unsupported command beacon $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($subcommand eq "on") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="on";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "off") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="off";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub inv {
	my $subcommand = shift;

	my $rc = 0;
	my $text;
	my @output;
	my @types;
	my $format = "%-20s %s";

	($rc,$text) = initsdr(); #Look for those precious locator reconds
	if($rc != 0) {
		return($rc,$text);
	}
	($rc,$text) = initfru();
	if($rc != 0) {
		return($rc,$text);
	}

    unless ($subcommand) {
        $subcommand = "all";
    }
	if($subcommand eq "all") {
		@types = qw(model serial deviceid mprom guid misc hw asset);
	}
	elsif($subcommand eq "asset") {
		@types = qw(asset);
	}
	elsif($subcommand eq "model") {
		@types = qw(model);
	}
	elsif($subcommand eq "serial") {
		@types = qw(serial);
	}
	elsif($subcommand eq "vpd") {
		@types = qw(model serial deviceid mprom);
	}
	elsif($subcommand eq "mprom") {
		@types = qw(mprom);
	}
	elsif($subcommand eq "misc") {
		@types = qw(misc);
	}
	elsif($subcommand eq "deviceid") {
		@types = qw(deviceid);
	}
	elsif($subcommand eq "guid") {
		@types = qw(guid);
	}
	elsif($subcommand eq "uuid") {
		@types = qw(guid);
	}
	else {
        @types = ($subcommand);
		#return(1,"unsupported BMC inv argument $subcommand");
	}

	my $otext;
	my $key;

	foreach $key (sort keys %fru_hash) {
		my $fru = $fru_hash{$key};
        my $type;
        foreach $type (split /,/,$fru->rec_type) {
    		if(grep {$_ eq $type} @types) {
    			$otext = sprintf($format,$fru_hash{$key}->desc . ":",$fru_hash{$key}->value);
    			#print $otext;
    			push(@output,$otext);
                last;
            }
        }
	}

	return($rc,@output);
}

sub initoemfru {
	my $mfg_id = shift;
	my $prod_id = shift;
	my $device_id = shift;

	my $netfun;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;

	if($mfg_id == 2 && ($prod_id == 34869 or $prod_id == 31081 or $prod_id==34888)) {
		$netfun = 0xc8;
		
		@cmd=(0x05);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my @oem_fru_data = @returnd[37-$authoffset..@returnd-2];
		my $model_type = getascii(@oem_fru_data[0..3]);
		my $model_number = getascii(@oem_fru_data[4..6]);
		my $serial = getascii(@oem_fru_data[7..13]);
		my $model = "$model_type-$model_number";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 4 && 0) {
		$netfun = 0x3a;
		
		@cmd=(0x0b,0x0,0x0,0x0,0x1,0x8);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

hexadump(\@returnd);
return(2,"");

		my @oem_fru_data = @returnd[37-$authoffset..@returnd-2];
		my $model_type = getascii(@oem_fru_data[0..3]);
		my $model_number = getascii(@oem_fru_data[4..6]);
		my $serial = getascii(@oem_fru_data[7..13]);
		my $model = "$model_type-$model_number";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 20) {
		my $serial = "unknown";
		my $model = "x3655";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 3) {
		my $serial = "unknown";
		my $model = "x346";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 4) {
		my $serial = "unknown";
		my $model = "x336";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
   my $serial = "unkown";
   my $model = "unkown";

   my $fru = FRU->new();
	$fru->rec_type("serial");
	$fru->desc("Serial Number");
	$fru->value($serial);
	$fru_hash{1} = $fru;

	$fru = FRU->new();
	$fru->rec_type("model");
	$fru->desc("Model Number");
	$fru->value($model);
	$fru_hash{2} = $fru;

	return(2,"");


	return(1,"No OEM FRU Support");
}

sub add_textual_fru {
    my $parsedfru = shift;
    my $description = shift;
    my $category = shift;
    my $subcategory = shift;
    my $types = shift;

    if ($parsedfru->{$category} and $parsedfru->{$category}->{$subcategory}) {
        my $fru;
        my @subfrus;

        if (ref $parsedfru->{$category}->{$subcategory} eq 'ARRAY') {
            @subfrus = @{$parsedfru->{$category}->{$subcategory}};
        } else {
            @subfrus = ($parsedfru->{$category}->{$subcategory})
        }
        foreach (@subfrus) {
            $fru = FRU->new();
            $fru->rec_type($types);
            $fru->desc($description);
            if (not ref $_) {
                $fru->value($_);
            } else {
                if ($_->{encoding} == 3) {
                    $fru->value($_->{value});
                } else {
                    $fru->value(phex($_->{value}));
                }
                    
            }
            $fru_hash{$frudex++} = $fru;
        }
    }
}
sub add_textual_frus {
    my $parsedfru = shift;
    my $desc = shift;
    my $categorydesc = shift;
    my $category = shift;
    my $type = shift;
    unless ($type) { $type = 'hw'; }
    add_textual_fru($parsedfru,$desc." ".$categorydesc."Part Number",$category,"partnumber","hw");
    add_textual_fru($parsedfru,$desc." ".$categorydesc."Manufacturer",$category,"manufacturer","hw");
    add_textual_fru($parsedfru,$desc." ".$categorydesc."Serial Number",$category,"serialnumber","hw");
    add_textual_fru($parsedfru,$desc." ".$categorydesc."",$category,"name","hw");
    if ($parsedfru->{$category}->{builddate}) {
        add_textual_fru($parsedfru,$desc." ".$categorydesc."Manufacture Date",$category,"builddate","hw");
    }
    if ($parsedfru->{$category}->{buildlocation}) {
        add_textual_fru($parsedfru,$desc." ".$categorydesc."Manufacture Location",$category,"buildlocation","hw");
    }
    if ($parsedfru->{$category}->{model})  {
        add_textual_fru($parsedfru,$desc." ".$categorydesc."Model",$category,"model","hw");
    }
    add_textual_fru($parsedfru,$desc." ".$categorydesc."Additional Info",$category,"extra","hw");
}

sub initfru {
	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;

	my $mfg_id;
	my $prod_id;
	my $device_id;
	my $dev_rev;
	my $fw_rev1;
	my $fw_rev2;
	my $mprom;
	my $fru;
	my $guid;
	my @guidcmd;

	($rc,$text,$mfg_id,$prod_id,$device_id,$dev_rev,$fw_rev1,$fw_rev2) = getdevid();
	if($rc != 0) {
		return($rc,$text);
	}

	@guidcmd = (0x18,0x37);
	if($mfg_id == 2 && $prod_id == 34869) {
		@guidcmd = (0x18,0x08);
	}
	if($mfg_id == 2 && $prod_id == 4) {
		@guidcmd = (0x18,0x08);
	}
	if($mfg_id == 2 && $prod_id == 3) {
		@guidcmd = (0x18,0x08);
	}

	($rc,$text,$guid) = getguid(\@guidcmd);
	if($rc != 0) {
		return($rc,$text);
	}

	if($mfg_id == 2 && $prod_id == 34869) {
		$mprom = sprintf("%x.%x",$fw_rev1,$fw_rev2);
	}
	elsif ($mfg_id == 2) {
		my @lcmd = (0x50);
		my @lreturnd = ();
		my $lerror = docmd(
			0xe8,
			\@lcmd,
			\@lreturnd
		);
		if ($lerror eq "" && $lreturnd[36-$authoffset] == 0) {
			my @a = ($fw_rev2);
			my @b= @lreturnd[37-$authoffset .. $#lreturnd-1];
			$mprom = sprintf("%d.%s (%s)",$fw_rev1,decodebcd(\@a),getascii(@b));
		} else {
			my @a = ($fw_rev2);
			$mprom = sprintf("%d.%s",$fw_rev1,decodebcd(\@a));
		}
	} else {
        my @a = ($fw_rev2);
        $mprom = sprintf("%d.%s",$fw_rev1,decodebcd(\@a));
    }

	$fru = FRU->new();
	$fru->rec_type("mprom");
	$fru->desc("BMC Firmware");
	$fru->value($mprom);
	$fru_hash{mprom} = $fru;

	$fru = FRU->new();
	$fru->rec_type("guid");
	$fru->desc("GUID");
	$fru->value($guid);
	$fru_hash{guid} = $fru;

	$fru = FRU->new();
	$fru->rec_type("deviceid");
	$fru->desc("Manufacturer ID");
	my $value = $mfg_id;
	if($MFG_ID{$mfg_id}) {
		$value = "$MFG_ID{$mfg_id} ($mfg_id)";
	}
	$fru->value($value);
	$fru_hash{mfg_id} = $fru;

	$fru = FRU->new();
	$fru->rec_type("deviceid");
	$fru->desc("Product ID");
	$value = $prod_id;
	my $tmp = "$mfg_id:$prod_id";
	if($PROD_ID{$tmp}) {
		$value = "$PROD_ID{$tmp} ($prod_id)";
	}
	$fru->value($value);
	$fru_hash{prod_id} = $fru;

	$fru = FRU->new();
	$fru->rec_type("deviceid");
	$fru->desc("Device ID");
	$fru->value($device_id);
	$fru_hash{device_id} = $fru;

#	($rc,$text)=initoemfru($mfg_id,$prod_id,$device_id);
#	if($rc == 1) {
#		return($rc,$text);
#	}
#	if($rc == 2) {
#		return(0,"");
#	}
    $netfun = 0x28; # Storage (0x0A << 2)
	my @bytes;
	@cmd=(0x10,0x00);
    $error = docmd($netfun,\@cmd,\@bytes);
    if ($error) { return (1,$error); }
    @bytes=splice @bytes,36-$authoffset;
    pop @bytes;
    unless (defined $bytes[0] and $bytes[0] == 0) {
        if ($codes{$bytes[0]}) {
            return (1,"FRU device 0 inaccessible".$codes{$bytes[0]});
        } else {
            return (1,"FRU device 0 inaccessible");
        }
    }
    my $frusize=($bytes[2]<<8)+$bytes[1];

	($rc,@bytes) = frudump(0,$frusize,16);
	if($rc != 0) {
		return($rc,@bytes);
	}
    my $fruhash;
    ($error,$fruhash) = parsefru(\@bytes);
    if ($error) {
		($rc,$text)=initoemfru($mfg_id,$prod_id,$device_id);
		if($rc == 1) {
			$text = "FRU format unknown";
			return($rc,$text);
		}
		if($rc == 2) {
			return(0,"");
		}
	}
    $frudex=0;
    if (defined $fruhash->{product}->{manufacturer}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("misc");
    	$fru->desc("System Manufacturer");
        if ($fruhash->{product}->{product}->{encoding}==3) {
        	$fru->value($fruhash->{product}->{manufacturer}->{value});
        } else {
        	$fru->value(phex($fruhash->{product}->{manufacturer}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if (defined $fruhash->{product}->{product}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("model");
    	$fru->desc("System Description");
        if ($fruhash->{product}->{product}->{encoding}==3) {
        	$fru->value($fruhash->{product}->{product}->{value});
        } else {
        	$fru->value(phex($fruhash->{product}->{product}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if (defined $fruhash->{product}->{model}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("model");
    	$fru->desc("System Model/MTM");
        if ($fruhash->{product}->{model}->{encoding}==3) {
        	$fru->value($fruhash->{product}->{model}->{value});
        } else {
        	$fru->value(phex($fruhash->{product}->{model}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if (defined $fruhash->{product}->{version}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("misc");
    	$fru->desc("System Revision");
        if ($fruhash->{product}->{version}->{encoding}==3) {
        	$fru->value($fruhash->{product}->{version}->{value});
        } else {
        	$fru->value(phex($fruhash->{product}->{version}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if (defined $fruhash->{product}->{serialnumber}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("serial");
    	$fru->desc("System Serial Number");
        if ($fruhash->{product}->{serialnumber}->{encoding}==3) {
        	$fru->value($fruhash->{product}->{serialnumber}->{value});
        } else {
        	$fru->value(phex($fruhash->{product}->{serialnumber}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if (defined $fruhash->{product}->{asset}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("asset");
    	$fru->desc("System Asset Number");
        if ($fruhash->{product}->{asset}->{encoding}==3) {
        	$fru->value($fruhash->{product}->{asset}->{value});
        } else {
        	$fru->value(phex($fruhash->{product}->{asset}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    foreach (@{$fruhash->{product}->{extra}}) {
        $fru = FRU->new();
        $fru->rec_type("misc");
        $fru->desc("Product Extra data");
        if ($_->{encoding} == 3) {
            $fru->value($_->{value});
        } else {
            #print Dumper($_);
            #print $_->{encoding};
            next;
            $fru->value(phex($_->{value}));
        }
        $fru_hash{$frudex++} = $fru;
    }
    

    if ($fruhash->{chassis}->{serialnumber}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("serial");
    	$fru->desc("Chassis Serial Number");
        if ($fruhash->{chassis}->{serialnumber}->{encoding}==3) {
        	$fru->value($fruhash->{chassis}->{serialnumber}->{value});
        } else {
        	$fru->value(phex($fruhash->{chassis}->{serialnumber}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }

    if ($fruhash->{chassis}->{partnumber}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("model");
    	$fru->desc("Chassis Part Number");
        if ($fruhash->{chassis}->{partnumber}->{encoding}==3) {
        	$fru->value($fruhash->{chassis}->{partnumber}->{value});
        } else {
        	$fru->value(phex($fruhash->{chassis}->{partnumber}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }


    foreach (@{$fruhash->{chassis}->{extra}}) {
        $fru = FRU->new();
        $fru->rec_type("misc");
        $fru->desc("Chassis Extra data");
        if ($_->{encoding} == 3) {
            $fru->value($_->{value});
        } else {
            next;
            #print Dumper($_);
            #print $_->{encoding};
            $fru->value(phex($_->{value}));
        }
        $fru_hash{$frudex++} = $fru;
    }

    if ($fruhash->{board}->{builddate})  {
        $fru = FRU->new();
        $fru->rec_type("misc");
        $fru->desc("Board manufacture date");
        $fru->value($fruhash->{board}->{builddate});
        $fru_hash{$frudex++} = $fru;
    }

    if ($fruhash->{board}->{manufacturer}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("misc");
    	$fru->desc("Board manufacturer");
        if ($fruhash->{board}->{manufacturer}->{encoding}==3) {
        	$fru->value($fruhash->{board}->{manufacturer}->{value});
        } else {
        	$fru->value(phex($fruhash->{board}->{manufacturer}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if ($fruhash->{board}->{name}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("misc");
    	$fru->desc("Board Description");
        if ($fruhash->{board}->{name}->{encoding}==3) {
        	$fru->value($fruhash->{board}->{name}->{value});
        } else {
        	$fru->value(phex($fruhash->{board}->{name}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if ($fruhash->{board}->{serialnumber}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("misc");
    	$fru->desc("Board Serial Number");
        if ($fruhash->{board}->{serialnumber}->{encoding}==3) {
        	$fru->value($fruhash->{board}->{serialnumber}->{value});
        } else {
        	$fru->value(phex($fruhash->{board}->{serialnumber}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    if ($fruhash->{board}->{partnumber}->{value}) {
	    $fru = FRU->new();
    	$fru->rec_type("misc");
    	$fru->desc("Board Model Number");
        if ($fruhash->{board}->{partnumber}->{encoding}==3) {
        	$fru->value($fruhash->{board}->{partnumber}->{value});
        } else {
        	$fru->value(phex($fruhash->{board}->{partnumber}->{value}));
        }
    	$fru_hash{$frudex++} = $fru;
    }
    foreach (@{$fruhash->{board}->{extra}}) {
        $fru = FRU->new();
        $fru->rec_type("misc");
        $fru->desc("Board Extra data");
        if ($_->{encoding} == 3) {
            $fru->value($_->{value});
        } else {
            next;
            #print Dumper($_);
            #print $_->{encoding};
            $fru->value(phex($_->{value}));
        }
        $fru_hash{$frudex++} = $fru;
    }
    #Ok, done with fru 0, on to the other fru devices from SDR
    my $key;
    my $subrc;
    foreach $key (sort {$sdr_hash{$a}->id_string cmp $sdr_hash{$b}->id_string} keys %sdr_hash) {
        my $sdr = $sdr_hash{$key};
        unless ($sdr->rec_type == 0x11 and $sdr->fru_type == 0x10) { #skip non fru sdr stuff and frus I don't understand
            next;
        }
        
        if ($sdr->fru_type == 0x10) { #supported
            if ($sdr->fru_subtype == 0x1) { #DIMM
                $fru = FRU->new();
                $fru->rec_type("hw,dimm");
                $fru->desc($sdr->id_string);
	            ($subrc,@bytes) = frudump(0,get_frusize($sdr->sensor_number),16,$sdr->sensor_number);
                if ($subrc) {
                    print $sdr->id_string.":".$bytes[0]."\n";
                    $fru->value($bytes[0]);
                    $fru_hash{$frudex++} = $fru;
                    next;
                }
                my $parsedfru = decode_spd(@bytes);
                add_textual_frus($parsedfru,$sdr->id_string,"",'product','dimm,hw');
            } elsif ($sdr->fru_subtype == 0 or $sdr->fru_subtype == 2) {
	            ($subrc,@bytes) = frudump(0,get_frusize($sdr->sensor_number),16,$sdr->sensor_number);
                if ($subrc) {
                    $fru = FRU->new();
                    $fru->value($bytes[0]);
                    $fru->rec_type("hw");
                    $fru->desc($sdr->id_string);
                    $fru_hash{$frudex++} = $fru;
                    next;
                }
                my $parsedfru=parsefru(\@bytes);
                add_textual_frus($parsedfru,$sdr->id_string,"Board ",'board');
                add_textual_frus($parsedfru,$sdr->id_string,"Product ",'product');
                add_textual_frus($parsedfru,$sdr->id_string,"Chassis ",'chassis');
            }
        }
    }



	return($rc,$text);
}
sub get_frusize {
    my $fruid=shift;
    my $netfun = 0x28; # Storage (0x0A << 2)
    my @cmd=(0x10,$fruid);
	my @bytes;
    my $error = docmd($netfun,\@cmd,\@bytes);
    @bytes=splice @bytes,36-$authoffset;
    pop @bytes;
    unless (defined $bytes[0] and $bytes[0] == 0) {
        if ($codes{$bytes[0]}) {
            return (0,$codes{$bytes[0]});
        }
        return (0,"FRU device $fruid inaccessible");
    }
    return ($bytes[2]<<8)+$bytes[1];
}

sub formfru {
    my $fruhash = shift;
    my $frusize = shift;
    $frusize-=8; #consume 8 bytes for mandatory header
    my $availindex=1;
    my @bytes=(1,0,0,0,0,0,0,0); #
    if ($fruhash->{internal}) { #Allocate the space at header time
        $bytes[1]=$availindex;
        $availindex+=ceil((scalar @{$fruhash->{internal}})/8);
        $frusize-=(scalar @{$fruhash->{internal}}); #consume internal bytes
        push @bytes,@{$fruhash->{internal}};
    } 
    if ($fruhash->{chassis}) {
        $bytes[2]=$availindex;
        push @bytes,@{$fruhash->{chassis}->{raw}};
        $availindex+=ceil((scalar @{$fruhash->{chassis}->{raw}})/8);
        $frusize -= ceil((scalar @{$fruhash->{chassis}->{raw}})/8)*8;
    }
    if ($fruhash->{board}) {
        $bytes[3]=$availindex;
        push @bytes,@{$fruhash->{board}->{raw}};
        $availindex+=ceil((scalar @{$fruhash->{board}->{raw}})/8);
        $frusize -= ceil((scalar @{$fruhash->{board}->{raw}})/8)*8;
    }
    #xCAT will always have a product FRU in this process
    $bytes[4]=$availindex;
    unless (defined $fruhash->{product}) { #Make sure there is a data structure
                        #to latch onto..
        $fruhash->{product}={};
    }
    my @prodbytes = buildprodfru($fruhash->{product});
    push @bytes,@prodbytes;
    $availindex+=ceil((scalar @prodbytes)/8);
    $frusize -= ceil((scalar @prodbytes)/8)*8;;
    #End of product fru setup
    if ($fruhash->{extra}) {
        $bytes[5]=$availindex;
        push @bytes,@{$fruhash->{extra}};
        $frusize -= ceil((scalar @{$fruhash->{extra}})/8)*8;
        #Don't need to track availindex anymore
    }
    $bytes[7] = dochksum([@bytes[0..6]]);
    if ($frusize<0) {
        return undef;
    } else {
        return \@bytes;
    }
}

sub transfieldtobytes {
    my $hashref=shift;
    unless (defined $hashref) {
        return (0xC0);
    }
    my @data;
    my $size;
    if ($hashref->{encoding} ==3) {
        @data=unpack("C*",$hashref->{value});
    } else {
        @data=@{$hashref->{value}};
    }
    $size=scalar(@data);
    if ($size > 64) {
        die "Field too large for IPMI FRU specification";
    }
    unshift(@data,$size|($hashref->{encoding}<<6));
    return @data;
}
sub mergefru {
    my $phash = shift; #Product hash
    if ($vpdhash->{$currnode}->[0]->{mtm}) {
        $phash->{model}->{encoding}=3;
        $phash->{model}->{value}=$vpdhash->{$currnode}->[0]->{mtm};
    }
    if ($vpdhash->{$currnode}->[0]->{serial}) {
        $phash->{serialnumber}->{encoding}=3;
        $phash->{serialnumber}->{value}=$vpdhash->{$currnode}->[0]->{serial};
    }
    if ($vpdhash->{$currnode}->[0]->{asset}) {
        $phash->{asset}->{encoding}=3;
        $phash->{asset}->{value}=$vpdhash->{$currnode}->[0]->{asset};
    }
}

sub buildprodfru {
    my $prod=shift;
    mergefru($prod);
    my @bytes=(1,0,0);
    my @data;
    my $padsize;
    push @bytes,transfieldtobytes($prod->{manufacturer});
    push @bytes,transfieldtobytes($prod->{product});
    push @bytes,transfieldtobytes($prod->{model});
    push @bytes,transfieldtobytes($prod->{version});
    push @bytes,transfieldtobytes($prod->{serialnumber});
    push @bytes,transfieldtobytes($prod->{asset});
    push @bytes,transfieldtobytes($prod->{fruid});
    push @bytes,transfieldtobytes($prod->{fruid});
    foreach (@{$prod->{extra}}) {
        my $sig=getascii(transfieldtobytes($_));
        unless ($sig and $sig =~ /FRU by xCAT/) {
            push @bytes,transfieldtobytes($_);
        }
    }
    push @bytes,transfieldtobytes({encoding=>3,value=>"$currnode FRU by xCAT ".xCAT::Utils::Version('short')});
    push @bytes,(0xc1);
    $bytes[1]=ceil((scalar(@bytes)+1)/8);
    $padsize=(ceil((scalar(@bytes)+1)/8)*8)-scalar(@bytes)-1;
    while ($padsize--) {
        push @bytes,(0x00);
    }
    $padsize=dochksum(\@bytes);#reuse padsize for a second to store checksum
    push @bytes,$padsize;

    return @bytes;
}

sub fru {
	my $subcommand = shift;
	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;

	@cmd=(0x10,0x00);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	if($rc != 0) {
		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	my $fru_size_ls = $returnd[37-$authoffset];
	my $fru_size_ms = $returnd[38-$authoffset];
	my $fru_size = $fru_size_ms*256 + $fru_size_ls;

	if($subcommand eq "dump") {
		print "FRU Size: $fru_size\n";
		my ($rc,@output) = frudump(0,$fru_size,8);
		if($rc) {
			return($rc,@output);
		}
		hexadump(\@output);
		return(0,"");
	}
	if($subcommand eq "wipe") {
		my @bytes = ();

		for(my $i = 0;$i < $fru_size;$i++) {
			push(@bytes,0xff);
		}
		my ($rc,$text) = fruwrite(0,\@bytes,8);
		if($rc) {
			return($rc,$text);
		}
		return(0,"FRU $fru_size bytes wiped");
	}

	return(0,"");
}

sub frudump {
	my $offset = shift;
	my $length = shift;
	my $chunk = shift;
    my $fruid = shift;
    unless (defined $fruid) { $fruid = 0; }
    unless ($length) { return (1,$chunk); } #chunk happens to get the error text

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;
	my @fru_data=();

	for(my $c=$offset;$c < $length+$offset;$c += $chunk) {
		my $ms = int($c / 0x100);
		my $ls = $c - $ms * 0x100;
        my $reqsize = $chunk;
        if ($c+$chunk > $length+$offset) {
            $reqsize = ($length+$offset-$c);
        }

		@cmd=(0x11,$fruid,$ls,$ms,$reqsize);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my $count = $returnd[37-$authoffset];
		if($count != $reqsize) {
			$rc = 1;
			$text = "FRU read error (bytes requested: $reqsize, got: $count)";
			return($rc,$text);
		}

		my @data = @returnd[38-$authoffset..@returnd-2];
		@fru_data = (@fru_data,@data);
	}

	return(0,@fru_data);
}

sub parsefru {
    my $bytes = shift;
    my $fruhash;
    my $curridx; #store indexes as needed for convenience
    my $currsize; #store current size
    my $subidx;
    my @currarea;
    unless ($bytes->[0]==1) {
        if ($bytes->[0]==0 or $bytes->[0]==0xff) { #not in spec, but probably unitialized, xCAT probably will rewrite fresh
            return "clear",undef;
        } else { #some meaning suggested, but not parsable, xCAT shouldn't meddle
            return "unknown",undef;
        }
    }
    if ($bytes->[1]) { #The FRU spec, unfortunately, gave no easy way to tell the size of internal area
        #consequently, will find the next defined field and preserve the addressing and size of current FRU 
        #area until then
        my $internal_size;
        if ($bytes->[2]) {
            $internal_size=$bytes->[2]*8-($bytes->[1]*8);
        } elsif ($bytes->[3]) {
            $internal_size=$bytes->[3]*8-($bytes->[1]*8);
        } elsif ($bytes->[4]) {
            $internal_size=$bytes->[4]*8-($bytes->[1]*8);
        } elsif ($bytes->[5]) {
            $internal_size=$bytes->[5]*8-($bytes->[1]*8);
        } else { #The FRU area is intact enough to signify xCAT can't safely manipulate contents
            return "unknown-winternal",undef;
        }
        #capture slice of bytes
        $fruhash->{internal}=[@{$bytes}[($bytes->[1]*8)..($bytes->[1]*8+$internal_size-1)]]; #,$bytes->[1]*8,$internal_size];
    }
    if ($bytes->[2]) { #Chassis info area, xCAT will preserve fields, not manipulate them
        $curridx=$bytes->[2]*8;
        unless ($bytes->[$curridx]==1) { #definitely unparsable, but the section is preservable
            return "unknown-COULDGUESS",undef; #be lazy for now, TODO revisit this and add guessing if it ever matters
        }
        $currsize=($bytes->[$curridx+1])*8;
        @currarea=@{$bytes}[$curridx..($curridx+$currsize-1)]; #splice @$bytes,$curridx,$currsize;
        $fruhash->{chassis} = parsechassis(@currarea);
    }
    if ($bytes->[3]) { #Board info area, to be preserved
        $curridx=$bytes->[3]*8;
        unless ($bytes->[$curridx]==1) {
            return "unknown-COULDGUESS",undef;
        }
        $currsize=($bytes->[$curridx+1])*8;
        @currarea=@{$bytes}[$curridx..($curridx+$currsize-1)];
        $fruhash->{board} = parseboard(@currarea);
    }
    if ($bytes->[4]) { #Product info area present, will probably be thoroughly modified
        $curridx=$bytes->[4]*8;
        unless ($bytes->[$curridx]==1) {
            return "unknown-COULDGUESS",undef;
        }
        $currsize=($bytes->[$curridx+1])*8;
        @currarea=@{$bytes}[$curridx..($curridx+$currsize-1)];
        $fruhash->{product} = parseprod(@currarea);
    }
    if ($bytes->[5]) { #Generic multirecord present..
        $fruhash->{extra}=[];
        my $last=0;
        $curridx=$bytes->[5]*8;
        my $currsize;
        while (not $last) {
            if ($bytes->[$curridx+1] & 128) {
                $last=1;
            }
            $currsize=$bytes->[$curridx+2];
            push @{$fruhash->{extra}},$bytes->[$curridx..$curridx+4+$currsize-1];
        }
    }
    return 0,$fruhash;
}

sub parseprod {
    my @area = @_;
    my %info;
    my $language=$area[2];
    my $idx=3;
    my $currsize;
    my $currdata;
    my $encode;
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%info;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $info{manufacturer}->{encoding}=$encode;
        $info{manufacturer}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%info;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $info{product}->{encoding}=$encode;
        $info{product}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%info;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $info{model}->{encoding}=$encode;
        $info{model}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%info;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $info{version}->{encoding}=$encode;
        $info{version}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%info;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $info{serialnumber}->{encoding}=$encode;
        $info{serialnumber}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%info;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $info{asset}->{encoding}=$encode;
        $info{asset}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%info;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $info{fruid}->{encoding}=$encode;
        $info{fruid}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    if ($currsize) {
        $info{extra}=[];
    }
    while ($currsize>0) {
        if ($currsize>1) {
            push @{$info{extra}},{value=>$currdata,encoding=>$encode};
        }
        $idx+=$currsize;
        ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    }
    return \%info;

}
sub parseboard {
    my @area = @_;
    my %boardinf;
    my $idx=6;
    my $language=$area[2];
    my $tstamp = ($area[3]+($area[4]<<8)+($area[5]<<16))*60+820472400; #820472400 is meant to be 1/1/1996
    $boardinf{raw}=[@area]; #store for verbatim replacement
    unless ($tstamp == 820472400) {
        $boardinf{builddate}=scalar localtime($tstamp);
    }
    my $encode;
    my $currsize;
    my $currdata;
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%boardinf;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $boardinf{manufacturer}->{encoding}=$encode;
        $boardinf{manufacturer}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%boardinf;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $boardinf{name}->{encoding}=$encode;
        $boardinf{name}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%boardinf;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $boardinf{serialnumber}->{encoding}=$encode;
        $boardinf{serialnumber}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%boardinf;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $boardinf{partnumber}->{encoding}=$encode;
        $boardinf{partnumber}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    unless ($currsize) {
        return \%boardinf;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $boardinf{fruid}->{encoding}=$encode;
        $boardinf{fruid}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    if ($currsize) {
        $boardinf{extra}=[];
    }
    while ($currsize>0) {
        if ($currsize>1) {
            push @{$boardinf{extra}},{value=>$currdata,encoding=>$encode};
        }
        $idx+=$currsize;
        ($currsize,$currdata,$encode)=extractfield(\@area,$idx);
    }
    return \%boardinf;
}
sub parsechassis {
    my @chassarea=@_;
    my %chassisinf;
    my $currsize;
    my $currdata;
    my $idx=3;
    my $encode;
    $chassisinf{raw}=[@chassarea]; #store for verbatim replacement
    $chassisinf{type}="unknown";
    if ($chassis_types{$chassarea[2]}) {
        $chassisinf{type}=$chassis_types{$chassarea[2]};
    }
    if ($chassarea[$idx] == 0xc1) {
        return \%chassisinf;
    }
    ($currsize,$currdata,$encode)=extractfield(\@chassarea,$idx);
    unless ($currsize) {
        return \%chassisinf;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $chassisinf{partnumber}->{encoding}=$encode;
        $chassisinf{partnumber}->{value}=$currdata;
    } 
    ($currsize,$currdata,$encode)=extractfield(\@chassarea,$idx);
    unless ($currsize) {
        return \%chassisinf;
    }
    $idx+=$currsize;
    if ($currsize>1) {
        $chassisinf{serialnumber}->{encoding}=$encode;
        $chassisinf{serialnumber}->{value}=$currdata;
    }
    ($currsize,$currdata,$encode)=extractfield(\@chassarea,$idx);
    if ($currsize) {
        $chassisinf{extra}=[];
    }
    while ($currsize>0) {
        if ($currsize>1) {
            push @{$chassisinf{extra}},{value=>$currdata,encoding=>$encode};
        }
        $idx+=$currsize;
        ($currsize,$currdata,$encode)=extractfield(\@chassarea,$idx);
    }
    return \%chassisinf;
}

sub extractfield { #idx is location of the type/length byte, returns something appropriate
    my $area = shift;
    my $idx = shift;
    my $language=shift;
    my $data;
    my $size = $area->[$idx] & 0b00111111;
    my $encoding = ($area->[$idx] & 0b11000000)>>6;
    unless ($size) {
        return 1,undef,undef;
    }
    if ($size==1 && $encoding==3) { 
        return 0,'','';
    }
    if ($encoding==3) {
        $data=getascii(@$area[$idx+1..$size+$idx]);
    } else {
        $data = [@$area[$idx+1..$size+$idx]];
    }
    return $size+1,$data,$encoding;
}






sub writefru {
    my $netfun = 0x28; # Storage (0x0A << 2)
    my @cmd=(0x10,0);
	my @bytes;
    my $error = docmd($netfun,\@cmd,\@bytes);
    @bytes=splice @bytes,36-$authoffset;
    pop @bytes;
    unless (defined $bytes[0] and $bytes[0] == 0) {
        return (1,"FRU device 0 inaccessible");
    }
    my $frusize=($bytes[2]<<8)+$bytes[1];
    ($error,@bytes) = frudump(0,$frusize,16);
    if ($error) {
        return (1,"Error retrieving FRU: ".$error);
    }
    my $fruhash; 
    ($error,$fruhash) = parsefru(\@bytes);
    my $newfru=formfru($fruhash,$frusize);
    unless ($newfru) {
        return (1,"FRU data will not fit in BMC FRU space, fields too long");
    }
    my $rc=1;
    my $writeattempts=0;
    my $text;
    while ($rc and $writeattempts<15) {
        if ($writeattempts) {
            sleep 1;
        }
    	($rc,$text) = fruwrite(0,$newfru,8);
        if ($text =~ /rotected/) {
            last;
        }
        $writeattempts++;
    }
	if($rc) {
		return($rc,$text);
	}
	return(0,"FRU Updated");
}

sub fruwrite {
	my $offset = shift;
	my $bytes = shift;
	my $chunk = shift;
	my $length = @$bytes;

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;
	my @fru_data=();

	for(my $c=$offset;$c < $length+$offset;$c += $chunk) {
		my $ms = int($c / 0x100);
		my $ls = $c - $ms * 0x100;

		@cmd=(0x12,0x00,$ls,$ms,@$bytes[$c-$offset..$c-$offset+$chunk-1]);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
            if ($code == 0x80) {
                $text = "Write protected FRU";
            }
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my $count = $returnd[37-$authoffset];
		if($count != $chunk) {
			$rc = 1;
			$text = "FRU write error (bytes requested: $chunk, wrote: $count)";
			return($rc,$text);
		}
	}

	return(0);
}

sub decodealert {
  my $trap = shift;
  my $skip_sdrinit=0;
  if ($trap =~ /xCAT_plugin::ipmi/) {
    $trap=shift;
    $skip_sdrinit=1;
  }
	my $node = shift;
	my @pet = @_;
	my $rc;
	my $text;
    
    if (!$skip_sdrinit) { 
	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}
    }

	my $type;
	my $desc;
	#my $ipmisensoreventtab = "$ENV{XCATROOT}/lib/GUMI/ipmisensorevent.tab";
	#my $ipmigenericeventtab = "$ENV{XCATROOT}/lib/GUMI/ipmigenericevent.tab";

	my $offsetmask     = 0b00000000000000000000000000001111;
	my $offsetrmask    = 0b00000000000000000000000001110000;
	my $assertionmask  = 0b00000000000000000000000010000000;
	my $eventtypemask  = 0b00000000000000001111111100000000;
	my $sensortypemask = 0b00000000111111110000000000000000;
	my $reservedmask   = 0b11111111000000000000000000000000;

	my $offset      = $trap & $offsetmask;
	my $offsetr     = $trap & $offsetrmask;
	my $event_dir   = $trap & $assertionmask;
	my $event_type  = ($trap & $eventtypemask) >> 8;
	my $sensor_type = ($trap & $sensortypemask) >> 16;
	my $reserved    = ($trap & $reservedmask) >> 24;

	if($debug >= 2) {
		printf("offset:     %02xh\n",$offset);
		printf("offsetr:    %02xh\n",$offsetr);
		printf("assertion:  %02xh\n",$event_dir);
		printf("eventtype:  %02xh\n",$event_type);
		printf("sensortype: %02xh\n",$sensor_type);
		printf("reserved:   %02xh\n",$reserved);
	}

	my @hex = (0,@pet);
	my $pad = $hex[0];
	my @uuid = @hex[1..16];
	my @seqnum = @hex[17,18];
	my @timestamp = @hex[19,20,21,22];
	my @utcoffset = @hex[23,24];
	my $trap_source_type = $hex[25];
	my $event_source_type = $hex[26];
	my $sev = $hex[27];
	my $sensor_device = $hex[28];
	my $sensor_num = $hex[29];
	my $entity_id = $hex[30];
	my $entity_instance = $hex[31];
	my $event_data_1 = $hex[32];
	my $event_data_2 = $hex[33];
	my $event_data_3 = $hex[34];
	my @event_data = @hex[35..39];
	my $langcode = $hex[40];
	my $mfg_id = $hex[41] + $hex[42] * 0x100 + $hex[43] * 0x10000 + $hex[44] * 0x1000000;
	my $prod_id = $hex[45] + $hex[46] * 0x100;
	my @oem = $hex[47..@hex-1];

	if($sev == 0x00) {
		$sev = "LOG";
	}
	elsif($sev == 0x01) {
		$sev = "MONITOR";
	}
	elsif($sev == 0x02) {
		$sev = "INFORMATION";
	}
	elsif($sev == 0x04) {
		$sev = "OK";
	}
	elsif($sev == 0x08) {
		$sev = "WARNING";
	}
	elsif($sev == 0x10) {
		$sev = "CRITICAL";
	}
	elsif($sev == 0x20) {
		$sev = "NON-RECOVERABLE";
	}
	else {
		$sev = "UNKNOWN-SEVERITY:$sev";
	}
	$text = "$sev:";

	($rc,$type,$desc) = getsensorevent($sensor_type,$offset,"ipmisensorevents");
	if($rc == 1) {
		$type = "Unknown Type $sensor_type";
		$desc = "Unknown Event $offset";
		$rc = 0;
	}

	if($event_type <= 0x0c) {
		my $gtype;
		my $gdesc;
		($rc,$gtype,$gdesc) = getsensorevent($event_type,$offset,"ipmigenericevents");
		if($rc == 1) {
			$gtype = "Unknown Type $gtype";
			$gdesc = "Unknown Event $offset";
			$rc = 0;
		}

		$desc = $gdesc;
	}

	if($type eq "" || $type eq "-") {
		$type = "OEM Sensor Type $sensor_type"
	}
	if($desc eq "" || $desc eq "-") {
		$desc = "OEM Sensor Event $offset"
	}

	if($type eq $desc) {
		$desc = "";
	}

	my $extra_info = getaddsensorevent($sensor_type,$offset,$event_data_1,$event_data_2,$event_data_3);
	if($extra_info) {
		if($desc) {
			$desc = "$desc $extra_info";
		}
		else {
			$desc = "$extra_info";
		}
	}

	$text = "$text $type,";
	$text = "$text $desc";

	my $key;
	my $sensor_desc = sprintf("Sensor 0x%02x",$sensor_num);
	foreach $key (keys %sdr_hash) {
		my $sdr = $sdr_hash{$key};
		if($sdr->sensor_number == $sensor_num) {
			$sensor_desc = $sdr_hash{$key}->id_string;
			if($sdr->rec_type == 0x01) {
				last;
			}
		}
	}

	$text = "$text ($sensor_desc)";

	if($event_dir) {
		$text = "$text - Recovered";
	}

	return(0,$text);
}

sub readauxentry {
    my $netfn=0x2e<<2;
    my $entrynum = shift;
    my $entryls = ($entrynum&0xff);
    my $entryms = ($entrynum>>8);
    my @cmd = (0x93,0x4d,0x4f,0x00,$entryls,$entryms,0,0,0xff,0x5); #Get log size andup to 1275 bytes of data, keeping it under 1500 to accomodate mixed-mtu circumstances
    my @data;
    my $error = docmd(
        $netfn,
        \@cmd,
        \@data
        );
    if ($error) { return $error; }
    @data=splice @data,36-$authoffset;
    if ($data[0]) { return $data[0]; }
    my $text;
    unless ($data[1] == 0x4d and $data[2] == 0x4f and $data[3] == 0) { return "Unrecognized response format" }
    $entrynum=$data[6]+($data[7]<<8);
    if (($data[10]&1) == 1) {
        $text="POSSIBLY INCOMPLETE DATA FOLLOWS:\n";
    }
    my $addtext="";
    if ($data[5] > 5) {
        $addtext="\nTODO:SUPPORT MORE DATA THAT WAS SEEN HERE";
    }
    @data = splice @data,11;
    pop @data;
    while(scalar(@data)) {
        my @subdata = splice @data,0,30;
        my $numbytes = scalar(@subdata);
        my $formatstring="%02x"x$numbytes;
        $formatstring =~ s/%02x%02x/%02x%02x /g;
        $text.=sprintf($formatstring."\n",@subdata);
    }
    $text.=$addtext;
    return (0,$entrynum,$text);


}



sub eventlog {
	my $subcommand = shift;

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;
	my @output;
	my $num;
	my $entry;
    my $skiptail=0;
	my @sel;
	#my $ipmisensoreventtab = "$ENV{XCATROOT}/lib/GUMI/ipmisensorevent.tab";
	#my $ipmigenericeventtab = "$ENV{XCATROOT}/lib/GUMI/ipmigenericevent.tab";
	my $mfg_id;
	my $prod_id;
	my $device_id;

	($rc,$text,$mfg_id,$prod_id,$device_id) = getdevid();
	$rc=0;
   unless (defined($subcommand)) {
      $subcommand = 'all';
   }
	if($subcommand eq "all") {
        $skiptail=1;

		$num = 0x100 * 0x100;
	}
	elsif($subcommand eq "clear") {
	}
	elsif($subcommand =~ /^\d+$/) {
		$num = $subcommand;
	}
	else {
		return(1,"unsupported command eventlog $subcommand");
	}

   #Here we set tfactor based on the delta between the BMC reported time and our
   #time.  The IPMI spec says the BMC should return seconds since 1970 in local
   #time, but the reality is the firmware pushing to the BMC has no context
   #to know, so here we guess and adjust all timestamps based on delta between
   #our now and the BMC's now
   $error = docmd(
      $netfun,
      [0x48],
      \@returnd
   );
   $tfactor = $returnd[40]<<24 | $returnd[39]<<16 | $returnd[38]<<8 | $returnd[37];
   if ($tfactor > 0x20000000) {
      $tfactor -= time(); 
   } else {
      $tfactor = 0;
   }
      
	@cmd=(0x40);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	elsif($code == 0x81) {
		$rc = 1;
		$text = "cannot execute command, SEL erase in progress";
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	if($rc != 0) {
		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	my $sel_version = $returnd[37-$authoffset];
	if($sel_version != 0x51) {
		$rc = 1;
		$text = sprintf("SEL version 51h support only, version reported: %x",$sel_version);
		return($rc,$text);
	}

	my $num_entries = $returnd[39-$authoffset]*256 + $returnd[38-$authoffset];
	if($num_entries <= 0) {
		$rc = 1;
		$text = "no SEL entries";
		return($rc,$text);
	}

	my $canres = $returnd[50-$authoffset] & 0b00000010;
	if(!$canres) {
		$rc = 1;
		$text = "SEL reservation not supported";
		return($rc,$text);
	}

    my $res_id_ls=0;
    my $res_id_ms=0;
    my %auxloginfo;
    if ($subcommand =~ /clear/) { #Don't bother with a reservation unless a clear is involved
        #atomic SEL retrieval need not require it, so an event during retrieval will not kill reventlog effort off
    	@cmd=(0x42);
    	$error = docmd(
    		$netfun,
    		\@cmd,
    		\@returnd
    	);
    
    	if($error) {
    		$rc = 1;
    		$text = $error;
    		return($rc,$text);
    	}
        
    	$code = $returnd[36-$authoffset];
    
    	if($code == 0x00) {
    	}
    	elsif($code == 0x81) {
    		$rc = 1;
    		$text = "cannot execute command, SEL erase in progress";
    	}
    	else {
    		$rc = 1;
    		$text = $codes{$code};
    	}
    
    	if($rc != 0) {
    		if(!$text) {
    			$text = sprintf("unknown response %02x",$code);
    		}
    		return($rc,$text);
    	}

	    $res_id_ls = $returnd[37-$authoffset];
    	$res_id_ms = $returnd[38-$authoffset];
    } elsif ($mfg_id == 2) {
        #For requests other than clear, we check for IBM extended auxillary log data
        my @auxdata;
        my $netfn = 0xa << 2;
        my @auxlogcmd = (0x5a,1);
        $error = docmd(
            $netfn,
            \@auxlogcmd,
            \@auxdata);
        @auxdata=splice @auxdata,36-$authoffset;
        print Dumper(\@auxdata);
        unless ($error or $auxdata[0] or $auxdata[5] != 0x4d or $auxdata[6] != 0x4f or $auxdata[7] !=0x0 ) { #Don't bother if support cannot be confirmed by service processor
            $netfn=0x2e<<2; #switch netfunctions to read
            my $numauxlogs = $auxdata[8]+($auxdata[9]<<8);
            my $auxidx=1;
            my $rc;
            my $entry;
            my $extdata;
            while ($auxidx<=$numauxlogs) {
                ($rc,$entry,$extdata) = readauxentry($auxidx++);
                unless ($rc) {
                    if ($auxloginfo{$entry}) {
                        $auxloginfo{$entry}.="!".$extdata;
                    } else {
                        $auxloginfo{$entry}=$extdata;
                    }
                }
            }
            if ($auxloginfo{0}) {
                if ($skiptail) {
                    foreach (split /!/,$auxloginfo{0}) {
                        sendoutput(0,":Unassociated auxillary data detected:");
                        foreach (split /\n/,$_) {
                            sendoutput(0,$_);
                        }
                    }
                }
            }
            print Dumper(\%auxloginfo);
        }
    }


	if($subcommand eq "clear") {
		@cmd=(0x47,$res_id_ls,$res_id_ms,0x43,0x4c,0x52,0xaa);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my $erase_status = $returnd[37-$authoffset] & 0b00000001;

#skip test for now, need to get new res id for some machines
		while($erase_status == 0 && 0) {
			sleep(1);
			@cmd=(0x47,$res_id_ls,$res_id_ms,0x43,0x4c,0x52,0x00);
			$error = docmd(
				$netfun,
				\@cmd,
				\@returnd
			);

			if($error) {
				$rc = 1;
				$text = $error;
				return($rc,$text);
			}

			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}

			if($rc != 0) {
				if(!$text) {
					$text = sprintf("unknown response %02x",$code);
				}
				return($rc,$text);
			}

			$erase_status = $returnd[37-$authoffset] & 0b00000001;
		}

		$text = "SEL cleared";
		return($rc,$text);
	}

	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}

	@cmd=(0x43,$res_id_ls,$res_id_ms,0x00,0x00,0x00,0xFF);
	while(1) {
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
            if ($skiptail) {
                sendoutput($rc,$text);
                return;
            }
            push(@output,$text);
			return($rc,@output);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		elsif($code == 0x81) {
			$rc = 1;
			$text = "cannot execute command, SEL erase in progress";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
            if ($skiptail) {
                sendoutput($rc,$text);
                return;
            }
            push(@output,$text);
			return($rc,@output);
		}

		my $next_rec_ls = $returnd[37-$authoffset];
		my $next_rec_ms = $returnd[38-$authoffset];
		my @sel_data = @returnd[39-$authoffset..39-$authoffset+16];
		@cmd=(0x43,$res_id_ls,$res_id_ms,$next_rec_ls,$next_rec_ms,0x00,0xFF);

		$entry++;
        if ($debug) {
			print "$entry: ";
			hexdump(\@sel_data);
        }

		my $record_id = $sel_data[0] + $sel_data[1]*256;
		my $record_type = $sel_data[2];

		if($record_type == 0x02) {
		}
		else {
			$text=getoemevent($record_type,$mfg_id,\@sel_data);
            if ($auxloginfo{$entry}) { 
                $text.=" With additional data:\n".$auxloginfo{$entry};
            }
            if ($skiptail) {
                sendoutput($rc,$text);
            } else {
			    push(@output,$text);
            }
			if($next_rec_ms == 0xFF && $next_rec_ls == 0xFF) {
				last;
			}
			next;
		}

		my $timestamp = ($sel_data[3] | $sel_data[4]<<8 | $sel_data[5]<<16 | $sel_data[6]<<24);
      unless ($timestamp < 0x20000000) { #IPMI Spec says below this is effectively BMC uptime, not correctable
         $timestamp -= $tfactor; #apply correction factor based on how off the current BMC clock is from management server
      }
		my ($seldate,$seltime) = timestamp2datetime($timestamp);
#		$text = "$entry: $seldate $seltime";
		$text = ":$seldate $seltime";

#		my $gen_id_slave_addr = ($sel_data[7] & 0b11111110) >> 1;
#		my $gen_id_slave_addr_hs = ($sel_data[7] & 0b00000001);
#		my $gen_id_ch_num = ($sel_data[8] & 0b11110000) >> 4;
#		my $gen_id_ipmb = ($sel_data[8] & 0b00000011);

		my $sensor_owner_id = $sel_data[7];
		my $sensor_owner_lun = $sel_data[8];

		my $sensor_type = $sel_data[10];
		my $sensor_num = $sel_data[11];
		my $event_dir = $sel_data[12] & 0b10000000;
		my $event_type = $sel_data[12] & 0b01111111;
		my $offset = $sel_data[13] & 0b00001111;
		my $event_data_1 = $sel_data[13];
		my $event_data_2 = $sel_data[14];
		my $event_data_3 = $sel_data[15];
		my $sev = 0;
		$sev = ($sel_data[14] & 0b11110000) >> 4;
#		if($event_type != 1) {
#			$sev = ($sel_data[14] & 0b11110000) >> 4;
#		}
#		$text = "$text $sev:";

		my $type;
		my $desc;
		($rc,$type,$desc) = getsensorevent($sensor_type,$offset,"ipmisensorevents");
		if($rc == 1) {
			$type = "Unknown Type $sensor_type";
			$desc = "Unknown Event $offset";
			$rc = 0;
		}

		if($event_type <= 0x0c) {
			my $gtype;
			my $gdesc;
			($rc,$gtype,$gdesc) = getsensorevent($event_type,$offset,"ipmigenericevents");
			if($rc == 1) {
				$gtype = "Unknown Type $gtype";
				$gdesc = "Unknown Event $offset";
				$rc = 0;
			}

			$desc = $gdesc;
		}

		if($type eq "" || $type eq "-") {
			$type = "OEM Sensor Type $sensor_type"
		}
		if($desc eq "" || $desc eq "-") {
			$desc = "OEM Sensor Event $offset"
		}

		if($type eq $desc) {
			$desc = "";
		}

		my $extra_info = getaddsensorevent($sensor_type,$offset,$event_data_1,$event_data_2,$event_data_3);
		if($extra_info) {
			if($desc) {
				$desc = "$desc $extra_info";
			}
			else {
				$desc = "$extra_info";
			}
		}

		$text = "$text $type,";
		$text = "$text $desc";

#		my $key;
		my $key = $sensor_owner_id . "." . $sensor_owner_lun . "." . $sensor_num;
		my $sensor_desc = sprintf("Sensor 0x%02x",$sensor_num);
#		foreach $key (keys %sdr_hash) {
#			my $sdr = $sdr_hash{$key};
#			if($sdr->sensor_number == $sensor_num) {
#				$sensor_desc = $sdr_hash{$key}->id_string;
#				last;
#			}
#		}
		if(defined $sdr_hash{$key}) {
			$sensor_desc = $sdr_hash{$key}->id_string;
         if ($sdr_hash{$key}->event_type_code == 1) {
            if (($event_data_1 & 0b11000000) == 0b01000000) {
               $sensor_desc .= " reading ".translate_sensor($event_data_2,$sdr_hash{$key});
               if (($event_data_1 & 0b00110000) == 0b00010000) {
                  $sensor_desc .= " with threshold " . translate_sensor($event_data_3,$sdr_hash{$key});
               }
            }
         }
		}

		$text = "$text ($sensor_desc)";

		if($event_dir) {
			$text = "$text - Recovered";
		}

        if ($auxloginfo{$entry}) {
             $text.=" with additional data:";
             if ($skiptail) {
                sendoutput($rc,$text);
                foreach (split /\n/,$auxloginfo{$entry}) {
                    sendoutput(0,$_);
                }
             } else {
        		push(@output,$text);
                push @output,split /\n/,$auxloginfo{$entry};
             } 

        } else {
            if ($skiptail) {
                sendoutput($rc,$text);
            } else {
        		push(@output,$text);
            }
        }

		if($next_rec_ms == 0xFF && $next_rec_ls == 0xFF) {
			last;
		}
	}

	my @routput = reverse(@output);
	my @noutput;
	my $c;
	foreach(@routput) {
		$c++;
		if($c > $num) {
			last;
		}
		push(@noutput,$_);
	}
	@output = reverse(@noutput);

	return($rc,@output);
}
sub getoemevent {
	my $record_type = shift;
	my $mfg_id = shift;
	my $sel_data = shift;
	my $text=":";
	if ($record_type < 0xE0 && $record_type > 0x2F) { #Should be timestampped, whatever it is
		my $timestamp =  (@$sel_data[3] | @$sel_data[4]<<8 | @$sel_data[5]<<16 | @$sel_data[6]<<24);
      unless ($timestamp < 0x20000000) {
         $timestamp -= $tfactor;
      }
		my ($seldate,$seltime) = timestamp2datetime($timestamp);
		my @rest = @$sel_data[7..15];
		if ($mfg_id==2) {
			$text.="$seldate $seltime IBM OEM Event-";
			if ($rest[3]==0 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."PCI Event/Error, details in next event"
			} elsif ($rest[3]==1 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Processor Event/Error occurred, details in next event"
			} elsif ($rest[3]==2 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Memory Event/Error occurred, details in next event"
			} elsif ($rest[3]==3 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Scalability Event/Error occurred, details in next event"
			} elsif ($rest[3]==4 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."PCI bus Event/Error occurred, details in next event"
			} elsif ($rest[3]==5 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Chipset Event/Error occurred, details in next event"
			} elsif ($rest[3]==6 && $rest[4]==1 && $rest[7]==0) {
				$text=$text."BIOS/BMC Power Executive mismatch (BIOS $rest[5], BMC $rest[6])"
			} elsif ($rest[3]==6 && $rest[4]==2 && $rest[7]==0) {
				$text=$text."Boot denied due to power limitations"
			} else {
				$text=$text."Unknown event ". phex(\@rest);
			}
		} else {
		     $text .= "$seldate $seltime " . sprintf("Unknown OEM SEL Type %02x:",$record_type) . phex(\@rest);
		}
	} else { #Non-timestamped
		my %memerrors = (
			0x00 => "DIMM enabled",
			0x01 => "DIMM disabled, failed ECC test",
			0x02 => "POST/BIOS memory test failed, DIMM disabled",
			0x03 => "DIMM disabled, non-supported memory device",
			0x04 => "DIMM disabled, non-matching or missing DIMM(s)",
		);
		my %pcierrors = (
			0x00 => "Device OK",
			0x01 => "Required ROM space not available",
			0x02 => "Required I/O Space not available",
			0x03 => "Required memory not available",
			0x04 => "Required memory below 1MB not available",
			0x05 => "ROM checksum failed",
			0x06 => "BIST failed",
			0x07 => "Planar device missing or disabled by user",
			0x08 => "PCI device has an invalid PCI configuration space header",
			0x09 => "FRU information for added PCI device",
			0x0a => "FRU information for removed PCI device",
			0x0b => "A PCI device was added, PCI FRU information is stored in next log entry",
			0x0c => "A PCI device was removed, PCI FRU information is stored in next log entry",
			0x0d => "Requested resources not available",
			0x0e => "Required I/O Space Not Available",
			0x0f => "Required I/O Space Not Available",
			0x10 => "Required I/O Space Not Available",
			0x11 => "Required I/O Space Not Available",
			0x12 => "Required I/O Space Not Available",
			0x13 => "Planar video disabled due to add in video card",
			0x14 => "FRU information for PCI device partially disabled ",
			0x15 => "A PCI device was partially disabled, PCI FRU information is stored in next log entry",
			0x16 => "A 33Mhz device is installed on a 66Mhz bus, PCI device information is stored in next log entry",
			0x17 => "FRU information, 33Mhz device installed on 66Mhz bus",
			0x18 => "Merge cable missing",
			0x19 => "Node 1 to Node 2 cable missing",
			0x1a => "Node 1 to Node 3 cable missing",
			0x1b => "Node 2 to Node 3 cable missing",
			0x1c => "Nodes could not merge",
			0x1d => "No 8 way SMP cable",
			0x1e => "Primary North Bridge to PCI Host Bridge IB Link has failed",
			0x1f => "Redundant PCI Host Bridge IB Link has failed",
		);
		my %procerrors = (
			0x00 => "Processor has failed BIST",
			0x01 => "Unable to apply processor microcode update",
			0x02 => "POST does not support current stepping level of processor",
			0x03 => "CPU mismatch detected",
		);
		my @rest = @$sel_data[3..15];
		if ($record_type == 0xE0 && $rest[0]==2 && $mfg_id==2 && $rest[1]==0 && $rest[12]==1) { #Rev 1 POST memory event
			$text="IBM Memory POST Event-";
			my $msuffix=sprintf(", chassis %d, card %d, dimm %d",$rest[3],$rest[4],$rest[5]);
			#the next bit is a basic lookup table, should implement as a table ala ibmleds.tab, or a hash... yeah, a hash...
			$text=$text.$memerrors{$rest[2]}.$msuffix;
		} elsif ($record_type == 0xE0 && $rest[0]==1 && $mfg_id==2 && $rest[12]==0) { #A processor error or event, rev 0 only known in the spec I looked at
			$text=$text.$procerrors{$rest[1]};
		} elsif ($record_type == 0xE0 && $rest[0]==0 && $mfg_id==2) { #A PCI error or event, rev 1 or 2, the revs differe in endianness
			my $msuffix;
			if ($rest[12]==0) {
				$msuffix=sprintf("chassis %d, slot %d, bus %s, device %02x%02x:%02x%02x",$rest[2],$rest[3],$rest[4],$rest[5],$rest[6],$rest[7],$rest[8]);
			} elsif ($rest[12]==1) {
				$msuffix=sprintf("chassis %d, slot %d, bus %s, device %02x%02x:%02x%02x",$rest[2],$rest[3],$rest[4],$rest[5],$rest[6],$rest[7],$rest[8]);
			} else {
				return ("Unknown IBM PCI event/error format");
			}
			$text=$text.$pcierrors{$rest[1]}.$msuffix;
		} else {
			#Some event we can't define that is OEM or some otherwise unknown event
			$text = sprintf("SEL Type %02x:",$record_type) . phex(\@rest);
		}
	} #End timestampped intepretation
	return ($text);
}

sub getsensorevent
{
	my $sensortype = sprintf("%02Xh",shift);
	my $sensoroffset = sprintf("%02Xh",shift);
	my $file = shift;

	my @line;
	my $type;
	my $code;
	my $desc;
	my $offset;
	my $rc = 1;

    if ($file eq "ipmigenericevents") {
      if ($xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,$sensoroffset"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,$sensoroffset"},2);
	    return(0,$type,$desc);
      }
      if ($xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,-"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,-"},2);
	    return(0,$type,$desc);
       }
    }
    if ($file eq "ipmisensorevents") {
      if ($xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,$sensoroffset"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,$sensoroffset"},2);
	    return(0,$type,$desc);
      }
      if ($xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,-"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,-"},2);
	    return(0,$type,$desc);
       }
    }
    return (0,"No Mappings found ($sensortype)","No Mappings found ($sensoroffset)");
}

sub getaddsensorevent {
	my $sensor_type = shift;
	my $offset = shift;
	my $event_data_1 = shift;
	my $event_data_2 = shift;
	my $event_data_3 = shift;
	my $text = "";

    if ($sensor_type == 0x08 && $offset == 6) {
        my %extra = (
            0x0 => "Vendor mismatch",
            0x1 => "Revision mismatch",
            0x2 => "Processor missing",
            );
        if ($extra{$event_data_3}) {
            $text = $extra{$event_data_3};
        }
    }
    if ($sensor_type == 0x0C) {
        $text = sprintf ("Memory module %d",$event_data_3);
    }

	if($sensor_type == 0x0f) {
		if($offset == 0x00) {
			my %extra = (
				0x00 => "Unspecified",
				0x01 => "No system memory installed",
				0x02 => "No usable system memory",
				0x03 => "Unrecoverable hard disk failure",
				0x04 => "Unrecoverable system board failure",
				0x05 => "Unrecoverable diskette failure",
				0x06 => "Unrecoverable hard disk controller failure",
				0x07 => "Unrecoverable keyboard failure",
				0x08 => "Removable boot media not found",
				0x09 => "Unrecoverable video controller failure",
				0x0a => "No video device detected",
				0x0b => "Firmware (BIOS) ROM corruption detected",
				0x0c => "CPU voltage mismatch",
				0x0d => "CPU speed matching failure",
			);
			$text = $extra{$event_data_2};
		}
		if($offset == 0x02) {
			my %extra = (
				0x00 => "Unspecified",
				0x01 => "Memory initialization",
				0x02 => "Hard-disk initialization",
				0x03 => "Secondary processor(s) initialization",
				0x04 => "User authentication",
				0x05 => "User-initiated system setup",
				0x06 => "USB resource configuration",
				0x07 => "PCI resource configuration",
				0x08 => "Option ROM initialization",
				0x09 => "Video initialization",
				0x0a => "Cache initialization",
				0x0b => "SM Bus initialization",
				0x0c => "Keyboard controller initialization",
				0x0d => "Embedded controller/management controller initialization",
				0x0e => "Docking station attachement",
				0x0f => "Enabling docking station",
				0x10 => "Docking staion ejection",
				0x11 => "Disable docking station",
				0x12 => "Calling operation system wake-up vector",
				0x13 => "Starting operation system boot process, call init 19h",
				0x14 => "Baseboard or motherboard initialization",
				0x16 => "Floppy initialization",
				0x17 => "Keyboard test",
				0x18 => "Pointing device test",
				0x19 => "Primary processor initialization",
			);
			$text = $extra{$event_data_2};
		}
	}
    if ($sensor_type == 0x10) {
        if ($offset == 0x0) {
            $text = sprintf("Memory module %d",$event_data_2);
        } elsif ($offset == 0x01) {
            $text = "Disabled for ";
            unless ($event_data_3 & 0x20) {
                if ($event_data_3 & 0x10) {
                    $text .= "assertions of";
                } else {
                    $text .= "deassertions of";
                } 
            }
            $text .= sprintf ("type %02xh/offset %02xh",$event_data_2,$event_data_3&0x0F);
        } elsif ($offset == 0x05) {
            $text = "$event_data_3% full";
        }
    }
            
	if($sensor_type == 0x12) {
		if($offset == 0x03) {
		}
		if($offset == 0x04) {
			if($event_data_2 & 0b00100000) {
				$text = "$text, NMI";
			}
			if($event_data_2 & 0b00010000) {
				$text = "$text, OEM action";
			}
			if($event_data_2 & 0b00001000) {
				$text = "$text, power cycle";
			}
			if($event_data_2 & 0b00000100) {
				$text = "$text, reset";
			}
			if($event_data_2 & 0b00000010) {
				$text = "$text, power off";
			}
			if($event_data_2 & 0b00000001) {
				$text = "$text, Alert";
			}
			$text =~ s/^, //;
		}
	}
    if ($sensor_type == 0x1d && $offset == 0x07) {
        my %causes = (
            0 => "Unknown",
            1 => "Chassis reset via User command to BMC",
            2 => "Reset button",
            3 => "Power button",
            4 => "Watchdog action",
            5 => "OEM",
            6 => "AC Power apply force on",
            7 => "Restore previous power state on AC",
            8 => "PEF initiated reset",
            9 => "PEF initiated power cycle",
            10 => "Soft reboot",
            11 => "RTC Wake",
        );
        if ($causes{$event_data_2 & 0xf}) {
            $text = $causes{$event_data_2};
        } else {
            $text = "Unrecognized cause ".$event_data_2 & 0xf;
        }
        $text .= "via channel $event_data_3";
    }
    if ($sensor_type == 0x21) {
        my %extra = (
            0 => "PCI slot",
            1 => "Drive array",
            2 => "External connector",
            3 => "Docking port",
            4 => "Other slot",
            5 => "Sensor ID",
            6 => "AdvncedTCA",
            7 => "Memory slot",
            8 => "FAN",
            9 => "PCIe",
            10 => "SCSI",
            11 => "SATA/SAS",
         );

        $text=$extra{$event_data_2 & 127};
        unless ($text) {
            $text = "Unknown slot/conn type ".$event_data_2&127;
        }
        $text .= " $event_data_3";
    }
    if ($sensor_type == 0x23) {
        my %extra = (
            0x10 => "SMI",
            0x20 => "NMI",
            0x30 => "Messaging Interrupt",
            0xF0 => "Unspecified",
            0x01 => "BIOS FRB2",
            0x02 => "BIOS/POST",
            0x03 => "OS Load",
            0x04 => "SMS/OS",
            0x05 => "OEM",
            0x0F => "Unspecified"
        );
        if ($extra{$event_data_2 & 0xF0}) {
            $text = $extra{$event_data_2 & 0xF0};
        }
        if ($extra{$event_data_2 & 0x0F}) {
            $text .= ", ".$extra{$event_data_2 & 0x0F};
        }
        $text =~ s/^, //;
    }
    if ($sensor_type == 0x28) {
        if ($offset == 0x4) {
            $text = "Sensor $event_data_2";
        } elsif ($offset == 0x5) {
            $text = "";
            my $logicalfru=0;
            if ($event_data_2 & 128) {
                $logicalfru=1;
            }
            my $intelligent=1;
            if ($event_data_2 & 24) {
                $text .= "LUN ".($event_data_2&24)>>3;
            } else {
                $intelligent=0;
            }
            if ($event_data_2 & 7) {
                $text .= "Bus ID ".($event_data_2&7);
            }
            if ($logicalfru) {
                $text .= "FRU ID ".$event_data_3;
            } elsif (not $intelligent) {
                $text .= "I2C addr ".$event_data_3>>1;
            }
        }
    }

    if ($sensor_type == 0x2a) {
        $text = sprintf("Channel %d, User %d",$event_data_3&0x0f,$event_data_2&0x3f);
        if ($offset == 1) {
            if (($event_data_3 & 207) == 1) {
                $text .= " at user request";
            } elsif (($event_data_3 & 207) == 2) {
                $text .= " timed out";
            } elsif (($event_data_3 & 207) == 3) {
                $text .= " configuration change";
            }
        }
    }
    if ($sensor_type == 0x2b) {
        my %extra = (
            0x0 => "Unspecified",
            0x1 => "BMC device ID",
            0x2 => "BMC Firmware",
            0x3 => "BMC Hardware",
            0x4 => "BMC manufacturer",
            0x5 => "IPMI Version",
            0x6 => "BMC aux firmware ID",
            0x7 => "BMC boot block",
            0x8 => "Other BMC Firmware",
            0x09 => "BIOS/EFI change",
            0x0a => "SMBIOS change",
            0x0b => "OS change",
            0x0c => "OS Loader change",
            0x0d => "Diagnostics change",
            0x0e => "Management agent change",
            0x0f => "Management software change",
            0x10 => "Management middleware change",
            0x11 => "FPGA/CPLD/PSoC change",
            0x12 => "FRU change",
            0x13 => "device addition/removal",
            0x14 => "Equivalent replacement",
            0x15 => "Newer replacement",
            0x16 => "Older replacement",
            0x17 => "DIP/Jumper change",
        );
        if ($extra{$event_data_2}) {
            $text = $extra{$event_data_2};
        } else {
            $text = "Unknown version change type $event_data_2";
        }
    }
    if ($sensor_type == 0x2c) {
        my %extra = (
            0 => "",
            1 => "Software dictated",
            2 => "Latch operated",
            3 => "Hotswap buton pressed",
            4 => "automatic operation",
            5 => "Communication lost",
            6 => "Communication lost locally",
            7 => "Unexpected removal",
            8 => "Operator intervention",
            9 => "Unknwon IPMB address",
            10 => "Unexpected deactivation",
            0xf => "unknown",
            );
        if ($extra{$event_data_2>>4}) {
              $text = $extra{$event_data_2>>4};
          } else {
              $text = "Unrecognized cause ".$event_data_2>>4;
          }
          my $prev_state=$event_data_2 & 0xf;
          unless ($prev_state == $offset) {
              my %oldstates = ( 
                0 => "Not Installed",
                1 => "Inactive",
                2 => "Activation requested",
                3 => "Activating",
                4 => "Active",
                5 => "Deactivation requested",
                6 => "Deactivating",
                7 => "Communication lost",
            );
            if ($oldstates{$prev_state}) {
                $text .= "(was ".$oldstates{$prev_state}.")";
            } else {
                $text .= "(was in unrecognized state $prev_state)";
            }
          }
    }



	return($text);
}

sub checkleds {
	my $netfun = 0xe8; #really 0x3a
	my @cmd;
	my @returnd = ();
	my $error;
	my $led_id_ms;
	my $led_id_ls;
	my $rc = 0;
	my @output =();
	my $text="";
	my $key;
	my $mfg_id;
	my $prod_id;
	($rc,$text,$mfg_id,$prod_id) = getdevid();
	if ($mfg_id != 2) {
		return (0,"LED status not supported on this system");
	}
	
	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}
	foreach $key (sort {$sdr_hash{$a}->id_string cmp $sdr_hash{$b}->id_string} keys %sdr_hash) {
		my $sdr = $sdr_hash{$key};
		if($sdr->rec_type == 0xC0 && $sdr->sensor_type == 0xED) {
			#this stuff is to help me build the file from spec paste
			#my $tehstr=sprintf("grep 0x%04X /opt/xcat/lib/x3755led.tab",$sdr->led_id);
			#my $tehstr=`$tehstr`;
			#$tehstr =~ s/^0x....//;
			
			#printf("%X.%X.0x%04x",$mfg_id,$prod_id,$sdr->led_id);
			#print $tehstr;
		
			#We are inconsistant in our spec, first try a best guess
			#at endianness, assume the smaller value is MSB
			if (($sdr->led_id&0xff) > ($sdr->led_id>>8)) {
				$led_id_ls=$sdr->led_id&0xff;
				$led_id_ms=$sdr->led_id>>8;
			} else {	
				$led_id_ls=$sdr->led_id>>8;
				$led_id_ms=$sdr->led_id&0xff;
			}
				
			@cmd=(0xc0,$led_id_ms,$led_id_ls);
			$error = docmd(
				$netfun,
				\@cmd,
				\@returnd
			);
			if($error) {
				$rc = 1;
				$text = $error;
				return($rc,$text);
			}
			if ($returnd[36-$authoffset] == 0xc9) {
				my $tmp;
				#we probably guessed endianness wrong.
				$tmp=$led_id_ls;
				$led_id_ls=$led_id_ms;
				$led_id_ms=$tmp;
				@cmd=(0xc0,$led_id_ms,$led_id_ls);
				$error = docmd(
                                	$netfun,
					\@cmd,
					\@returnd
                       		);
				if($error) {
					$rc = 1;
					$text = $error;
					return($rc,$text);
				}
			}

			if ($returnd[38-$authoffset]) { # != 0) {
				#It's on...
				if ($returnd[42-$authoffset] == 4) {
					push(@output,sprintf("BIOS or admininstrator has %s lit",getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds")));
				}
				elsif ($returnd[42-$authoffset] == 3) {
					push(@output,sprintf("A user has manually requested LED 0x%04x (%s) be active",$sdr->led_id,getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds")));
				}
				elsif ($returnd[42-$authoffset] == 1 && $sdr->led_id !=0) {
					push(@output,sprintf("LED 0x%02x%02x (%s) active to indicate LED 0x%02x%02x (%s) is active",$led_id_ms,$led_id_ls,getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds"),$returnd[40-$authoffset],$returnd[41-$authoffset],getsensorname($mfg_id,$prod_id,($returnd[40-$authoffset]<<8)+$returnd[41-$authoffset],"ibmleds")));
				}
				elsif ($sdr->led_id ==0) {
					push(@output,sprintf("LED 0x0000 (%s) active to indicate system error condition.",getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds")));
				}
				elsif ($returnd[42-$authoffset] == 2) {
					my $sensor_desc;
					#Ok, LED is tied to a sensor..
					my $sensor_num=$returnd[41-$authoffset];
				        foreach $key (keys %sdr_hash) {
						my $osdr = $sdr_hash{$key};
				                if($osdr->sensor_number == $sensor_num) {
				                        $sensor_desc = $sdr_hash{$key}->id_string;
				                        if($osdr->rec_type == 0x01) {
			                                	last;
							}
			                        }
			                }
					$rc=0;
					#push(@output,sprintf("Sensor 0x%02x (%s) has activated LED 0x%04x",$sensor_num,$sensor_desc,$sdr->led_id));
					push(@output,sprintf("LED 0x%02x%02x active to indicate Sensor 0x%02x (%s) error.",$led_id_ms,$led_id_ls,$sensor_num,$sensor_desc));
			        }
			} 
					
		}
	}
	if ($#output==-1) {
		push(@output,"No active error LEDs detected");
	}
	return($rc,@output);
}
	
sub vitals {
	my $subcommand = shift;

	my $rc = 0;
	my $text;
	my $key;
	my @sensor_filters=(0x00);
	my @output;
	my $reading;
	my $unitdesc;
	my $value;
	my $format = "%-30s%8s %-20s";
	my $per = " ";
   my $doall;
   $doall=0;
	$rc=0;

	if($subcommand eq "all") {
		@sensor_filters=(0x01); #,0x02,0x03,0x04);
      $doall=1;
	}
	elsif($subcommand =~ /temp/) {
		@sensor_filters=(0x01);
	}
	elsif($subcommand eq "voltage") {
		@sensor_filters=(0x02);
	}
    elsif($subcommand =~ /watt/) {
        @sensor_filters=(0x03);
    }
	elsif($subcommand eq "fanspeed") {
		@sensor_filters=(0x04);
	}
	elsif($subcommand eq "power") {
		($rc,$text) = power("stat");
		$text = sprintf($format,"Power Status:",$text);
		return($rc,$text);
	}
	elsif($subcommand eq "leds") {
		my @cleds;
		($rc,@cleds) = checkleds();
		foreach $text (@cleds) {
			push(@output,$text);
		}
	}
	else {
		return(1,"unsupported command vitals $subcommand");
	}

	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}

	foreach(@sensor_filters) {
		my $filter = $_;

		foreach $key (sort {$sdr_hash{$a}->id_string cmp $sdr_hash{$b}->id_string} keys %sdr_hash) {
			my $sdr = $sdr_hash{$key};
			if(($doall and not $sdr->rec_type == 0x11 and not $sdr->sensor_type==0xed) or ($sdr->rec_type == 0x01 and $sdr->sensor_type == $filter)) {
				my $lformat = $format;

				($rc,$reading) = readsensor($sdr->sensor_number);
				$unitdesc = "";
				if($rc == 0) {
					$unitdesc = $units{$sdr->sensor_units_2};

                    $value = $reading;
                    if ($sdr->rec_type==1) {
    					$value = (($sdr->M * $reading) + ($sdr->B * (10**$sdr->B_exp))) * (10**$sdr->R_exp);
                    }
					if($sdr->rec_type != 1 or $sdr->linearization == 0) {
						$reading = $value;
						if($value == int($value)) {
							$lformat = "%-30s%8d%-20s";
						}
						else {
							$lformat = "%-30s%8.3f%-20s";
						}
					}
					elsif($sdr->linearization == 7) {
						if($value > 0) {
							$reading = 1/$value;
						}
						else {
							$reading = 0;
						}
						$lformat = "%-30s%8d %-20s";
					}
					else {
						$reading = "RAW(".$sdr->linearization.") $reading";
					}
	
					if($sdr->sensor_units_1 & 1) {
						$per = "% ";
					} else {
                  $per = " ";
               }
               my $numformat = ($sdr->sensor_units_1 & 0b11000000) >> 6;
               if ($numformat) {
                  if ($numformat eq 0b11)  {
                     #Not sure what to do here..
                  } else {
                     if ($reading & 0b10000000) {
                        if ($numformat eq 0b01) {
                           $reading = 0-((~($reading&0b01111111))&0b1111111);
                        } elsif ($numformat eq 0b10) {
                           $reading = 0-(((~($reading&0b01111111))&0b1111111)+1);
                        }
                     }
                  }
               }
	
                    if($unitdesc eq "Watts") {
                        my $f = ($reading * 3.413);
                        $unitdesc = "Watts (".int($f+.5)." BTUs/hr)";
                    }
					if($unitdesc eq "C") {
						my $f = ($reading * 9/5) + 32;
						$unitdesc = "C (" . int($f + .5) . " F)";
					}
					if($unitdesc eq "F") {
						my $c = ($reading - 32) * 5/9;
						$unitdesc = "F (" . int($c + .5) . " C)";
					}
				}
            #$unitdesc.= sprintf(" %x",$sdr->sensor_type);
				$text = sprintf($lformat,$sdr->id_string . ":",$reading,$per.$unitdesc);
				push(@output,$text);
			}
#			else {
#				printf("%x %s %d\n",$sdr->sensor_number,$sdr->id_string,$sdr->sensor_type);
#			}
		}
	}

	if($subcommand eq "all") {
		my @cleds;
		($rc,$text) = power("stat");
		$text = sprintf($format,"Power Status:",$text,"");
		push(@output,$text);
		($rc,@cleds) = checkleds();
		foreach $text (@cleds) {
			push(@output,$text);
		}
	}

	return($rc,@output);
}

sub readsensor {
	my $sensor = shift;
	my $netfun = 0x10;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x2d,$sensor);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];
	if($code != 0x00) {
		$rc = 1;
		$text = $codes{$code};

		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		chomp $text;

		return($rc,$text);
	}
	
	if ($returnd[38-$authoffset] & 0x20) {
		$rc = 1;
		$text = "N/A";
		return($rc,$text);
	}
	$text = $returnd[37-$authoffset];

	return($rc,$text);
}

sub initsdr {
	my $netfun;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	my $sdr_rep_info = SDR_rep_info->new();

	my $resv_id_ls;
	my $resv_id_ms;
	my $nrid_ls = 0;
	my $nrid_ms = 0;
	my $rid_ls = 0;
	my $rid_ms = 0;
	my $sdr_ver;
	my $sdr_type;
	my $sdr_offset;
	my $sdr_len;
	my @sdr_data = ();
	my $offset;
	my $len;
	my $i;
#	my $numbytes = 27;
	my $numbytes = 22;
	my $override_string;
	my $ipmisensortab = "$ENV{XCATROOT}/lib/GUMI/ipmisensor.tab";
	my $byte_format;
	my $cache_file;

	my $mfg_id;
	my $prod_id;
	my $device_id;
	my $dev_rev;
	my $fw_rev1;
	my $fw_rev2;

	($rc,$text,$mfg_id,$prod_id,$device_id,$dev_rev,$fw_rev1,$fw_rev2) = getdevid();
	if($rc != 0) {
		return($rc,$text);
	}

	$cache_file = "$cache_dir/sdr_$mfg_id.$prod_id.$device_id.$dev_rev.$fw_rev1.$fw_rev2.$cache_version";
	if($enable_cache eq "yes") {
		$rc = loadsdrcache($cache_file);
		if($rc == 0) {
			return($rc);
		}
		$rc = 0;
	}

	($rc,$text) = get_sdr_rep_info($sdr_rep_info);
	if($rc != 0) {
		return($rc,$text);
	}

	if($sdr_rep_info->version != 0x51) {
		$rc = 1;
		$text = "SDR version 51h support only.";
		return($rc,$text);
	}

	if($sdr_rep_info->resv_sdr != 1) {
		$rc = 1;
		$text = "SDR reservation unsupported.";
		return($rc,$text);
	}

	($rc,$text,$resv_id_ls,$resv_id_ms) = resv_sdr_repo();
	if($rc != 0) {
		return($rc,$text);
	}

	if($debug) {
		print "mfg,prod,dev: $mfg_id, $prod_id, $device_id\n";
		printf("SDR info: %02x %d %d\n",$sdr_rep_info->version,$sdr_rep_info->rec_count,$sdr_rep_info->resv_sdr);
		print "resv_id: $resv_id_ls $resv_id_ms\n";
	}

	foreach(1..$sdr_rep_info->rec_count) {
		$netfun = 0x28;
		@cmd = (0x23,$resv_id_ls,$resv_id_ms,$nrid_ls,$nrid_ms,0,5);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];
		if($code != 0x00) {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
###x336 hack
		$rid_ls = $nrid_ls;
		$rid_ms = $nrid_ms;
###
		$nrid_ls = $returnd[37-$authoffset];
		$nrid_ms = $returnd[38-$authoffset];
### correct IPMI code
#		$rid_ls = $returnd[39-$authoffset];
#		$rid_ms = $returnd[40-$authoffset];
###
		$sdr_ver = $returnd[41-$authoffset];
		$sdr_type = $returnd[42-$authoffset];
		$sdr_len = $returnd[43-$authoffset] + 5;

		if($sdr_type == 0x01) {
			$sdr_offset = 0;
		}
		elsif($sdr_type == 0x02) {
			$sdr_offset = 16;
		}
		elsif($sdr_type == 0xC0) {
			#LED descriptor, maybe
		}
		elsif($sdr_type == 0x11) { #FRU locator
		}
		elsif($sdr_type == 0x12) {
			next;
		}
		else {
			next;
		}

		@sdr_data = (0,0,0,$sdr_ver,$sdr_type,$sdr_len);
		$offset = 5;
		for($i=5;$i<$sdr_len;$i+=$numbytes) {
			$len = $numbytes;
			if($offset+$len > $sdr_len) {
				$len = $sdr_len - $offset;
			}

			@cmd = (0x23,$resv_id_ls,$resv_id_ms,$rid_ls,$rid_ms,$offset,$len);
			$error = docmd(
				$netfun,
				\@cmd,
				\@returnd
			);

			if($error) {
				$rc = 1;
				$text = $error;
				return($rc,$text);
			}

			$code = $returnd[36-$authoffset];
			if($code != 0x00) {
				$rc = 1;
				$text = $codes{$code};
				if(!$text) {
					$rc = 1;
					$text = sprintf("unknown response %02x",$code);
				}
				return($rc,$text);
			}

			@sdr_data = (@sdr_data,@returnd[39-$authoffset..@returnd-2]);

			$offset += $len;
		}
		if($sdr_type == 0x11) { #FRU locator
            my $sdr = decode_fru_locator(@sdr_data);
            if ($sdr) {
		        $sdr_hash{$sdr->sensor_owner_id . "." . $sdr->sensor_owner_lun . "." . $sdr->sensor_number} = $sdr;
            }
            next;
        }

		if($debug) {
			hexadump(\@sdr_data);
		}
		if($sdr_type == 0x12) {
			hexadump(\@sdr_data);
			next;
		}

		my $sdr = SDR->new();

		if ($mfg_id == 2 && $sdr_type==0xC0 && $sdr_data[9] == 0xED) {
			#printf("%02x%02x\n",$sdr_data[13],$sdr_data[12]);
			$sdr->rec_type($sdr_type);
			$sdr->sensor_type($sdr_data[9]);
			#Using an impossible sensor number to not conflict with decodealert
			$sdr->sensor_owner_id(260);
			$sdr->sensor_owner_lun(260);
            $sdr->id_string("LED");
			if ($sdr_data[12] > $sdr_data[13]) {
				$sdr->led_id(($sdr_data[13]<<8)+$sdr_data[12]);
			} else {
				$sdr->led_id(($sdr_data[12]<<8)+$sdr_data[13]);
			}
			#$sdr->led_id_ms($sdr_data[13]);
			#$sdr->led_id_ls($sdr_data[12]);
			$sdr->sensor_number(sprintf("%04x",$sdr->led_id));
			#printf("%02x,%02x,%04x\n",$mfg_id,$prod_id,$sdr->led_id);	
			#Was going to have a human readable name, but specs
			#seem to not to match reality...
			#$override_string = getsensorname($mfg_id,$prod_id,$sdr->sensor_number,$ipmiledtab);
			#I'm hacking in owner and lun of 260 for LEDs....
			$sdr_hash{"260.260.".$sdr->led_id} = $sdr;
			next;
		}


		$sdr->rec_type($sdr_type);
		$sdr->sensor_owner_id($sdr_data[6]);
		$sdr->sensor_owner_lun($sdr_data[7]);
		$sdr->sensor_number($sdr_data[8]);
		$sdr->entity_id($sdr_data[9]);
		$sdr->entity_instance($sdr_data[10]);
		$sdr->sensor_type($sdr_data[13]);
		$sdr->event_type_code($sdr_data[14]);
		$sdr->sensor_units_2($sdr_data[22]);
		$sdr->sensor_units_3($sdr_data[23]);

		if($sdr_type == 0x01) {
		   $sdr->sensor_units_1($sdr_data[21]);
			$sdr->linearization($sdr_data[24] & 0b01111111);
			$sdr->M(comp2int(10,(($sdr_data[26] & 0b11000000) << 2) + $sdr_data[25]));
			$sdr->B(comp2int(10,(($sdr_data[28] & 0b11000000) << 2) + $sdr_data[27]));
			$sdr->R_exp(comp2int(4,($sdr_data[30] & 0b11110000) >> 4));
			$sdr->B_exp(comp2int(4,$sdr_data[30] & 0b00001111));
		} elsif ($sdr_type == 0x02) {
		   $sdr->sensor_units_1($sdr_data[21]);
      }

		$sdr->id_string_type($sdr_data[48-$sdr_offset]);

		$override_string = getsensorname($mfg_id,$prod_id,$sdr->sensor_number,$ipmisensortab);

		if($override_string ne "") {
			$sdr->id_string($override_string);
		}
		else {
            unless (defined $sdr->id_string_type) { next; }
			$byte_format = ($sdr->id_string_type & 0b11000000) >> 6;
			if($byte_format == 0b11) {
				my $len = ($sdr->id_string_type & 0b00011111) - 1;
				if($len > 1) {
					$sdr->id_string(pack("C*",@sdr_data[49-$sdr_offset..49-$sdr_offset+$len]));
				}
				else {
					$sdr->id_string("no description");
				}
			}
			elsif($byte_format == 0b10) {
				$sdr->id_string("ASCII packed unsupported");
			}
			elsif($byte_format == 0b01) {
				$sdr->id_string("BCD unsupported");
			}
			elsif($byte_format == 0b00) {
                my $len = ($sdr->id_string_type & 0b00011111) - 1;
                if ($len > 1) { #It should be something, but need sample to code
				    $sdr->id_string("unicode unsupported");
                } else {
                    next;
                }
			}
		}

		$sdr_hash{$sdr->sensor_owner_id . "." . $sdr->sensor_owner_lun . "." . $sdr->sensor_number} = $sdr;
	}

	if($debug) {
		my $key;
#		foreach $key (sort {$sdr_hash{$a}->sensor_number <=> $sdr_hash{$b}->sensor_number} keys %sdr_hash) {
		foreach $key (sort {$sdr_hash{$a}->id_string cmp $sdr_hash{$b}->id_string} keys %sdr_hash) {
			my $sdr = $sdr_hash{$key};
#			printf("%d %x %s\n",$sdr->rec_type,$sdr->sensor_number,$sdr->id_string);
#			printf("%x %x %x %s\n",$sdr->sensor_owner_id,$sdr->sensor_owner_lun,$sdr->sensor_number,$sdr->id_string);
			printf("%x %x %x %s %d\n",$sdr->sensor_owner_id,$sdr->sensor_owner_lun,$sdr->sensor_number,$sdr->id_string,$sdr->linearization);
		}
#		printf("\n%x %s\n",$sdr_hash{0x70}->sensor_number,$sdr_hash{0x70}->id_string);
	}

	if($enable_cache eq "yes") {
		storsdrcache($cache_file);
	}

	return($rc,$text);
}

sub getsensorname
{
	my $mfgid = shift;
	my $prodid = shift;
	my $sensor = shift;
	my $file = shift;

	my $mfg;
	my $prod;
	my $type;
	my $num;
	my $desc;
	my $name="";

    if ($file eq "ibmleds") {
            if ($xCAT::data::ibmleds::leds{"$mfgid,$prodid"}->{$sensor}) {
              return $xCAT::data::ibmleds::leds{"$mfgid,$prodid"}->{$sensor}. " LED";
            } elsif ($ndebug) {
              return "Unknown $sensor/$mfgid/$prodid";
            } else {
              return sprintf ("LED 0x%x",$sensor);
            }
    } else {
      return "";
    }
}

sub getchassiscap {
	my $netfun = 0x00;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x00);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];
	if($code == 0x00) {
		$text = "";
	}
	else {
		$rc = 1;
		$text = $codes{$code};
		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	return($rc,@returnd[37-$authoffset..@returnd-2]);
}

sub getdevid {
	my $netfun = 0x18;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x01);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	my $device_id = $returnd[37-$authoffset];
	my $device_rev = $returnd[38-$authoffset] & 0b00001111;
	my $firmware_rev1 = $returnd[39-$authoffset] & 0b01111111;
	my $firmware_rev2 = $returnd[40-$authoffset];
	my $ipmi_ver = $returnd[41-$authoffset];
	my $dev_support = $returnd[42-$authoffset];
	my $sensor_device = 0;
	my $SDR = 0;
	my $SEL = 0;
	my $FRU = 0;
	my $IPMB_ER = 0;
	my $IPMB_EG = 0;
	my $BD = 0;
	my $CD = 0;
	if($dev_support & 0b00000001) {
		$sensor_device = 1;
	}
	if($dev_support & 0b00000010) {
		$SDR = 1;
	}
	if($dev_support & 0b00000100) {
		$SEL = 1;
	}
	if($dev_support & 0b00001000) {
		$FRU = 1;
	}
	if($dev_support & 0b00010000) {
		$IPMB_ER = 1;
	}
	if($dev_support & 0b00100000) {
		$IPMB_EG = 1;
	}
	if($dev_support & 0b01000000) {
		$BD = 1;
	}
	if($dev_support & 0b10000000) {
		$CD = 1;
	}
	my $mfg_id = $returnd[43-$authoffset] + $returnd[44-$authoffset]*0x100 +  $returnd[45-$authoffset]*0x10000;
	my $prod_id = $returnd[46-$authoffset] + $returnd[47-$authoffset]*0x100;
	my @data = @returnd[48-$authoffset..@returnd-2];

	return($rc,$text,$mfg_id,$prod_id,$device_id,$device_rev,$firmware_rev1,$firmware_rev2);
}

sub getguid {
	my $guidcmd = shift;
	my $netfun = @$guidcmd[0] || 0x18;
	my @cmd = @$guidcmd[1] || 0x37;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	my @guid = @returnd[37-$authoffset..52-$authoffset];
	my $guidtext = sprintf("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",@guid);
	$guidtext =~ tr/[a-z]/[A-Z]/;

	return($rc,$text,$guidtext);
}

sub get_sdr_rep_info {
	my $sdr_rep_info = shift;

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x20);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	$sdr_rep_info->version($returnd[37-$authoffset]);
	$sdr_rep_info->rec_count($returnd[38-$authoffset] + $returnd[39-$authoffset]*0x100);
	$sdr_rep_info->resv_sdr(($returnd[50-$authoffset] & 0b00000010) ? 1 : 0);

	return($rc,$text);
}

sub resv_sdr_repo {
	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x22);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	my $resv_id_ls = $returnd[37-$authoffset];
	my $resv_id_ms = $returnd[38-$authoffset];

	return($rc,$text,$resv_id_ls,$resv_id_ms);
}

sub docmd {
	my $netfun = shift;
	my $cmd = shift;
	my $response = shift;

	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my @data;

	incseqlun();

	@data = ($rqsa,$seqlun,@$cmd);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	incseqnum();

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@$response) = domsg($sock,\@msg,$timeout,1);

	return($error);
}

sub getchanauthcap {
	$auth = 0x00;
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my $error = "";
	my @response;
	my $code;

	@data = ($rqsa,$seqlun,0x38,0x8e,0x04);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	
	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		$length,
		$rssa,
		$netfun,
		dochksum(\@rn),
		@data,
		dochksum(\@data)
	);

	($error,@response) = domsg($sock,\@msg,$timeout,0);

	if($error) {
		return($error);
	}

	$code = $response[20];
    if ($code == 0xcc) {
        #Despite the fact that the IPMI 1.5 spec declared the high bits to be
        #reserved, some 1.5 BMCs checked the value anyway (erroneously)
        #This retries with the IPMI 2.0 bit cleared
    	@data = ($rqsa,$seqlun,0x38,0x0e,0x04);
    	@rn = ($rssa,$netfun);
    	$length = (scalar @data)+4;
    	
    	@msg = (
    		@rmcp,
    		$auth,
    		@seqnum,
    		@session_id,
    		$length,
    		$rssa,
    		$netfun,
    		dochksum(\@rn),
    		@data,
    		dochksum(\@data)
    	);

    	($error,@response) = domsg($sock,\@msg,$timeout,0);
    
    	if($error) {
    		return($error);
    	}
    	$code = $response[20];
    }
	if($code != 0x00) {
		$error = $codes{$code};
		if(!$error) {
			$error = "Unknown get channel authentication capabilities error $code"
		}
		return($error);
	}

	$channel_number=$response[21];

	if($response[22] & 0b10000000 and $response[24] & 0b00000010) {
		$ipmiv2=1;
	}
	if($response[22] & 0b00000100) {
		$auth=0x02;
	}
	elsif($response[22] & 0b00010000) {
		$auth=0x04;
	}
	else {
		$error = "unsupported Authentication Type Support";
	}

	return($error);
}

sub getsessionchallenge {
	my $tauth = 0x00;
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x39,$auth,@user);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	
	@msg = (
		@rmcp,
		$tauth,
		@seqnum,
		@session_id,
		$length,
		$rssa,
		$netfun,
		dochksum(\@rn),
		@data,
		dochksum(\@data)
	);

	($error,@response) = domsg($sock,\@msg,$timeout,0);

	if(!$error) {
		$code = $response[20];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown get session challenge error $code"
			}
		}

		if($code == 0x81) {
			$error = "Invalid user name";
		}
		elsif($code == 0x82) {
			$error = "null user name not enabled";
		}

		@session_id = @response[21,22,23,24];

    	for (my $i=0;$i<16;$i++){
			$challenge[$i] = $response[25+$i];
    	}
	}

	return($error);
}

sub activatesession {
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x3A,$auth,0x04,@challenge,0x01,0x00,0x00,0x00);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@response) = domsg($sock,\@msg,$timeout,0);

	if(!$error) {
		$code = $response[36];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown activate session error $code"
			}
		}

		if($code == 0x81) {
			$error = "No session slot available";
		}
		elsif($code == 0x82) {
			$error = "No slot available for given user";
		}
		elsif($code == 0x83) {
			$error = "No slot available to support user due to maximum privilege capability";
		}
		elsif($code == 0x84) {
			$error = "Session sequence number out-of-range";
		}
		elsif($code == 0x85) {
			$error = "Invalid session ID in request";
		}
		elsif($code == 0x86) {
			$error = "Requested maximum privilege level exceeds user and/of channel privilege limit";
		}

        unless ($error) {
    		$auth = $response[37];
    		if($auth == 0x00) {
    			$authoffset=16;
    		}
    		elsif($auth == 0x02) {
    		}
    		elsif($auth == 0x04) {
    		}
    		else {
    			$error = "activate session requested unsupported Authentication Type Support";
    		}
        }

###check
		@session_id = @response[38,39,40,41];
		@seqnum = @response[42,43,44,45];
	}

	return($error);
}

sub setprivlevel()
{
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x3B,0x04);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@response) = domsg($sock,\@msg,$timeout,1);

	if(!$error) {
		$code = $response[36-$authoffset];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown set session privilege level error $code"
			}
		}

		if($code == 0x80) {
			$error = "Requested level not available for this user";
		}
		elsif($code == 0x81) {
			$error = "Requested level exceeds channel and/or user privilege limit";
		}
		elsif($code == 0x82) {
			$error = "Cannot disable user level authentication";
		}
	}

	return($error);
}

sub closesession()
{
	incseqnum();

	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x3C,@session_id);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@response) = domsg($sock,\@msg,$timeout,1);

	if(!$error) {
		$code = $response[36-$authoffset];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown close session error $code"
			}
		}

		if($code == 0x87) {
			$error = "Invalid session ID in request";
		}
	}

	return($error);
}

sub domsg {
	my $sock = shift;
	my $msg = shift;
	my $timeout = shift;
	my $seq = shift || 0;
	my $debug = $localdebug;
	my $trys = $localtrys;
	my $send;
	my $quit = 0;
	my $error="";
	my $recv;
	my @response;
	my $timedout;
	my @foo;
	my @message;

	$send = pack('C*',@$msg);

	while($trys > 0) {
		$trys--;
		$error = "";
		$timedout = 0;

		if($debug) {
			print "try: $trys, timeout: $timeout\n";
		}

		if(!$sock->send($send)) {
			$error = $!;
			sleep(1);
			next;
		}
		my $s = IO::Select->new($sock);
		#local $SIG{ALRM} = sub { $timedout = 1 and die };
		#alarm($timeout);
		my $received = $s->can_read($timeout);
		if($received and $received > 0) {
			if ($sock->recv($recv,1300)) {
				if($recv) {
					@response = unpack("C*",$recv);
					last;
				}
			} else {
				$error = $!;
			}
		}
		else {
			$error = "timeout";
		}

###ugly updated hack to support md5.
		if($seq) {
			incseqnum();

			@$msg[5..8] = @seqnum[0..3];
			@message = @$msg[30..@$msg-1];
			if($auth != 0x00) {
				@$msg[13..28] = authcode(2,\@message);
			}

			$send = pack('C*',@$msg);
		}
	}

	if($timedout == 1) {
		if($error) {
			$error = "timeout $error"
		}
		else {
			$error = "timeout"
		}
	}

	return($error,@response);
}

sub dochksum()
{
	my $data = shift;
	my $sum = 0;

	foreach(@$data) {
		$sum += $_;
	}

	$sum = ~$sum + 1;
	return($sum & 0xFF);
}

sub dopad16 {
	my @pad16 = unpack("C*",shift);	

	for(my $i=@pad16;$i<16;$i++) {
		$pad16[$i] = 0;
	}

	return(@pad16);
}

sub hexdump {
	my $data = shift;

	foreach(@$data) {
		printf("%02x ",$_);
	}
	print "\n";
}

sub getascii {
        my @alpha;
        my $text ="";
        my $c = 0;

        foreach(@_) {
                if (defined $_ and $_ < 128 and $_ > 0x20) {
                    $alpha[$c] = sprintf("%c",$_);
                } else {
                    $alpha[$c]=" ";
                }
                if($alpha[$c] !~ /[\/\w\-:\[\.\]]/) {
        			if ($alpha[($c-1)] !~ /\s/) {
                    	    $alpha[$c] = " ";
	          		} else {
			        	$c--;
			        }
                }
                $c++;
        }
        foreach(@alpha) {
                $text=$text.$_;
        }
	$text =~ s/^\s+|\s+$//;
	return $text;
}
sub phex {
        my $data = shift;
        my @alpha;
        my $text ="";
        my $c = 0;

        foreach(@$data) {
                $text = $text . sprintf("%02x ",$_);
                $alpha[$c] = sprintf("%c",$_);
                if($alpha[$c] !~ /\w/) {
                        $alpha[$c] = " ";
                }
                $c++;
        }
        $text = $text . "(";
        foreach(@alpha) {
                $text=$text.$_;
        }
        $text = $text . ")";
        return $text;
}

sub hexadump {
	my $data = shift;
	my @alpha;
	my $c = 0;

	foreach(@$data) {
		printf("%02x ",$_);
		$alpha[$c] = sprintf("%c",$_);
		if($alpha[$c] !~ /\w/) {
			$alpha[$c] = ".";
		}
		$c++;
		if($c == 16) {
			print "   ";
			foreach(@alpha) {
				print $_;
			}
			print "\n";
			@alpha=();
			$c=0;
		}
	}
	foreach($c..16) {
		print "   ";
	}
	foreach(@alpha) {
		print $_;
	}
	print "\n";
}

sub incseqnum {
	my $i;

	for($i = 0;$i < 4;$i++) {
		if($seqnum[$i] < 0xFF) {
			$seqnum[$i]++;
			last;
		}
		$seqnum[$i] = 0;
	}

	if($seqnum[3] > 0xFF) {
		@seqnum = (0,0,0,0);
	}
}

sub incseqlun {
	$seqlun += 4;

	if($seqlun > 0xFF) {
		$seqlun = 0;
	}
}

sub authcode {
	my $type = shift;
	my $message = shift;
	my @authcode;

	if($auth == 0x02) {
		if($type == 1) {
			@authcode = unpack("C*",md5(pack("C*",@pass,@session_id,@challenge,@pass)));
		}
		elsif($type == 2) {
			@authcode = unpack("C*",md5(pack("C*",@pass,@session_id,@$message,@seqnum,@pass)));
		}
	}
	elsif($auth == 0x04) {
		@authcode = @pass;
	}
	elsif($auth == 0x00) {
		@authcode = ();
	}

	return(@authcode);
}

sub comp2int {
	my $length = shift;
	my $bits = shift;
	my $neg = 0;

	if($bits & 2**($length - 1)) {
		$neg = 1;
	}

	$bits &= (2**($length - 1) - 1);

	if($neg) {
		$bits -= 2**($length - 1);
	}

	return($bits);
}

sub timestamp2datetime {
	my $ts = shift;
   if ($ts < 0x20000000) {
      return "BMC Uptime",sprintf("%6d s",$ts);
   }
	my @t = localtime($ts);
	my $time = strftime("%H:%M:%S",@t);
	my $date = strftime("%m/%d/%Y",@t);

	return($date,$time);
}

sub decodebcd {
	my $numbers = shift;
	my @bcd;
	my $text;
	my $ms;
	my $ls;

	foreach(@$numbers) {
		$ms = ($_ & 0b11110000) >> 4;
		$ls = ($_ & 0b00001111);
		push(@bcd,$ms);
		push(@bcd,$ls);
	}

	foreach(@bcd) {
		if($_ < 0x0a) {
			$text .= $_;
		}
		elsif($_ == 0x0a) {
			$text .= " ";
		}
		elsif($_ == 0x0b) {
			$text .= "-";
		}
		elsif($_ == 0x0c) {
			$text .= ".";
		}
	}

	return($text);
}

sub storsdrcache {
	my $file = shift;
	my $key;
	my $fh;

	system("mkdir -p $cache_dir");
	if(!open($fh,">$file")) {
		return(1);
	}

	flock($fh,LOCK_EX) || return(1);

	foreach $key (keys %sdr_hash) {
		my $r = $sdr_hash{$key};
		store_fd($r,$fh);
	}

	close($fh);

	return(0);
}

sub loadsdrcache {
	my $file = shift;
	my $r;
	my $c=0;
	my $fh;

	if(!open($fh,"<$file")) {
		return(1);
	}

	flock($fh,LOCK_SH) || return(1);

	while() {
		eval {
			$r = retrieve_fd($fh);
		} || last;

		$sdr_hash{$r->sensor_owner_id . "." . $r->sensor_owner_lun . "." . $r->sensor_number} = $r;
	}

	close($fh);

	return(0);
}


sub preprocess_request { 
  $SIG{INT} = $SIG{TERM} = sub { 
     foreach (keys %bmc_comm_pids) {
        kill 2, $_;
     }
     exit 0;
  };
  my $request = shift;
  if ($request->{_xcatdest}) { return [$request]; }    #exit if preprocessed
  my $callback=shift;
  my @requests;

  my $noderange = $request->{node}; #Should be arrayref
  my $command = $request->{command}->[0];
  my $extrargs = $request->{arg};
  my @exargs=($request->{arg});
  if (ref($extrargs)) {
    @exargs=@$extrargs;
  }

  my $usage_string=xCAT::Usage->parseCommand($command, @exargs);
  if ($usage_string) {
    $callback->({data=>$usage_string});
    $request = {};
    return;
  }

  if (!$noderange) {
    $usage_string=xCAT::Usage->getUsage($command);
    $callback->({data=>$usage_string});
    $request = {};
    return;
  }   
  
  #print "noderange=@$noderange\n";

  # find service nodes for requested nodes
  # build an individual request for each service node
  my $service  = "xcat";
  my $sn = xCAT::Utils->get_ServiceNode($noderange, $service, "MN");

  # build each request for each service node

  foreach my $snkey (keys %$sn)
  {
    #print "snkey=$snkey\n";
    my $reqcopy = {%$request};
    $reqcopy->{node} = $sn->{$snkey};
    $reqcopy->{'_xcatdest'} = $snkey;
    push @requests, $reqcopy;
  }
  return \@requests;
}
    
     
sub getipmicons {
    my $argr=shift;
    #$argr is [$node,$nodeip,$nodeuser,$nodepass];
    my $cb = shift;
    my $ipmicons={node=>[{name=>[$argr->[0]]}]};
    $ipmicons->{node}->[0]->{bmcaddr}->[0]=$argr->[1];
    $ipmicons->{node}->[0]->{bmcuser}->[0]=$argr->[2];
    $ipmicons->{node}->[0]->{bmcpass}->[0]=$argr->[3];
    $cb->($ipmicons);
}



   
sub process_request {
  my $request = shift;
  my $callback = shift;
  my $noderange = $request->{node}; #Should be arrayref
  my $command = $request->{command}->[0];
  my $extrargs = $request->{arg};
  my @exargs=($request->{arg});
  if (ref($extrargs)) {
    @exargs=@$extrargs;
  }
	my $ipmiuser = 'USERID';
	my $ipmipass = 'PASSW0RD';
	my $ipmitrys = 3;
	my $ipmitimeout = 2;
	my $ipmimaxp = 64;
	my $sitetab = xCAT::Table->new('site');
	my $ipmitab = xCAT::Table->new('ipmi');
	my $tmp;
	if ($sitetab) {
		($tmp)=$sitetab->getAttribs({'key'=>'ipmimaxp'},'value');
		if (defined($tmp)) { $ipmimaxp=$tmp->{value}; }
		($tmp)=$sitetab->getAttribs({'key'=>'ipmitimeout'},'value');
		if (defined($tmp)) { $ipmitimeout=$tmp->{value}; }
		($tmp)=$sitetab->getAttribs({'key'=>'ipmiretries'},'value');
		if (defined($tmp)) { $ipmitrys=$tmp->{value}; }
		($tmp)=$sitetab->getAttribs({'key'=>'ipmisdrcache'},'value');
		if (defined($tmp)) { $enable_cache=$tmp->{value}; }
	}
	my $passtab = xCAT::Table->new('passwd');
	if ($passtab) {
		($tmp)=$passtab->getAttribs({'key'=>'ipmi'},'username','password');
		if (defined($tmp)) { 
			$ipmiuser = $tmp->{username};
			$ipmipass = $tmp->{password};
		}
	}

    #my @threads;
    my @donargs=();
    if ($request->{command}->[0] =~ /fru/) {
        my $vpdtab = xCAT::Table->new('vpd');
        $vpdhash = $vpdtab->getNodesAttribs($noderange,[qw(serial mtm asset)]);
    }
	my $ipmihash = $ipmitab->getNodesAttribs($noderange,['bmc','username','password']) ;
	foreach(@$noderange) {
		my $node=$_;
		my $nodeuser=$ipmiuser;
		my $nodepass=$ipmipass;
		my $nodeip = $node;
		my $ent;
		if (defined($ipmitab)) {
			$ent=$ipmihash->{$node}->[0];
			if (ref($ent) and defined $ent->{bmc}) { $nodeip = $ent->{bmc}; }
			if (ref($ent) and defined $ent->{username}) { $nodeuser = $ent->{username}; }
			if (ref($ent) and defined $ent->{password}) { $nodepass = $ent->{password}; }
		}
        push @donargs,[$node,$nodeip,$nodeuser,$nodepass];
    }
    if ($request->{command}->[0] eq "getipmicons") {
        foreach (@donargs) {
            getipmicons($_,$callback);
        }
        return;
    }

  #get new node status
  my %nodestat=();
  my $check=0;
  my $newstat;
  if ($command eq 'rpower') {
    if (($extrargs->[0] ne 'stat') && ($extrargs->[0] ne 'status') && ($extrargs->[0] ne 'state')) { 
      $check=1; 
      my @allnodes;
      foreach (@donargs) { push(@allnodes, $_->[0]); }

      if ($extrargs->[0] eq 'off') { $newstat=$::STATUS_POWERING_OFF; }
      else { $newstat=$::STATUS_BOOTING;}
      foreach (@allnodes) { $nodestat{$_}=$newstat; }

      if ($extrargs->[0] ne 'off') {
        #get the current nodeset stat
        if (@allnodes>0) {
	  my $nsh={};
          my ($ret, $msg)=xCAT::SvrUtils->getNodesetStates(\@allnodes, $nsh);
          if (!$ret) { 
            foreach (keys %$nsh) {
	      my $currstate=$nsh->{$_};
              $nodestat{$_}=xCAT_monitoring::monitorctrl->getNodeStatusFromNodesetState($currstate, "rpower");
	    }
	  }
        }
      }
    }
  }
  #foreach (keys %nodestat) { print "node=$_,status=" . $nodestat{$_} ."\n"; } #Ling:remove

    my $children = 0;
    $SIG{CHLD} = sub {my $kpid; do { $kpid = waitpid(-1, WNOHANG); if ($kpid > 0) { delete $bmc_comm_pids{$kpid}; $children--; } } while $kpid > 0; };
    my $sub_fds = new IO::Select;
    foreach (@donargs) {
      while ($children > $ipmimaxp) { 
        my $errornodes={};
        forward_data($callback,$sub_fds,$errornodes);
        #update the node status to the nodelist.status table
        if ($check) {
          updateNodeStatus(\%nodestat, $errornodes);
        }
      }
      $children++;
      my $cfd;
      my $pfd;
      socketpair($pfd, $cfd,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die "socketpair: $!";
      $cfd->autoflush(1);
      $pfd->autoflush(1);
      my $child = xCAT::Utils->xfork();
      unless (defined $child) { die "Fork failed" };
	if ($child == 0) { 
        close($cfd);
        my $rrc=donode($pfd,$_->[0],$_->[1],$_->[2],$_->[3],$ipmitimeout,$ipmitrys,$command,-args=>\@exargs);
        close($pfd);
	exit(0);
      }
      $bmc_comm_pids{$child}=1;
      close ($pfd);
      $sub_fds->add($cfd)
	}
    while ($sub_fds->count > 0 and $children > 0) {
      my $errornodes={};
      forward_data($callback,$sub_fds,$errornodes);
      #update the node status to the nodelist.status table
      if ($check) {
        updateNodeStatus(\%nodestat, $errornodes);
      }
    }
    
    #Make sure they get drained, this probably is overkill but shouldn't hurt
    my $rc=1;
    while ( $rc>0 ) {
      my $errornodes={};
      $rc=forward_data($callback,$sub_fds,$errornodes);
      #update the node status to the nodelist.status table
      if ($check) {
        updateNodeStatus(\%nodestat, $errornodes);
      }
    }   
}

sub updateNodeStatus {
  my $nodestat=shift;
  my $errornodes=shift;
  my %node_status=();
  foreach my $node (keys(%$errornodes)) {
    if ($errornodes->{$node} == -1) { next;} #has error, not updating status
    my $stat=$nodestat->{$node};
    if (exists($node_status{$stat})) {
      my $pa=$node_status{$stat};
      push(@$pa, $node);
    }
    else {
      $node_status{$stat}=[$node];
    }
  }
  xCAT_monitoring::monitorctrl::setNodeStatusAttributes(\%node_status, 1);
}



sub forward_data { #unserialize data from pipe, chunk at a time, use magic to determine end of data structure
  my $callback = shift;
  my $fds = shift;
  my $errornodes=shift;

  my @ready_fds = $fds->can_read(1);
  my $rfh;
  my $rc = @ready_fds;
  foreach $rfh (@ready_fds) {
    my $data;
    if ($data = <$rfh>) {
      while ($data !~ /ENDOFFREEZE6sK4ci/) {
        $data .= <$rfh>;
      }
      print $rfh "ACK\n";
      my $responses=thaw($data);
      foreach (@$responses) {
        #save the nodes that has errors and the ones that has no-op for use by the node status monitoring
        my $no_op=0;
        if (exists($_->{node}->[0]->{errorcode})) { $no_op=1; }
        else { 
          my $text=$_->{node}->[0]->{data}->[0]->{contents}->[0];
          #print "data:$text\n";
          if (($text) && ($text =~ /$status_noop/)) {
	    $no_op=1;
            #remove the symbols that meant for use by node status
            $_->{node}->[0]->{data}->[0]->{contents}->[0] =~ s/ $status_noop//; 
          }
        }  
	#print "data:". $_->{node}->[0]->{data}->[0]->{contents}->[0] . "\n";
        if ($no_op) {
          if ($errornodes) { $errornodes->{$_->{node}->[0]->{name}->[0]}=-1; } 
        } else {
          if ($errornodes) { $errornodes->{$_->{node}->[0]->{name}->[0]}=1; } 
        }
        $callback->($_);
      }
    } else {
      $fds->remove($rfh);
      close($rfh);
    }
  }
  yield; #Avoid useless loop iterations by giving children a chance to fill pipes
  return $rc;
}

sub donode {
  $outfd = shift;
  my $node = shift;
  $currnode=$node;
  my $bmcip = shift;
  my $user = shift;
  my $pass = shift;
  my $timeout = shift;
  my $retries = shift;
  my $command = shift;
  my %namedargs=@_;
  my $transid = $namedargs{-transid};
  my $extra=$namedargs{-args};
  my @exargs=@$extra;
  my ($rc,@output) = ipmicmd($bmcip,623,$user,$pass,$timeout,$retries,0,$command,@exargs);
  my @outhashes;
  sendoutput($rc,@output);
  yield;
  #my $msgtoparent=freeze(\@outhashes);
 # print $outfd $msgtoparent;
  return $rc;
}

sub sendoutput {
    my $rc=shift;
    foreach (@_) {
        my %output;
        (my $desc,my $text) = split(/:/,$_,2);
        unless ($text) {
          $text=$desc;
        } else {
          $desc =~ s/^\s+//;
          $desc =~ s/\s+$//;
          if ($desc) {
             $output{node}->[0]->{data}->[0]->{desc}->[0]=$desc;
          }
        }
        $text =~ s/^\s+//;
        $text =~ s/\s+$//;
        $output{node}->[0]->{name}->[0]=$currnode;
        if ($rc) {
          $output{node}->[0]->{errorcode}=[$rc];
            $output{node}->[0]->{error}->[0]=$text;
        } else {
            $output{node}->[0]->{data}->[0]->{contents}->[0]=$text;
        }
        #push @outhashes,\%output; #Save everything for the end, don't know how to be slicker with Storable and a pipe
        print $outfd freeze([\%output]);
        print $outfd "\nENDOFFREEZE6sK4ci\n";
        yield;
        waitforack($outfd);
    }
}

1;
