# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::PPCpower;
use strict;
use Getopt::Long;
use xCAT::PPCcli qw(SUCCESS EXPECT_ERROR RC_ERROR NR_ERROR);
use xCAT::Usage;


##########################################################################
# Parse the command line for options and operands
##########################################################################
sub parse_args {
    my $request = shift;
    my $command = $request->{command};
    my $args    = $request->{arg};
    my %opt     = ();
    my @rpower  = qw(on onstandby off stat state reset boot of);

    #############################################
    # Responds with usage statement
    #############################################
    local *usage = sub {
        my $usage_string = xCAT::Usage->getUsage($command);
        return( [ $_[0], $usage_string] );
    };
    #############################################
    # Process command-line arguments
    #############################################
    if ( !defined( $args )) {
        return(usage( "No command specified" ));
    }
    #############################################
    # Checks case in GetOptions, allows opts
    # to be grouped (e.g. -vx), and terminates
    # at the first unrecognized option.
    #############################################
    @ARGV = @$args;
    $Getopt::Long::ignorecase = 0;
    Getopt::Long::Configure( "bundling" );

    if ( !GetOptions( \%opt, qw(V|Verbose) )) {
        return( usage() );
    }
    ####################################
    # Check for "-" with no option
    ####################################
    if ( grep(/^-$/, @ARGV )) {
        return(usage( "Missing option: -" ));
    }
    ####################################
    # Unsupported commands
    ####################################
    my ($cmd) = grep(/^$ARGV[0]$/, @rpower );
    if ( !defined( $cmd )) {
        return(usage( "Invalid command: $ARGV[0]" ));
    }
    ####################################
    # Check for an extra argument
    ####################################
    shift @ARGV;
    if ( defined( $ARGV[0] )) {
        return(usage( "Invalid Argument: $ARGV[0]" ));
    }
    ####################################
    # Change "stat" to "state" 
    ####################################
    $request->{op} = $cmd;
    $cmd =~ s/^stat$/state/;
    
    ####################################
    # Power commands special case
    ####################################
    if ( $cmd ne "state" ) {
       $cmd = ($cmd eq "boot") ? "powercmd_boot" : "powercmd";
    }
    $request->{method} = $cmd;
    return( \%opt );
}


##########################################################################
# Builds a hash of CEC/LPAR information returned from HMC/IVM
##########################################################################
sub enumerate {

    my $exp     = shift;
    my $node    = shift;
    my $mtms    = shift;
    my %outhash = ();
    my %cmds    = (); 

    ######################################
    # Check for CEC/LPAR/BPAs in list
    ######################################
    while (my ($name,$d) = each(%$node) ) {
        my $type = @$d[4];
        $cmds{$type} = ($type=~/^lpar$/) ? "state,lpar_id" : "state";
    }
    foreach my $type ( keys %cmds ) {
        my $filter = $cmds{$type};
        my $values = xCAT::PPCcli::lssyscfg( $exp, $type, $mtms, $filter );
        my $Rc = shift(@$values);

        ##################################
        # Return error 
        ##################################
        if ( $Rc != SUCCESS ) {
            return( [$Rc,@$values[0]] );
        }
        ##################################
        # Save LPARs by id 
        ##################################
        foreach ( @$values ) {
            my ($state,$lparid) = split /,/;

            ##############################
            # No lparid for fsp/bpa     
            ##############################
            if ( $type =~ /^(fsp|bpa)$/ ) {
                $lparid = $type;
            }
            $outhash{ $lparid } = $state;
        }
    }
    return( [SUCCESS,\%outhash] );
}


##########################################################################
# Performs boot operation (Off->On, On->Reset)
##########################################################################
sub powercmd_boot {

    my $request = shift;
    my $hash    = shift;
    my $exp     = shift;
    my @output  = ();

    ######################################
    # Power commands are grouped by CEC 
    # not Hardware Control Point
    ######################################

    ######################################
    # Get CEC MTMS 
    ######################################
    my ($name) = keys %$hash;
    my $mtms   = @{$hash->{$name}}[2];

    ######################################
    # Build CEC/LPAR information hash
    ######################################
    my $stat = enumerate( $exp, $hash, $mtms );
    my $Rc = shift(@$stat);
    my $data = @$stat[0];

    while (my ($name,$d) = each(%$hash) ) { 
        ##################################
        # Look up by lparid
        ##################################
        my $type = @$d[4];
        my $id   = ($type=~/^(fsp|bpa)$/) ? $type : @$d[0];

        ##################################
        # Output error
        ##################################
        if ( $Rc != SUCCESS ) {
            push @output, [$name,$data,$Rc];
            next;
        }
        ##################################
        # Node not found 
        ##################################
        if ( !exists( $data->{$id} )) {
            push @output, [$name,"Node not found",1];
            next;
        }
        ##################################
        # Convert state to on/off
        ##################################
        my $state = power_status($data->{$id});
        my $op    = ($state =~ /^off$/) ? "on" : "reset";

        ##############################
        # Send power command
        ##############################
        my $result = xCAT::PPCcli::chsysstate(
                            $exp,
                            $op,
                            $d );
        push @output, [$name,@$result[1],@$result[0]];
    }
    return( \@output );
}


##########################################################################
# Performs power control operations (on,off,reboot,etc)
##########################################################################
sub powercmd {

    my $request = shift;
    my $hash    = shift;
    my $exp     = shift;
    my @result  = ();

    ####################################
    # Power commands are grouped by CEC 
    # not Hardware Control Point
    ####################################

    while (my ($name,$d) = each(%$hash) ) {
        ################################
        # Send command to each LPAR
        ################################
        my $values = xCAT::PPCcli::chsysstate(
                            $exp,
                            $request->{op},
                            $d );
        my $Rc = shift(@$values);

        ################################
        # Return result
        ################################
        push @result, [$name,@$values[0],$Rc];
    }
    return( \@result );
}


##########################################################################
# Queries CEC/LPAR power status (On or Off)
##########################################################################
sub power_status {

    my @states = (
        "Operating",
        "Running",
        "Open Firmware"
    );
    foreach ( @states ) { 
        if ( /^$_[0]$/ ) {
            return("on");
        }
    } 
    return("off");  
}


##########################################################################
# Queries CEC/LPAR power state
##########################################################################
sub state {

    my $request = shift;
    my $hash    = shift;
    my $exp     = shift;
    my $prefix  = shift;
    my $convert = shift;
    my @result  = ();

    if ( !defined( $prefix )) {
        $prefix = "";
    }
    while (my ($mtms,$h) = each(%$hash) ) {
        ######################################
        # Build CEC/LPAR information hash
        ######################################
        my $stat = enumerate( $exp, $h, $mtms );
        my $Rc = shift(@$stat);
        my $data = @$stat[0];
    
        while (my ($name,$d) = each(%$h) ) {
            ##################################
            # Look up by lparid 
            ##################################
            my $type = @$d[4];
            my $id   = ($type=~/^(fsp|bpa)$/) ? $type : @$d[0];
            
            ##################################
            # Output error
            ##################################
            if ( $Rc != SUCCESS ) {
                push @result, [$name, "$prefix$data",$Rc];
                next;
            }
            ##################################
            # Node not found 
            ##################################
            if ( !exists( $data->{$id} )) {
                push @result, [$name, $prefix."Node not found",1];
                next;
            }
            ##################################
            # Output value
            ##################################
            my $value = $data->{$id};

            ##############################
            # Convert state to on/off 
            ##############################
            if ( defined( $convert )) {
                $value = power_status( $value );
            }
            push @result, [$name,"$prefix$value",$Rc];
        }
    }
    return( \@result );
}



1;

