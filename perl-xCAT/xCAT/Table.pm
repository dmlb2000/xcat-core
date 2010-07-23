#IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#TODO:
#MEMLEAK fix
# see NodeRange.pm for notes about how to produce a memory leak
# xCAT as it stands at this moment shouldn't leak anymore due to what is 
# described there, but that only hides from the real problem and the leak will
# likely crop up if future architecture changes happen
# in summary, a created Table object without benefit of db worker thread
# to abstract its existance will consume a few kilobytes of memory
# that never gets reused
# just enough notes to remind me of the design that I think would allow for
#   -cache to persist so long as '_build_cache' calls concurrently stack (for NodeRange interpretation mainly) (done)
#   -Allow plugins to define a staleness threshold for getNodesAttribs freshness (complicated enough to postpone...)
#    so that actions requested by disparate managed nodes may aggregate in SQL calls
# reference count managed cache lifetime, if clear_cache is called, and build_chache has been called twice, decrement the counter
# if called again, decrement again and clear cache
# for getNodesAttribs, we can put a parameter to request allowable staleneess
# if the cachestamp is too old, build_cache is called
# in this mode, 'use_cache' is temporarily set to 1, regardless of 
# potential other consumers (notably, NodeRange)
#perl errors/and warnings are not currently wrapped.
#  This probably will be cleaned
#up
#Some known weird behaviors
#creating new sqlite db files when only requested to read non-existant table, easy to fix,
#class xcattable
#FYI on emulated AutoCommit:
#SQLite specific behavior has Table layer implementing AutoCommit.  There
#is a significant limitation, 'rollback' may not roll all the way back
#if an intermediate transaction occured on the same table
#TODO: short term, have tabutils implement it's own rollback (the only consumer)
#TODO: longer term, either figure out a way to properly implement it or 
#      document it as a limitation for SQLite configurations
package xCAT::Table;
use xCAT::MsgUtils;
use Sys::Syslog;
use Storable qw/freeze thaw/;
use IO::Socket;
use Data::Dumper;
use POSIX qw/WNOHANG/;
BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : -d '/opt/xcat' ? '/opt/xcat' : '/usr';
}

# if AIX - make sure we include perl 5.8.2 in INC path.
#       Needed to find perl dependencies shipped in deps tarball.
if ($^O =~ /^aix/i) {
        use lib "/usr/opt/perl5/lib/5.8.2/aix-thread-multi";
        use lib "/usr/opt/perl5/lib/5.8.2";
        use lib "/usr/opt/perl5/lib/site_perl/5.8.2/aix-thread-multi";
        use lib "/usr/opt/perl5/lib/site_perl/5.8.2";
}

use lib "$::XCATROOT/lib/perl";
my $cachethreshold=16; #How many nodes in 'getNodesAttribs' before switching to full DB retrieval

use DBI;
$DBI::dbi_debug=9; # increase the debug output

use strict;
use Scalar::Util qw/weaken/;
require xCAT::Schema;
require xCAT::NodeRange;
use Text::Balanced qw(extract_bracketed);
require xCAT::NotifHandler;

my $dbworkerpid; #The process id of the database worker
my $dbworkersocket;
my $dbsockpath = "/tmp/xcat/dbworker.sock.".$$;
my $exitdbthread;
my $dbobjsforhandle;
my $intendedpid;


sub dbc_call {
    my $self = shift;
    my $function = shift;
    my @args = @_;
    my $request = { 
         function => $function,
         tablename => $self->{tabname},
         autocommit => $self->{autocommit},
          args=>\@args,
    };
    return dbc_submit($request);
}

sub dbc_submit {
    my $request = shift;
    $request->{'wantarray'} = wantarray();
    my $data = freeze($request);
    $data.= "\nENDOFFREEZEQFVyo4Cj6Q0v\n";
    my $clisock;
    while(!($clisock = IO::Socket::UNIX->new(Peer => $dbsockpath, Type => SOCK_STREAM, Timeout => 120) ) ) {
        #print "waiting for clisock to be available\n";
        sleep 0.1;
    }
    unless ($clisock) {
        use Carp qw/cluck/;
        cluck();
    }
    print $clisock $data;
    $data="";
    my $lastline="";
    while ($lastline ne "ENDOFFREEZEQFVyo4Cj6Q0j\n" and $lastline ne "*XCATBUGDETECTED*76e9b54341\n") { #index($lastline,"ENDOFFREEZEQFVyo4Cj6Q0j") < 0) {
        $lastline = <$clisock>;
	    $data .= $lastline;
    }
    if ($lastline eq "*XCATBUGDETECTED*76e9b54341\n") { #if it was an error
        #in the midst of the operation, die like it used to die
        my $err;
        $data =~ /\*XCATBUGDETECTED\*:(.*):\*XCATBUGDETECTED\*/s;
        $err = $1;
        die $err;
    }
    my @returndata = @{thaw($data)};
    if (wantarray) {
        return @returndata;
    } else {
        return $returndata[0];
    }
}

sub shut_dbworker {
    $dbworkerpid = 0; #For now, just turn off usage of the db worker
    #This was created as the monitoring framework shutdown code otherwise seems to have a race condition
    #this may incur an extra db handle per service node to tolerate shutdown scenarios
}
sub init_dbworker {
#create a db worker process
#First, release all non-db-worker owned db handles (will recreate if we have to)
    foreach (values %{$::XCAT_DBHS})
    {    #@{$drh->{ChildHandles}}) {
        if ($_) { $_->disconnect(); }
        $_->{InactiveDestroy} = 1;
        undef $_;
    }
    $::XCAT_DBHS={};
    $dbobjsforhandle={};#TODO: It's not said explicitly, but this means an 
    #existing TABLE object is useless if going into db worker.  Table objects
    #must be recreated after the transition.  Only xcatd should have to
    #worry about it.  This may warrant being done better, making a Table
    #object meaningfully survive in much the same way it survives a DB handle
    #migration in handle_dbc_request


    $dbworkerpid = fork;

    unless (defined $dbworkerpid) {
        die "Error spawining database worker";
    }
    unless ($dbworkerpid) {
        $intendedpid = $$;
        $SIG{CHLD} = sub { while (waitpid(-1,WNOHANG) > 0) {}}; #avoid zombies from notification framework
        #This process is the database worker, it's job is to manage database queries to reduce required handles and to permit cross-process caching
        $0 = "xcatd: DB Access";
        use File::Path;
        mkpath('/tmp/xcat/');
        use IO::Socket;
        $SIG{TERM} = $SIG{INT} = sub {
            $exitdbthread=1;
            $SIG{ALRM} = sub { exit 0; };
            alarm(10);
        };
        unlink($dbsockpath);
        umask(0077);
        $dbworkersocket = IO::Socket::UNIX->new(Local => $dbsockpath, Type => SOCK_STREAM, Listen => 8192);
        unless ($dbworkersocket) {
            die $!;
        }
        my $currcon;
        my $clientset = new IO::Select;
        $clientset->add($dbworkersocket);

        #setup signal in NotifHandler so that the cache can be updated
        xCAT::NotifHandler::setup($$, 0);

        while (not $exitdbthread) {
            eval {
                my @ready_socks = $clientset->can_read;
                foreach $currcon (@ready_socks) {
                    if ($currcon == $dbworkersocket) { #We have a new connection to register
                        my $dbconn = $currcon->accept;
                        if ($dbconn) {
                            $clientset->add($dbconn);
                        }
                    } else {
                        eval {
                            handle_dbc_conn($currcon,$clientset);
                        };
                        if ($@) { 
                            my $err=$@;
                            xCAT::MsgUtils->message("S","xcatd: possible BUG encountered by xCAT DB worker ".$err);
                            if ($currcon) {
                                eval { #avoid hang by allowin client to die too
                                    print $currcon "*XCATBUGDETECTED*:$err:*XCATBUGDETECTED*\n";
                                    print $currcon "*XCATBUGDETECTED*76e9b54341\n";
                                };
                            }
                        }
                    }
                }
            };
            if ($@) { #this should never be reached, but leave it intact just in case
                my $err=$@;
                xCAT::MsgUtils->message("S","xcatd: possible BUG encountered by xCAT DB worker ".$err);
            }
            if ($intendedpid != $$) { #avoid redundant fork
                exit(0);
            }
        }
        close($dbworkersocket);
        unlink($dbsockpath);
        exit 0;
    }
    return $dbworkerpid;
}
sub handle_dbc_conn {
    my $client = shift;
    my $clientset = shift;
    my $data;
    if ($data = <$client>) {
	my $lastline;
        while ($lastline ne "ENDOFFREEZEQFVyo4Cj6Q0v\n") { #$data !~ /ENDOFFREEZEQFVyo4Cj6Q0v/) {
	    $lastline = <$client>;
            $data .= $lastline;
        }
        my $request = thaw($data);
        my $response;
        my @returndata;
        if ($request->{'wantarray'}) {
            @returndata = handle_dbc_request($request);
        } else {
            @returndata = (scalar(handle_dbc_request($request)));
        }
        $response = freeze(\@returndata);
        $response .= "\nENDOFFREEZEQFVyo4Cj6Q0j\n";
        print $client $response;
    } else { #Connection terminated, clean up
        $clientset->remove($client);
        close($client);
    }

}

my %opentables; #USED ONLY BY THE DB WORKER TO TRACK OPEN DATABASES
sub handle_dbc_request {
    my $request = shift;
    my $functionname = $request->{function};
    my $tablename = $request->{tablename};
    my @args = @{$request->{args}};
    my $autocommit = $request->{autocommit};
    my $dbindex;
    foreach $dbindex (keys %{$::XCAT_DBHS}) { #Go through the current open DB handles
        unless ($::XCAT_DBHS->{$dbindex}) { next; } #If we have a stale dbindex entry skip it (should no longer happen with additions to init_dbworker
        unless ($::XCAT_DBHS->{$dbindex} and $::XCAT_DBHS->{$dbindex}->ping) {
            #We have a database that we were unable to reach, migrate database 
            #handles out from under table objects
            my @afflictedobjs = (); #Get the list of objects whose database handle needs to be replaced
            if (defined $dbobjsforhandle->{$::XCAT_DBHS->{$dbindex}}) {
                @afflictedobjs = @{$dbobjsforhandle->{$::XCAT_DBHS->{$dbindex}}};
            } else {
                die "DB HANDLE TRACKING CODE HAS A BUG";
            }
            my $oldhandle = $::XCAT_DBHS->{$dbindex}; #store old handle off 
            $::XCAT_DBHS->{$dbindex} = $::XCAT_DBHS->{$dbindex}->clone(); #replace broken db handle with nice, new, working one
            $dbobjsforhandle->{$::XCAT_DBHS->{$dbindex}} = $dbobjsforhandle->{$oldhandle}; #Move the map of depenednt objects to the new handle
            foreach (@afflictedobjs) {  #migrate afflicted objects to the new DB handle
                $$_->{dbh} = $::XCAT_DBHS->{$dbindex};
            }   
            delete $dbobjsforhandle->{$oldhandle}; #remove the entry for the stale handle
            $oldhandle->disconnect(); #free resources associated with dead handle
        }   
    }   
    if ($functionname eq 'new') {
        unless ($opentables{$tablename}->{$autocommit}) {
            shift @args; #Strip repeat class stuff
            $opentables{$tablename}->{$autocommit} = xCAT::Table->new(@args);
        }
        if ($opentables{$tablename}->{$autocommit}) {
            return 1;
        } else {
            return 0;
        }
    } else { 
        unless (defined $opentables{$tablename}->{$autocommit}) {
        #We are servicing a Table object that used to be 
        #non data-worker.  Create a new DB worker side Table like the one
        #that requests this
            $opentables{$tablename}->{$autocommit} = xCAT::Table->new($tablename,-create=>0,-autocommit=>$autocommit);
            unless ($opentables{$tablename}->{$autocommit}) {
                return undef;
            }
        }
    }
    if ($functionname eq 'getAllAttribs') {
         return $opentables{$tablename}->{$autocommit}->getAllAttribs(@args);
    } elsif ($functionname eq 'getAttribs') {
         return $opentables{$tablename}->{$autocommit}->getAttribs(@args);
    } elsif ($functionname eq 'getTable') {
         return $opentables{$tablename}->{$autocommit}->getTable(@args);
    } elsif ($functionname eq 'getAllNodeAttribs') {
         return $opentables{$tablename}->{$autocommit}->getAllNodeAttribs(@args);
    } elsif ($functionname eq 'getAllEntries') {
         return $opentables{$tablename}->{$autocommit}->getAllEntries(@args);
    } elsif ($functionname eq 'getAllAttribsWhere') {
         return $opentables{$tablename}->{$autocommit}->getAllAttribsWhere(@args);
    } elsif ($functionname eq 'addAttribs') {
         return $opentables{$tablename}->{$autocommit}->addAttribs(@args);
    } elsif ($functionname eq 'setAttribs') {
         return $opentables{$tablename}->{$autocommit}->setAttribs(@args);
    } elsif ($functionname eq 'setAttribsWhere') {
         return $opentables{$tablename}->{$autocommit}->setAttribsWhere(@args);
    } elsif ($functionname eq 'delEntries') {
         return $opentables{$tablename}->{$autocommit}->delEntries(@args);
    } elsif ($functionname eq 'commit') {
         return $opentables{$tablename}->{$autocommit}->commit(@args);
    } elsif ($functionname eq 'rollback') {
         return $opentables{$tablename}->{$autocommit}->rollback(@args);
    } elsif ($functionname eq 'getNodesAttribs') {
         return $opentables{$tablename}->{$autocommit}->getNodesAttribs(@args);
    } elsif ($functionname eq 'setNodesAttribs') {
         return $opentables{$tablename}->{$autocommit}->setNodesAttribs(@args);
    } elsif ($functionname eq 'getNodeAttribs') {
         return $opentables{$tablename}->{$autocommit}->getNodeAttribs(@args);
    } elsif ($functionname eq '_set_use_cache') {
         return $opentables{$tablename}->{$autocommit}->_set_use_cache(@args);
    } elsif ($functionname eq '_build_cache') {
         return $opentables{$tablename}->{$autocommit}->_build_cache(@args);
    } elsif ($functionname eq '_clear_cache') {
         return $opentables{$tablename}->{$autocommit}->_clear_cache(@args);
    } else {
        die "undefined function $functionname";
    }
}

sub _set_use_cache {
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'_set_use_cache',@_);
    }
    $self->{_use_cache} = shift;
}
#--------------------------------------------------------------------------------

=head1 xCAT::Table

xCAT::Table - Perl module for xCAT configuration access

=head2 SYNOPSIS

use xCAT::Table;
my $table = xCAT::Table->new("tablename");

my $hashref=$table->getNodeAttribs("nodename","columname1","columname2");
printf $hashref->{columname1};


=head2 DESCRIPTION

This module provides convenience methods that abstract the backend specific configuration to a common API.

Currently implements the preferred SQLite backend, as well as a CSV backend, postgresql and MySQL, using their respective perl DBD modules.

NOTES

The CSV backend is really slow at scale.  Room for optimization is likely, but in general DBD::CSV is slow, relative to xCAT 1.2.x.
The SQLite backend, on the other hand, is significantly faster on reads than the xCAT 1.2.x way, so it is recommended.

BUGS

This module is not thread-safe, due to underlying DBD thread issues.  Specifically in testing, SQLite DBD leaks scalars if a thread
where a Table object exists spawns a child and that child exits.  The recommended workaround for now is to spawn a thread to contain
all Table objects if you intend to spawn threads from your main thread.  As long as no thread in which the new method is called spawns
child threads, it seems to work fine.

AUTHOR

Jarrod Johnson <jbjohnso@us.ibm.com>

xCAT::Table is released under an IBM license....


=cut

#--------------------------------------------------------------------------

=head2   Subroutines

=cut

#--------------------------------------------------------------------------

=head3   buildcreatestmt

    Description:  Build create table statement ( see new)

    Arguments:
                Table name
				Table schema ( hash of column names)
    Returns:
                Table creation SQL
    Globals:

    Error:

    Example:

                my $str =
                  buildcreatestmt($self->{tabname},
                                  $xCAT::Schema::tabspec{$self->{tabname}});

=cut

#--------------------------------------------------------------------------------
sub buildcreatestmt
{
    my $tabn  = shift;
    my $descr = shift;
    my $xcatcfg = shift;
    my $retv  = "CREATE TABLE $tabn (\n  ";
    my $col;
    my $types=$descr->{types};

    foreach $col (@{$descr->{cols}})
    {
        my $datatype;
        if ($xcatcfg =~ /^DB2:/){
         $datatype=get_datatype_string_db2($col, $types, $tabn,$descr);
        } else {
         $datatype=get_datatype_string($col,$xcatcfg, $types);
        }
        if ($datatype eq "TEXT") {
	    if (isAKey(\@{$descr->{keys}}, $col)) {   # keys need defined length
              
		$datatype = "VARCHAR(128) ";
	    }
	}  
        # build the columns of the table
        if ($xcatcfg =~ /^mysql:/) {  #for mysql
	      $retv .= q(`) . $col . q(`) . " $datatype";  # mysql change
        } else { # for other dbs including DB2
            $retv .= "\"$col\" $datatype ";
        }
        
        if (grep /^$col$/, @{$descr->{required}})
        { 
            # will have already put in NOT NULL, if DB2 and a key
            if (!($xcatcfg =~ /^DB2:/)){   # not a db2 key
              $retv .= " NOT NULL";
            }
        }
        $retv .= ",\n  ";
    }
    if ($retv =~ /PRIMARY KEY/) {
	$retv =~ s/,\n  $/\n)/;
    } else {
	$retv .= "PRIMARY KEY (";
	foreach (@{$descr->{keys}})
	{

            if ($xcatcfg =~ /^mysql:/) {  #for mysql
	      $retv .= q(`) . $_ . q(`) . ",";  # mysql  support reserved words
            } else { # for other dbs including db2
	       $retv .= "\"$_\",";
            }
	}
	$retv =~ s/,$/)\n)/;
    }
        #if ($xcatcfg =~ /^DB2:/) {  # for DB2 add tablespace
	 #  $retv .= " IN XCATTBS16K";
        #} 
	#print "retv=$retv\n";
    return $retv; 
}

#--------------------------------------------------------------------------

=head3   

    Description: get_datatype_string ( for mysql,sqlite,postgresql) 

    Arguments:
                Table column,database,types 
    Returns:
              the datatype for the column being defined 
    Globals:

    Error:

    Example:

        my $datatype=get_datatype_string($col,$xcatcfg, $types);

=cut

#--------------------------------------------------------------------------------
sub get_datatype_string {
    my $col=shift;    #column name
    my $xcatcfg=shift;  #db config string
    my $types=shift;  #hash pointer
    my $ret;

    if (($types) && ($types->{$col})) {
	if ($types->{$col} =~ /INTEGER AUTO_INCREMENT/) {
	    if ($xcatcfg =~ /^SQLite:/) {
		$ret = "INTEGER PRIMARY KEY AUTOINCREMENT";
	    } elsif ($xcatcfg =~ /^Pg:/) {
		$ret = "SERIAL";
	    } elsif ($xcatcfg =~ /^mysql:/){
		$ret = "INTEGER AUTO_INCREMENT";
	    } else {
	    }
	} else {
	    $ret = $types->{$col};
	}
    } else {
       $ret = "TEXT";
    }
    return $ret;
}

#--------------------------------------------------------------------------

=head3   

    Description: get_datatype_string_db2 ( for DB2) 

    Arguments:
                Table column,database,types,tablename,table schema 
    Returns:
              the datatype for the column being defined 
    Globals:

    Error:

    Example:

        my $datatype=get_datatype_string_db2($col, $types,$tablename,$descr);

=cut

#--------------------------------------------------------------------------------
sub get_datatype_string_db2 {
    my $col=shift;    #column name
    my $types=shift;  #types field (eventlog)
    my $tablename=shift;  # tablename
    my $descr=shift;  # table schema
    my $typedefined=0;
    my $ret = "varchar(512)";  # default for most attributes
    if (($types) && ($types->{$col})) {
	if ($types->{$col} =~ /INTEGER AUTO_INCREMENT/) {
		$ret = "INTEGER GENERATED ALWAYS AS IDENTITY";  
	} else {
	    $ret = $types->{$col};
	}
     $typedefined=1; 
    }
    if ($col eq "disable") {
         
       $ret = "varchar(8)";
    }
    if ($col eq "rawdata") {  # from eventlog table
         
       $ret = "varchar(4098)";
    }
    # if the column is a key  and not already defined
    if (isAKey(\@{$descr->{keys}}, $col)) { 
       if ($typedefined == 0) {          
          $ret = "VARCHAR(128) NOT NULL ";  
       }
    }
    return $ret;
}

#--------------------------------------------------------------------------

=head3   

    Description: get_xcatcfg 

    Arguments:
              none 
    Returns:
              the database name from /etc/xcat/cfgloc or sqlite
    Globals:

    Error:

    Example:
	my $xcatcfg =get_xcatcfg();


=cut

#--------------------------------------------------------------------------------

sub get_xcatcfg
{
    my $xcatcfg = (defined $ENV{'XCATCFG'} ? $ENV{'XCATCFG'} : '');
    unless ($xcatcfg) {
        if (-r "/etc/xcat/cfgloc") {
	    my $cfgl;
	    open($cfgl,"<","/etc/xcat/cfgloc");
	    $xcatcfg = <$cfgl>;
	    close($cfgl);
	    chomp($xcatcfg);
	    $ENV{'XCATCFG'}=$xcatcfg; #Store it in env to avoid many file reads
        }
    }
    if ($xcatcfg =~ /^$/)
    {
        if (-d "/opt/xcat/cfg")
        {
            $xcatcfg = "SQLite:/opt/xcat/cfg";
        }
        else
        {
            if (-d "/etc/xcat")
            {
                $xcatcfg = "SQLite:/etc/xcat";
            }
        }
    }
    ($xcatcfg =~ /^$/) && die "Can't locate xCAT configuration";
    unless ($xcatcfg =~ /:/)
    {
        $xcatcfg = "SQLite:" . $xcatcfg;
    }
    return $xcatcfg;
}

#--------------------------------------------------------------------------

=head3   new

    Description: Constructor: Connects to  or Creates Database Table


    Arguments:  Table name
                0 = Connect to table
				1 = Create table
    Returns:
               Hash: Database Handle, Statement Handle, nodelist
    Globals:

    Error:

    Example:
       $nodelisttab = xCAT::Table->new("nodelist");
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub new
{
    #Constructor takes table name as argument
    #Also takes a true/false value, or assumes 0.  If something true is passed, create table
    #is requested
    my @args = @_;
    my $self  = {};
    my $proto = shift;
    $self->{tabname} = shift;
    unless (defined($xCAT::Schema::tabspec{$self->{tabname}})) { return undef; }
    $self->{schema}   = $xCAT::Schema::tabspec{$self->{tabname}};
    $self->{colnames} = \@{$self->{schema}->{cols}};
    $self->{descriptions} = \%{$self->{schema}->{descriptions}};
    my %otherargs  = @_;
    my $create = 1;
    if (exists($otherargs{'-create'}) && ($otherargs{'-create'}==0)) {$create = 0;}
    $self->{autocommit} = $otherargs{'-autocommit'};
    $self->{realautocommit} = $self->{autocommit}; #Assume we let the DB do the work, i.e. the autocommit is either not used or is not emulated by Table.pm
    unless (defined($self->{autocommit}))
    {
        $self->{autocommit} = 1;
    }
    my $class = ref($proto) || $proto;
    if ($dbworkerpid) {
        my $request = { 
            function => "new",
            tablename => $self->{tabname},
            autocommit => $self->{autocommit},
            args=>\@args,
        };
        unless (dbc_submit($request)) {
            return undef;
        }
    } else { #direct db access mode
        $self->{dbuser}="";
        $self->{dbpass}="";

	my $xcatcfg =get_xcatcfg();
        my $xcatdb2schema;
        if ($xcatcfg =~ /^DB2:/) {  # for DB2 , get schema name
         my @parts =  split ( '\|', $xcatcfg);
         $xcatdb2schema = $parts[1];
         $xcatdb2schema =~ tr/a-z/A-Z/;    # convert to upper 
        }

        if ($xcatcfg =~ /^SQLite:/)
        {
            $self->{backend_type} = 'sqlite';
            $self->{realautocommit} = 1; #Regardless of autocommit semantics, only electively do autocommit due to SQLite locking difficulties
            my @path = split(':', $xcatcfg, 2);
            unless (-e $path[1] . "/" . $self->{tabname} . ".sqlite" || $create)
            {
                return undef;
            }
            $self->{connstring} =
              "dbi:" . $xcatcfg . "/" . $self->{tabname} . ".sqlite";
        }
        elsif ($xcatcfg =~ /^CSV:/)
        {
            $self->{backend_type} = 'csv';
            $xcatcfg =~ m/^.*?:(.*)$/;
            my $path = $1;
            $self->{connstring} = "dbi:CSV:f_dir=" . $path;
        }
        else #Generic DBI
        {
           ($self->{connstring},$self->{dbuser},$self->{dbpass}) = split(/\|/,$xcatcfg);
           $self->{connstring} =~ s/^dbi://;
           $self->{connstring} =~ s/^/dbi:/;
            #return undef;
        }
        if ($xcatcfg =~ /^DB2:/) {  # for DB2 ,export the INSTANCE name
           $ENV{'DB2INSTANCE'} = $self->{dbuser};
        } 
        
        my $oldumask= umask 0077;
        unless ($::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{realautocommit}}) { #= $self->{tabname};
          $::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{realautocommit}} =
            DBI->connect($self->{connstring}, $self->{dbuser}, $self->{dbpass}, {AutoCommit => $self->{realautocommit}});
         }
         umask $oldumask;

        $self->{dbh} = $::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{realautocommit}};
        #Store the Table object reference as afflicted by changes to the DBH
        #This for now is ok, as either we aren't in DB worker mode, in which case this structure would be short lived...
        #or we are in db worker mode, in which case Table objects live indefinitely
        #TODO: be able to reap these objects sanely, just in case
        push @{$dbobjsforhandle->{$::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{realautocommit}}}},\$self;
          #DBI->connect($self->{connstring}, $self->{dbuser}, $self->{dbpass}, {AutoCommit => $autocommit});
        if ($xcatcfg =~ /^SQLite:/)
        {
            my $dbexistq =
              "SELECT name from sqlite_master WHERE type='table' and name = ?";
            my $sth = $self->{dbh}->prepare($dbexistq);
            $sth->execute($self->{tabname});
            my $result = $sth->fetchrow();
            $sth->finish;
            unless (defined $result)
            {
                if ($create)
                {
                    my $str =
                      buildcreatestmt($self->{tabname},
                                      $xCAT::Schema::tabspec{$self->{tabname}},
                      $xcatcfg);
                    $self->{dbh}->do($str);
                    if (!$self->{dbh}->{AutoCommit}) {
                        $self->{dbh}->commit;
                    }
                }
                else { return undef; }
            }
        }
        elsif ($xcatcfg =~ /^CSV:/)
        {
            $self->{dbh}->{'csv_tables'}->{$self->{tabname}} =
              {'file' => $self->{tabname} . ".csv"};
            $xcatcfg =~ m/^.*?:(.*)$/;
            my $path = $1;
            if (!-e $path . "/" . $self->{tabname} . ".csv")
            {
                unless ($create)
                {
                    return undef;
                }
                my $str =
                  buildcreatestmt($self->{tabname},
                                  $xCAT::Schema::tabspec{$self->{tabname}},
                      $xcatcfg);
                $self->{dbh}->do($str);
            }
        } else { #generic DBI
           if (!$self->{dbh})
           {
			   xCAT::MsgUtils->message("S", "Could not connect to the database. Database handle not defined.");

               return undef;
           }
           my $tbexistq;
           my $dbtablename=$self->{tabname};
           my $found = 0;
           if ($xcatcfg =~ /^DB2:/) {  # for DB2 
              $dbtablename  =~ tr/a-z/A-Z/;    # convert to upper 
              $tbexistq = $self->{dbh}->table_info(undef,$xcatdb2schema,$dbtablename,'TABLE');
           } else {  
              $tbexistq = $self->{dbh}->table_info('','',$self->{tabname},'TABLE');
           }
           while (my $data = $tbexistq->fetchrow_hashref) {
            if ($data->{'TABLE_NAME'} =~ /^\"?$dbtablename\"?\z/) {
              if ($xcatcfg =~ /^DB2:/) {  # for DB2
                 if ($data->{'TABLE_SCHEM'}  =~ /^\"?$xcatdb2schema\"?\z/) {
                   # must check schema also with db2
                     $found = 1;
                       last;
                 }
              } else {  # not db2
                 $found = 1;
                 last;
              }
            }
           }

  
           unless ($found) {
              unless ($create)
              {
                 return undef;
              }
              my $str =
               buildcreatestmt($self->{tabname},
                               $xCAT::Schema::tabspec{$self->{tabname}},
                       $xcatcfg);
              $self->{dbh}->do($str);
			     $self->{dbh}->commit;  #  commit the create

              
          }
         } # end Generic DBI


       updateschema($self, $xcatcfg);
    } #END DB ACCESS SPECIFIC SECTION
    if ($self->{tabname} eq 'nodelist')
    {
        weaken($self->{nodelist} = $self);
    }
    else
    {
        $self->{nodelist} = xCAT::Table->new('nodelist',-create=>1);
    }
    bless($self, $class);
    return $self;
}

#--------------------------------------------------------------------------

=head3  updateschema

    Description: Alters table schema

    Arguments: Hash containing Database and Table Handle and schema

    Returns: None

    Globals:

    Error:

    Example:
		  $self->{tabname} = shift;
          $self->{schema}   = $xCAT::Schema::tabspec{$self->{tabname}};
          $self->{colnames} = \@{$self->{schema}->{cols}};
          updateschema($self);
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub updateschema
{

    #This determines alter table statements required..
    my $self = shift;
    my $xcatcfg = shift;
    my $descr=$xCAT::Schema::tabspec{$self->{tabname}};
    my $tn=$self->{tabname};
    my $xcatdb2schema;
    if ($xcatcfg =~ /^DB2:/) {  # for DB2 , get schema name
      my @parts =  split ( '\|', $xcatcfg);
      $xcatdb2schema = $parts[1];
      $xcatdb2schema =~ tr/a-z/A-Z/;    # convert to upper 
    }

    my @columns;
    my %dbkeys;
    if ($self->{backend_type} eq 'sqlite')
    {
        my $dbexistq =
          "PRAGMA table_info('$tn')";
        my $sth = $self->{dbh}->prepare($dbexistq);
        $sth->execute;
            my $tn=$self->{tabname};
        while ( my $col_info = $sth->fetchrow_hashref ) {
	    #print Dumper($col_info);
            my $tmp_col=$col_info->{name};
            $tmp_col =~ s/"//g;
	    push @columns, $tmp_col;
	    if ($col_info->{pk}) {
		$dbkeys{$tmp_col}=1;
	    }
	}
        $sth->finish;
    } else { #Attempt generic dbi..
       #my $sth = $self->{dbh}->column_info('','',$self->{tabname},'');
       my $sth;
       if ($xcatcfg =~ /^DB2:/) {  # for DB2 
          my $db2table = $self->{tabname};
          $db2table =~ tr/a-z/A-Z/;    # convert to upper for db2 
          $sth = $self->{dbh}->column_info(undef,$xcatdb2schema,$db2table,'%'); 
       } else {
          $sth = $self->{dbh}->column_info(undef,undef,$self->{tabname},'%'); 
       }
       while (my $cd = $sth->fetchrow_hashref) {
           #print Dumper($cd);
           push @columns,$cd->{'COLUMN_NAME'};

           #special code for old version of perl-DBD-mysql
           if (defined($cd->{mysql_is_pri_key}) && ($cd->{mysql_is_pri_key}==1)) {
               my $tmp_col=$cd->{'COLUMN_NAME'};
               $tmp_col =~ s/"//g;
               $dbkeys{$tmp_col}=1;
 	   }
       }
	foreach (@columns) { #Column names may end up quoted by database engin
		s/"//g;
	}

       #get primary keys
       if ($xcatcfg =~ /^DB2:/) {  # for DB2 
          my $db2table = $self->{tabname};
          $db2table =~ tr/a-z/A-Z/;    # convert to upper for db2 
          $sth = $self->{dbh}->primary_key_info(undef,$xcatdb2schema,$db2table); 
       } else {
          $sth = $self->{dbh}->primary_key_info(undef,undef,$self->{tabname});
       }
       if ($sth) {
           my $data = $sth->fetchall_arrayref;
           #print "data=". Dumper($data);
           foreach my $cd (@$data) {
               my $tmp_col=$cd->[3];
               $tmp_col =~ s/"//g;
               $dbkeys{$tmp_col}=1;
           }      
        }
    }

    #Now @columns reflects the *actual* columns in the database
    my $dcol;
    my $types=$descr->{types};

    foreach $dcol (@{$self->{colnames}})
    {
        unless (grep /^$dcol$/, @columns)
        {
            #TODO: log/notify of schema upgrade?
            my $datatype;
            if ($xcatcfg =~ /^DB2:/){
             $datatype=get_datatype_string_db2($dcol, $types, $tn,$descr);
            } else{
             $datatype=get_datatype_string($dcol, $xcatcfg, $types);
            }
            if ($datatype eq "TEXT") { 
	 	       if (isAKey(\@{$descr->{keys}}, $dcol)) {   # keys 
		         $datatype = "VARCHAR(128) ";
		       }
	    }

	    if (grep /^$dcol$/, @{$descr->{required}})
	    {
	 	    $datatype .= " NOT NULL";
	    }
            my $stmt =
                  "ALTER TABLE " . $self->{tabname} . " ADD $dcol $datatype";
            $self->{dbh}->do($stmt);
        }
    }

    #for existing columns that are new keys now,
    my @new_dbkeys=@{$descr->{keys}};
    my @old_dbkeys=keys %dbkeys;
    #print "new_dbkeys=@new_dbkeys;  old_dbkeys=@old_dbkeys; columns=@columns\n";
    my $change_keys=0;
    foreach my $dbkey (@new_dbkeys) {
        if (! exists($dbkeys{$dbkey})) { 
	    $change_keys=1; 
            #for my sql, we do not have to recreate table, but we have to make sure the type is correct, 
            #TEXT is not a valid type for a primary key
            my $datatype;
	    if (($xcatcfg =~ /^mysql:/) || ($xcatcfg =~ /^DB2:/)) {  
               if ($xcatcfg =~ /^mysql:/) { 
		 $datatype=get_datatype_string($dbkey, $xcatcfg, $types);
               } else {   # db2 
		 $datatype=get_datatype_string_db2($dbkey, $types, $tn,$descr);
               }
               if ($datatype eq "TEXT") { 
		    if (isAKey(\@{$descr->{keys}}, $dbkey)) {   # keys need defined length
		        $datatype = "VARCHAR(128) ";
		    }
		}
		
		if (grep /^$dbkey$/, @{$descr->{required}})
		{
		    $datatype .= " NOT NULL";
		}
		my $stmt =
		    "ALTER TABLE " . $self->{tabname} . " MODIFY COLUMN $dbkey $datatype";
		print "stmt=$stmt\n";
		$self->{dbh}->do($stmt);
		if ($self->{dbh}->errstr) {
		    xCAT::MsgUtils->message("S", "Error changing the keys for table " . $self->{tabname} .":" . $self->{dbh}->errstr);
		}
	    }
        }
    }
    #check for cloumns that used to be keys but now are not
    if (!$change_keys) {
	foreach(keys %dbkeys) {
	    if (! isAKey(\@new_dbkeys, $_)) { 
		$change_keys=1;
		last;
	    }
	}
    }

    #finally drop the old keys and add the new keys
    if ($change_keys) {
	if ($xcatcfg =~ /^mysql:/) {  #for mysql, just alter the table
	    my $tmp=join(',',@new_dbkeys); 
	    my $stmt =
	        "ALTER TABLE " . $self->{tabname} . " DROP PRIMARY KEY, ADD PRIMARY KEY ($tmp)";
	    print "stmt=$stmt\n";
	    $self->{dbh}->do($stmt);
            if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error changing the keys for table " . $self->{tabname} .":" . $self->{dbh}->errstr);
	    }
	} else { #for the rest, recreate the table
            #print "need to change keys\n";
            my $btn=$tn . "_xcatbackup";
            
            #remove the backup table just in case;
            #my $str="DROP TABLE $btn";
	    #$self->{dbh}->do($str);

	    #rename the table name to name_xcatbackup
	    my $str = "ALTER TABLE $tn RENAME TO $btn";
	    $self->{dbh}->do($str);
	    if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error renaming the table from $tn to $btn:" . $self->{dbh}->errstr);
	    }

	    #create the table again
	    $str = 
                  buildcreatestmt($tn,
                                  $descr,
				  $xcatcfg);
	    $self->{dbh}->do($str);
	    if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error recreating table $tn:" . $self->{dbh}->errstr);
	    }

            #copy the data from backup to the table
            $str = "INSERT INTO $tn SELECT * FROM $btn";
	    $self->{dbh}->do($str);
	    if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error copying data from table $btn to $tn:" . $self->{dbh}->errstr);
	    } else {
		#drop the backup table
		$str = "DROP TABLE $btn";
		$self->{dbh}->do($str);
	    }
 
            if (!$self->{dbh}->{AutoCommit}) {
                $self->{dbh}->commit;
           }

	}
    }
}

#--------------------------------------------------------------------------

=head3  setNodeAttribs

    Description: Set attributes values on the node input to the routine

    Arguments:
               Hash: Database Handle, Statement Handle, nodelist
               Node name
			   Attribute hash
    Returns:

    Globals:

    Error:

    Example:
       my $mactab = xCAT::Table->new('mac',-create=>1);
	   $mactab->setNodeAttribs($node,{mac=>$mac});
	   $mactab->close();

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub setNodeAttribs
{
    my $self = shift;
    my $node = shift;
    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
        $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    };
    return $self->setAttribs({$nodekey => $node}, @_);
}

#--------------------------------------------------------------------------

=head3  addNodeAttribs

    Description: Add new attributes input to the routine to the nodes

    Arguments:
           Hash of new attributes
    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub addNodeAttribs
{
    my $self = shift;
    return $self->addAttribs('node', @_);
}

#--------------------------------------------------------------------------

=head3  addAttribs

    Description: add new attributes

    Arguments:
               Hash: Database Handle, Statement Handle, nodelist
               Key name
		       Key value
			   Hash reference of column-value pairs to set
    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub addAttribs
{
    my $self   = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'addAttribs',@_);
    }
    if (not $self->{intransaction} and not $self->{autocommit} and $self->{realautocommit}) {
        $self->{intransaction}=1;
        $self->{dbh}->{AutoCommit}=0;
    }
    my $key    = shift;
    my $keyval = shift;
    my $elems  = shift;
    my $cols   = "";
    my @bind   = ();
    @bind = ($keyval);
    $cols = "$key,";

    for my $col (keys %$elems)
    {
        $cols = $cols . $col . ",";
        if (ref($$elems{$col}))
        {
            push @bind, ${$elems}{$col}->[0];
        }
        else
        {
            push @bind, $$elems{$col};
        }
    }
    chop($cols);
    my $qstring = 'INSERT INTO ' . $self->{tabname} . " ($cols) VALUES (";
    for (@bind)
    {
        $qstring = $qstring . "?,";
    }
    $qstring =~ s/,$/)/;
    my $sth = $self->{dbh}->prepare($qstring);
    $sth->execute(@bind);

    #$self->{dbh}->commit;

    #notify the interested parties
    my $notif = xCAT::NotifHandler->needToNotify($self->{tabname}, 'a');
    if ($notif == 1)
    {
        my %new_notif_data;
        $new_notif_data{$key} = $keyval;
        foreach (keys %$elems)
        {
            $new_notif_data{$_} = $$elems{$_};
        }
        xCAT::NotifHandler->notify("a", $self->{tabname}, [0],
                                          \%new_notif_data);
    }
    $sth->finish();

}

#--------------------------------------------------------------------------

=head3 rollback

    Description:  rollback changes

    Arguments:
              Database Handle
    Returns:
           none
    Globals:

    Error:

    Example:

       my $tab = xCAT::Table->new($table,-create =>1,-autocommit=>0);
	   $tab->rollback();

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub rollback
{
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'rollback',@_);
    }
    $self->{dbh}->rollback;
    if ($self->{intransaction} and not $self->{autocommit} and $self->{realautocommit}) {
        $self->{intransaction}=0;
        $self->{dbh}->{AutoCommit}=1;
    }
}

#--------------------------------------------------------------------------

=head3 commit

    Description:
             Commit changes
    Arguments:
        Database Handle
    Returns:
       none
    Globals:

    Error:

    Example:
       my $tab = xCAT::Table->new($table,-create =>1,-autocommit=>0);
	   $tab->commit();

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub commit
{
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'commit',@_);
    }
    $self->{dbh}->commit;
    if ($self->{intransaction} and not $self->{autocommit} and $self->{realautocommit}) {
        $self->{intransaction}=0;
        $self->{dbh}->{AutoCommit}=1;
    }
}

#--------------------------------------------------------------------------

=head3 setAttribs

    Description:

    Arguments:
         Key name
		 Key value
		 Hash reference of column-value pairs to set

    Returns:
         None
    Globals:

    Error:

    Example:
       my $tab = xCAT::Table->new( 'ppc', -create=>1, -autocommit=>0 );
	   $keyhash{'node'}    = $name;
	   $updates{'type'}    = lc($type);
	   $updates{'id'}      = $lparid;
	   $updates{'hcp'}     = $server;
	   $updates{'profile'} = $prof;
	   $updates{'frame'}   = $frame;
	   $updates{'mtms'}    = "$model*$serial";
	   $tab->setAttribs( \%keyhash,\%updates );
	   $tab->commit;

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub setAttribs
{

    #Takes three arguments:
    #-Key name
    #-Key value
    #-Hash reference of column-value pairs to set
    my $xcatcfg =get_xcatcfg();
    my $self     = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'setAttribs',@_);
    }
    my $pKeypairs=shift;
    my %keypairs = ();
    if ($pKeypairs != undef) { %keypairs = %{$pKeypairs}; }

    #my $key = shift;
    #my $keyval=shift;
    my $elems = shift;
    my $cols  = "";
    my @bind  = ();
    my $action;
    my @notif_data;
    my $qstring;
    $qstring = "SELECT * FROM " . $self->{tabname} . " WHERE ";
    my @qargs   = ();
    my $query;
    my $data;
    if (not $self->{intransaction} and not $self->{autocommit} and $self->{realautocommit}) {
        $self->{intransaction}=1;
        $self->{dbh}->{AutoCommit}=0;
    }
    if (($pKeypairs != undef) && (keys(%keypairs)>0)) {
	foreach (keys %keypairs)
	{

            if ($xcatcfg =~ /^mysql:/) {  #for mysql
	      $qstring .= q(`) . $_ . q(`) . " = ? AND ";  
            } else {
                 if ($xcatcfg =~ /^DB2:/) { # for DB2
	            $qstring .= "\"$_\" LIKE ? AND ";  
              
                 } else { # for other dbs
	           $qstring .= "$_ = ? AND "; 
                 }  
            }  

	    push @qargs, $keypairs{$_};
	    
	}
	$qstring =~ s/ AND \z//;
         #print "this is qstring1: $qstring\n";
	$query = $self->{dbh}->prepare($qstring);
	$query->execute(@qargs);
	
	#get the first row
	$data = $query->fetchrow_arrayref();
	if (defined $data)
	{
	    $action = "u";
	}
	else
	{
	    $action = "a";
	}
    } else { $action = "a";}

    #prepare the notification data
    my $notif =
      xCAT::NotifHandler->needToNotify($self->{tabname}, $action);
    if ($notif == 1)
    {
        if ($action eq "u")
        {

            #put the column names at the very front
            push(@notif_data, $query->{NAME});

            #copy the data out because fetchall_arrayref overrides the data.
            my @first_row = @$data;
            push(@notif_data, \@first_row);

            #get the rest of the rows
            my $temp_data = $query->fetchall_arrayref();
            foreach (@$temp_data)
            {
                push(@notif_data, $_);
            }
        }
    }

    if ($query) {
	$query->finish();
    }

    if ($action eq "u")
    {

        #update the rows
        $action = "u";
        for my $col (keys %$elems)
        {
           if ($xcatcfg =~ /^DB2:/) {  #for DB2 
             my $colsq = q(") . $col . q(");  # quote columns
             $cols = $cols . $colsq . " = ?,";
           } else {
             $cols = $cols . $col . " = ?,";
           }
            push @bind, (($$elems{$col} =~ /NULL/) ? undef: $$elems{$col});
        }
        chop($cols);
        my $cmd ;

        $cmd = "UPDATE " . $self->{tabname} . " set $cols where ";
        foreach (keys %keypairs)
        {
            if (ref($keypairs{$_}))
            {
                if ($xcatcfg =~ /^mysql:/) {  #for mysql
                  $cmd .= q(`) . $_ . q(`) . " = '" . $keypairs{$_}->[0] . "' AND ";
                } else { 
                   if ($xcatcfg =~ /^DB2:/) {  #for DB2 
                     $cmd .= "\"$_\"" . " = '" . $keypairs{$_}->[0] . "' AND ";
                   } else {  # other dbs
                     $cmd .= "$_" . " = '" . $keypairs{$_}->[0] . "' AND ";
                   }
                }
            }
            else
            {
                if ($xcatcfg =~ /^mysql:/) {  #for mysql
                  $cmd .= q(`) . $_ . q(`) . " = '" . $keypairs{$_} . "' AND ";
                } else {  
                   if ($xcatcfg =~ /^DB2:/) {  #for DB2 
                     $cmd .= "\"$_\"" . " = '" . $keypairs{$_} . "' AND ";
                   } else {  # other dbs
                     $cmd .= "$_" . " = '" . $keypairs{$_} . "' AND ";
                   }
                }
            }
        }
        $cmd =~ s/ AND \z//;
        my $sth = $self->{dbh}->prepare($cmd);
        unless ($sth) {
            return (undef,"Error attempting requested DB operation");
        }
        my $err = $sth->execute(@bind);
        if (not defined($err))
        {
            return (undef, $sth->errstr);
        }
	    $sth->finish;
    }
    else
    {
        #insert the rows
        $action = "a";
        @bind   = ();
        $cols   = "";
	my %newpairs;
	#first, merge the two structures to a single hash
        foreach (keys %keypairs)
        {
	    $newpairs{$_} = $keypairs{$_};
	}
        my $needinsert=0;
        for my $col (keys %$elems)
        {
	        $newpairs{$col} = $$elems{$col};
            if (defined $newpairs{$col} and not $newpairs{$col} eq "") {
               $needinsert=1;
            }
        }
        unless ($needinsert) {  #Don't bother inserting truly blank lines
            return;
        }
	foreach (keys %newpairs) {

	   if ($xcatcfg =~ /^mysql:/) {  #for mysql
              $cols .= q(`) . $_ . q(`) . ","; 
           } else {
               if ($xcatcfg =~ /^DB2:/) {  #for DB2
                   $cols .= "\"$_\"" . ",";
               } else {
                $cols .= $_ . ","; # for other dbs 
               }  
            }  
            push @bind, $newpairs{$_};
        }
        chop($cols);
        my $qstring = 'INSERT INTO ' . $self->{tabname} . " ($cols) VALUES (";
        for (@bind)
        {
            $qstring = $qstring . "?,";
        }
        $qstring =~ s/,$/)/;
        my $sth = $self->{dbh}->prepare($qstring);
        my $err = $sth->execute(@bind);
        if (not defined($err))
        {
            return (undef, $sth->errstr);
        }
	    $sth->finish;
    }

    $self->_refresh_cache(); #cache is invalid, refresh
    #notify the interested parties
    if ($notif == 1)
    {
        #create new data ref
        my %new_notif_data = %keypairs;
        foreach (keys %$elems)
        {
            $new_notif_data{$_} = $$elems{$_};
        }
        xCAT::NotifHandler->notify($action, $self->{tabname},
                                          \@notif_data, \%new_notif_data);
    }
    return 0;
}

#--------------------------------------------------------------------------

=head3 setAttribsWhere

    Description:
       This function sets the attributes for the rows selected by the where clause.
    Warning, because we support mulitiple databases (SQLite,MySQL and DB2) that
    require different syntax.  Any code using this routine,  must call the 
    Utils->getDBName routine and code the where clause that is appropriate for
    each supported database.

    Arguments:
         Where clause.
         Note: if the Where clause contains any reserved keywords like
         keys from the site table,  then you will have to code them in backticks
         for MySQL  and not in backticks for Postgresql.
	 Hash reference of column-value pairs to set
    Returns:
         None
    Globals:
    Error:
    Example:
       my $tab = xCAT::Table->new( 'ppc', -create=>1, -autocommit=>1 );
	   $updates{'type'}    = lc($type);
	   $updates{'id'}      = $lparid;
	   $updates{'hcp'}     = $server;
	   $updates{'profile'} = $prof;
	   $updates{'frame'}   = $frame;
	   $updates{'mtms'}    = "$model*$serial";
	   $tab->setAttribsWhere( "node in ('node1', 'node2', 'node3')", \%updates );
    Comments:
        none
=cut
#--------------------------------------------------------------------------------
sub setAttribsWhere
{
    #Takes three arguments:
    #-Where clause
    #-Hash reference of column-value pairs to set
    my $self     = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'setAttribsWhere',@_);
    }
    my $where_clause = shift;
    my $elems = shift;
    my $cols  = "";
    my @bind  = ();
    my $action;
    my @notif_data;
    if (not $self->{intransaction} and not $self->{autocommit} and $self->{realautocommit}) {
        $self->{intransaction}=1;
        $self->{dbh}->{AutoCommit}=0;
    }
    my $qstring = "SELECT * FROM " . $self->{tabname} . " WHERE " . $where_clause;
    my @qargs   = ();
    my $query = $self->{dbh}->prepare($qstring);
    $query->execute(@qargs);

    #get the first row
    my $data = $query->fetchrow_arrayref();
    if (defined $data){  $action = "u";}
    else { return (0, "no rows selected."); }

    #prepare the notification data
    my $notif =
      xCAT::NotifHandler->needToNotify($self->{tabname}, $action);
    if ($notif == 1)
    {
      #put the column names at the very front
      push(@notif_data, $query->{NAME});

      #copy the data out because fetchall_arrayref overrides the data.
      my @first_row = @$data;
      push(@notif_data, \@first_row);
      #get the rest of the rows
      my $temp_data = $query->fetchall_arrayref();
      foreach (@$temp_data) {
        push(@notif_data, $_);
      }
    }

    $query->finish();

    #update the rows
    for my $col (keys %$elems)
    {
      $cols = $cols . $col . " = ?,";
      push @bind, (($$elems{$col} =~ /NULL/) ? undef: $$elems{$col});
    }
    chop($cols);
    my $cmd = "UPDATE " . $self->{tabname} . " set $cols where " . $where_clause;
    my $sth = $self->{dbh}->prepare($cmd);
    my $err = $sth->execute(@bind);
    if (not defined($err))
    {
      return (undef, $sth->errstr);
    }

    #notify the interested parties
    if ($notif == 1)
    {
      #create new data ref
      my %new_notif_data = ();
      foreach (keys %$elems)
      {
        $new_notif_data{$_} = $$elems{$_};
      }
      xCAT::NotifHandler->notify($action, $self->{tabname},
                                 \@notif_data, \%new_notif_data);
    }
    $sth->finish;
    return 0;
}


#--------------------------------------------------------------------------
=head3 setNodesAttribs

    Description: Unconditionally assigns the requested values to tables for a list of nodes

    Arguments:
        'self' (implicit in OO style call)
        A reference to a two-level hash similar to:
            {
                'n1' => {
                    comments => 'foo',
                    data => 'foo2'
                },
                'n2' => {
                    comments => 'bar',
                    data => 'bar2'
                }
            }

     Alternative arguments (same set of data to be applied to multiple nodes):
        'self'
        Reference to a list of nodes (no noderanges, just nodes)
        A hash of attributes to set, like in 'setNodeAttribs'

    Returns:
=cut
#--------------------------------------------------------------------------
sub setNodesAttribs {
#This is currently a stub to be filled out with at scale enhancements.  It will be a touch more complex than getNodesAttribs, due to the notification
#The three steps should be:
#-Query table and divide nodes into list to update and list to insert
#-Update intelligently with respect to scale
#-Insert intelligently with respect to scale (prepare one statement, execute many times, other syntaxes not universal)
#Intelligently in this case means folding them to some degree.  Update where clauses will be longer, but must be capped to avoid exceeding SQL statement length restrictions on some DBs.  Restricting even all the way down to 256 could provide better than an order of magnitude better performance though
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'setNodesAttribs',@_);
    }
    my $nodelist = shift;
    my $keyset = shift;
    my %cols = ();
    my @orderedcols=();
    my $oldac = $self->{dbh}->{AutoCommit}; #save autocommit state
    $self->{dbh}->{AutoCommit}=0; #turn off autocommit for performance
    my $hashrec;
    my $colsmatch=1;
    if (ref $nodelist eq 'HASH') { # argument of the form  { n001 => { groups => 'something' }, n002 => { groups => 'other' } }
        $hashrec = $nodelist;
        my @nodes = keys %$nodelist;
        $nodelist = \@nodes;
        my $firstpass=1;
        foreach my $node (keys %$hashrec) { #Determine whether the passed structure is trying to set the same columns 
                                   #for every node to determine if the short path can work or not
            if ($firstpass) {
                $firstpass=0;
                foreach (keys %{$hashrec->{$node}}) {
                    $cols{$_}=1;
                }
            } else {
                foreach (keys %{$hashrec->{$node}}) { #make sure all columns in this entry are in the first
                    unless (defined $cols{$_}) {
                        $colsmatch=0;
                        last;
                    }
                }
                foreach my $col (keys %cols) { #make sure this entry does not lack any columns from the first
                    unless (defined $hashrec->{$node}->{$col}) {
                        $colsmatch=0;
                        last;
                    }
                }
            }
        }

    } else { #the legacy calling style with a list reference and a single hash reference of col=>va/ue pairs
        $hashrec = {};
        foreach (@$nodelist) {
            $hashrec->{$_}=$keyset;
        }
        foreach (keys %$keyset) {
            $cols{$_}=1;
        }
    }
    #revert to the old way if notification is required or asymettric setNodesAttribs was requested with different columns
    #for different nodes
    if (not $colsmatch or xCAT::NotifHandler->needToNotify($self->{tabname}, 'u') or xCAT::NotifHandler->needToNotify($self->{tabname}, 'a')) {
        #TODO: enhance performance of this case too, for now just call the notification-capable code per node
        foreach  (keys %$hashrec) {
            $self->setNodeAttribs($_,$hashrec->{$_});
        }
        $self->{dbh}->commit; #commit pending transactions
        $self->{dbh}->{AutoCommit}=$oldac;#restore autocommit semantics
        return;
    }
    #this code currently is notification incapable.  It enhances scaled setting by:
    #-turning off autocommit if on (done for above code too, but to be clear document the fact here too
    #-executing one select statement per set of nodes instead of per node (chopping into 1,000 node chunks for SQL statement length
    #-aggregating update statements
    #-preparing one insert statement and re-execing it (SQL-92 multi-row insert isn't ubiquitous enough)

    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
       $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    };
    @orderedcols = keys %cols; #pick a specific column ordering explicitly to assure consistency
    use Data::Dumper;
    my $nodesatatime = 999; #the update case statement will consume '?' of which we are allowed 999 in the most restricted DB we support
    #ostensibly, we could do 999 at a time for the select statement, and subsequently limit the update aggregation only
    #to get fewer sql statements, but the code is probably more complex than most people want to read
    #at the moment anyway
    my @currnodes = splice(@$nodelist,0,$nodesatatime); #Do a few at a time to stay under max sql statement length and max variable count
    my $insertsth; #if insert is needed, this will hold the single prepared insert statement
    my $upsth;
    while (scalar @currnodes) {
        my %updatenodes=();
        my %insertnodes=();
        my $qstring = "SELECT * FROM " . $self->{tabname} . " WHERE $nodekey in (";#sort nodes into inserts and updates
        $qstring .= '?, ' x scalar(@currnodes);
        $qstring =~ s/, $/)/;
    	my $query = $self->{dbh}->prepare($qstring);
    	$query->execute(@currnodes);
        my $rec;
	    while ($rec = $query->fetchrow_hashref()) {
            $updatenodes{$rec->{$nodekey}}=1;
        }
        if (scalar keys %updatenodes < scalar @currnodes) {
            foreach (@currnodes) {
                unless ($updatenodes{$_}) {
                    $insertnodes{$_}=1;
                }
            }
        }
        my $havenodecol; #whether to put node first in execute arguments or let it go naturally
        if (not $insertsth and keys %insertnodes) { #prepare an insert statement since one will be needed
            my $columns="";
            my $bindhooks="";
            $havenodecol = defined $cols{$nodekey};
            unless ($havenodecol) {
                $columns = "$nodekey, ";
                $bindhooks="?, ";
            }
            $columns .= join(", ",@orderedcols);
            $bindhooks .= "?, " x scalar @orderedcols;
            $bindhooks =~ s/, $//;
            $columns =~ s/, $//;
            my $instring = "INSERT INTO ".$self->{tabname}." ($columns) VALUES ($bindhooks)";
            print $instring;
            $insertsth = $self->{dbh}->prepare($instring);
        }
        foreach my $node (keys %insertnodes) {
            my @args = ();
            unless ($havenodecol) {
                @args = ($node);
            }
            foreach my $col (@orderedcols) {
                push @args,$hashrec->{$node}->{$col};
            }
            $insertsth->execute(@args);
        }
        if (not $upsth and keys %updatenodes) { #prepare an insert statement since one will be needed
            my $upstring = "UPDATE ".$self->{tabname}." set ";
            foreach my $col (@orderedcols) { #try aggregating requests.  Could also see about single prepare, multiple executes instead
                $upstring .= "$col = ?, ";
            }
            if (grep { $_ eq $nodekey } @orderedcols) {
                $upstring =~ s/, \z//;
            } else {
                $upstring =~ s/, \z/ where $nodekey = ?/;
            }
            $upsth = $self->{dbh}->prepare($upstring);
        }
        if (scalar keys %updatenodes) {
            my $upstring = "UPDATE ".$self->{tabname}." set ";
            foreach my $node (keys %updatenodes) {
                my @args=();
                foreach my $col (@orderedcols) { #try aggregating requests.  Could also see about single prepare, multiple executes instead
                    push @args,$hashrec->{$node}->{$col};
                }
                push @args,$node;
                $upsth->execute(@args);
            }
        }
        @currnodes = splice(@$nodelist,0,$nodesatatime);
    }
    $self->{dbh}->commit; #commit pending transactions
    $self->{dbh}->{AutoCommit}=$oldac;#restore autocommit semantics
    $self->_refresh_cache(); #cache is invalid, refresh
}

#--------------------------------------------------------------------------

=head3 getNodesAttribs

    Description: Retrieves the requested attributes for a node list

    Arguments:
            Table handle ('self')
			List ref of nodes
	        Attribute type array
    Returns:

			two layer hash reference (->{nodename}->{attrib} 
    Globals:

    Error:

    Example:
           my $ostab = xCAT::Table->new('nodetype');
		   my $ent = $ostab->getNodesAttribs(\@nodes,['profile','os','arch']);
           if ($ent) { print $ent->{n1}->{profile}

    Comments:
        Using this function will clue the table layer into the atomic nature of the request, and allow shortcuts to be taken as appropriate to fulfill the request at scale.

=cut

#--------------------------------------------------------------------------------
sub getNodesAttribs {
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getNodesAttribs',@_);
    }
    my $nodelist = shift;
    my %options=();
    my @attribs;
    if (ref $_[0]) {
        @attribs = @{shift()};
        %options = @_;
    } else {
        @attribs = @_;
    }
    if (scalar($nodelist) > $cachethreshold) {
        $self->{_use_cache} = 0;
        $self->{nodelist}->{_use_cache}=0;
        if ($self->{tabname} eq 'nodelist') { #a sticky situation
            my @locattribs=@attribs;
            unless (grep(/^node$/,@locattribs)) {
                push @locattribs,'node';
            }
            unless (grep(/^groups$/,@locattribs)) {
                push @locattribs,'node';
            }
            $self->_build_cache(\@locattribs);
        } else {
            $self->_build_cache(\@attribs);
            $self->{nodelist}->_build_cache(['node','groups']);
        }
        $self->{_use_cache} = 1;
        $self->{nodelist}->{_use_cache}=1;
    }
    my $rethash;
    foreach (@$nodelist) {
        my @nodeentries=$self->getNodeAttribs($_,\@attribs,%options);
        $rethash->{$_} = \@nodeentries; #$self->getNodeAttribs($_,\@attribs);
    }
    $self->_clear_cache;
    $self->{_use_cache} = 0;
    $self->{nodelist}->_clear_cache;
    $self->{nodelist}->{_use_cache} = 0;
    return $rethash;
}

sub _refresh_cache { #if cache exists, force a rebuild, leaving reference counts alone
    my $self = shift; #dbworker check not currently required
    if ($self->{_use_cache}) { #only do things if cache is set up
        $self->_build_cache(1); #for now, rebuild the whole thing.
                    #in the future, a faster cache update may be possible
                    #however, the payoff may not be worth it
                    #as this case is so rare
                    #the only known case that trips over this is:
                    #1st noderange starts being expanded
                    #the nodelist is updated by another process
                    #2nd noderange  starts being expanded (sharing first cache)
                    #   (uses stale nodelist data and misses new nodes, the error)
                    #1st noderange finishes
                    #2nd noderange finishes
    }
    return;
}

sub _clear_cache { #PRIVATE FUNCTION TO EXPIRE CACHED DATA EXPLICITLY
    #This is no longer sufficient to do at destructor time, as Table objects actually live an indeterminite amount of time now
    #TODO: only clear cache if ref count mentioned in build_cache is 1, otherwise decrement ref count
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'_clear_cache',@_);
    }
    if ($self->{_cache_ref} > 1) { #don't clear the cache if there are still live references
        $self->{_cache_ref} -= 1;
        return;
    } elsif ($self->{_cache_ref} == 1) { #If it is 1, decrement to zero and carry on
        $self->{_cache_ref} = 0;
    }
    #it shouldn't have been zero, but whether it was 0 or 1, ensure that the cache is gone
    $self->{_use_cache}=0; # Signal slow operation to any in-flight operations that may fail with empty cache
    undef $self->{_tablecache};
    undef $self->{_nodecache};
}

sub _build_cache { #PRIVATE FUNCTION, PLEASE DON'T CALL DIRECTLY
#TODO: increment a reference counter type thing to preserve current cache
#Also, if ref count is 1 or greater, and the current cache is less than 3 seconds old, reuse the cache?
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'_build_cache',@_);
    }
    my $attriblist = shift;
    my $refresh = not ref $attriblist; #if attriblist is not a reference, it is a refresh request
    if (not $refresh and $self->{_cache_ref}) { #we have active cache reference, increment counter and return
        #TODO: ensure that the cache isn't somehow still ludirously old
        $self->{_cache_ref} += 1;
        return;
    }
    #If here, _cache_ref indicates no cache
    if (not $refresh) {
        $self->{_cache_ref} = 1;
    }
    my $oldusecache = $self->{_use_cache}; #save previous 'use_cache' setting
    $self->{_use_cache} = 0; #This function must disable cache 
                            #to function
    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
        $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    };
    unless (grep /^$nodekey$/,@$attriblist) {
        push @$attriblist,$nodekey;
    }
    my @tabcache = $self->getAllAttribs(@$attriblist);
    $self->{_tablecache} = \@tabcache;
    $self->{_nodecache}  = {};
    if ($tabcache[0]->{$nodekey}) {
        foreach(@tabcache) {
            push @{$self->{_nodecache}->{$_->{$nodekey}}},$_;
        }
    }

    $self->{_use_cache} = $oldusecache; #Restore setting to previous value
    $self->{_cachestamp} = time;
}
#--------------------------------------------------------------------------

=head3 getNodeAttribs

    Description: Retrieves the requested attribute

    Arguments:
            Table handle
			Noderange
	        Attribute type array
    Returns:

			Attribute hash ( key attribute type)
    Globals:

    Error:

    Example:
           my $ostab = xCAT::Table->new('nodetype');
		   my $ent = $ostab->getNodeAttribs($node,['profile','os','arch']);

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getNodeAttribs
{
    my $self    = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getNodeAttribs',@_);
    }
    my $node    = shift;
    my @attribs;
    my %options = ();
    if (ref $_[0]) {
        @attribs = @{shift()};
        %options = @_;
    } else {
        @attribs = @_;
    }
    my $datum;
    my @data = $self->getNodeAttribs_nosub($node, \@attribs,%options);
    #my ($datum, $extra) = $self->getNodeAttribs_nosub($node, \@attribs);
    #if ($extra) { return undef; }    # return (undef,"Ambiguous query"); }
    defined($data[0])
      || return undef;    #(undef,"No matching entry found in configuration");
    my $attrib;
    foreach $datum (@data) {
    foreach $attrib (@attribs)
    {
        unless (defined $datum->{$attrib}) {
            #skip undefined values, save time
            next;
        }

        if ($datum->{$attrib} =~ /^\/[^\/]*\/[^\/]*\/$/)
        {
            my $exp = substr($datum->{$attrib}, 1);
            chop $exp;
            my @parts = split('/', $exp, 2);
            $node =~ s/$parts[0]/$parts[1]/;
            $datum->{$attrib} = $node;
        }
        elsif ($datum->{$attrib} =~ /^\|.*\|.*\|$/)
        {

            #Perform arithmetic and only arithmetic operations in bracketed issues on the right.
            #Tricky part:  don't allow potentially dangerous code, only eval if
            #to-be-evaled expression is only made up of ()\d+-/%$
            #Futher paranoia?  use Safe module to make sure I'm good
            my $exp = substr($datum->{$attrib}, 1);
            chop $exp;
            my @parts = split('\|', $exp, 2);
            my $curr;
            my $next;
            my $prev;
            my $retval = $parts[1];
            ($curr, $next, $prev) =
              extract_bracketed($retval, '()', qr/[^()]*/);

            unless($curr) { #If there were no paramaters to save, treat this one like a plain regex
               $retval = $node;
               $retval =~ s/$parts[0]/$parts[1]/;
               $datum->{$attrib} = $retval;
               if ($datum->{$attrib} =~ /^$/) {
                  #If regex forces a blank, act like a normal blank does
                  delete $datum->{$attrib};
               }
               next; #skip the redundancy that follows otherwise
            }
            while ($curr)
            {

                #my $next = $comps[0];
                if ($curr =~ /^[\{\}()\-\+\/\%\*\$\d]+$/ or $curr =~ /^\(sprintf\(["'%\dcsduoxefg]+,\s*[\{\}()\-\+\/\%\*\$\d]+\)\)$/ )
                {
                    use integer
                      ; #We only allow integer operations, they are the ones that make sense for the application
                    my $value = $node;
                    $value =~ s/$parts[0]/$curr/ee;
                    $retval = $prev . $value . $next;
                }
                else
                {
                    print "$curr is bad\n";
                }
                ($curr, $next, $prev) =
                  extract_bracketed($retval, '()', qr/[^()]*/);
            }
            #At this point, $retval is the expression after being arithmetically contemplated, a generated regex, and therefore
            #must be applied in total
            my $answval = $node;
            $answval =~ s/$parts[0]/$retval/;
            $datum->{$attrib} = $answval; #$retval;

            #print Data::Dumper::Dumper(extract_bracketed($parts[1],'()',qr/[^()]*/));
            #use text::balanced extract_bracketed to parse earch atom, make sure nothing but arith operators, parans, and numbers are in it to guard against code execution
        }
        if ($datum->{$attrib} =~ /^$/) {
            #If regex forces a blank, act like a normal blank does
            delete $datum->{$attrib};
        }
    }
    }
    return wantarray ? @data : $data[0];
}

#--------------------------------------------------------------------------

=head3 getNodeAttribs_nosub

    Description:

    Arguments:

    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getNodeAttribs_nosub
{
    my $self   = shift;
    my $node   = shift;
    my $attref = shift;
    my %options = @_;
    my @data;
    my $datum;
    my @tents;
    my $return = 0;
    @tents = $self->getNodeAttribs_nosub_returnany($node, $attref,%options);
    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
        $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    }
    foreach my $tent (@tents) {
      $datum={};
      foreach (@$attref)
      {
        if ($tent and defined($tent->{$_}))
        {
           $return = 1;
           $datum->{$_} = $tent->{$_};
           if ($options{withattribution} and $_ ne $nodekey) {
               $datum->{'!!xcatgroupattribution!!'}->{$_} = $tent->{'!!xcatsourcegroup!!'};
           }
        } else { #attempt to fill in gapped attributes
           unless (scalar(@$attref) <= 1) {
             my $sent = $self->getNodeAttribs($node, [$_],%options);
             if ($sent and defined($sent->{$_})) {
                 $return = 1;
                 $datum->{$_} = $sent->{$_};
                if ($options{withattribution} and $_ ne $nodekey) {
                   $datum->{'!!xcatgroupattribution!!'}->{$_} = $sent->{'!!xcatgroupattribution!!'}->{$_};
               }
             }
           }
        }
      }
      push(@data,$datum);
    }
    if ($return)
    {
        return wantarray ? @data : $data[0];
    }
    else
    {
        return undef;
    }
}

#--------------------------------------------------------------------------

=head3 getNodeAttribs_nosub_returnany

    Description:  not used, kept for reference 

    Arguments:

    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getNodeAttribs_nosub_returnany_old
{    #This is the original function
    my $self    = shift;
    my $node    = shift;
    my @attribs = @{shift()};
    my %options = @_;
    my @results;

    #my $recurse = ((scalar(@_) == 1) ?  shift : 1);
    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
        $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    };
    @results = $self->getAttribs({$nodekey => $node}, @attribs);
    my $data = $results[0];
    if (!defined($data))
    {
        my ($nodeghash) =
          $self->{nodelist}->getAttribs({node => $node}, 'groups');
        unless (defined($nodeghash) && defined($nodeghash->{groups}))
        {
            return undef;
        }
        my @nodegroups = split(/,/, $nodeghash->{groups});
        my $group;
        foreach $group (@nodegroups)
        {
            @results = $self->getAttribs({$nodekey => $group}, @attribs);
	    $data = $results[0];
            if ($data != undef)
            {
                foreach (@results) {
                   if ($_->{$nodekey}) { $_->{$nodekey} = $node; }
                   if ($options{withattribution}) { $_->{'!!xcatsourcegroup!!'} = $group; }
                };
                return @results;
            }
        }
    }
    else
    {

        #Don't need to 'correct' node attribute, considering result of the if that governs this code block?
        return @results;
    }
    return undef;    #Made it here, config has no good answer
}

sub getNodeAttribs_nosub_returnany
{
	my $self    = shift;
    my $node    = shift;
    my @attribs = @{shift()};
    my %options = @_;
    my @results;

    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
        $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    };
    @results = $self->getAttribs({$nodekey => $node}, @attribs);
    
    my %attribsToDo;
    for(@attribs) {$attribsToDo{$_} = 0};
    
    my $attrib;
    my $result;
    
    my $data = $results[0];
    if(defined{$data}) #if there was some data for the node, loop through and check it
    {
	    foreach $result (@results)
    	{
    		foreach $attrib (keys %attribsToDo)
    		{
    			#check each item in the results to see which attributes were satisfied
    			if(defined($result->{$attrib}) && $result->{$attrib} !~ /\+=NEXTRECORD$/)
    			{
    				delete $attribsToDo{$attrib};
    			} 
    		}   
    	}
    }
    
    #find the groups for this node
    my ($nodeghash) = $self->{nodelist}->getAttribs({node => $node}, 'groups');
    
    #no groups for the node, we are done
    unless (defined($nodeghash) && defined($nodeghash->{groups}))
    {
        return @results;
    }
    
    my @nodegroups = split(/,/, $nodeghash->{groups});
    my $group;
    my @groupResults;
    my $groupResult;
    my $wasAdded; #used to keep track 
    my %attribsDone;

    foreach $group (@nodegroups)
    {
        @groupResults = $self->getAttribs({$nodekey => $group}, keys (%attribsToDo));
	    $data = $groupResults[0];
        if (defined($data))  #if some attributes came back from the query for this group
        {
            foreach $groupResult (@groupResults) {
            	$wasAdded = 0;
                if ($groupResult->{$nodekey}) { $groupResult->{$nodekey} = $node; }
                if ($options{withattribution}) { $groupResult->{'!!xcatsourcegroup!!'} = $group; }
                
                foreach $attrib (%attribsToDo) #check each unfinished attribute against the results for this group
                {
                	if(defined($groupResult->{$attrib})){
                		
                		foreach $result (@results){ #loop through our existing results to add or modify the value for this attribute
                			
                			if(defined($result->{$attrib}) && $result->{$attrib} =~/\+=NEXTRECORD$/){ #if the attribute was there and the value should be added
                				
                				$result->{$attrib} =~ s/\+=NEXTRECORD$//; #pull out the existing next record string
                				$result->{$attrib} .= " " . $groupResult->{$attrib}; #add the group result onto the end of the existing value
						if($options{withattribution}) {
							if(defined($result->{'!!xcatsourcegroup!!'})) {
								$result->{'!!xcatsourcegroup!!'} .= " " . $group;
							}
							else {
								$result->{'!!xcatsourcegroup!!'} = $group;
							}
						}
                				$wasAdded = 1; #this group result was handled
                				last;
                			}
                		
                		}
                		if(!$wasAdded){ #if there was not a value already in the results.  we know there is no entry for this
                			push(@results, $groupResult);
                		}
           				if($groupResult->{$attrib} !~ /\+=NEXTRECORD$/){ #the attribute was satisfied if it does not expect to add the next record
           					$attribsDone{$attrib} = 0;
						#delete $attribsToDo{$attrib};
           				}
                	}
                
                }
		foreach $attrib (%attribsDone) {
			if(defined($attribsToDo{$attrib})) {
				delete $attribsToDo{$attrib};
			}
		}
            }
        }
        if((keys (%attribsToDo)) == 0) #if all of the attributes are satisfied, so stop looking at the groups
        {
        	last;
        }
    }
    
    my $element;
    #run through the results and remove any "+=NEXTRECORD" ocurrances
    foreach $result (@results)
    {
    	foreach $element ($result)
    	{
    		$result->{$element} =~ s/\+=NEXTRECORD$//;
    	}
    }
    
    #Don't need to 'correct' node attribute, considering result of the if that governs this code block?
    return @results;
}


#--------------------------------------------------------------------------

=head3 getAllEntries

    Description:  Read entire table

    Arguments:
           Table handle
           "all" return all lines ( even disabled)
           Default is to return only lines that have not been disabled

    Returns:
       Hash containing all rows in table
    Globals:

    Error:

    Example:

	 my $tabh = xCAT::Table->new($table);
         my $recs=$tabh->getAllEntries(); # returns entries not disabled
         my $recs=$tabh->getAllEntries("all"); # returns all  entries

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllEntries
{
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getAllEntries',@_);
    }
    my $allentries = shift;
    my @rets;
    my $query;
    my $xcatcfg =get_xcatcfg();

    if ($allentries) { # get all lines
     $query = $self->{dbh}->prepare('SELECT * FROM ' . $self->{tabname});
    } else {  # get only enabled lines
      if ($xcatcfg =~ /^mysql:/) {  #for mysql
         $query = $self->{dbh}->prepare('SELECT * FROM '
             . $self->{tabname}
        . " WHERE " . q(`disable`) . " is NULL or " .  q(`disable`) . " in ('0','no','NO','No','nO')");

      } else {   
          if ($xcatcfg =~ /^DB2:/) {  #for DB2
              my $qstring = 
                "SELECT * FROM "
                . $self->{tabname}
                . " WHERE \"disable\" is NULL OR \"disable\" LIKE '0' OR \"disable\" LIKE 'no' OR \"disable\" LIKE 'NO' OR \"disable\" LIKE 'nO' ";
               $query =  $self->{dbh}->prepare($qstring);
 
          } else { # for other dbs
            $query = $self->{dbh}->prepare('SELECT * FROM '
             . $self->{tabname}
          . " WHERE \"disable\" is NULL or \"disable\" in ('','0','no','NO','No','nO')");
          }
      }
    }

    $query->execute();
    while (my $data = $query->fetchrow_hashref())
    {
        foreach (keys %$data)
        {
            if ($data->{$_} =~ /^$/)
            {
                $data->{$_} = undef;
            }
        }
        push @rets, $data;
    }
    $query->finish();
    return \@rets;
}

#--------------------------------------------------------------------------

=head3 getAllAttribsWhere

    Description:  Get all attributes with "where" clause

    Warning, because we support mulitiple databases (SQLite,MySQL and DB2) that
    require different syntax.  Any code using this routine,  must call the 
    Utils->getDBName routine and code the where clause that is appropriate for
    each supported database.

    Arguments:
       Database Handle
       Where clause
    Returns:
        Array of attributes
    Globals:

    Error:

    Example:
    $nodelist->getAllAttribsWhere("groups like '%".$atom."%'",'node','group');
    returns  node and group attributes
    $nodelist->getAllAttribsWhere("groups like '%".$atom."%'",'ALL');
    returns  all attributes
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllAttribsWhere
{

    #Takes a list of attributes, returns all records in the table.
    my $self        = shift;
    my $xcatcfg =get_xcatcfg();
    if ($dbworkerpid) {
        return dbc_call($self,'getAllAttribsWhere',@_);
    }
    my $whereclause = shift;
    my @attribs     = @_;
    my @results     = ();
    my $query;
    my $query2;

    if ($xcatcfg =~ /^mysql:/) {  #for mysql
           $query2='SELECT * FROM '  . $self->{tabname} . ' WHERE (' . $whereclause . ")  and  (\`disable\`  is NULL or \`disable\` in ('0','no','NO','No','nO'))";
           $query = $self->{dbh}->prepare($query2);
      } else {   
          if ($xcatcfg =~ /^DB2:/) {  #for DB2
            $query2= 'SELECT * FROM ' . $self->{tabname} . ' WHERE (' . $whereclause . " ) and (\"disable\" is NULL OR \"disable\" LIKE '0' OR \"disable\" LIKE 'no' OR  \"disable\" LIKE 'NO' OR  \"disable\" LIKE 'No' OR  \"disable\" LIKE 'nO')";
            $query = $self->{dbh}->prepare($query2);
 
           } else { # for other dbs
              $query = $self->{dbh}->prepare('SELECT * FROM '
                . $self->{tabname}
                . ' WHERE ('
                . $whereclause
                . ") and (\"disable\" is NULL or \"disable\" in ('0','no','NO','no'))");
            }
    }
    $query->execute();
    while (my $data = $query->fetchrow_hashref())
    {
        my %newrow = ();
        if ($attribs[0] eq "ALL") {  # want all attributes
           foreach (keys %$data){
           
             if ($data->{$_} =~ /^$/)
             {
                $data->{$_} = undef;
             }
           }
           push @results, $data;
        } else {  # want specific attributes
          foreach (@attribs)
          {
            unless ($data->{$_} =~ /^$/ || !defined($data->{$_}))
            { #The reason we do this is to undef fields in rows that may still be returned..
                $newrow{$_} = $data->{$_};
            }
          }
          if (keys %newrow)
          {
             push(@results, \%newrow);
          }
        }
    }
    $query->finish();
    return @results;
}

#--------------------------------------------------------------------------

=head3 getAllNodeAttribs

    Description: Get all the node attributes values for the input table on the
				 attribute list

    Arguments:
                 Table handle
				 Attribute list
    Returns:
                 Array of attribute values
    Globals:

    Error:

    Example:
         my @entries = $self->{switchtab}->getAllNodeAttribs(['port','switch']);
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllNodeAttribs
{

    #Extract and substitute every node record, expanding groups and substituting as getNodeAttribs does
    my $self    = shift;
    my $xcatcfg =get_xcatcfg();
    if ($dbworkerpid) {
        return dbc_call($self,'getAllNodeAttribs',@_);
    }
    my $attribq = shift;
    my $hashretstyle = shift;
    my $rethash;
    my @results = ();
    my %donenodes
      ; #Remember those that have been done once to not return same node multiple times
    my $query;
    if ($xcatcfg =~ /^mysql:/) {  #for mysql
         $query = $self->{dbh}->prepare('SELECT node FROM '
             . $self->{tabname}
        . " WHERE " . q(`disable`) . " is NULL or " .  q(`disable`) . " in ('0','no','NO','No','nO')");
      } else {   
          if ($xcatcfg =~ /^DB2:/) {  #for DB2
            my $qstring = "Select \"node\" FROM ";
            $qstring  .= $self->{tabname};
            $qstring  .=  " WHERE \"disable\" is NULL OR \"disable\" LIKE '0' OR \"disable\" LIKE 'no' OR  \"disable\" LIKE 'NO' OR  \"disable\" LIKE 'No' OR  \"disable\" LIKE 'nO'";
            $query =  $self->{dbh}->prepare($qstring); 
          } else {  # for other dbs 
             $query =
             $self->{dbh}->prepare('SELECT node FROM '
              . $self->{tabname}
              . " WHERE \"disable\" is NULL or \"disable\" in ('','0','no','NO','no')");
          }
       }
    $query->execute();
    xCAT::NodeRange::retain_cache(1);
    $self->{_use_cache} = 0;
    $self->{nodelist}->{_use_cache}=0;
    $self->_clear_cache();
    $self->{nodelist}->_clear_cache();
    $self->_build_cache($attribq);
    $self->{nodelist}->_build_cache(['node','groups']);
    $self->{_use_cache} = 1;
    $self->{nodelist}->{_use_cache}=1;
    while (my $data = $query->fetchrow_hashref())
    {

        unless ($data->{node} =~ /^$/ || !defined($data->{node}))
        {    #ignore records without node attrib, not possible?
            my @nodes =
              xCAT::NodeRange::noderange($data->{node})
              ;    #expand node entry, to make groups expand
            #my $localhash = $self->getNodesAttribs(\@nodes,$attribq); #NOTE:  This is stupid, rebuilds the cache for every entry, FIXME
            foreach (@nodes)
            {
                if ($donenodes{$_}) { next; }
                my $attrs;
                my $nde = $_;

                #if ($self->{giveand}) { #software requests each attribute be independently inherited
                #  foreach (@attribs) {
                #    my $attr = $self->getNodeAttribs($nde,$_);
                #    $attrs->{$_}=$attr->{$_};
                #  }
                #} else {
                my @attrs =
                  $self->getNodeAttribs($_, $attribq);#@{$localhash->{$_}} #$self->getNodeAttribs($_, $attribq)
                  ;    #Logic moves to getNodeAttribs
                       #}
                 #populate node attribute by default, this sort of expansion essentially requires it.
                #$attrs->{node} = $_;
		foreach my $att (@attrs) {
			$att->{node} = $_;
		}
                $donenodes{$_} = 1;

                if ($hashretstyle) {
                    $rethash->{$_} = \@attrs; #$self->getNodeAttribs($_,\@attribs);
                } else {
                    push @results, @attrs;    #$self->getNodeAttribs($_,@attribs);
                }
            }
        }
    }
    $self->_clear_cache();
    $self->{nodelist}->_clear_cache();
    $self->{_use_cache} = 0;
    $self->{nodelist}->{_use_cache} = 0;
    xCAT::NodeRange::retain_cache(0);
    $query->finish();
    if ($hashretstyle) {
        return $rethash;
    } else {
        return @results;
    }
}

#--------------------------------------------------------------------------

=head3 getAllAttribs

    Description: Returns a list of records in the input table for the input
				 list of attributes.

    Arguments:
             Table handle
			 List of attributes
    Returns:
        Array of attribute values
    Globals:

    Error:

    Example:
        $nodelisttab = xCAT::Table->new("nodelist");
		my @attribs = ("node");
		@nodes = $nodelisttab->getAllAttribs(@attribs);
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllAttribs
{

    #Takes a list of attributes, returns all records in the table.
    my $self    = shift;
    my $xcatcfg =get_xcatcfg();
    if ($dbworkerpid) {
        return dbc_call($self,'getAllAttribs',@_);
    }
    #print "Being asked to dump ".$self->{tabname}."for something\n";
    my @attribs = @_;
    my @results = ();
    if ($self->{_use_cache}) {
        my @results;
        my $cacheline;
        CACHELINE: foreach $cacheline (@{$self->{_tablecache}}) {
            my $attrib;
            my %rethash;
            foreach $attrib (@attribs)
            {
                unless ($cacheline->{$attrib} =~ /^$/ || !defined($cacheline->{$attrib}))
                {    #To undef fields in rows that may still be returned
                    $rethash{$attrib} = $cacheline->{$attrib};
                }
            }
            if (keys %rethash)
            {
                push @results, \%rethash;
            }
        }
        if (@results)
        {
          return @results; #return wantarray ? @results : $results[0];
        }
        return undef;
    }
    my $query;
    if ($xcatcfg =~ /^mysql:/) {  #for mysql
         $query = $self->{dbh}->prepare('SELECT * FROM '
             . $self->{tabname}
        . " WHERE " . q(`disable`) . " is NULL or " .  q(`disable`) . " in ('0','no','NO','No','nO')");
    } else {
      if ($xcatcfg =~ /^DB2:/) {  #for DB2  
         my $qstring = 
          "SELECT * FROM "
              . $self->{tabname}
              . " WHERE \"disable\" is NULL OR \"disable\" LIKE '0' OR \"disable\" LIKE 'no' OR \"disable\" LIKE 'NO' OR \"disable\" LIKE 'nO' ";
         $query =  $self->{dbh}->prepare($qstring);
      } else { # for other dbs
         $query =  $self->{dbh}->prepare('SELECT * FROM '
              . $self->{tabname}
              . " WHERE \"disable\" is NULL or \"disable\" in ('','0','no','NO','nO')");
      }
    }
    #print $query;
    $query->execute();
    while (my $data = $query->fetchrow_hashref())
    {
        my %newrow = ();
        foreach (@attribs)
        {
            unless ($data->{$_} =~ /^$/ || !defined($data->{$_}))
            { #The reason we do this is to undef fields in rows that may still be returned..
                $newrow{$_} = $data->{$_};
            }
        }
        if (keys %newrow)
        {
            push(@results, \%newrow);
        }
    }
    $query->finish();
    return @results;
}

#--------------------------------------------------------------------------

=head3 delEntries

    Description:  Delete table entries

    Arguments:
                Table Handle
                Entry to delete
    Returns:

    Globals:

    Error:

    Example:
	my $table=xCAT::Table->new("notification", -create => 1,-autocommit => 0);
	my %key_col = (filename=>$fname);
	$table->delEntries(\%key_col);
	$table->commit;

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub delEntries
{
    my $self   = shift;
    my $xcatcfg =get_xcatcfg();
    if ($dbworkerpid) {
        return dbc_call($self,'delEntries',@_);
    }
    my $keyref = shift;
    my @all_keyparis;
    my %keypairs;
    if (not $self->{intransaction} and not $self->{autocommit} and $self->{realautocommit}) {
        $self->{intransaction}=1;
        $self->{dbh}->{AutoCommit}=0;
    }
    if (ref($keyref) eq 'ARRAY')
    {
        @all_keyparis = @{$keyref};
    }else {
        push @all_keyparis, $keyref;
    }

    
    my $notif = xCAT::NotifHandler->needToNotify($self->{tabname}, 'd');

    my $record_num = 100;
    my @pieces = splice(@all_keyparis, 0, $record_num); 
    while (@pieces) {
        my @notif_data;
        if ($notif == 1)
        {
            my $qstring = "SELECT * FROM " . $self->{tabname};
            if ($keyref) { $qstring .= " WHERE "; }
            my @qargs = ();
            foreach my $keypairs (@pieces) {
                $qstring .= "(";
                foreach my $keypair (keys %{$keypairs})
                {
                    if ($xcatcfg =~ /^mysql:/) {
                      $qstring .= q(`) . $keypair . q(`) . " = ? AND ";
                    } else {
                      if ($xcatcfg =~ /^DB2:/) {
                        $qstring .= q(") . $keypair . q(") . " = ? AND "; 
                      } else { # for other dbs
                        $qstring .= "$keypair = ? AND ";
                      }
                    }

                    push @qargs, $keypairs->{$keypair};
                }
                $qstring =~ s/ AND \z//;
                $qstring .= ") OR ";
            }
            $qstring =~ s/\(\)//;
            $qstring =~ s/ OR \z//;

            
            my $query = $self->{dbh}->prepare($qstring);
            $query->execute(@qargs);
    
            #prepare the notification data
            #put the column names at the very front
            push(@notif_data, $query->{NAME});
            my $temp_data = $query->fetchall_arrayref();
            foreach (@$temp_data)
            {
                push(@notif_data, $_);
            }
            $query->finish();
        }
    
        my @stargs    = ();
        my $delstring = 'DELETE FROM ' . $self->{tabname};
        if ($keyref) { $delstring .= ' WHERE '; }
        foreach my $keypairs (@pieces) {
            $delstring .= "(";
            foreach my $keypair (keys %{$keypairs})
            {
                if ($xcatcfg =~ /^mysql:/) {
                   $delstring .= q(`) . $keypair. q(`) . ' = ? AND '; 
                } else {
                   if ($xcatcfg =~ /^DB2:/) {
                     $delstring .= q(") . $keypair. q(") . ' = ? AND '; 
                   } else { # for other dbs
                     $delstring .= $keypair . ' = ? AND ';
                   }
                }
                if (ref($keypairs->{$keypair}))
                {   #XML transformed data may come in mangled unreasonably into listrefs
                    push @stargs, $keypairs->{$keypair}->[0];
                }
                else
                {
                    push @stargs, $keypairs->{$keypair};
                }
            }
            $delstring =~ s/ AND \z//;
            $delstring .= ") OR ";
        }
        $delstring =~ s/\(\)//;
        $delstring =~ s/ OR \z//;
        my $stmt = $self->{dbh}->prepare($delstring);
        $stmt->execute(@stargs);
        $stmt->finish;
    
        #notify the interested parties
        if ($notif == 1)
        {
            xCAT::NotifHandler->notify("d", $self->{tabname}, \@notif_data, {});
        }
        @pieces = splice(@all_keyparis, 0, $record_num); 
    }
    
}

#--------------------------------------------------------------------------

=head3 getAttribs

    Description:

    Arguments:
               key
			   List of attributes
    Returns:
               Hash of requested attributes
    Globals:

    Error:

    Example:
        $table = xCAT::Table->new('passwd');
		@tmp=$table->getAttribs({'key'=>'ipmi'},('username','password');
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAttribs
{

    #Takes two arguments:
    #-Node name (will be compared against the 'Node' column)
    #-List reference of attributes for which calling code wants at least one of defined
    # (recurse argument intended only for internal use.)
    # Returns a hash reference with requested attributes defined.
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getAttribs',@_);
    }

    #my $key = shift;
    #my $keyval = shift;
    my %keypairs = %{shift()};
    my @attribs;
    if (ref $_[0]) {
        @attribs = @{shift()};
    } else {
        @attribs  = @_;
    }
    my @return;
    if ($self->{_use_cache}) {
        my @results;
        my $cacheline;
        if (scalar(keys %keypairs) == 1 and $keypairs{node}) { #99.9% of queries look like this, optimized case
            foreach $cacheline (@{$self->{_nodecache}->{$keypairs{node}}}) {
                my $attrib;
                my %rethash;
                foreach $attrib (@attribs)
               {
                   unless ($cacheline->{$attrib} =~ /^$/ || !defined($cacheline->{$attrib}))
                 {    #To undef fields in rows that may still be returned
                     $rethash{$attrib} = $cacheline->{$attrib};
                 }
               }
               if (keys %rethash)
             {
                 push @results, \%rethash;
             }
            }
        } else { #SLOW WAY FOR GENERIC CASE
            CACHELINE: foreach $cacheline (@{$self->{_tablecache}}) {
                foreach (keys %keypairs) {
                    if (not $keypairs{$_} and $keypairs{$_} ne 0 and $cacheline->{$_}) {
                        next CACHELINE;
                    }
                    unless ($keypairs{$_} eq $cacheline->{$_}) {
                        next CACHELINE;
                    }
                }
                my $attrib;
                my %rethash;
                foreach $attrib (@attribs)
               {
                   unless ($cacheline->{$attrib} =~ /^$/ || !defined($cacheline->{$attrib}))
                 {    #To undef fields in rows that may still be returned
                     $rethash{$attrib} = $cacheline->{$attrib};
                 }
               }
               if (keys %rethash)
             {
                 push @results, \%rethash;
             }
            }
        }
        if (@results)
        {
          return wantarray ? @results : $results[0];
        }
        return undef;
    }
    my $xcatcfg =get_xcatcfg();
    #print "Uncached access to ".$self->{tabname}."\n";
    my $statement = 'SELECT * FROM ' . $self->{tabname} . ' WHERE ';
    my @exeargs;
    foreach (keys %keypairs)
    {
        if ($keypairs{$_})
        {
            if ($xcatcfg =~ /^mysql:/) {  #for mysql
              $statement .= q(`) . $_ . q(`) . " = ? and "
            } else {
              if ($xcatcfg =~ /^DB2:/) {  #for  DB2
                 $statement .= q(") . $_ . q(") . " = ? and "
                } else { # for other dbs
                   $statement .= "$_ = ? and ";
              }  
            }  
            if (ref($keypairs{$_}))
            {    #correct for XML process mangling if occurred
                push @exeargs, $keypairs{$_}->[0];
            }
            else
            {
                push @exeargs, $keypairs{$_};
            }
        }
        else
        {
            if ($xcatcfg =~ /^mysql:/) {  #for mysql
	        $statement .= q(`) . $_ . q(`) . " is NULL and " ; 
            } else {
              if ($xcatcfg =~ /^DB2:/) {  #for  DB2
	        $statement .= q(") . $_ . q(") . " is NULL and " ; 
              } else { # for other dbs
                $statement .= "$_ is NULL and ";
              }
            }
        }
    }
    if ($xcatcfg =~ /^mysql:/) {  #for mysql
       $statement .= "(" . q(`disable`) . " is NULL or " .  q(`disable`) . " in ('0','no','NO','No','nO'))";
    } else {
       if ($xcatcfg =~ /^DB2:/) {  #for DB2 
         $statement .= "(\"disable\" is NULL OR \"disable\" LIKE '0' OR \"disable\" LIKE 'no' OR \"disable\" LIKE 'NO'  OR \"disable\" LIKE 'No' OR \"disable\" LIKE 'nO')";
       } else { # for other dbs
         $statement .= "(\"disable\" is NULL or \"disable\" in ('0','no','NO','No','nO'))";
       }
    }
    #print "This is my statement: $statement \n";
    my $query = $self->{dbh}->prepare($statement);
    unless (defined $query) {
        return undef;
    }
    $query->execute(@exeargs);
    my $data;
    while ($data = $query->fetchrow_hashref())
    {
        my $attrib;
        my %rethash;
        foreach $attrib (@attribs)
        {
            unless ($data->{$attrib} =~ /^$/ || !defined($data->{$attrib}))
            {    #To undef fields in rows that may still be returned
                $rethash{$attrib} = $data->{$attrib};
            }
        }
        if (keys %rethash)
        {
            push @return, \%rethash;
        }
    }
    $query->finish();
    if (@return)
    {
      return wantarray ? @return : $return[0];
    }
    return undef;
}

#--------------------------------------------------------------------------

=head3 getTable

    Description:  Read entire Table

    Arguments:
                Table Handle

    Returns:
                Array of table rows
    Globals:

    Error:

    Example:
                  my $table=xCAT::Table->new("notification", -create =>0);
				  my @row_array= $table->getTable;
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getTable
{

    # Get contents of table
    # Takes no arguments
    # Returns an array of hashes containing the entire contents of this
    #   table.  Each array entry contains a pointer to a hash which is
    #   one row of the table.  The row hash is keyed by attribute name.
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getTable',@_);
    }
    my @return;
    my $statement = 'SELECT * FROM ' . $self->{tabname};
    my $query     = $self->{dbh}->prepare($statement);
    $query->execute();
    my $data;
    while ($data = $query->fetchrow_hashref())
    {
        my $attrib;
        my %rethash;
        foreach $attrib (keys %{$data})
        {
            $rethash{$attrib} = $data->{$attrib};
        }
        if (keys %rethash)
        {
            push @return, \%rethash;
        }
    }
    $query->finish();
    if (@return)
    {
        return @return;
    }
    return undef;
}

#--------------------------------------------------------------------------

=head3 close

    Description: Close out Table transaction

    Arguments:
                Table Handle
    Returns:

    Globals:

    Error:

    Example:
                  my $mactab = xCAT::Table->new('mac');
				  $mactab->setNodeAttribs($macmap{$mac},{mac=>$mac});
				  $mactab->close();
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub close
{
    my $self = shift;
    #if ($self->{dbh}) { $self->{dbh}->disconnect(); }
    #undef $self->{dbh};
    if ($self->{tabname} eq 'nodelist') {
       undef $self->{nodelist};
    } else {
       $self->{nodelist}->close();
    }
}

#--------------------------------------------------------------------------

=head3 open

    Description: Connect to Database

    Arguments:
           Empty Hash
    Returns:
           Data Base Handle
    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
#UNSUED FUNCTION
#sub open
#{
#    my $self = shift;
#    $self->{dbh} = DBI->connect($self->{connstring}, "", "");
#}

#--------------------------------------------------------------------------

=head3 DESTROY

    Description:  Disconnect from Database

    Arguments:
              Database Handle
    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub DESTROY
{
    my $self = shift;
    $self->{dbh} = '';
    undef $self->{dbh};
    #if ($self->{dbh}) { $self->{dbh}->disconnect(); undef $self->{dbh};}
    undef $self->{nodelist};    #Could be circular
}

=head3 getTableList
	Description: Returns a list of the table names in the xCAT database.
=cut
sub getTableList { return keys %xCAT::Schema::tabspec; }


=head3 getTableSchema
	Description: Returns the db schema for the specified table.
	Returns: A reference to a hash that contains the cols, keys, etc. for this table. (See Schema.pm for details.)
=cut
sub getTableSchema { return $xCAT::Schema::tabspec{$_[1]}; }


=head3 getTableList
	Description: Returns a summary description for each table.
	Returns: A reference to a hash.  Each key is the table name.
			Each value is the table description.
=cut
sub getDescriptions {
	my $classname = shift;     # we ignore this because this function is static
	# List each table name and the value for table_desc.
	my $ret = {};
	#my @a = keys %{$xCAT::Schema::tabspec{nodelist}};  print 'a=', @a, "\n";
	foreach my $t (keys %xCAT::Schema::tabspec) { $ret->{$t} = $xCAT::Schema::tabspec{$t}->{table_desc}; }
	return $ret;
}

#--------------------------------------------------------------------------
=head3  isAKey 
    Description:  Checks to see if table field is a table key 

    Arguments:
               Table field 
	       List of keys 
    Returns:
               1= is a key
               0 = not a key 
    Globals:

    Error:

    Example:
              if(isaKey($key_list, $col));

=cut
#--------------------------------------------------------------------------------
sub isAKey 
{
    my ($keys,$col)  = @_;
    my @key_list = @$keys;
    foreach my $key (@key_list)
    {
       if ( $col eq $key) {   # it is a key
         return 1;
       } 
    }
    return 0;
}

#--------------------------------------------------------------------------
=head3   getAutoIncrementColumns
    get a list of column names that are of type "INTEGER AUTO_INCREMENT".

    Returns:
        an array of column names that are auto increment.
=cut
#--------------------------------------------------------------------------------
sub getAutoIncrementColumns {
    my $self=shift;
    my $descr=$xCAT::Schema::tabspec{$self->{tabname}};
    my $types=$descr->{types};
    my @ret=();

    foreach my $col (@{$descr->{cols}})
    {
	if (($types) && ($types->{$col})) {
            if ($types->{$col} =~ /INTEGER AUTO_INCREMENT/) { push(@ret,$col); }
	}
    }
    return @ret;
}

1;

