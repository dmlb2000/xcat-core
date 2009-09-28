# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#####################################################
#
#  xCAT plugin package to handle various commands that work with the
#     xCAT tables
#
#####################################################
package xCAT_plugin::tabutils;
use strict;
use warnings;
use xCAT::Table;
use xCAT::Schema;
use Data::Dumper;
use xCAT::NodeRange qw/noderange abbreviate_noderange/;
use xCAT::Schema;
use xCAT::Utils;
use Getopt::Long;
my $requestcommand;

1;

#some quick aliases to table/value
my %shortnames = (
                  groups => [qw(nodelist groups)],
                  tags   => [qw(nodelist groups)],
                  mgt    => [qw(nodehm mgt)],
                  #switch => [qw(switch switch)],
                  );

#####################################################
# Return list of commands handled by this plugin
#####################################################
sub handled_commands
{
    return {
            gettab     => "tabutils",
            tabdump    => "tabutils",
            tabrestore => "tabutils",
            tabch      => "tabutils",     # not implemented yet
            nodech     => "tabutils",
            nodeadd    => "tabutils",
            noderm     => "tabutils",
            tabls      => "tabutils",     # not implemented yet
            nodels     => "tabutils",
            getnodecfg => "tabutils",     # not implemented yet (?? this doesn't seem much different from gettab)
            addattr    => "tabutils",     # not implemented yet
            delattr    => "tabutils",     # not implemented yet
            chtype     => "tabutils",     # not implemented yet
            nr         => "tabutils",     # not implemented yet
            rnoderange => "tabutils",     # not implemented yet
            tabgrep    => "tabutils"
            };
}

# Each cmd now returns its own usage inside its function
#my %usage = (
    #nodech => "Usage: nodech <noderange> [table.column=value] [table.column=value] ...",
    #nodeadd => "Usage: nodeadd <noderange> [table.column=value] [table.column=value] ...",
    #noderm  => "Usage: noderm <noderange>",
    # the usage for tabdump is in the tabdump function
    #tabdump => "Usage: tabdump <tablename>\n   where <tablename> is one of the following:\n     " . join("\n     ", keys %xCAT::Schema::tabspec),
    # the usage for tabrestore is in the tabrestore client cmd
    #tabrestore => "Usage: tabrestore <tablename>.csv",
    #);

#####################################################
# Process the command
#####################################################
sub process_request
{
    #use Getopt::Long;
    Getopt::Long::Configure("bundling");
    #Getopt::Long::Configure("pass_through");
    Getopt::Long::Configure("no_pass_through");

    my $request  = shift;
    my $callback = shift;
    $requestcommand = shift;
    my $nodes    = $request->{node};
    my $command  = $request->{command}->[0];
    my $args     = $request->{arg};
    #unless ($args or $nodes or $request->{data})
    #{
        #if ($usage{$command})
        #{
            #$callback->({data => [$usage{$command}]});
            #return;
        #}
    #}

    if ($command eq "nodels")
    {
        return nodels($nodes, $args, $callback, $request->{emptynoderange}->[0]);
    }
    elsif ($command eq "rnoderange") 
    {
        return rnoderange($nodes,$args,$callback);
    }
    elsif ($command eq "noderm" or $command eq "rmnode")
    {
        return noderm($nodes, $args, $callback);
    }
    elsif ($command eq "nodeadd" or $command eq "addnode")
    {
        return nodech($nodes, $args, $callback, 1);
    }
    elsif ($command eq "nodech" or $command eq "nodech")
    {
        return nodech($nodes, $args, $callback, 0);
    }
    elsif ($command eq "tabrestore")
    {
        return tabrestore($request, $callback);
    }
    elsif ($command eq "tabdump")
    {
        return tabdump($args, $callback);
    }
    elsif ($command eq "gettab")
    {
        return gettab($request, $callback);
    }
    elsif ($command eq "tabgrep")
    {
        return tabgrep($nodes, $callback);
    }
    else
    {
        print "$command not implemented yet\n";
        return (1, "$command not written yet");
    }

}

# Display particular attributes, using query strings.
sub gettab
{
    my $req      = shift;
    my $callback = shift;
    my $HELP;
    my $NOTERSE;

    my $gettab_usage = sub {
    	my $exitcode = shift @_;
        my %rsp;
        push @{$rsp{data}}, "Usage: gettab [-H|--with-fieldname] key=value,...  table.attribute ...";
        push @{$rsp{data}}, "       gettab [-?|-h|--help]";
        if ($exitcode) { $rsp{errorcode} = $exitcode; }
        $callback->(\%rsp);
    };

	# Process arguments
	if (!defined($req->{arg})) { $gettab_usage->(1); return; }
    @ARGV = @{$req->{arg}};
    if (!GetOptions('h|?|help' => \$HELP,'H|with-fieldname' => \$NOTERSE)) { $gettab_usage->(1); return; }

    if ($HELP) { $gettab_usage->(0); return; }
    if (scalar(@ARGV)<2) { $gettab_usage->(1); return; }

    # Get all the key/value pairs into a hash
    my $keyspec  = shift @ARGV;
    my @keypairs = split /,/, $keyspec;
    my %keyhash;
    foreach (@keypairs)
    {
        (my $key, my $value) = split /=/, $_;
        unless (defined $key) {
            $gettab_usage->(1);
            return;
        }
        $keyhash{$key} = $value;
    }

    # Group the columns asked for by table (so we can do 1 query per table)
    my %tabhash;
    my $terse = 2;
    if ($NOTERSE) {
        $terse = 0;
    }
    foreach my $tabvalue (@ARGV)
    {
        $terse--;
        (my $table, my $column) = split /\./, $tabvalue;
        $tabhash{$table}->{$column} = 1;
    }

    #Sanity check the key against all tables in question
    foreach my $tabn (keys %tabhash) {
        foreach my $kcheck (keys %keyhash) {
            unless (grep /^$kcheck$/, @{$xCAT::Schema::tabspec{$tabn}->{cols}}) {
                $callback->({error => ["Unkown key $kcheck to $tabn"],errorcode=>[1]});
                return;
            }
        }
    }
    # Get the requested columns from each table
    foreach my $tabn (keys %tabhash)
    {
        my $tab = xCAT::Table->new($tabn);
        (my $ent) = $tab->getAttribs(\%keyhash, keys %{$tabhash{$tabn}});
        foreach my $coln (keys %{$tabhash{$tabn}})
        {
            if ($terse > 0) {
                $callback->({data => ["" . $ent->{$coln}]});
            } else {
                $callback->({data => ["$tabn.$coln: " . $ent->{$coln}]});
            }
        }
        $tab->close;
    }
}

sub noderm
{
    my $nodes = shift;
    my $args  = shift;
    my $cb    = shift;
    my $VERSION;
    my $HELP;

    my $noderm_usage = sub {
    	my $exitcode = shift @_;
        my %rsp;
        push @{$rsp{data}}, "Usage:";
        push @{$rsp{data}}, "  noderm noderange";
        push @{$rsp{data}}, "  noderm {-v|--version}";
        push @{$rsp{data}}, "  noderm [-?|-h|--help]";
        if ($exitcode) { $rsp{errorcode} = $exitcode; }
        $cb->(\%rsp);
    };

    if ($args) {
        @ARGV = @{$args};
    }
    if (!GetOptions('h|?|help'  => \$HELP, 'v|version' => \$VERSION) ) { $noderm_usage->(1); return; }

    if ($HELP) { $noderm_usage->(0); return; }

    if ($VERSION) {
        my %rsp;
        my $version = xCAT::Utils->Version();
        $rsp{data}->[0] = "$version";
        $cb->(\%rsp);
        return;
    }

    if (!$nodes) { $noderm_usage->(1); return; }
    my $sitetab = xCAT::Table->new('site');
    my $pdhcp = $sitetab->getAttribs({key=>'pruneservices'},['value']);
    if ($pdhcp and $pdhcp->{value} and $pdhcp->{value} !~ /n(\z|o)/i) {
        $requestcommand->({command=>['makedhcp'],node=>$nodes,arg=>['-d']});
    }

    

    # Build the argument list for using the -d option of nodech to do our work for us
    my @tablist = ("-d");
    foreach (keys %{xCAT::Schema::tabspec})
    {
        if (grep /^node$/, @{$xCAT::Schema::tabspec{$_}->{cols}})
        {
            push @tablist, $_;
        }
    }
    nodech($nodes, \@tablist, $cb, 0);
}

sub tabrestore
{
    # the usage for tabrestore is in the tabrestore client cmd

    #request->{data} is an array of CSV formatted lines
    my $request    = shift;
    my $cb         = shift;
    my $table      = $request->{table}->[0];
    my $linenumber = 1;
    my $tab        = xCAT::Table->new($table, -create => 1, -autocommit => 0);
    unless ($tab) {
        $cb->({error => "Unable to open $table",errorcode=>4});
        return;
    }
    $tab->delEntries();    #Yes, delete *all* entries
    my $header = shift @{$request->{data}};
    unless ($header =~ /^#/) {
        $cb->({error => "Data missing header line starting with #",errorcode=>1});
        return;
    }
    $header =~ s/"//g;     #Strip " from overzealous CSV apps
    $header =~ s/^#//;
    $header =~ s/\s+$//;
    my @colns = split(/,/, $header);
    my $tcol;
    foreach $tcol (@colns) { #validate the restore data has no invalid column names
        unless (grep /^$tcol\z/,@{$xCAT::Schema::tabspec{$table}->{cols}}) {
            $cb->({error => "The header line indicates that column '$tcol' should exist, which is not defined in the schema for '$table'",errorcode=>1});
            return;
        }
        #print Dumper(grep /^$tcol\z/,@{$xCAT::Schema::tabspec{$table}->{cols}});
    }
    #print "We passed it!\n";
    my $line;
    my $rollback = 0;

    my @tmp=$tab->getAutoIncrementColumns(); #get the columns that are auto increment by DB. 
    my %auto_cols=();
    foreach (@tmp) { $auto_cols{$_}=1;}

  LINE: foreach $line (@{$request->{data}})
    {
        $linenumber++;
        $line =~ s/\s+$//;
        my $origline = $line;    #save for error reporting
        my %record;
        my $col;
        foreach $col (@colns)
        {
            if ($line =~ /^,/ or $line eq "")
            {                    #Match empty, or end of line that is empty
                 #TODO: should we detect when there weren't enough CSV fields on a line to match colums?
                if (!exists($auto_cols{$col})) {
		    $record{$col} = undef;
		}
                $line =~ s/^,//;
            }
            elsif ($line =~ /^[^,]*"/)
            {    # We have stuff in quotes... pain...
                    #I don't know what I'm doing, so I'll do it a hard way....
                if ($line !~ /^"/)
                {
                    $rollback = 1;
                    $cb->(
                        {
                         error =>
                           "CSV missing opening \" for record with \" characters on line $linenumber, character "
                           . index($origline, $line) . ": $origline", errorcode=>4
                        }
                        );
                    next LINE;
                }
                my $offset = 1;
                my $nextchar;
                my $ent;
                while (not defined $ent)
                {
                    $offset = index($line, '"', $offset);
                    $offset++;
                    if ($offset <= 0)
                    {

                        #MALFORMED CSV, request rollback, report an error
                        $rollback = 1;
                        $cb->(
                            {
                             error =>
                               "CSV unmatched \" in record on line $linenumber, character "
                               . index($origline, $line) . ": $origline", errorcode=>4
                            }
                            );
                        next LINE;
                    }
                    $nextchar = substr($line, $offset, 1);
                    if ($nextchar eq '"')
                    {
                        $offset++;
                    }
                    elsif ($offset eq length($line) or $nextchar eq ',')
                    {
                        $ent = substr($line, 0, $offset, '');
                        $line =~ s/^,//;
                        chop $ent;
                        $ent = substr($ent, 1);
                        $ent =~ s/""/"/g;
			if (!exists($auto_cols{$col})) {
			    $record{$col} = $ent;
			}
                    }
                    else
                    {
                        $cb->(
                            {
                             error =>
                               "CSV unescaped \" in record on line $linenumber, character "
                               . index($origline, $line) . ": $origline", errorcode=>4
                            }
                            );
                        $rollback = 1;
                        next LINE;
                    }
                }
            }
            elsif ($line =~ /^([^,]+)/)
            {    #easiest case, no Text::Balanced needed..
		if (!exists($auto_cols{$col})) {
		    $record{$col} = $1;
		}
                $line =~ s/^([^,]+)(,|$)//;
            }
        }
        if ($line)
        {
            $rollback = 1;
            $cb->({error => "Too many fields on line $linenumber: $origline | $line", errorcode=>4});
            next LINE;
        }

        #TODO: check for error from DB and rollback
        my @rc = $tab->setAttribs(\%record, \%record);
        if (not defined($rc[0]))
        {
            $rollback = 1;
            $cb->({error => "DB error " . $rc[1] . " with line $linenumber: " . $origline, errorcode=>4});
        }
    }
    if ($rollback)
    {
        $tab->rollback();
        $tab->close;
        undef $tab;
        return;
    }
    else
    {
        $tab->commit;    #Made it all the way here, commit
    }
}

# Display a list of tables, or a specific table in CSV format
sub tabdump
{
    my $args  = shift;
    my $cb    = shift;
    my $table = "";
    my $HELP;
    my $DESC;

    my $tabdump_usage = sub {
    	my $exitcode = shift @_;
        my %rsp;
        push @{$rsp{data}}, "Usage: tabdump [-d] [table]";
        push @{$rsp{data}}, "       tabdump [-?|-h|--help]";
        if ($exitcode) { $rsp{errorcode} = $exitcode; }
        $cb->(\%rsp);
    };

	# Process arguments
    if ($args) {
        @ARGV = @{$args};
    }
    if (!GetOptions('h|?|help' => \$HELP, 'd' => \$DESC)) { $tabdump_usage->(1); return; }

    if ($HELP) { $tabdump_usage->(0); return; }
    if (scalar(@ARGV)>1) { $tabdump_usage->(1); return; }

    my %rsp;
    # If no arguments given, we display a list of the tables
    if (!scalar(@ARGV)) {
    	if ($DESC) {  # display the description of each table
    		my $tab = xCAT::Table->getDescriptions();
    		foreach my $key (keys %$tab) {
    			my $space = (length($key)<7 ? "\t\t" : "\t");
    			push @{$rsp{data}}, "$key:$space".$tab->{$key}."\n";
    		}
    	}
    	else { push @{$rsp{data}}, xCAT::Table->getTableList(); }   # if no descriptions, just display the list of table names
    	@{$rsp{data}} = sort @{$rsp{data}};
		if ($DESC && scalar(@{$rsp{data}})) { chop($rsp{data}->[scalar(@{$rsp{data}})-1]); }   # remove the final newline
        $cb->(\%rsp);
    	return;
    }

    $table = $ARGV[0];
    if ($DESC) {     # only show the attribute descriptions, not the values
    	my $schema = xCAT::Table->getTableSchema($table);
    	if (!$schema) { $cb->({error => "table $table does not exist.",errorcode=>1}); return; }
		my $desc = $schema->{descriptions};
		foreach my $c (@{$schema->{cols}}) {
			my $space = (length($c)<7 ? "\t\t" : "\t");
			push @{$rsp{data}}, "$c:$space".$desc->{$c}."\n";
		}
		if (scalar(@{$rsp{data}})) { chop($rsp{data}->[scalar(@{$rsp{data}})-1]); }   # remove the final newline
        $cb->(\%rsp);
		return;
    }


    my $tabh = xCAT::Table->new($table);

    my $tabdump_header = sub {
        my $header = "#" . join(",", @_);
        push @{$rsp{data}}, $header;
    };

    # If the table does not exist yet (because its never been written to),
    # at least show the header (the column names)
    unless ($tabh)
    {
        if (defined($xCAT::Schema::tabspec{$table}))
        {
        	$tabdump_header->(@{$xCAT::Schema::tabspec{$table}->{cols}});
        	$cb->(\%rsp);
            return;
        }
        $cb->({error => "No such table: $table",errorcode=>1});
        return 1;
    }

    my $recs = $tabh->getAllEntries("all");
    my $rec;
    unless (@$recs)        # table exists, but is empty.  Show header.
    {
        if (defined($xCAT::Schema::tabspec{$table}))
        {
        	$tabdump_header->(@{$xCAT::Schema::tabspec{$table}->{cols}});
        	$cb->(\%rsp);
            return;
        }
    }

	# Display all the rows of the table in the order of the columns in the schema
    $tabdump_header->(@{$tabh->{colnames}});
    foreach $rec (@$recs)
    {
        my $line = '';
        foreach (@{$tabh->{colnames}})
        {
            if (defined $rec->{$_})
            {
            	$rec->{$_} =~ s/"/""/g;
                $line = $line . '"' . $rec->{$_} . '",';
            }
            else
            {
                $line .= ',';
            }
        }
        $line =~ s/,$//;    # remove the extra comma at the end
        push @{$rsp{data}}, $line;
    }
    $cb->(\%rsp);
}

sub getTableColumn {
    my $string = shift;
    if ($shortnames{$string}) {
            return @{$shortnames{$string}};
    }
    unless ($string =~ /\./) {
        return undef;
    }
    return split /\./,$string,2;
}

sub nodech
{
    my $nodes    = shift;
    my $args     = shift;
    my $callback = shift;
    my $addmode  = shift;
    my $VERSION;
    my $HELP;
    my $deletemode;
    my $grptab;
    my @grplist;

    my $nodech_usage = sub
    {
    	my $exitcode = shift @_;
    	my $addmode = shift @_;
    	my $cmdname = $addmode ? 'nodeadd' : 'nodech';
        my %rsp;
        if ($addmode) {
        	push @{$rsp{data}}, "Usage: $cmdname <noderange> groups=<groupnames> [table.column=value] [...]";
        } else {
        	push @{$rsp{data}}, "Usage: $cmdname <noderange> table.column=value [...]";
        	push @{$rsp{data}}, "       $cmdname {-d | --delete} <noderange> <table> [...]";
        }
        push @{$rsp{data}}, "       $cmdname {-v | --version}";
        push @{$rsp{data}}, "       $cmdname [-? | -h | --help]";
        if ($exitcode) { $rsp{errorcode} = $exitcode; }
        $callback->(\%rsp);
    };

    if ($args) {
        @ARGV = @{$args};
    } else {
        @ARGV=();
    }
    my %options = ('h|?|help'  => \$HELP, 'v|version' => \$VERSION);
    if (!$addmode) { $options{'d|delete'} = \$deletemode; }
    if (!GetOptions(%options)) {
        $nodech_usage->(1, $addmode);
        return;
    }

    # Help
    if ($HELP) {
        $nodech_usage->(0, $addmode);
        return;
    }

    # Version
    if ($VERSION) {
        my %rsp;
        my $version = xCAT::Utils->Version();
        $rsp{data}->[0] = "$version";
        $callback->(\%rsp);
        return;
    }

    # Note: the noderange comes through in $arg (and therefore @ARGV) for nodeadd,
    # because it is linked to xcatclientnnr, since the nodes specified in the noderange
    # do not exist yet.  The nodech cmd is linked to xcatclient, so its noderange is
    # put in $nodes instead of $args.
    if (scalar(@ARGV) < (1+$addmode)) { $nodech_usage->(1, $addmode);  return; }

    if ($addmode)
    {
    	my $nr = shift @ARGV;
    	$nodes = [noderange($nr, 0)];
        unless ($nodes) {
            $callback->({error => "No noderange to add.\n",errorcode=>1});
            return;
        }
    }
    my $column;
    my $value;
    my $temp;
    my %tables;
    my %criteria=();
    my $tab;

    #print Dumper($deletemode);
    foreach (@ARGV)
    {
        if ($deletemode)
        {
            if (m/[=\.]/)   # in delete mode they can only specify tables names
            {
                $callback->({error => [". and = not valid in delete mode."],errorcode=>1});
                next;
            }
            $tables{$_} = 1;
            next;
        }
        unless (m/=/ or m/!~/)
        {
            $callback->({error => ["Malformed argument $_ ignored."],errorcode=>1});
            next;
        }
        my $stable;
        my $scolumn;
        #Check for selection criteria
        if (m/^[^=]*==/) {
            ($temp,$value)=split /==/,$_,2;
            ($stable,$scolumn)=getTableColumn($temp);
            $criteria{$stable}->{$scolumn}=[$value,'match'];

            next; #Is a selection criteria, not an assignment specification
        } elsif (m/^[^=]*!=/) {
            ($temp,$value)=split /!=/,$_,2;
            ($stable,$scolumn)=getTableColumn($temp);
            $criteria{$stable}->{$scolumn}=[$value,'natch'];
            next; #Is a selection criteria, not an assignment specification
        } elsif (m/^[^=]*=~/) {
            ($temp,$value)=split /=~/,$_,2;
            ($stable,$scolumn)=getTableColumn($temp);
            $value =~ s/^\///;
            $value =~ s/\/$//;
            $criteria{$stable}->{$scolumn}=[$value,'regex'];
            next; #Is a selection criteria, not an assignment specification
        } elsif (m/^[^=]*!~/) {
            ($temp,$value)=split /!~/,$_,2;
            ($stable,$scolumn)=getTableColumn($temp);
            $value =~ s/^\///;
            $value =~ s/\/$//;
            $criteria{$stable}->{$scolumn}=[$value,'negex'];
            next; #Is a selection criteria, not an assignment specification
        }
        #Now definitely an assignment
                        
        ($temp, $value) = split('=', $_, 2);
        $value =~ s/^@//; #Allow the =@ operator to exist for an unambiguous assignmenet operator
                          #So before, table.column==value meant set to =value, now it would be matching value
                          #the new way would be table.column=@=value to be unambiguous
                          #now a value like '@hi' would be set with table.column=@@hi
        if ($value eq '') { #If blank, force a null entry to override group settings
            $value = '|^.*$||';
        }
        my $op = '=';
        if ($temp =~ /,$/)
        {
            $op = ',=';
            chop($temp);
        }
        elsif ($temp =~ /\^$/)
        {
            $op = '^=';
            chop($temp);
        }

        my $table;
        if ($shortnames{$temp})
        {
            ($table, $column) = @{$shortnames{$temp}};
        }
        else
        {
            ($table, $column) = split('\.', $temp, 2);
        }
        unless (grep /$column/,@{$xCAT::Schema::tabspec{$table}->{cols}}) {
             $callback->({error=>"$table.$column not a valid table.column description",errorcode=>[1]});
             return;
        }

        # Keep a list of the value/op pairs, in case there is more than 1 per table.column
        #$tables{$table}->{$column} = [$value, $op];
        push @{$tables{$table}->{$column}}, ($value, $op);
    }
    my %nodehash;
    if (keys %criteria) {
        foreach (@$nodes) {
            $nodehash{$_}=1;
        }
    }
    foreach $tab (keys %criteria) {
        my $tabhdl = xCAT::Table->new($tab, -create => 1, -autocommit => 0);
        my @columns=keys %{$criteria{$tab}};
        my $tabhash = $tabhdl->getNodesAttribs($nodes,\@columns);
        my $node;
        my $col;
        my $rec;
        foreach $node (@$nodes) {
            foreach $rec (@{$tabhash->{$node}}) {
                foreach $col (@columns) {
                    my $value=$criteria{$tab}->{$col}->[0];
                    unless (defined $value) {
                        $value = "";
                    }
                    my $matchtype=$criteria{$tab}->{$col}->[1];
                    if ($matchtype eq 'match' and not ($rec->{$col} eq $value) or
                        $matchtype eq 'natch' and ($rec->{$col} eq $value) or
                        $matchtype eq 'regex' and ($rec->{$col} !~ /$value/) or
                        $matchtype eq 'negex' and ($rec->{$col} =~ /$value/)) {
                        delete $nodehash{$node};
                    }
                }
            }
        }
        $nodes = [keys %nodehash];
    }
    foreach $tab (keys %tables)
    {
        my $tabhdl = xCAT::Table->new($tab, -create => 1, -autocommit => 0);
        if ($tabhdl)
        {
            foreach (@$nodes)
            {
                if ($deletemode)
                {
                    $tabhdl->delEntries({'node' => $_});
                }
                else
                {

                    #$tabhdl->setNodeAttribs($_,$tables{$tab});
                    my %uhsh;
                    my $node = $_;
                    foreach (keys %{$tables{$tab}})		# for each column specified for this table
                    {
                        #my $op  = $tables{$tab}->{$_}->[1];
                        #my $val = $tables{$tab}->{$_}->[0];
                        my @valoppairs = @{$tables{$tab}->{$_}}; #Deep copy
                        while (scalar(@valoppairs)) {			# alternating list of value and op for this table.column
                        	my $val = shift @valoppairs;
                        	my $op  = shift @valoppairs;
                        	my $key = $_;
                                # When changing the groups of the node, check whether the new group
                                # is a dynamic group.
                                if (($key eq 'groups') && ($op eq '=')) {
                                    if (scalar(@grplist) == 0) { # Do not call $grptab->getAllEntries for each node, performance issue.
                                        $grptab = xCAT::Table->new('nodegroup');
                                        if ($grptab) {
                                            @grplist = @{$grptab->getAllEntries()};
                                        }
                                    }
                                    my @grps = split(/,/, $val);
                                    foreach my $grp (@grps) {
                                        foreach my $grpdef_ref (@grplist) {
                                            my %grpdef = %$grpdef_ref;
                                            if (($grpdef{'groupname'} eq $grp) && ($grpdef{'grouptype'} eq 'dynamic')) {
                                                my %rsp;
                                                $rsp{data}->[0] = "nodegroup $grp is a dynamic node group, should not add a node into a dynamic node group statically.\n";
                                                $callback->(\%rsp);
                                            }
                                        }
                                    }
                                }
                        	if ($op eq '=') {
                            	$uhsh{$key} = $val;
                        	}
                        	elsif ($op eq ',=') {    #splice assignment
                        		my $curval = $uhsh{$key};    # in case it was already set
                        		if (!defined($curval)) {
                            		my $cent = $tabhdl->getNodeAttribs($node, [$key]);
                            		if ($cent) { $curval = $cent->{$key}; }
                        		}
                            	if ($curval) {
                                	my @vals = split(/,/, $curval);
                                	unless (grep /^$val$/, @vals) {
                                    	@vals = (@vals, $val);
                                    	my $newval = join(',', @vals);
                                    	$uhsh{$key} = $newval;
                                	}
                            	} else {
                                	$uhsh{$key} = $val;
                            	}
                        	}
                        	elsif ($op eq '^=') {
                        		my $curval = $uhsh{$key};    # in case it was already set
                        		if (!defined($curval)) {
                            		my $cent = $tabhdl->getNodeAttribs($node, [$key]);
                            		if ($cent) { $curval = $cent->{$key}; }
                        		}
                            	if ($curval) {
                                	my @vals = split(/,/, $curval);
                                	if (grep /^$val$/, @vals) {    #only bother if there
                                    	@vals = grep(!/^$val$/, @vals);
                                    	my $newval = join(',', @vals);
                                    	$uhsh{$key} = $newval;
                                	}
                            	}    #else, what they asked for is the case alredy
                        	}
                        }		# end of while @valoppairs
                    }		# end of foreach column specified for this table

                    if (keys %uhsh)
                    {
                        my @rc = $tabhdl->setNodeAttribs($node, \%uhsh);
                        if (not defined($rc[0]))
                        {
                            $callback->({error => "DB error " . $rc[1],errorcode=>1});
                        }
                    }
                }
            }
            $tabhdl->commit;
        }
        else
        {
            $callback->(
                 {error => ["ERROR: Unable to open table $tab in configuration"],errorcode=>1}
                 );
        }
    }
}

sub tabgrep
{
    my $node = shift;
    my @tablist;
    my $callback = shift;

    if (!defined($node) || !scalar(@$node)) {
        my %rsp;
        push @{$rsp{data}}, "Usage: tabgrep nodename";
        push @{$rsp{data}}, "       tabgrep [-?|-h|--help]";
        $rsp{errorcode} = 1;
        $callback->(\%rsp);
        return;
    }

    foreach (keys %{xCAT::Schema::tabspec})
    {
        if (grep /^node$/, @{$xCAT::Schema::tabspec{$_}->{cols}})
        {
            push @tablist, $_;
        }
    }
    foreach (@tablist)
    {
        my $tab = xCAT::Table->new($_);
        unless ($tab) { next; }
        if ($tab and $tab->getNodeAttribs($node->[0], ["node"]))
        {
            $callback->({data => [$_]});
        }
        $tab->close;
    }

}

sub rnoderange 
{
    my $nodes = shift;
    my $args = shift;
    my $callback = shift;
    my $data = abbreviate_noderange($nodes);
    if ($data) {
        $callback->({data=>[$data]});
    }
}
#####################################################
#  nodels command
#####################################################
sub nodels
{
    my $nodes     = shift;
    my $args      = shift;
    my $callback  = shift;
    my $noderange = shift;
    unless ($nodes) {
        $nodes=[];
    }

    my $VERSION;
    my $HELP;

    my $nodels_usage = sub 
    {
    	my $exitcode = shift @_;
        my %rsp;
        push @{$rsp{data}}, "Usage:";
        push @{$rsp{data}}, "  nodels [noderange] [-H|--with-fieldname] [table.attribute | shortname] [...]";
        push @{$rsp{data}}, "  nodels {-v|--version}";
        push @{$rsp{data}}, "  nodels [-?|-h|--help]";
        if ($exitcode) { $rsp{errorcode} = $exitcode; }
        $callback->(\%rsp);
    };

    if ($args) {
        @ARGV = @{$args};
    } else {
        @ARGV=();
    }
    my $NOTERSE;

   if (!GetOptions('h|?|help'  => \$HELP, 'H|with-fieldname' => \$NOTERSE, 'v|version' => \$VERSION,) ) { $nodels_usage->(1); return; }

    # Help
    if ($HELP) { $nodels_usage->(0); return; }

    # Version
    if ($VERSION)
    {
        my %rsp;
        my $version = xCAT::Utils->Version();
        $rsp{data}->[0] = "$version";
        $callback->(\%rsp);
        return;
    }

    # TODO -- Parse command arguments
    #  my $opt;
    #  my %attrs;
    #  foreach $opt (@ARGV) {
    #     if ($opt =~ /^group/) {
    #     }
    #  }
    my $argc = @ARGV;
    my $terse = 2;
    if ($NOTERSE) {
        $terse = 0;
    }

    if (@$nodes > 0 or $noderange)
    { #Make sure that there are zero nodes *and* that a noderange wasn't requested
                    # TODO - gather data for each node
                    #        for now just return the flattened list of nodes)
        my $rsp;    #build up fewer requests, be less chatty
        if ($argc)
        {
            my %tables;
            foreach (@ARGV)
            {
                my $table;
                my $column;
                my $value;
                my $matchtype;
                my $temp = $_;
                if ($temp =~ /^[^=]*\!=/) {
                    ($temp,$value) = split /!=/,$temp,2;
                    $matchtype='natch';
                }
                elsif ($temp =~ /^[^=]*=~/) {
                    ($temp,$value) = split /=~/,$temp,2;
                    $value =~ s/^\///;
                    $value =~ s/\/$//;
                    $matchtype='regex';
                }
                elsif ($temp =~ /[^=]*==/) {
                    ($temp,$value) = split /==/,$temp,2;
                    $matchtype='match';
                }
                elsif ($temp =~ /[^=]*!~/) {
                    ($temp,$value) = split /!~/,$temp,2;
                    $value =~ s/^\///;
                    $value =~ s/\/$//;
                    $matchtype='negex';
                }
                if ($shortnames{$temp})
                {
                    ($table, $column) = @{$shortnames{$temp}};
                    $terse--;
                } elsif ($temp =~ /\./) {
                    ($table, $column) = split('\.', $temp, 2);
                    $terse--;
                } elsif ($xCAT::Schema::tabspec{$temp}) {
                   $terse=0;
                   $table = $temp;
                   foreach my $column (@{$xCAT::Schema::tabspec{$table}->{cols}}) {
                      unless (grep /^$column$/, @{$tables{$table}}) {
                        push @{$tables{$table}},[$column,"$temp.$column"];
                      }
                   }
                   next;
                } else {
                   $callback->({error=>"$temp not a valid table.column description",errorcode=>[1]});
                   next;
                }


                unless (grep /$column/,@{$xCAT::Schema::tabspec{$table}->{cols}}) {
                   $callback->({error=>"$table.$column not a valid table.column description",errorcode=>[1]});
                   next;
                }
                unless (grep /^$column$/, @{$tables{$table}})
                {
                    push @{$tables{$table}},
                      [$column, $temp,$value,$matchtype];    #Mark this as something to get
                }
            }
            my $tab;
            my %noderecs;
            my %filterednodes=();
            my %mustdisplaynodes=();
            my %forcedisplaykeys=();
            foreach $tab (keys %tables)
            {
                my $tabh = xCAT::Table->new($tab);
                unless ($tabh) { next; }

                #print Dumper($tables{$tab});
                my $node;
                my %labels;
                my %values;
                my %matchtypes;
                my @cols=();
                foreach (@{$tables{$tab}}) 
                {
                    push @cols, $_->[0];
                    $labels{$_->[0]} = $_->[1]; #Remember user supplied discreptions and use them
                    if (not defined  $values{$_->[0]}) { #If selection criteria not previously specified
                        $values{$_->[0]} = $_->[2];  #assign selection criteria
                    } elsif (not defined $_->[2]) { #we already have selection criteria, but this field isn't that
                        $forcedisplaykeys{$_->[0]}=1; #allow switch.switch=~switch switch.switch, for example
                    } else { #User attempted multiple selection criteria on the same field, bail
                        $callback->({error=>["Multiple selection critera for ".$labels{$_->[0]}]});
                        return;
                    }
                    if (not defined $matchtypes{$_->[0]}) { 
                        $matchtypes{$_->[0]} = $_->[3]; 
                    }
                }
                my $nodekey = "node";
                if (defined $xCAT::Schema::tabspec{$tab}->{nodecol}) {
                    $nodekey = $xCAT::Schema::tabspec{$tab}->{nodecol}
                };

                my $removenodecol=1;
                if (grep /^$nodekey$/,@cols) {
                    $removenodecol=0;
                }
                my $rechash=$tabh->getNodesAttribs($nodes,\@cols);
                foreach $node (@$nodes)
                {
                    my @cols;
                    my $recs = $rechash->{$node}; #$tabh->getNodeAttribs($node, \@cols);
                    my %satisfiedreqs=();
                    foreach my $rec (@$recs) {

                        foreach (keys %$rec)
                        {
                          if ($_ eq $nodekey and $removenodecol) { next; }
                          $satisfiedreqs{$_}=1;
                          my %datseg=();
                          if (defined $values{$_}) {
                              my $criteria=$values{$_}; #At least vim highlighting makes me worry about syntax in regex
                              if ($matchtypes{$_} eq 'match' and not ($rec->{$_} eq $criteria) or
                                  $matchtypes{$_} eq 'natch' and ($rec->{$_} eq $criteria) or
                                  $matchtypes{$_} eq 'regex' and ($rec->{$_} !~ /$criteria/) or
                                  $matchtypes{$_} eq 'negex' and ($rec->{$_} =~ /$criteria/)) {
                              #unless ($rec->{$_} eq $values{$_}) { 
                                  $filterednodes{$node}=1;
                                  next; 
                              }
                              $mustdisplaynodes{$node}=1;
                              unless ($forcedisplaykeys{$_}) { next; } #skip if only specified once on command line
                          } 
                          unless ($terse > 0) {
                              $datseg{data}->[0]->{desc}     = [$labels{$_}];
                          }
                          $datseg{data}->[0]->{contents} = [$rec->{$_}];
                          $datseg{name} = [$node]; #{}->{contents} = [$rec->{$_}];
                          push @{$noderecs{$node}}, \%datseg;
                        }
                    }
                    foreach (keys %labels) {
                        unless (defined $satisfiedreqs{$_}) {
                            my %dataseg;
                            if (defined $values{$_}) {
                                my $criteria = $values{$_};
                              if ($matchtypes{$_} eq 'match' and not ("" eq $criteria) or
                                  $matchtypes{$_} eq 'natch' and ("" eq $criteria) or
                                  $matchtypes{$_} eq 'regex' and ("" !~ /$criteria/) or
                                  $matchtypes{$_} eq 'negex' and ("" =~ /$criteria/)) {
                              #unless ("" eq $values{$_}) { 
                                  $filterednodes{$node}=1;
                                  next; 
                              }
                              $mustdisplaynodes{$node}=1;
                              unless ($forcedisplaykeys{$_}) { next; }
                            } 
                            $dataseg{name} = [ $node ];
                            unless ($terse > 0) {
                                $dataseg{data}->[0]->{desc} = [$labels{$_}];
                            }
                            $dataseg{data}->[0]->{contents} = [""];
                            push @{$noderecs{$node}}, \%dataseg;
                        }
                    }
                }

                #$rsp->{node}->[0]->{data}->[0]->{desc}->[0] = $_;
                #$rsp->{node}->[0]->{data}->[0]->{contents}->[0] = $_;
                $tabh->close();
                undef $tabh;
            }
            foreach (keys %mustdisplaynodes) {
                if ($filterednodes{$_} or defined $noderecs{$_}) {
                    next;
                }
                $noderecs{$_}=[{name=>[$_]}];
            }
            foreach (keys %filterednodes) {
                delete $noderecs{$_};
            }
            foreach (sort (keys %noderecs))
            {
                push @{$rsp->{"node"}}, @{$noderecs{$_}};
            }
        }
        else
        {
            foreach (@$nodes)
            {
                my $noderec;
                $noderec->{name}->[0] = ($_);
                push @{$rsp->{node}}, $noderec;
            }
        }
        $callback->($rsp);
    }
    else
    {

        # no noderange specified on command line, return list of all nodes
        my $nodelisttab;
        if ($nodelisttab = xCAT::Table->new("nodelist"))
        {
            my @attribs = ("node");
            my @ents    = $nodelisttab->getAllAttribs(@attribs);
            foreach (@ents)
            {
                my $rsp;
                if ($_->{node})
                {
                    $rsp->{node}->[0]->{name}->[0] = ($_->{node});

                    #              $rsp->{node}->[0]->{data}->[0]->{contents}->[0]="$_->{node} node contents";
                    #              $rsp->{node}->[0]->{data}->[0]->{desc}->[0]="$_->{node} node desc";
                    $callback->($rsp);
                }
            }
        }
    }

    return 0;
}
