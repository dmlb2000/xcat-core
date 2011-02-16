# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::FSPscan;
use strict;
use Getopt::Long;
use Socket;
use XML::Simple;
$XML::Simple::PREFERRED_PARSER='XML::Parser';
use xCAT::PPCcli qw(SUCCESS EXPECT_ERROR RC_ERROR NR_ERROR);
use xCAT::PPCdb;
use xCAT::PPCscan;
use xCAT::GlobalDef;
use xCAT::Usage;
use xCAT::NetworkUtils;
use xCAT::FSPUtils;
#use Data::Dumper;

##############################################
# Globals
##############################################
my @header = ( 
    ["type",          "%-8s" ],
    ["name",          "placeholder" ],
    ["id",            "%-8s" ],
    ["type-model",    "%-12s" ],
    ["serial-number", "%-15s" ],
    ["side",          "%-8s" ],
    ["address",       "%-20s\n" ]);

my @attribs = qw(nodetype node id mtm serial side hcp pprofile parent groups mgt cons);
my %nodetype = (
    fsp  => $::NODETYPE_FSP,
    bpa  => $::NODETYPE_BPA,
    lpar =>"$::NODETYPE_LPAR,$::NODETYPE_OSI"
);


##########################################################################
# Parse the command line for options and operands
##########################################################################
sub parse_args {
    xCAT::PPCscan::parse_args(@_);
}



##########################################################################
# Returns short-hostname given an IP 
##########################################################################
sub getshorthost {

    my $ip = shift;

    my $host = xCAT::NetworkUtils->gethostname($ip);
    if ( $host and !$! ) {
        ##############################
        # Get short-hostname
        ##############################
        if ( $host =~ /([^\.]+)\./ ) {
           return($1);
        }
    }
    ##################################
    # Failed
    ##################################
    return undef;
}


##########################################################################
# Returns I/O bus information
##########################################################################
sub enumerate {

    my $hash   = shift;
    my $exp   = shift;
    my $hwtype = ();
    my $server = ();
    my @values = (); 
    my $cageid;
    my $server;
    my $prof;
    my $fname;
    my %cage   = ();
    my %hwconn = ();
    my $Rc;
    my $filter;
    my $data;
    my @output;
    
    foreach my $cec_bpa ( keys %$hash)
    { 

        my $node_hash = $hash->{$cec_bpa};
        for my $node_name ( keys %$node_hash)
        {
            my $d = $node_hash->{$node_name};
	    if($$d[4] =~ /^lpar$/ || $$d[4] =~ /^bpa$/ || $$d[4] =~ /^frame$/ ) {
	        $data = "please check the $node_name; the noderange of rscan couldn't be LPAR or BPA, or frame. ";
		#push @output, [$node_name,$data,$Rc];
                push @values, $data;
                next;
            }  
            my $stat = xCAT::FSPUtils::fsp_api_action ($node_name, $d, "query_connection");
            my $Rc = @$stat[2];
    	    my $data = @$stat[1];
	    
            ##################################
            # Output error
            ##################################
            if ( $Rc != SUCCESS ) {
		#push @output, [$node_name,$data,$Rc];
                push @values, $data;
                next;
            }
	    if($data !~ "Connected" && $data !~ "LINE UP" ) {
	        $data = "please check if the $node_name is coneected to the hardware server";
		#push @output, [$node_name,$data,$Rc];
                push @values, $data;
                next;
	    }
            
            #########################################
            # GET CEC's information
            #########################################
	    #$data =~ /state=([\w\s]+),\(type=([\w-]+)\),\(serial-number=([\w]+)\),\(machinetype-model=([\w-]+)\),sp=([\w]+),\(ip-address=([\w.]+),([\w.]+)\)/ ;
	    $data =~ /state=([\w\s]+), type=([\w-]+), MTMS=([\w-]+)\*([\w-]+), ([\w=]+), slot=([\w]+), ipadd=([\w.]+), alt_ipadd=([\w.]+)/ ;
	    print "parsing: $1,$2,$3,$4,$5,$6,$7,$8\n";
	    
	    my $fsp=$node_name;
	    my $model = $3;
	    my $serial = $4;
            my $side = $6; 
	    $server = $fsp;
	    $fname  = $fsp; 
            my $ips ="$7,$8";	    
            push @values, join( ",",
             $$d[4],$node_name,$cageid,$model,$serial,$side, $server,$prof,$fname, $7);
            # "fsp",$node_name,$cageid,$model,$serial,$side, $server,$prof,$fname, $7);
            #"fsp",$fsp,$cageid,$model,$serial,$side,$server,$prof,$fname,$ips );
           
	    #####################################
            # Enumerate LPARs 
            #####################################
            $stat = xCAT::FSPUtils::fsp_api_action ($node_name, $d, "get_lpar_info");
            $Rc = @$stat[2];
    	    $data = @$stat[1];
	    
            ##################################
            # Output error
            ##################################
            if ( $Rc != SUCCESS ) {
		#push @output, [$node_name,$data,$Rc];
                push @values, $data;
                next;
            }
	    my @list = split(/\n/,$data);    
        #print "list\n";
        #print Dumper(\@list);
	    foreach my $lpar (@list) {
	         $lpar =~ /lparname:\s+(\w+),\s+lparid:\s+(\d+),\s+state:/;
		 my $name = $1;
		 my $lparid = $2;
                 my $prof = $1; 
		 my $server = $fsp;
                 my $ips  = "";
          	 my $port = "";
		 $name =~ s/\-//g;
		 $name =~ tr/A-Z/a-z/;
                 	
                 #####################################
                 # Save LPAR information
                 #####################################
                 push @values, join( ",",
                    "lpar",$name,$lparid,$model,$serial,$port,$server,$prof,$fsp,$ips );
		 
           	 } 

	}
	#return(\@values); 
    }

   
       return( \@values );
}



##########################################################################
# Format responses
##########################################################################
sub format_output {

    my $request = shift;
    my $exp     = shift;
    my $values  = shift;
    my $opt     = $request->{opt};
    my %output  = ();
    my $hwtype  = "fsp";
    my $max_length = 0;
    my $result;
 
    #print "In format output\n";
    #print Dumper($request);   
    #print Dumper($exp);   
    #print Dumper($values);   
    ###########################################
    # -w flag for write to xCat database
    ###########################################
    if ( exists( $opt->{w} )) {
        my $server = @$exp[3];
        my $uid    = @$exp[4];
        my $pw     = @$exp[5];

        #######################################
        # Strip errors for results
        #######################################
        my @val = grep( !/^#.*: ERROR /, @$values );
        xCAT::PPCdb::add_ppc( $hwtype, \@val );
    }

    ###########################################
    # -u flag for write to xCat database
    ###########################################
    if ( exists( $opt->{u} )) {
        #######################################
        # Strip errors for results
        #######################################
        my @val = grep( !/^#.*: ERROR /, @$values );
        $values = xCAT::PPCdb::update_ppc( $hwtype, \@val );
        if ( exists( $opt->{x} ) or exists( $opt->{z} ))
        {
            unshift @$values, "hmc";
        }
    }

    ###########################################
    # -x flag for xml format
    ###########################################
    if ( exists( $opt->{x} )) {
        $result .= format_xml( $hwtype, $values );
    }
    ###########################################
    # -z flag for stanza format
    ###########################################
    elsif ( exists( $opt->{z} )) {
        $result .= format_stanza( $hwtype, $values );
    }
    else {
        $result = sprintf( "#Updated following nodes:\n") if ( exists( $opt->{u}));
        #######################################
        # Get longest name for formatting
        #######################################
        foreach ( @$values ) { 
            ###################################
            # Skip error message
            ###################################
            if ( /^#.*: ERROR / ) {
                next;
            }
            /[^\,]+,([^\,]+),/;
            my $length  = length( $1 );
            $max_length = ($length > $max_length) ? $length : $max_length;
        }
        my $format = sprintf( "%%-%ds", ($max_length + 2 ));
        $header[1][1] = $format;

        #######################################
        # Add header
        #######################################
        foreach ( @header ) {
            $result .= sprintf( @$_[1], @$_[0] );
        }
        #######################################
        # Add node information
        #######################################
        my @errmsg;
        foreach ( @$values ) {
            my @data = split /,/;
            my $i = 0;

            ###################################
            # Save error messages for last
            ###################################
            if ( /^#.*: ERROR / ) {
                push @errmsg, $_;
                next;
            }
            foreach ( @header ) {
                my $d = $data[$i++]; 

                ###############################
                # Use IPs instead of 
                # hardware control address 
                ###############################
                if ( @$_[0] eq "address" ) {
                    if ( $data[0] !~ /^(hmc|ivm)$/ ) {
                        $d = $data[9]; 
                    } 
                }
                $result .= sprintf( @$_[1], $d );
            }
        }
        #######################################
        # Add any error messages 
        #######################################
        foreach ( @errmsg ) {
            $result.= "\n$_";
        }
    }
    $output{data} = [$result];
    return( [\%output] );
}



##########################################################################
# Stanza formatting
##########################################################################
sub format_stanza {

    my $hwtype = shift;
    my $values = shift;
    
    my $result;

    #####################################
    # Skip hardware control point 
    #####################################
    shift(@$values);

    foreach ( sort @$values ) {
        my @data = split /,/;
        my $type = $data[0];
        my $i = 0;

        #################################
        # Skip error message 
        #################################
        if ( /^#.*: ERROR / ) {
            next;
        }
        #################################
        # Node attributes
        #################################
        $result .= "$data[1]:\n\tobjtype=node\n";

        #################################
        # Add each attribute
        #################################
        foreach ( @attribs ) {
            my $d = $data[$i++];

            if ( /^node$/ ) {
                next;
            } elsif ( /^nodetype$/ ) {
                $d = $nodetype{$d}; 
            } elsif ( /^groups$/ ) {
                $d = "$type,all";
            } elsif ( /^mgt$/ ) {
                $d = $hwtype;
            } elsif ( /^cons$/ ) {
                 if ( $type eq "lpar" ) {
                    $d = $hwtype;
                } else {
                    $d = undef;
                }
               
            } elsif ( /^(mtm|serial)$/ ) {
                if ( $type eq "lpar" ) {
                    $d = undef;                    
                }     
            }
            $result .= "\t$_=$d\n";
        }
    }
    return( $result );
}


##########################################################################
# XML formatting
##########################################################################
sub format_xml {

    my $hwtype = shift;
    my $values = shift;
    my $xml;

    #####################################
    # Skip hardware control point 
    #####################################
    #shift(@$values);

    #####################################
    # Create XML formatted attributes
    #####################################
    foreach ( @$values ) {
        my @data = split /,/;
        my $type = $data[0];
        my $i = 0;

        #################################
        # Skip error message
        #################################
        if ( /^#.*: ERROR / ) {
            next;
        }
        #################################
        # Initialize hash reference
        #################################
        my $href = {
            Node => { }
        };
        #################################
        # Add each attribute 
        #################################
        foreach ( @attribs ) {
            my $d = $data[$i++];

            if ( /^nodetype$/ ) {
                $d = $nodetype{$d};
            } elsif ( /^groups$/ ) {
                $d = "$type,all";
            } elsif ( /^mgt$/ ) {
                $d = $hwtype;
            } elsif ( /^cons$/ ) {
                if ( $type eq "lpar" ) {
                    $d = $hwtype;
                } else {
                    $d = undef;
                }
            } elsif ( /^(mtm|serial)$/ ) {
                if ( $type eq "lpar" ) {
                    $d = undef;
                }
            }
            $href->{Node}->{$_} = $d;
        }
        #print Dumper($href);
        #################################
        # XML encoding
        #################################
        $xml.= XMLout($href,
                     NoAttr   => 1,
                     KeyAttr  => [],
                     RootName => undef );
    }
    return( $xml ); 
}



##########################################################################
# Returns I/O bus information
##########################################################################
sub rscan {

    my $request = shift;
    my $hash   = shift;
    my $exp     = shift;
    my $args    = $request->{arg};
    my $server  = @$exp[3];

    #print "in rscan,";
    #print Dumper($request);
    #print Dumper($hash);
    #print Dumper($exp);
    
    ###################################
    # Enumerate all the hardware
    ###################################
    my $values = enumerate( $hash );
    #print "In rscan:\n";
    #print Dumper($values);
    if ( ref($values) ne 'ARRAY' ) {
        return( [[$server,$values,1]] );
    }
    ###################################
    # Success 
    ###################################
    my $result = format_output( $request, $exp, $values );
    unshift @$result, "FORMATDATA6sK4ci";
    return( $result );

}



1;







