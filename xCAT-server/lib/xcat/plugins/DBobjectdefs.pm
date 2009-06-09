#!/usr/bin/env perl -w
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#####################################################
#
#  xCAT plugin package to handle commands that manage the xCAT object
#     definitions
#
#####################################################

package xCAT_plugin::DBobjectdefs;

use xCAT::NodeRange;
use xCAT::Schema;
use xCAT::DBobjUtils;
use Data::Dumper;
use Getopt::Long;
use xCAT::MsgUtils;
use strict;

# options can be bundled up like -vV
Getopt::Long::Configure("bundling");
$Getopt::Long::ignorecase = 0;

#
# Globals
#

%::CLIATTRS;      # attr=values provided on the command line
%::FILEATTRS;     # attr=values provided in an input file
%::FINALATTRS;    # final set of attr=values that are used to set
                  #	the object

%::objfilehash;   #  hash of objects/types based of "-f" option
                  #	(list in file)

%::WhereHash;     # hash of attr=val from "-w" option
@::AttrList;      # list of attrs from "-i" option

# object type lists
@::clobjtypes;      # list of object types derived from the command line.
@::fileobjtypes;    # list of object types from input file ("-x" or "-z")

#  object name lists
@::clobjnames;      # list of object names derived from the command line
@::fileobjnames;    # list of object names from an input file
@::objfilelist;     # list of object names from the "-f" option
@::allobjnames;     # combined list

@::noderange;       # list of nodes derived from command line

#------------------------------------------------------------------------------

=head1    DBobjectdefs

This program module file supports the management of the xCAT data object
definitions.

Supported xCAT data object commands:
     mkdef - create xCAT data object definitions.
     lsdef - list xCAT data object definitions.
     chdef - change xCAT data object definitions.
     rmdef - remove xCAT data object definitions.

If adding to this file, please take a moment to ensure that:

    1. Your contrib has a readable pod header describing the purpose and use of
      the subroutine.

    2. Your contrib is under the correct heading and is in alphabetical order
    under that heading.

    3. You have run tidypod on your this file and saved the html file

=cut

#------------------------------------------------------------------------------

=head2    xCAT data object definition support

=cut

#------------------------------------------------------------------------------

#----------------------------------------------------------------------------

=head3  handled_commands

        Return a list of commands handled by this plugin

=cut

#-----------------------------------------------------------------------------

sub handled_commands
{
    return {
            mkdef => "DBobjectdefs",
            lsdef => "DBobjectdefs",
            chdef => "DBobjectdefs",
            rmdef => "DBobjectdefs"
            };
}

#----------------------------------------------------------------------------

=head3   process_request

        Check for xCAT command and call the appropriate subroutine.

        Arguments:

        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub process_request
{

    $::request  = shift;
    $::callback = shift;

    my $ret;
    my $msg;

    # globals used by all subroutines.
    $::command  = $::request->{command}->[0];
    $::args     = $::request->{arg};
    $::filedata = $::request->{stdin}->[0];

    # figure out which cmd and call the subroutine to process
    if ($::command eq "mkdef")
    {
        ($ret, $msg) = &defmk;
    }
    elsif ($::command eq "lsdef")
    {
        ($ret, $msg) = &defls;
    }
    elsif ($::command eq "chdef")
    {
        ($ret, $msg) = &defch;
    }
    elsif ($::command eq "rmdef")
    {
        ($ret, $msg) = &defrm;
    }

	my $rsp;
    if ($msg)
    {
        $rsp->{data}->[0] = $msg;
        $::callback->($rsp);
    }
	if ($ret > 0) {
		$rsp->{errorcode}->[0] = $ret;
	}
}

#----------------------------------------------------------------------------

=head3   processArgs

        Process the command line. Covers all four commands.

		Also - Process any input files provided on cmd line.

        Arguments:

        Returns:
                0 - OK
                1 - just print usage
				2 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub processArgs
{
    my $gotattrs = 0;

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        return 2;
    }

    if (scalar(@ARGV) <= 0) {
        return 2;
    }

    # parse the options - include any option from all 4 cmds
	Getopt::Long::Configure("no_pass_through");
    if (
        !GetOptions(
                    'all|a'     => \$::opt_a,
                    'dynamic|d' => \$::opt_d,
                    'f|force'   => \$::opt_f,
                    'i=s'       => \$::opt_i,
                    'help|h|?'    => \$::opt_h,
                    'long|l'    => \$::opt_l,
                    'm|minus'   => \$::opt_m,
                    'o=s'       => \$::opt_o,
                    'p|plus'    => \$::opt_p,
                    't=s'       => \$::opt_t,
                    'verbose|V' => \$::opt_V,
                    'version|v' => \$::opt_v,
                    'w=s'       => \$::opt_w,
                    'x|xml'     => \$::opt_x,
                    'z|stanza'  => \$::opt_z
        )
      )
    {

        # return 2;
    }

    #  opt_x not yet supported
    if ($::opt_x)
    {

        my $rsp;
        $rsp->{data}->[0] =
          "The \'-x\' (XML format) option is not yet implemented.";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        return 2;
    }

    # can get object names in many ways - easier to keep track
    $::objectsfrom_args = 0;
    $::objectsfrom_opto = 0;
    $::objectsfrom_optt = 0;
    $::objectsfrom_opta = 0;
    $::objectsfrom_nr   = 0;
    $::objectsfrom_file = 0;

    #
    # process @ARGV
    #

    #  - put attr=val operands in ATTRS hash
    while (my $a = shift(@ARGV))
    {

        if (!($a =~ /=/))
        {

            # the first arg could be a noderange or a list of args
            if (($::opt_t) && ($::opt_t ne 'node'))
            {

                # if we know the type isn't "node" then set the object list
                @::clobjnames = split(',', $a);
                $::objectsfrom_args = 1;
            }
            elsif (!$::opt_t || ($::opt_t eq 'node'))
            {

                # if the type was not provided or it is "node"
                #	then set noderange
                @::noderange = &noderange($a, 0);
            }

        }
        else
        {

            # if it has an "=" sign its an attr=val - we hope
            #   - this will handle "attr= "
            my ($attr, $value) = $a =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
            if (!defined($attr) || !defined($value))
            {
                my $rsp;
                $rsp->{data}->[0] = "Incorrect \'attr=val\' pair - $a\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 3;
            }

            $gotattrs = 1;

            # put attr=val in hash
            $::ATTRS{$attr} = $value;

        }
    }

    # Option -h for Help
    # if user specifies "-t" & "-h" they want a list of valid attrs
    if (defined($::opt_h) && !defined($::opt_t))
    {
        return 2;
    }

    # Option -v for version - do we need this???
    if (defined($::opt_v))
    {
        my $rsp;
		my $version=xCAT::Utils->Version();
        push @{$rsp->{data}}, "$::command - $version\n";
        xCAT::MsgUtils->message("I", $rsp, $::callback);
        return 1;    # no usage - just exit
    }

    # Option -V for verbose output
    if (defined($::opt_V))
    {
        $::verbose = 1;
        $::VERBOSE = 1;
    } else {
		$::verbose = 0;
        $::VERBOSE = 0;
	}

    #
    # process the input file - if provided
    #
    if ($::filedata)
    {

        my $rc = xCAT::DBobjUtils->readFileInput($::filedata);

        if ($rc)
        {
            my $rsp;
            $rsp->{data}->[0] = "Could not process file input data.\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
            return 1;
        }

        #   - %::FILEATTRS{fileobjname}{attr}=val
        # set @::fileobjtypes, @::fileobjnames, %::FILEATTRS

        $::objectsfrom_file = 1;
    }

    #
    #  determine the object types
    #

    # could have comma seperated list of types
    if ($::opt_t)
    {
        my @tmptypes;

        if ($::opt_t =~ /,/)
        {

            # can't have mult types when using attr=val
            if ($gotattrs)
            {
                my $rsp;
                $rsp->{data}->[0] =
                  "Cannot combine multiple types with \'att=val\' pairs on the command line.\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 3;
            }
            else
            {
                @tmptypes = split(',', $::opt_t);
            }
        }
        else
        {
            push(@tmptypes, $::opt_t);
        }

        # check for valid types
        my @xdeftypes;
        foreach my $k (keys %{xCAT::Schema::defspec})
        {
            push(@xdeftypes, $k);
        }

        foreach my $t (@tmptypes)
        {
            if (!grep(/$t/, @xdeftypes))
            {
                my $rsp;
                $rsp->{data}->[0] =
                  "\nType \'$t\' is not a valid xCAT object type.";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
				return 3;
            }
            else
            {
                chomp $t;
                push(@::clobjtypes, $t);
            }
        }
    }


    # must have object type(s) - default if not provided
    if (!@::clobjtypes && !@::fileobjtypes && !$::opt_a && !$::opt_t)
    {

        # make the default type = 'node' if not specified
        push(@::clobjtypes, 'node');
        my $rsp;
		if ( !$::opt_z && !$::opt_x) {
			# don't want this msg in stanza or xml output
        	#$rsp->{data}->[0] = "Assuming an object type of \'node\'.\n";
        	#xCAT::MsgUtils->message("I", $rsp, $::callback);
		}
    }

    # if user specifies "-t" & "-h" they want valid type or attrs info
    if ($::opt_h && $::opt_t)
    {

        # give the list of attr names for each type specified
        foreach my $t (@::clobjtypes)
        {
            my $rsp;

			if ($t eq 'site') {
				my $schema = xCAT::Table->getTableSchema('site');
				my $desc;

				$rsp->{data}->[0] = "\nThere can only be one xCAT site definition. This definition consists \nof an unlimited list of user-defined attributes and values that represent \nglobal settings for the whole cluster. The following is a list \nof the attributes currently supported by xCAT.\n"; 

				$desc = $schema->{descriptions}->{'key'};
				$rsp->{data}->[1] = $desc;

				xCAT::MsgUtils->message("I", $rsp, $::callback);
				next;
			}

			# get the data type  definition from Schema.pm
            my $datatype = $xCAT::Schema::defspec{$t};

			$rsp->{data}->[0] = "The valid attribute names for object type '$t' are:\n";

            # get the objkey for this type object (ex. objkey = 'node')
            my $objkey = $datatype->{'objkey'};

            $rsp->{data}->[1] = "Attribute          Description\n";

            my @alreadydone;    # the same attr may appear more then once
			my @attrlist;
            my $outstr = "";

            foreach my $this_attr (@{$datatype->{'attrs'}})
            {
                my $attr = $this_attr->{attr_name};
                my $desc = $this_attr->{description};
                if (!defined($desc)) {     
					# description key not there, so go to the corresponding 
					#	entry in tabspec to get the description
                	my ($tab, $at) = split(/\./, $this_attr->{tabentry});
                	my $schema = xCAT::Table->getTableSchema($tab);
                	$desc = $schema->{descriptions}->{$at};
                }

				# could display the table that the attr is in
				# however some attrs are in more than one table!!!
				#my ($tab, $junk) = split('\.', $this_attr->{tabentry});

                if (!grep(/^$attr$/, @alreadydone))
                {
					my $space = (length($attr)<7 ? "\t\t" : "\t");
					push(@attrlist, "$attr:$space$desc\n\n");
                }
                push(@alreadydone, $attr);
            }

			# print the output in alphabetical order
            foreach my $a (sort @attrlist) {
                $outstr .= "$a";
            }
            chop($outstr);  chop($outstr);
            $rsp->{data}->[2] = $outstr;

			# the monitoring table is  special
			if ($t eq 'monitoring') {
				$rsp->{data}->[3] = "\nYou can also include additional monitoring plug-in specific settings. These settings will be used by the monitoring plug-in to customize the behavior such as event filter, sample interval, responses etc.\n";
			}
			
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }

        return 1;
    }

    #
    #  determine the object names
    #

    # -  get object names from the -o option or the noderange
    if ($::opt_o)
    {

        $::objectsfrom_opto = 1;

        # special handling for site table !!!!!
        if (($::opt_t eq 'site') && ($::opt_o ne 'clustersite'))
        {
            push(@::clobjnames, 'clustersite');
			my $rsp;
            $rsp->{data}->[0] ="Only one site definition is supported.";
			$rsp->{data}->[1] = "Setting the name of the site definition to \'clustersite\'.\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);

        }
        elsif ($::opt_t eq 'node')
        {
            @::clobjnames = &noderange($::opt_o, 0);
        }
        else
        {

            # make a list
            if ($::opt_o =~ /,/)
            {
                @::clobjnames = split(',', $::opt_o);
            }
            else
            {
                push(@::clobjnames, $::opt_o);
            }
        }
    }
    elsif (@::noderange && (@::clobjtypes[0] eq 'node'))
    {

        # if there's no object list and the type is node then the
        #   noderange list is assumed to be the object names list
        @::clobjnames     = @::noderange;
        $::objectsfrom_nr = 1;
    }

    # special case for site table!!!!!!!!!!!!!!
    if (($::opt_t eq 'site') && !$::opt_o)
    {
		my $rsp;
        $rsp->{data}->[0] ="Setting the name of the site definition to \'clustersite\'.";
        xCAT::MsgUtils->message("I", $rsp, $::callback);
        push(@::clobjnames, 'clustersite');
        $::objectsfrom_opto = 1;
    }

    # if there is no other input for object names then we need to
    #	find all the object names for the specified types
    if ($::opt_t
        && !(   $::opt_o
             || $::filedata
             || $::opt_a
             || @::noderange
             || @::clobjnames))
    {
        my @tmplist;

        # also ne chdef ????????
        if ($::command ne 'mkdef')
        {

            $::objectsfrom_optt = 1;

            # could have multiple type
            foreach my $t (@::clobjtypes)
            {

                # special case for site table !!!!
                if ($t eq 'site')
                {
                    push(@tmplist, 'clustersite');

                }
                else
                {

                    #  look up all objects of this type in the DB ???
                    @tmplist = xCAT::DBobjUtils->getObjectsOfType($t);

                    unless (@tmplist)
                    {
                        my $rsp;
                        $rsp->{data}->[0] =
                          "Could not get objects of type \'$t\'.\n";
                        #$rsp->{data}->[1] = "Skipping to the next type.\n";
                        xCAT::MsgUtils->message("E", $rsp, $::callback);
                        return 3;
                    }
                }

                # add objname and type to hash and global list
                foreach my $o (@tmplist)
                {
                    push(@::clobjnames, $o);
                    $::ObjTypeHash{$o} = $t;
                }
            }
        }
    }


    # can't have -a with other obj sources
    if ($::opt_a
        && ($::opt_o || $::filedata || @::noderange))
    {

        my $rsp;
        $rsp->{data}->[0] =
          "Cannot use \'-a\' with \'-o\', a noderange or file input.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        return 3;
    }

    #  if -a then get a list of all DB objects
    if ($::opt_a)
    {

        my @tmplist;

        # for every type of data object get the list of defined objects
        foreach my $t (keys %{xCAT::Schema::defspec})
        {

            $::objectsfrom_opta = 1;

            my @tmplist;
            @tmplist = xCAT::DBobjUtils->getObjectsOfType($t);

            # add objname and type to hash and global list
            if (scalar(@tmplist) > 0)
            {
                foreach my $o (@tmplist)
                {
                    push(@::clobjnames, $o);
                    $::AllObjTypeHash{$o} = $t;
                }
            }
        }
    }

    # must have object name(s) -
	if ((scalar(@::clobjnames) == 0) && (scalar(@::fileobjnames) == 0))
    {
        return 3;
    }

    # combine object name all object names provided
    @::allobjnames = @::clobjnames;
	if (scalar(@::fileobjnames) > 0)
    {

        # add list from stanza or xml file
        push @::allobjnames, @::fileobjnames;
    }
	elsif (scalar(@::objfilelist) > 0)
    {

        # add list from "-f" file option
        push @::allobjnames, @::objfilelist;
    }

    #  check for the -w option
    if ($::opt_w)
    {
        my @tmpWhereList = split(',', $::opt_w);
        foreach my $w (@tmpWhereList)
        {
            if ($w =~ /=/)
            {
                my ($a, $v) = $w =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
                if (!defined($a) || !defined($v))
                {
                    my $rsp;
                    $rsp->{data}->[0] = "Incorrect \'attr=val\' pair - $a\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    return 3;
                }

                $::WhereHash{$a} = $v;

            }
        }
    }

    #  check for the -i option
    if ($::opt_i && ($::command ne 'lsdef'))
    {
        my $rsp;
        $rsp->{data}->[0] =
          "The \'-i\' option is only valid for the lsdef command.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        return 3;
    }

    #  just make a global list of the attr names provided
    if ($::opt_i)
    {
        @::AttrList = split(',', $::opt_i);
    }

    return 0;
}

#----------------------------------------------------------------------------

=head3   defmk

        Support for the xCAT mkdef command.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
			Object names to create are derived from
				-o, -t, w, -z, -x, or noderange!
			Attr=val pairs come from cmd line args or -z/-x files
=cut

#-----------------------------------------------------------------------------

sub defmk
{

    @::allobjnames = [];

    my $rc    = 0;
    my $error = 0;

	my %objTypeLists;

    # process the command line
    $rc = &processArgs;
    if ($rc != 0)
    {

        # rc: 0 - ok, 1 - return, 2 - help, 3 - error
        if ($rc != 1)
        {
            &defmk_usage;
        }
        return ($rc - 1);
    }

    # check options unique to these commands
    if ($::opt_p || $::opt_m)
    {

        # error
        my $rsp;
        $rsp->{data}->[0] =
          "The \'-p\' and \'-m\' options are not valid for the mkdef command.";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        &defmk_usage;
        return 1;
    }

    if ($::opt_t && ($::opt_a || $::opt_z || $::opt_x))
    {
        my $rsp;
        $rsp->{data}->[0] =
          "Cannot combine \'-t\' and \'-a\', \'-z\', or \'-x\' options.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        &defmk_usage;
        return 1;
    }

	# can't have -z with other obj sources
	if ($::opt_z && ($::opt_o || @::noderange))
	{
		my $rsp;
		$rsp->{data}->[0] = "Cannot use \'-z\' with \'-o\' or a noderange.";
		$rsp->{data}->[1] = "Example of -z usage:\n\t\'cat stanzafile | mkdef -z\'\n";
		xCAT::MsgUtils->message("E", $rsp, $::callback);
		&defmk_usage;
		return 1;
	}

    # check to make sure we have a list of objects to work with
    if (!@::allobjnames)
    {
        my $rsp;
        $rsp->{data}->[0] = "No object names were provided.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        &defmk_usage;
        return 1;
    }

    # set $objtype & fill in cmd line hash
    if (%::ATTRS || ($::opt_t eq "group"))
    {

        # if attr=val on cmd line then could only have one type
        $::objtype = @::clobjtypes[0];

        #
        #  set cli attrs for each object definition
        #
        foreach my $objname (@::clobjnames)
        {

            #  set the objtype attr - if provided
            if ($::objtype)
            {
                $::CLIATTRS{$objname}{objtype} = $::objtype;
            }

            # get the data type definition from Schema.pm
            my $datatype = $xCAT::Schema::defspec{$::objtype};
            my @list;
            foreach my $this_attr (sort @{$datatype->{'attrs'}})
            {
                my $a = $this_attr->{attr_name};
                push(@list, $a);
            }

            # set the attrs from the attr=val pairs
            foreach my $attr (keys %::ATTRS)
            {
				if (!grep(/$attr/, @list) && ($::objtype ne 'site') && ($::objtype ne 'monitoring'))
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "\'$attr\' is not a valid attribute name for for an object type of \'$::objtype\'.\n";
                    $rsp->{data}->[1] = "Skipping to the next attribute.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    $error = 1;
                    next;
                }
                else
                {
                    $::CLIATTRS{$objname}{$attr} = $::ATTRS{$attr};
                    if ($::verbose)
                    {
                        my $rsp;
                        $rsp->{data}->[0] = "\nFunction: defmk-->set the attrs for each object definition";
                        $rsp->{data}->[1] = "defmk: objname=$objname, attr=$attr, value=$::ATTRS{$attr}";
                        xCAT::MsgUtils->message("I", $rsp, $::callback);
                    }
                }
            }    # end - foreach attr

        }
    }

    #
    #   Pull all the pieces together for the final hash
    #		- combines the command line attrs and input file attrs if provided
    #
    if (&setFINALattrs != 0)
    {
        $error = 1;
    }

    # we need a list of objects that are
    #	already defined for each type.
    foreach my $t (@::finalTypeList)
    {

        # special case for site table !!!!!!!!!!!!!!!!!!!!
        if ($t eq 'site')
        {
            @{$objTypeLists{$t}} = 'clustersite';
        }
        else
        {

            @{$objTypeLists{$t}} = xCAT::DBobjUtils->getObjectsOfType($t);
        }
        if ($::verbose)
        {
            my $rsp;
            $rsp->{data}->[0] = "\ndefmk: list objects that are defined for each type";
            $rsp->{data}->[1] = "@{$objTypeLists{$t}}\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }
    }

    OBJ: foreach my $obj (keys %::FINALATTRS)
    {

        my $type = $::FINALATTRS{$obj}{objtype};

        # check to make sure we have type
        if (!$type)
        {
            my $rsp;
            $rsp->{data}->[0] = "No type was provided for object \'$obj\'.\n";
            $rsp->{data}->[1] = "Skipping to the next object.\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
            next;
        }

		# we don't want to overwrite any existing table row.  This could
		#	happen if there are multiple table keys. (ex. networks table -
		#		where the object name is not either of the table keys - net 
		#		& mask)
		#  just handle network objects for now - 
		if ($type eq 'network') {
			my @nets = xCAT::DBobjUtils->getObjectsOfType('network');
			my %objhash;
			foreach my $n (@nets) {
				$objhash{$n} = $type;
			}
			my %nethash = xCAT::DBobjUtils->getobjdefs(\%objhash);
			foreach my $o (keys %nethash) {
				if ( ($nethash{$o}{net} eq $::FINALATTRS{$obj}{net})  && ($nethash{$o}{mask} eq $::FINALATTRS{$obj}{mask}) ) {
					my $rsp;
					$rsp->{data}->[0] = "A network definition called \'$o\' already exists that contains the same net and mask values. Cannot create a definition for \'$obj\'.\n";
					xCAT::MsgUtils->message("E", $rsp, $::callback);
					$error = 1;
					delete $::FINALATTRS{$obj};
					next OBJ;
				}	
			}
		}

        # if object already exists
        if (grep(/^$obj$/, @{$objTypeLists{$type}}))
        {
            if ($::opt_f)
            {
                # remove the old object
				my %objhash;
                $objhash{$obj} = $type;
                if (xCAT::DBobjUtils->rmobjdefs(\%objhash) != 0)
                {
                    $error = 1;
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not remove the definition for \'$obj\'.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                }
            }
            else
            {

                #  won't remove the old one unless the force option is used
                my $rsp;
                $rsp->{data}->[0] =
                  "\nA definition for \'$obj\' already exists.\n";
                $rsp->{data}->[1] =
                  "To remove the old definition and replace it with \na new definition use the force \'-f\' option.\n";
                $rsp->{data}->[2] =
                  "To change the existing definition use the \'chdef\' command.\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                $error = 1;
                next;

            }

        }

        # need to handle group definitions - special!
        if ($type eq 'group')
        {

            my @memberlist;

            # if the group type was not set then set it
            if (!$::FINALATTRS{$obj}{grouptype})
            {
                if ($::opt_d)
                {
                    $::FINALATTRS{$obj}{grouptype} = 'dynamic';
                    $::FINALATTRS{$obj}{members}   = 'dynamic';
                }
                else
                {
                    $::FINALATTRS{$obj}{grouptype} = 'static';
                }
            }

            # if dynamic and wherevals not set then set to opt_w
            if ($::FINALATTRS{$obj}{grouptype} eq 'dynamic')
            {
                if (!$::FINALATTRS{$obj}{wherevals})
                {
                    if ($::opt_w)
                    {
                        $::FINALATTRS{$obj}{wherevals} = $::opt_w;
                    }
                    else
                    {
                        my $rsp;
                        $rsp->{data}->[0] =
                          "The \'where\' attributes and values were not provided for dynamic group \'$obj\'.\n";
                        $rsp->{data}->[1] = "Skipping to the next group.\n";
                        xCAT::MsgUtils->message("E", $rsp, $::callback);
                        next;
                    }
                }
            }

            # if static group then figure out memberlist
            if ($::FINALATTRS{$obj}{grouptype} eq 'static')
            {
                if ($::opt_w && $::FINALATTRS{$obj}{members})
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Cannot use a list of members together with the \'-w\' option.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    return 1;
                }

                if ($::FINALATTRS{$obj}{members})
                {
                    @memberlist = &noderange($::FINALATTRS{$obj}{members}, 0);

                    #  don't list all the nodes in the group table
                    #	set the value to static and we'll figure out the list
                    # 	by looking in the nodelist table
                    $::FINALATTRS{$obj}{members} = 'static';

                }
                else
                {
                    if ($::opt_w)
                    {
                        $::FINALATTRS{$obj}{members} = 'static';

                        #  get a list of nodes whose attr values match the
                        #   "where" values and make that the memberlist of
                        #   the group.

                        # get a list of all node nodes
                        my @tmplist =
                          xCAT::DBobjUtils->getObjectsOfType('node');

                        # create a hash of obj names and types
						my %objhash;
                        foreach my $n (@tmplist)
                        {
                            $objhash{$n} = 'node';
                        }

                        # get all the attrs for these nodes
                        my %myhash = xCAT::DBobjUtils->getobjdefs(\%objhash);

                        # see which ones match the where values
                        foreach my $objname (keys %myhash)
                        {

                            #  all the "where" attrs must match the object attrs
                            my $addlist = 1;

                            foreach my $testattr (keys %::WhereHash)
                            {
								if ( !($myhash{$objname}{$testattr} =~ /\b$::WhereHash{$testattr}\b/) )
                                {

                                    # don't disply
                                    $addlist = 0;
                                    next;
                                }
                            }

                            if ($addlist)
                            {
                                push(@memberlist, $objname);

                            }
                        }

                    }
                    else
                    {
                        my $rsp;
                        $rsp->{data}->[0] =
                          "Cannot determine a member list for group \'$obj\'.\n";
                        xCAT::MsgUtils->message("E", $rsp, $::callback);
                    }
                }

                #  need to add group name to all members in nodelist table
                my $tab =
                  xCAT::Table->new('nodelist', -create => 1, -autocommit => 0);

                my $newgroups;
                foreach my $n (@memberlist)
                {
                    if ($::verbose)
                    {
                        my $rsp;
                        $rsp->{data}->[0] = "defmk: add group name [$n] to nodelist table";
                        xCAT::MsgUtils->message("I", $rsp, $::callback);
                    }

                    #  add this group name to the node entry in
                    #		the nodelist table
                    #$nodehash{$n}{groups} = $obj;

                    # get the current value
                    my $grps = $tab->getNodeAttribs($n, ['groups']);

                    # if it's not already in the "groups" list then add it
                    my @tmpgrps = split(/,/, $grps->{'groups'});

                    if (!grep(/^$obj$/, @tmpgrps))
                    {
                        if ($grps and $grps->{'groups'})
                        {
                            $newgroups = "$grps->{'groups'},$obj";

                        }
                        else
                        {
                            $newgroups = $obj;
                        }
                    }

                    #  add this group name to the node entry in
                    #       the nodelist table
                    if ($newgroups)
                    {
                        $tab->setNodeAttribs($n, {groups => $newgroups});
                    }

                }

                $tab->commit;


            }
        }    # end - if group type

        #
        #  Need special handling for node objects that have the
        #	groups attr set - may need to create group defs
        #
        if (($type eq "node") && $::FINALATTRS{$obj}{groups})
        {

            # get the list of groups in the "groups" attr
            my @grouplist;
            @grouplist = split(/,/, $::FINALATTRS{$obj}{groups});

            # get the list of all defined group objects

            # getObjectsOfType("group") only returns static groups,
            # generally speaking, the nodegroup table should includes all the static and dynamic groups,
            # but it is possible that the static groups are not in nodegroup table,
            # so we have to get the static and dynamic groups separately.
            my @definedgroups = xCAT::DBobjUtils->getObjectsOfType("group"); #static groups
            my $grptab = xCAT::Table->new('nodegroup');
            my @grplist = @{$grptab->getAllEntries()}; #dynamic groups and static groups in nodegroup table

			my %GroupHash;
            foreach my $g (@grouplist)
            {
                my $indynamicgrp = 0;
                #check the dynamic node groups
                foreach my $grpdef_ref (@grplist) 
                {
                     my %grpdef = %$grpdef_ref;
                     if (($grpdef{'groupname'} eq $g) && ($grpdef{'grouptype'} eq 'dynamic'))
                     {
                         $indynamicgrp = 1;
                         my $rsp;
                         $rsp->{data}->[0] = "nodegroup $g is a dynamic node group, should not add a node into a dynamic node group statically.\n";
                         xCAT::MsgUtils->message("I", $rsp, $::callback);
                          last;
                      }
                }
                if (!$indynamicgrp)
                {
                    if (!grep(/^$g$/, @definedgroups))
                    {
                        # define it
                        $GroupHash{$g}{objtype}   = "group";
                        $GroupHash{$g}{grouptype} = "static";
                        $GroupHash{$g}{members}   = "static";
                     }
                }
            }
            if (defined(%GroupHash))
            {
                if ($::verbose)
                {
                    my $rsp;
                    $rsp->{data}->[0] = "Write GroupHash: %GroupHash to xCAT database\n";
                    xCAT::MsgUtils->message("I", $rsp, $::callback);
                }
                if (xCAT::DBobjUtils->setobjdefs(\%GroupHash) != 0)
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not write data to the xCAT database.\n";

                    # xCAT::MsgUtils->message("E", $rsp, $::callback);
                    $error = 1;
                }
            }

        }    # end - if type = node
        # If none of the attributes in nodelist is defined: groups,status,appstatus,primarysn,comments,disable
        # the nodelist table will not be updated, caused mkdef failed.
        # We can give a restriction that the "groups" must be specified with mkdef,
        # but it is not so reasonable especially when the dynamic node group feature is implemented.
        # fixing this issue with specifying an empty "groups" if the "groups" is not specified with the command line or stanza file
        if (($type eq "node") && !defined($::FINALATTRS{$obj}{groups}))
        {
            $::FINALATTRS{$obj}{groups} = '';
        }

    } # end of each obj

    #
    #  write each object into the tables in the xCAT database
    #

    if (xCAT::DBobjUtils->setobjdefs(\%::FINALATTRS) != 0)
    {
        my $rsp;
        $rsp->{data}->[0] = "Could not write data to the xCAT database.\n";

        #		xCAT::MsgUtils->message("E", $rsp, $::callback);
        $error = 1;
    }

    if ($error)
    {
        my $rsp;
        $rsp->{data}->[0] =
          "One or more errors occured when attempting to create or modify xCAT \nobject definitions.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        return 1;
    }
    else
    {
        if ($::verbose)
        {

            #  give results
            my $rsp;
            $rsp->{data}->[0] =
              "The database was updated for the following objects:\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);

            my $n = 1;
            foreach my $o (sort(keys %::FINALATTRS))
            {
                $rsp->{data}->[$n] = "$o\n";
                $n++;
            }
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }
        else
        {
            my $rsp;
            $rsp->{data}->[0] =
              "Object definitions have been created or modified.\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }
        return 0;
    }
}

#----------------------------------------------------------------------------

=head3   defch

        Support for the xCAT chdef command.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
			Object names to create are derived from
				-o, -t, w, -z, -x, or noderange!
			Attr=val pairs come from cmd line args or -z/-x files
=cut

#-----------------------------------------------------------------------------

sub defch
{

    @::allobjnames = [];

    my $rc    = 0;
    my $error = 0;
	my $firsttime = 1;

	my %objTypeLists;

    # process the command line
    $rc = &processArgs;
    if ($rc != 0)
    {

        # rc: 0 - ok, 1 - return, 2 - help, 3 - error
        if ($rc != 1)
        {
            &defch_usage;
        }
        return ($rc - 1);
    }

    #
    # check options unique to this command
    #
    if ($::opt_f)
    {

        # error
        my $rsp;
        $rsp->{data}->[0] =
          "The \'-f\' option is not valid for the chdef command.";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        &defch_usage;
        return 1;
    }

    if ($::opt_t && ($::opt_a || $::opt_z || $::opt_x))
    {
        my $rsp;
        $rsp->{data}->[0] =
          "Cannot combine \'-t\' and \'-a\', \'-z\', or \'-x\' options.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        &defch_usage;
        return 1;
    }

	# can't have -z with other obj sources
	if ($::opt_z && ($::opt_o || @::noderange))
	{
		my $rsp;
		$rsp->{data}->[0] = "Cannot use \'-z\' with \'-o\' or a noderange.";
		$rsp->{data}->[1] = "Example of -z usage:\n\t\'cat stanzafile | chdef -z\'\n";
		xCAT::MsgUtils->message("E", $rsp, $::callback);
		&defch_usage;
		return 1;
	}

    # check to make sure we have a list of objects to work with
    if (!@::allobjnames)
    {
        my $rsp;
        $rsp->{data}->[0] = "No object names were provided.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        &defch_usage;
        return 1;
    }

    # set $objtype & fill in cmd line hash
    if (%::ATTRS || ($::opt_t eq "group"))
    {

        # if attr=val on cmd line then could only have one type
        $::objtype = @::clobjtypes[0];

        #
        #  set cli attrs for each object definition
        #
        foreach my $objname (@::clobjnames)
        {

            #  set the objtype attr - if provided
            if ($::objtype)
            {
                chomp $::objtype;
                $::CLIATTRS{$objname}{objtype} = $::objtype;
            }

            # get the data type definition from Schema.pm
            my $datatype = $xCAT::Schema::defspec{$::objtype};
            my @list;
            foreach my $this_attr (sort @{$datatype->{'attrs'}})
            {
                my $a = $this_attr->{attr_name};
                push(@list, $a);
            }

            # set the attrs from the attr=val pairs
            foreach my $attr (keys %::ATTRS)
            {
				if (!grep(/$attr/, @list) && ($::objtype ne 'site') && ($::objtype ne 'monitoring'))
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "\'$attr\' is not a valid attribute name for for an object type of \'$::objtype\'.\n";
                    $rsp->{data}->[1] = "Skipping to the next attribute.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    $error = 1;
                    next;
                }
                else
                {
                    $::CLIATTRS{$objname}{$attr} = $::ATTRS{$attr};
                }
            }

        }
    }

    #
    #   Pull all the pieces together for the final hash
    #		- combines the command line attrs and input file attrs if provided
    #
    if (&setFINALattrs != 0)
    {
        $error = 1;
    }

    # we need a list of objects that are
    #   already defined for each type.
    foreach my $t (@::finalTypeList)
    {

        # special case for site table !!!!!!!!!!!!!!!!!!!!
        if ($t eq 'site')
        {
            @{$objTypeLists{$t}} = 'clustersite';
        }
        else
        {
            @{$objTypeLists{$t}} = xCAT::DBobjUtils->getObjectsOfType($t);
        }
        if ($::verbose)
        {
            my $rsp;
            $rsp->{data}->[0] = "\ndefch: list objects that are defined for each type";
            $rsp->{data}->[1] = "@{$objTypeLists{$t}}\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }
    }

    foreach my $obj (keys %::FINALATTRS)
    {

        my $isDefined = 0;
        my $type      = $::FINALATTRS{$obj}{objtype};

        # check to make sure we have type
        if (!$type)
        {
            my $rsp;
            $rsp->{data}->[0] = "No type was provided for object \'$obj\'.\n";
            $rsp->{data}->[1] = "Skipping to the next object.\n";
            xCAT::MsgUtils->message("E", $rsp, $::callback);
            $error = 1;
            next;
        }

        if (grep(/$obj/, @{$objTypeLists{$type}}))
        {
            $isDefined = 1;
        }


        if (!$isDefined && $::opt_m)
        {

            #error - cannot remove items from an object that does not exist.
            my $rsp;
            $rsp->{data}->[0] =
              "The \'-m\' option is not valid since the \'$obj\' definition does not exist.\n";
            xCAT::MsgUtils->message("E", $rsp, $::callback);
            $error = 1;
            next;
        }

        #
        # need to handle group definitions - special!
        #	- may need to update the node definitions for the group members
        #
        if ($type eq 'group')
        {
            my %grphash;
            my @memberlist;

            # what kind of group is this? - static or dynamic
            my $grptype;
			my %objhash;
            if ($isDefined)
            {
                $objhash{$obj} = $type;
                %grphash = xCAT::DBobjUtils->getobjdefs(\%objhash);
                if (!defined(%grphash))
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not get xCAT object definitions.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    return 1;

                }
               # $grptype = $grphash{$obj}{grouptype};
				# for now all groups are static
				$grptype = 'static';
            }
            else
            {    #not defined
                if ($::FINALATTRS{$obj}{grouptype})
                {
                    $grptype = $::FINALATTRS{$obj}{grouptype};
                }
                elsif ($::opt_d)
                {
                    $grptype = 'dynamic';
                }
                else
                {
                    $grptype = 'static';
                }
            }

            # make sure wherevals was set - if info provided
            if (!$::FINALATTRS{$obj}{wherevals})
            {
                if ($::opt_w)
                {
                    $::FINALATTRS{$obj}{wherevals} = $::opt_w;
                }
            }

            #  get the @memberlist for static group
            #	- if provided - to use below
            if ($grptype eq 'static')
            {

                # check for bad cmd line options
                if ($::opt_w && $::FINALATTRS{$obj}{members})
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Cannot use a list of members together with the \'-w\' option.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    $error = 1;
                    next;
                }

                if ($::FINALATTRS{$obj}{members})
                {
                    @memberlist = &noderange($::FINALATTRS{$obj}{members}, 0);
                    #  don't list all the nodes in the group table
                    #   set the value to static and we figure out the list
                    #   by looking in the nodelist table
                    $::FINALATTRS{$obj}{members} = 'static';

                }
                elsif ($::FINALATTRS{$obj}{wherevals})
                {
                    $::FINALATTRS{$obj}{members} = 'static';

                    #  get a list of nodes whose attr values match the
                    #   "where" values and make that the memberlist of
                    #   the group.

                    # get a list of all node nodes
                    my @tmplist = xCAT::DBobjUtils->getObjectsOfType('node');

                    # create a hash of obj names and types
					my %objhash;
                    foreach my $n (@tmplist)
                    {
                        $objhash{$n} = 'node';
                    }

                    # get all the attrs for these nodes
                    my %myhash = xCAT::DBobjUtils->getobjdefs(\%objhash);

                    # get a list of attr=val pairs
                    my @tmpWhereList =
                      split(',', $::FINALATTRS{$obj}{wherevals});

                    # create an attr-val hash
                    foreach my $w (@tmpWhereList)
                    {
                        if ($w =~ /=/)
                        {
                            my ($a, $v) = $w =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
                            if (!defined($a) || !defined($v))
                            {
                                my $rsp;
                                $rsp->{data}->[0] =
                                  "Incorrect \'attr=val\' pair - $a\n";
                                xCAT::MsgUtils->message("E", $rsp, $::callback);
                                return 3;
                            }
                            $::WhereHash{$a} = $v;
                        }
                    }

                    # see which ones match the where values
                    foreach my $objname (keys %myhash)
                    {

                        #  all the "where" attrs must match the object attrs
                        my $addlist = 1;

                        foreach my $testattr (keys %::WhereHash)
                        {

                            if ($myhash{$objname}{$testattr} ne
                                $::WhereHash{$testattr})
                            {

                                # don't disply
                                $addlist = 0;
                                next;
                            }
                        }

                        if ($addlist)
                        {
                            push(@memberlist, $objname);

                        }
                    }

                }

            }    # end - get memberlist for static group

            if (!$isDefined)
            {

                # if the group type was not set then set it
                if (!$::FINALATTRS{$obj}{grouptype})
                {
                    if ($::opt_d)
                    {
                        $::FINALATTRS{$obj}{grouptype} = 'dynamic';
                        $::FINALATTRS{$obj}{members}   = 'dynamic';
                        if (!$::FINALATTRS{$obj}{wherevals})
                        {
                            my $rsp;
                            $rsp->{data}->[0] =
                              "The \'where\' attributes and values were not provided for dynamic group \'$obj\'.\n";
                            $rsp->{data}->[1] = "Skipping to the next group.\n";
                            xCAT::MsgUtils->message("E", $rsp, $::callback);
                            $error = 1;
                            next;
                        }
                    }
                    else
                    {
                        $::FINALATTRS{$obj}{grouptype} = 'static';
                    }
                }

                # if this is a static group
                #	then update the "groups" attr of each member node
                if ($::FINALATTRS{$obj}{grouptype} eq 'static')
                {

                    # for each node in memberlist add this group
                    # name to the groups attr of the node
                    my %membhash;
                    foreach my $n (@memberlist)
                    {

                        $membhash{$n}{groups} = $obj;
                    }
                    $::plus_option  = 1;
                    $::minus_option = 0;
                    if (xCAT::DBobjUtils->setobjdefs(\%membhash) != 0)
                    {
                        $error = 1;
                    }
                    $::plus_option = 0;

                }

            }
            else
            {    # group is defined

                # if a list of members is provided then update the node entries
                #   note: the members attr of the group def will be set
                #	to static
                if (@memberlist)
                {

                    #  options supported
                    if ($::opt_m)
                    {    # removing these members

                        # for each node in memberlist - remove this group
                        #  from the groups attr
                        my %membhash;
                        foreach my $n (@memberlist)
                        {
                            $membhash{$n}{groups}  = $obj;
                            $membhash{$n}{objtype} = 'node';
                        }

                        $::plus_option  = 0;
                        $::minus_option = 1;
                        if (xCAT::DBobjUtils->setobjdefs(\%membhash) != 0)
                        {
                            $error = 1;
                        }
                        $::minus_option = 0;

                    }
                    elsif ($::opt_p)
                    {    #adding these new members
                            # for each node in memberlist add this group
                            # name to the groups attr
                        my %membhash;
                        foreach my $n (@memberlist)
                        {
                            $membhash{$n}{groups}  = $obj;
                            $membhash{$n}{objtype} = 'node';
                        }
                        $::plus_option  = 1;
                        $::minus_option = 0;
                        if (xCAT::DBobjUtils->setobjdefs(\%membhash) != 0)
                        {
                            $error = 1;
                        }
                        $::plus_option = 0;

                    }
                    else
                    {    # replace the members list altogether

                        # this is the default for the chdef command
				if ($firsttime) {
                        # get the current members list

						$grphash{$obj}{'grouptype'} = "static";
                        my $list =
                          xCAT::DBobjUtils->getGroupMembers($obj, \%grphash);
                        my @currentlist = split(',', $list);

                        # for each node in currentlist - remove group name
                        #	from groups attr

                        my %membhash;
                        foreach my $n (@currentlist)
                        {
                            $membhash{$n}{groups}  = $obj;
                            $membhash{$n}{objtype} = 'node';
                        }

                        $::plus_option  = 0;
                        $::minus_option = 1;


                        if (xCAT::DBobjUtils->setobjdefs(\%membhash) != 0)
                        {
                            $error = 1;
                        }
					$firsttime=0;
				} # end - first time
                        $::minus_option = 0;

                        # for each node in memberlist add this group
                        # name to the groups attr

                        my %membhash;
                        foreach my $n (@memberlist)
                        {
                            $membhash{$n}{groups}  = $obj;
                            $membhash{$n}{objtype} = 'node';
                        }
                        $::plus_option  = 1;
                        $::minus_option = 0;


                        if (xCAT::DBobjUtils->setobjdefs(\%membhash) != 0)
                        {
                            $error = 1;
                        }
                        $::plus_option = 0;

                    }

                }    # end - if memberlist

            }    # end - if group is defined

        }    # end - if group type

        #
        #  Need special handling for node objects that have the
        #	groups attr set - may need to create group defs
        #
        if (($type eq "node") && $::FINALATTRS{$obj}{groups})
        {

            # get the list of groups in the "groups" attr
            my @grouplist;
            @grouplist = split(/,/, $::FINALATTRS{$obj}{groups});

            # get the list of all defined group objects

            # getObjectsOfType("group") only returns static groups,
            # generally speaking, the nodegroup table should includes all the static and dynamic groups,
            # but it is possible that the static groups are not in nodegroup table,
            # so we have to get the static and dynamic groups separately.
            my @definedgroups = xCAT::DBobjUtils->getObjectsOfType("group"); #Static node groups
            my $grptab = xCAT::Table->new('nodegroup');
            my @grplist = @{$grptab->getAllEntries()}; #dynamic groups and static groups in nodegroup table

            # if we're creating the node or we're adding to or replacing
            #	the "groups" attr then check if the group
            # 	defs exist and create them if they don't
            if (!$isDefined || !$::opt_m)
            {

                #  we either replace, add or take away from the "groups"
                #		list
                #  if not taking away then we must be adding or replacing
				my %GroupHash;
                foreach my $g (@grouplist)
                {
                    my $indynamicgrp = 0;
                    #check the dynamic node groups
                    foreach my $grpdef_ref (@grplist)    
                    {
                         my %grpdef = %$grpdef_ref;
                         if (($grpdef{'groupname'} eq $g) && ($grpdef{'grouptype'} eq 'dynamic'))
                         {
                             $indynamicgrp = 1;
                             my $rsp;
                             $rsp->{data}->[0] = "nodegroup $g is a dynamic node group, should not add a node into a dynamic node group statically.\n";
                             xCAT::MsgUtils->message("I", $rsp, $::callback);
                              last;
                          }
                    }
                    if (!$indynamicgrp)
                    {
                        if (!grep(/^$g$/, @definedgroups))
                        {

                            # define it
                            $GroupHash{$g}{objtype}   = "group";
                            $GroupHash{$g}{grouptype} = "static";
                            $GroupHash{$g}{members}   = "static";
                        }
                    }
                }
                if (defined(%GroupHash))
                {

                    if (xCAT::DBobjUtils->setobjdefs(\%GroupHash) != 0)
                    {
                        my $rsp;
                        $rsp->{data}->[0] =
                          "Could not write data to the xCAT database.\n";

                        # xCAT::MsgUtils->message("E", $rsp, $::callback);
                        $error = 1;
                    }
                }
            }

        }    # end - if type = node

    }    # end - for each object to update

    #
    #  write each object into the tables in the xCAT database
    #

    # set update option
    $::plus_option  = 0;
    $::minus_option = 0;
    if ($::opt_p)
    {
        $::plus_option = 1;
    }
    elsif ($::opt_m)
    {
        $::minus_option = 1;
    }

    if (xCAT::DBobjUtils->setobjdefs(\%::FINALATTRS) != 0)
    {
        my $rsp;
        $rsp->{data}->[0] = "Could not write data to the xCAT database.\n";

        #		xCAT::MsgUtils->message("E", $rsp, $::callback);
        $error = 1;
    }

    if ($error)
    {
        my $rsp;
        $rsp->{data}->[0] =
          "One or more errors occured when attempting to create or modify xCAT \nobject definitions.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        return 1;
    }
    else
    {
        if ($::verbose)
        {

            #  give results
            my $rsp;
            $rsp->{data}->[0] =
              "The database was updated for the following objects:\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);

            my $n = 1;
            foreach my $o (sort(keys %::FINALATTRS))
            {
                $rsp->{data}->[$n] = "$o\n";
                $n++;
            }
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }
        else
        {
            my $rsp;
            $rsp->{data}->[0] =
              "Object definitions have been created or modified.\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }
        return 0;
    }
}

#----------------------------------------------------------------------------

=head3   setFINALattrs

		create %::FINALATTRS{objname}{attr}=val hash
		conbines %::FILEATTRS, and %::CLIATTR

        Arguments:

        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------
sub setFINALattrs
{

    my $error = 0;

    # set the final hash based on the info from the input file
    if (@::fileobjnames)
    {
        foreach my $objname (@::fileobjnames)
        {

            #  check if this object is one of the type specified
            if (@::clobtypes)
            {
                if (!grep(/$::FILEATTRS{$objname}{objtype}/, @::clobtypes))
                {
                    next;
                }

            }

            # get the data type definition from Schema.pm

			if (!$::FILEATTRS{$objname}{objtype}) {
				my $rsp;
				$rsp->{data}->[0] = "\nNo objtype value was specified for \'$objname\'. Cannot create object definition.\n";
				xCAT::MsgUtils->message("E", $rsp, $::callback);
				$error = 1;
				next;
			}

            my $datatype =
              $xCAT::Schema::defspec{$::FILEATTRS{$objname}{objtype}};
            my @list;
            foreach my $this_attr (sort @{$datatype->{'attrs'}})
            {
                my $a = $this_attr->{attr_name};
                push(@list, $a);
            }
            push(@list, "objtype");

            # if so then add it to the final hash
            foreach my $attr (keys %{$::FILEATTRS{$objname}})
            {

                # see if valid attr
				if (!grep(/$attr/, @list) && ($::FILEATTRS{$objname}{objtype} ne 'site') && ($::FILEATTRS{$objname}{objtype} ne 'monitoring'))
                {

                    my $rsp;
                    $rsp->{data}->[0] =
                      "\'$attr\' is not a valid attribute name for for an object type of \'$::objtype\'.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    $error = 1;
                    next;
                }
                else
                {
                    $::FINALATTRS{$objname}{$attr} =
                      $::FILEATTRS{$objname}{$attr};
                }

            }
			# need to make sure the node attr is set otherwise nothing 
			#	gets set in the nodelist table
			if ($::FINALATTRS{$objname}{objtype} eq "node") {
				$::FINALATTRS{$objname}{node} = $objname;
			}
        }
    }

    # set the final hash based on the info from the cmd line hash
    @::finalTypeList = ();

    foreach my $objname (@::clobjnames)
    {
        foreach my $attr (keys %{$::CLIATTRS{$objname}})
        {

            $::FINALATTRS{$objname}{$attr} = $::CLIATTRS{$objname}{$attr};
            if ($attr eq 'objtype')
            {
                if (
                    !grep(/^$::FINALATTRS{$objname}{objtype}/, @::finalTypeList)
                  )
                {
                    my $type = $::FINALATTRS{$objname}{objtype};
                    chomp $type;
                    push @::finalTypeList, $type;
                }

            }

        }
		# need to make sure the node attr is set otherwise nothing 
		#   gets set in the nodelist table
		if ($::FINALATTRS{$objname}{objtype} eq "node") {
            $::FINALATTRS{$objname}{node} = $objname;
        }
    }

    if ($error)
    {
        return 1;
    }
    else
    {
        return 0;
    }
}

#----------------------------------------------------------------------------

=head3   defls

        Support for the xCAT defls command.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
			Object names derived from -o, -t, w, -a or noderange!
            List of attrs to display is given by -i.
            Output goes to standard out or a stanza/xml file (-z or -x)

=cut

#-----------------------------------------------------------------------------

sub defls
{
    my $long = 0;
    my %myhash;
    my %objhash;

    my @objectlist;
    @::allobjnames;
	my @displayObjList;

    my $numtypes = 0;

    # process the command line
    my $rc = &processArgs;
    if ($rc != 0)
    {

        # rc: 0 - ok, 1 - return, 2 - help, 3 - error
        if ($rc != 1)
        {
            &defls_usage;
        }
        return ($rc - 1);
    }

    # do we want just the object names or all the attr=val
    if ($::opt_l || @::noderange || $::opt_i)
    {

        # assume we want the the details - not just the names
        # 	- if provided object names or noderange
        $long++;

    }
    
    # which attrs do we want?
    # this is a temp hack to help scaling when you only 
    #   want a list of nodes - needs to be fully implemented
    if ($::opt_l || $::opt_w) {
        # if long or -w then get all the attrs
        $::ATTRLIST="all";
    } elsif ($::opt_i) {
        # is -i then just get the ones in the list
        $::ATTRLIST=$::opt_i;
    } elsif ( @::noderange || $::opt_o) {
        # if they gave a list of objects then they must want more
        #       than the object names!
        $::ATTRLIST="all";
    } else {
        # otherwise just get a list of object names
        $::ATTRLIST="none";
    }

    #
    #	put together a hash with the list of objects and the associated types
    #  		- need to figure out which objects to look up
    #

    # if a set of objects was provided on the cmd line then there can
    #	be only one type value
    if ($::objectsfrom_opto || $::objectsfrom_nr || $::objectsfrom_args)
    {
        my $type = @::clobjtypes[0];

        $numtypes = 1;

        foreach my $obj (sort @::clobjnames)
        {
            $objhash{$obj} = $type;

        }

        %myhash = xCAT::DBobjUtils->getobjdefs(\%objhash, $::VERBOSE);
        if (!defined(%myhash))
        {
            my $rsp;
            $rsp->{data}->[0] = "Could not get xCAT object definitions.\n";
            xCAT::MsgUtils->message("E", $rsp, $::callback);
            return 1;

        }

    }

    #  if just provided type list then find all objects of these types
    if ($::objectsfrom_optt)
    {
        %objhash = %::ObjTypeHash;

        %myhash = xCAT::DBobjUtils->getobjdefs(\%objhash, $::VERBOSE);
        if (!defined(%myhash))
        {
            my $rsp;
            $rsp->{data}->[0] = "Could not get xCAT object definitions.\n";
            xCAT::MsgUtils->message("E", $rsp, $::callback);
            return 1;
        }
    }

    # if specify all
    if ($::opt_a)
    {

        # could be modified by type
        if ($::opt_t)
        {

            # get all objects matching type list
            # Get all object in this type list
            foreach my $t (@::clobjtypes)
            {
                my @tmplist = xCAT::DBobjUtils->getObjectsOfType($t);

                if (scalar(@tmplist) > 1)
                {
                    foreach my $obj (@tmplist)
                    {

                        $objhash{$obj} = $t;
                    }
                }
                else
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not get objects of type \'$t\'.\n";
                    xCAT::MsgUtils->message("I", $rsp, $::callback);
                }
            }

            %myhash = xCAT::DBobjUtils->getobjdefs(\%objhash);
            if (!defined(%myhash))
            {
                my $rsp;
                $rsp->{data}->[0] = "Could not get xCAT object definitions.\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }

        }
        else
        {

            %myhash = xCAT::DBobjUtils->getobjdefs(\%::AllObjTypeHash, $::VERBOSE);
            if (!defined(%myhash))
            {
                my $rsp;
                $rsp->{data}->[0] = "Could not get xCAT object definitions.\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }

        }
        foreach my $t (keys %{xCAT::Schema::defspec})
        {
            push(@::clobjtypes, $t);
        }
    } # end - if specify all

    if (!defined(%myhash))
    {
        my $rsp;
        $rsp->{data}->[0] = "Could not find any objects to display.\n";
        xCAT::MsgUtils->message("I", $rsp, $::callback);
        return 0;
    }

    # the list of objects may be limited by the "-w" option
    # see which objects have attr/val that match the where values
    #		- if provided
    if ($::opt_w)
    {
        foreach my $obj (sort (keys %myhash))
        {

            #  all the "where" attrs must match the object attrs
            my $dodisplay = 1;

            foreach my $testattr (keys %::WhereHash)
            {
                if ($myhash{$obj}{$testattr} ne $::WhereHash{$testattr})
                {

                    # don't disply
                    $dodisplay = 0;
                    next;
                }
            }
            if ($dodisplay)
            {
                push(@displayObjList, $obj);
            }
        }
    }

    #
    # output in specified format
    #

    my @foundobjlist;

    if ($::opt_z)
    {
        my $rsp;
        $rsp->{data}->[0] = "# <xCAT data object stanza file>";
        xCAT::MsgUtils->message("I", $rsp, $::callback);
    }

    # group the objects by type to make the output easier to read
    my $numobjects = 0;    # keep track of how many object we want to display
	# for each type
    foreach my $type (@::clobjtypes)
    {

        my %defhash;

        foreach my $obj (keys %myhash)
        {
            if ($obj)
            {
                $numobjects++;
                if ($myhash{$obj}{'objtype'} eq $type)
                {
                    $defhash{$obj} = $myhash{$obj};

                }
            }
        }

        if ($numobjects == 0)
        {
            my $rsp;
            $rsp->{data}->[0] =
              "Could not find any object definitions to display.\n";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
            return 0;
        }

		# for each object
        foreach my $obj (keys %defhash)
        {

            unless ($obj)
            {
                next;
            }

			# if anything but the site table do this
            if ($defhash{$obj}{'objtype'} ne 'site')
            {
                my @tmplist =
                  xCAT::DBobjUtils->getObjectsOfType($defhash{$obj}{'objtype'});

                unless (@tmplist)
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not find any objects of type \'$defhash{$obj}{'objtype'}\'.\n";
                    xCAT::MsgUtils->message("I", $rsp, $::callback);
                    next;
                }

                if (!grep(/^$obj$/, @tmplist))
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not find an object named \'$obj\' of type \'$defhash{$obj}{'objtype'}\'.\n";
                    xCAT::MsgUtils->message("I", $rsp, $::callback);
                    next;
                }
            }    # end - if not site table

			#
            # special handling for site table - for now !!!!!!!
			#
            my @attrlist;
            if (($defhash{$obj}{'objtype'} eq 'site') || ($defhash{$obj}{'objtype'} eq 'monitoring'))
            {

                foreach my $a (keys %{$defhash{$obj}})
                {

                    push(@attrlist, $a);

                }
            }
            else
            {

                # get the list of all attrs for this type object
                # get the data type  definition from Schema.pm
                my $datatype =
                  $xCAT::Schema::defspec{$defhash{$obj}{'objtype'}};
				my @alreadydone;
                foreach my $this_attr (@{$datatype->{'attrs'}})
                {
					if (!grep(/^$this_attr->{attr_name}$/, @alreadydone)) {
                    	push(@attrlist, $this_attr->{attr_name});
					}
					push(@alreadydone, $this_attr->{attr_name});
                }
            }


            if ($::opt_x)
            {

                # TBD - do output in XML format
            }
            else
            {

                #  standard output or stanza format
                if ($::opt_w)
                {

                    #  just display objects that match -w
                    if (grep /^$obj$/, @displayObjList)
                    {

                        # display data
                        # do we want the short or long output?
                        if ($long)
                        {
                            if ($::opt_z)
                            {
                                my $rsp;
                                $rsp->{data}->[0] = "\n$obj:";
                                $rsp->{data}->[1] =
                                  "    objtype=$defhash{$obj}{'objtype'}";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                            else
                            {
                                if ($#::clobjtypes > 0)
                                {
                                    my $rsp;
                                    $rsp->{data}->[0] =
                                      "Object name: $obj  ($defhash{$obj}{'objtype'})";
                                    xCAT::MsgUtils->message("I", $rsp,
                                                            $::callback);
                                }
                                else
                                {
                                    my $rsp;
                                    $rsp->{data}->[0] = "Object name: $obj";
                                    xCAT::MsgUtils->message("I", $rsp,
                                                            $::callback);
                                }

                            }

                            foreach my $showattr (sort @attrlist)
                            {
                                if ($showattr eq 'objtype')
                                {
                                    next;
                                }

                                if (exists($myhash{$obj}{$showattr}))
                                {
                                    my $rsp;
                                    $rsp->{data}->[0] =
                                      "    $showattr=$defhash{$obj}{$showattr}";
                                    xCAT::MsgUtils->message("I", $rsp,
                                                            $::callback);
                                }

                            }
                        }
                        else
                        {

                            # just give names of objects
                            if ($::opt_z)
                            {
                                my $rsp;
                                $rsp->{data}->[0] = "\n$obj:";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                            else
                            {
                                my $rsp;
                                $rsp->{data}->[0] = "$obj";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                        }
                    }

                }
                else
                {

                    # not -w
                    # display all data
                    # do we want the short or long output?
                    if ($long)
                    {
                        if ($::opt_z)
                        {
                            my $rsp;
                            $rsp->{data}->[0] = "\n$obj:";
                            $rsp->{data}->[1] =
                              "    objtype=$defhash{$obj}{'objtype'}";
                            xCAT::MsgUtils->message("I", $rsp, $::callback);
                        }
                        else
                        {
                            if ($#::clobjtypes > 0)
                            {
                                my $rsp;
                                $rsp->{data}->[0] =
                                  "\nObject name: $obj  ($defhash{$obj}{'objtype'})";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                            else
                            {
                                my $rsp;
                                $rsp->{data}->[0] = "\nObject name: $obj";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                        }

                        foreach my $showattr (sort @attrlist)
                        {
                            if ($showattr eq 'objtype')
                            {
                                next;
                            }

                            my $attrval;
							if ( exists($defhash{$obj}{$showattr}))
                            {
                                $attrval = $defhash{$obj}{$showattr};
                            }

                            # if an attr list was provided then just display those
                            if ($::opt_i)
                            {
                                if (grep (/^$showattr$/, @::AttrList))
                                {

									if ( ($defhash{$obj}{'objtype'} eq 'group') && ($showattr eq 'members'))
                                    {
										#$defhash{$obj}{'grouptype'} = "static";
                                        my $memberlist =
                                          xCAT::DBobjUtils->getGroupMembers(
                                                                     $obj,
                                                                     \%defhash);
                                        my $rsp;
                                        $rsp->{data}->[0] =
                                          "    $showattr=$memberlist";
                                        xCAT::MsgUtils->message("I", $rsp,
                                                                $::callback);
                                    }
                                    else
                                    {

                                        # since they asked for this attr
                                        #   show it even if not set
                                        my $rsp;
                                        $rsp->{data}->[0] =
                                          "    $showattr=$attrval";
                                        xCAT::MsgUtils->message("I", $rsp,
                                                                $::callback);
                                    }
                                }
                            }
                            else
                            {

                                if (   ($defhash{$obj}{'objtype'} eq 'group')
                                    && ($showattr eq 'members'))

                                {
									#$defhash{$obj}{'grouptype'} = "static";
                                    my $memberlist =
                                      xCAT::DBobjUtils->getGroupMembers($obj,\%defhash);
                                    my $rsp;
                                    $rsp->{data}->[0] =
                                      "    $showattr=$memberlist";
                                    xCAT::MsgUtils->message("I", $rsp,
                                                            $::callback);
                                }
                                else
                                {

                                    # don't print unless set
									if (defined($attrval))
                                    {
                                        my $rsp;
                                        $rsp->{data}->[0] =
                                          "    $showattr=$attrval";
                                        xCAT::MsgUtils->message("I", $rsp,
                                                                $::callback);
                                    }
                                }
                            }
                        }

                    }
                    else
                    {

                        if ($::opt_a)
                        {
                            if ($::opt_z)
                            {
                                my $rsp;
                                $rsp->{data}->[0] = "\n$obj:";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                            else
                            {

                                # give the type also
                                my $rsp;
                                $rsp->{data}->[0] =
                                  "$obj ($::AllObjTypeHash{$obj})";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                        }
                        else
                        {

                            # just give the name
                            if ($::opt_z)
                            {
                                my $rsp;
                                $rsp->{data}->[0] = "\n$obj:";
                                xCAT::MsgUtils->message("I", $rsp, $::callback);
                            }
                            else
                            {
                                if ($#::clobjtypes > 0)
                                {
                                    my $rsp;
                                    $rsp->{data}->[0] =
                                      "$obj  ($defhash{$obj}{'objtype'})";
                                    xCAT::MsgUtils->message("I", $rsp,
                                                            $::callback);

                                }
                                else
                                {
                                    my $rsp;
                                    $rsp->{data}->[0] = "$obj";
                                    xCAT::MsgUtils->message("I", $rsp,
                                                            $::callback);
                                }
                            }
                        }
                    }
                }
            } # end - standard output or stanza format
        } # end - for each object
    } # end - for each type
    return 0;
}

#----------------------------------------------------------------------------

=head3  defrm

        Support for the xCAT defrm command.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
			Object names to remove are derived from -o, -t, w, -a, -f,
				 or noderange!
=cut

#-----------------------------------------------------------------------------

sub defrm
{

    my %objhash;
    my $error = 0;
    my %rmhash;
    my %myhash;

    # process the command line
    my $rc = &processArgs;
    if ($rc != 0)
    {

        # rc: 0 - ok, 1 - return, 2 - help, 3 - error
        if ($rc != 1)
        {
            &defrm_usage;
        }
        return ($rc - 1);
    }

    if ($::opt_a && !$::opt_f)
    {
        my $rsp;
        $rsp->{data}->[0] =
          "You must use the \'-f\' option when using the \'-a\' option.\n";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        &defrm_usage;
        return 1;
    }

    #
    #  build a hash of object names and their types
    #

    # the list of objects to remove could have come from: the arg list,
    #	opt_o, a noderange, opt_t, or opt_a. (rmdef doesn't take file
    #	input)

    # if a set of objects was specifically provided on the cmd line then
    #	there can only be one type value
    if ($::objectsfrom_opto || $::objectsfrom_nr || $::objectsfrom_args)
    {
        my $type = @::clobjtypes[0];

        foreach my $obj (sort @::clobjnames)
        {
            $objhash{$obj} = $type;
        }
    }

    # if we derived a list of objects from a list of types
    if ($::objectsfrom_optt)
    {
        %objhash = %::ObjTypeHash;
    }

    # if we derived the list of objects from the "all" option
    if ($::objectsfrom_opta)
    {
        %objhash = %::AllObjTypeHash;
    }

    # handle the "-w" value - if provided
    # the list of objects may be limited by the "-w" option
    # see which objects have attr/val that match the where values
    #       - if provided
    #  !!!!! don't support -w for now - gets way too complicated with groups!!!!
    if ($::opt_w)
    {
        my $rsp;
        $rsp->{data}->[0] =
          "The \'-w\' option is not supported for the rmdef command.";
        xCAT::MsgUtils->message("I", $rsp, $::callback);
        $error = 1;
        return 1;
    }
    if (0)
    {

        # need to get object defs from DB
        %myhash = xCAT::DBobjUtils->getobjdefs(\%objhash);
        if (!defined(%myhash))
        {
            $error = 1;
        }

        foreach my $obj (sort (keys %objhash))
        {
            foreach my $testattr (keys %::WhereHash)
            {
                if ($myhash{$obj}{$testattr} eq $::WhereHash{$testattr})
                {

                    # add this object to the remove hash
                    $rmhash{$obj} = $objhash{$obj};
                }
            }

        }
        %objhash = %rmhash;
    }

    # if the object to remove is a group then the "groups" attr of
    #	the memberlist nodes must be updated.

    my $numobjects = 0;
    foreach my $obj (keys %objhash)
    {
        $numobjects++;

        if ($objhash{$obj} eq 'group')
        {

            # get the group object definition
			my %ghash;
            $ghash{$obj} = 'group';
            my %grphash = xCAT::DBobjUtils->getobjdefs(\%ghash);
            if (!defined(%grphash))
            {
                my $rsp;
                $rsp->{data}->[0] =
                  "Could not get xCAT object definition for \'$obj\'.";
                xCAT::MsgUtils->message("I", $rsp, $::callback);
                next;
            }

            # get the members list
			#  all groups are "static" for now
			$grphash{$obj}{'grouptype'} = "static";
            my $memberlist = xCAT::DBobjUtils->getGroupMembers($obj, \%grphash);
            my @members = split(',', $memberlist);

            # foreach member node of the group
            my %nodehash;
            my %nhash;
            my @gprslist;
            foreach my $m (@members)
            {

                # need to update the "groups" attr of the node def

                # get the def of this node
                $nhash{$m} = 'node';
                %nodehash = xCAT::DBobjUtils->getobjdefs(\%nhash);
                if (!defined(%nodehash))
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not get xCAT object definition for \'$m\'.";
                    xCAT::MsgUtils->message("I", $rsp, $::callback);
                    next;
                }

                # split the "groups" to get a list
                @gprslist = split(',', $nodehash{$m}{groups});

                # make a new "groups" list for the node without the
                #  	group that is being removed
                my $first = 1;
                my $newgrps = "";
                foreach my $grp (@gprslist)
                {
                    chomp($grp);
                    if ($grp eq $obj)
                    {
                        next;
                    }
                    else
                    {

                        # set new groups list for node
                        if (!$first)
                        {
                            $newgrps .= ",";
                        }
                        $newgrps .="$grp";
                        $first = 0;

                    }
                }

                # make the change to %nodehash
                $nodehash{$m}{groups} = $newgrps;
            }

            # set the new node attr values
            if (xCAT::DBobjUtils->setobjdefs(\%nodehash) != 0)
            {
                my $rsp;
                $rsp->{data}->[0] = "Could not write data to xCAT database.";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                $error = 1;
            }
        }
    }

    # remove the objects
    if (xCAT::DBobjUtils->rmobjdefs(\%objhash) != 0)
    {
        $error = 1;
    }

    if ($error)
    {
        my $rsp;
        $rsp->{data}->[0] =
          "One or more errors occured when attempting to remove xCAT object definitions.";
        xCAT::MsgUtils->message("E", $rsp, $::callback);
        return 1;
    }
    else
    {
        if ($numobjects > 0)
        {
            if ($::verbose)
            {

                #  give results
                my $rsp;
                $rsp->{data}->[0] = "The following objects were removed:";
                xCAT::MsgUtils->message("I", $rsp, $::callback);

                my $n = 1;
                foreach my $o (sort(keys %objhash))
                {
                    $rsp->{data}->[$n] = "$o";
                    $n++;
                }
                xCAT::MsgUtils->message("I", $rsp, $::callback);
            }
            else
            {
                my $rsp;
                $rsp->{data}->[0] = "Object definitions have been removed.";
                xCAT::MsgUtils->message("I", $rsp, $::callback);
            }
        }
        else
        {
            my $rsp;
            $rsp->{data}->[0] =
              "No objects have been removed from the xCAT database.";
            xCAT::MsgUtils->message("I", $rsp, $::callback);
        }
        return 0;

    }

}

#----------------------------------------------------------------------------

=head3  defmk_usage

        Arguments:
        Returns:
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

# subroutines to display the usage
sub defmk_usage
{
    my $rsp;
    $rsp->{data}->[0] =
      "\nUsage: mkdef - Create xCAT data object definitions.\n";
    $rsp->{data}->[1] = "  mkdef [-h | --help ] [-t object-types]\n";
    $rsp->{data}->[2] =
      "  mkdef [-V | --verbose] [-t object-types] [-o object-names] [-z|--stanza ]";
    $rsp->{data}->[3] =
      "      [-d | --dynamic] [-w attr=val,[attr=val...]]";
    $rsp->{data}->[4] =
      "      [-f | --force] [noderange] [attr=val [attr=val...]]\n";
    $rsp->{data}->[5] =
      "\nThe following data object types are supported by xCAT.\n";
    my $n = 6;

    foreach my $t (sort(keys %{xCAT::Schema::defspec}))
    {
        $rsp->{data}->[$n] = "$t";
        $n++;
    }
    $rsp->{data}->[$n] =
      "\nUse the \'-h\' option together with the \'-t\' option to";
    $n++;
    $rsp->{data}->[$n] =
      "get a list of valid attribute names for each object type.\n";
    xCAT::MsgUtils->message("I", $rsp, $::callback);
    return 0;
}

#----------------------------------------------------------------------------

=head3  defch_usage

        Arguments:
        Returns:
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub defch_usage
{
    my $rsp;
    $rsp->{data}->[0] =
      "\nUsage: chdef - Change xCAT data object definitions.\n";
    $rsp->{data}->[1] = "  chdef [-h | --help ] [-t object-types]\n";
    $rsp->{data}->[2] =
      "  chdef [-V | --verbose] [-t object-types] [-o object-names] [-d | --dynamic]";
    $rsp->{data}->[3] =
      "    [-z | --stanza] [-m | --minus] [-p | --plus]";
    $rsp->{data}->[4] =
      "    [-w attr=val,[attr=val...] ] [noderange] [attr=val [attr=val...]]\n";
    $rsp->{data}->[5] =
      "\nThe following data object types are supported by xCAT.\n";
    my $n = 6;

    foreach my $t (sort(keys %{xCAT::Schema::defspec}))
    {
        $rsp->{data}->[$n] = "$t";
        $n++;
    }
    $rsp->{data}->[$n] =
      "\nUse the \'-h\' option together with the \'-t\' option to";
    $n++;
    $rsp->{data}->[$n] =
      "get a list of valid attribute names for each object type.\n";
    xCAT::MsgUtils->message("I", $rsp, $::callback);
    return 0;
}

#----------------------------------------------------------------------------

=head3  defls_usage

        Arguments:
        Returns:
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub defls_usage
{
    my $rsp;
    $rsp->{data}->[0] = "\nUsage: lsdef - List xCAT data object definitions.\n";
    $rsp->{data}->[1] = "  lsdef [-h | --help ] [-t object-types]\n";
    $rsp->{data}->[2] =
      "  lsdef [-V | --verbose] [-t object-types] [-o object-names]";
    $rsp->{data}->[3] =
      "    [ -l | --long] [-a | --all] [-z | --stanza ]";
    $rsp->{data}->[4] =
      "    [-i attr-list] [-w attr=val,[attr=val...]] [noderange]\n";
    $rsp->{data}->[5] =
      "\nThe following data object types are supported by xCAT.\n";
    my $n = 6;

    foreach my $t (sort(keys %{xCAT::Schema::defspec}))
    {
        $rsp->{data}->[$n] = "$t";
        $n++;
    }
    $rsp->{data}->[$n] =
      "\nUse the \'-h\' option together with the \'-t\' option to";
    $n++;
    $rsp->{data}->[$n] =
      "get a list of valid attribute names for each object type.\n";
    xCAT::MsgUtils->message("I", $rsp, $::callback);
    return 0;
}

#----------------------------------------------------------------------------

=head3  defrm_usage

        Arguments:
        Returns:
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub defrm_usage
{
    my $rsp;
    $rsp->{data}->[0] =
      "\nUsage: rmdef - Remove xCAT data object definitions.\n";
    $rsp->{data}->[1] = "  rmdef [-h | --help ] [-t object-types]\n";
    $rsp->{data}->[2] =
      "  rmdef [-V | --verbose] [-t object-types] [-a | --all] [-f | --force]";
    $rsp->{data}->[3] =
      "    [-o object-names] [-w attr=val,[attr=val...] [noderange]\n";
    $rsp->{data}->[4] =
      "\nThe following data object types are supported by xCAT.\n";
    my $n = 5;

    foreach my $t (sort(keys %{xCAT::Schema::defspec}))
    {
        $rsp->{data}->[$n] = "$t";
        $n++;
    }
    $rsp->{data}->[$n] =
      "\nUse the \'-h\' option together with the \'-t\' option to";
    $n++;
    $rsp->{data}->[$n] =
      "get a list of valid attribute names for each object type.\n";
    xCAT::MsgUtils->message("I", $rsp, $::callback);
    return 0;
}

1;

