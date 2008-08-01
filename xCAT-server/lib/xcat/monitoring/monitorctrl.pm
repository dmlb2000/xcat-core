#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_monitoring::monitorctrl;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use strict;
use xCAT::NodeRange;
use xCAT::Table;
use xCAT::MsgUtils;
use xCAT::Utils;
use xCAT_plugin::notification;
use xCAT_monitoring::montbhandler;
use Sys::Hostname;

#the list stores the names of the monitoring plug-in and the file name and module names.
#the names are stored in the "name" column of the monitoring table. 
#the format is: (name=>[filename, modulename], ...)
my %PRODUCT_LIST;

#stores the module name and the method that is used for the node status monitoring
#for xCAT.
my $NODESTAT_MON_NAME; 
my $masterpid;



1;

#-------------------------------------------------------------------------------
=head1  xCAT_monitoring:monitorctrl
=head2    Package Description
  xCAT monitoring control  module. This module is the center for the xCAT
  monitoring support. It interacts with xctad and the monitoring plug-in modules
  for the 3rd party monitoring products. 
=cut
#-------------------------------------------------------------------------------




#--------------------------------------------------------------------------------
=head3    start
      It is called by the xcatd when xcatd gets started.
      It gets a list of monitoring plugin module names from the "monitoring" 
      table. It gets a list of nodes in the xcat cluster and,
      in tern, calls the start() function of all the monitoring
      plug-in modules. It registers for nodelist
      tble changes. It queries each monitoring plug-in modules
      to see whether they can feed node status info to xcat or not.
      If some of them can, this function will set up the necessary
      timers (for pull mode) or callback mechanism (for callback mode)
      in order to get the node status from them.
    Arguments:
        none
    Returns:
        0 for successful.
        non-0 for not successful.
=cut
#--------------------------------------------------------------------------------
sub start {
  #print "\nmonitorctrl::start called\n";
  $masterpid=shift;
  if ($masterpid =~ /xCAT_monitoring::monitorctrl/) {
    $masterpid=shift;
  }
  
  #print "masterpid=$masterpid\n";
  # get the plug-in list from the monitoring table
  #refreshProductList();

  #setup signal 
  #$SIG{USR2}=\&handleMonSignal;

  undef $SIG{CHLD};
  my $isMN=xCAT::Utils->isMN();
  my $isMonServer=isMonServer();

  if ($isMN) {
    xCAT_monitoring::montbhandler->regMonitoringNotif();
  }


  #start monitoring for all the registered plug-ins in the monitoring table.
  #better span a process so that it will not block the xcatd.
  my $pid;
  if ($pid=xCAT::Utils->xfork()) {#parent process 
    #print "parent done\n";
    return 0;
  }
  elsif (defined($pid)) { #child process
    my $localhostname=hostname();
    
    if ($isMonServer) { #only start monitoring on monservers.
      #on the service node, need to configure the local host in case it is in a process
      #of diskless rebooting
      if (xCAT::Utils->isServiceNode()) {
        my %ret3=config([], [], 0);
        if (%ret3) {
          foreach(keys(%ret3)) {
            my $retstat3=$ret3{$_}; 
            xCAT::MsgUtils->message('S', "[mon]: $_: @$retstat3 on $localhostname\n");
            #print "$_: @$retstat\n";
          }
        }
      }

      #mn and sn
      my %ret = startMonitoring([], [], 0);
      if ($NODESTAT_MON_NAME) {
        my @ret2 = startNodeStatusMonitoring($NODESTAT_MON_NAME, [], 0);
        $ret{"Node status monitoring with $NODESTAT_MON_NAME"}=\@ret2;
      }
      if (%ret) {
        foreach(keys(%ret)) {
          my $retstat=$ret{$_}; 
          xCAT::MsgUtils->message('S', "[mon]: $_: @$retstat on $localhostname\n");
          #print "$_: @$retstat\n";
        }
      }
    }

    #print "child done\n";
    exit 0;
  }
}



#--------------------------------------------------------------------------------
=head3    stop
      It is called by the xcatd when xcatd stops. It 
      in tern calls the stop() function of each monitoring
      plug-in modules, stops all the timers for pulling the
      node status and unregisters for the nodelist  
      tables changes. 
    Arguments:
       configLocal -- 1 means that only the local node get configured. 
    Returns:
        0 for successful.
        non-0 for not successful.
=cut
#--------------------------------------------------------------------------------
sub stop {

  if (xCAT::Utils->isMN()) {
    xCAT_monitoring::montbhandler->unregMonitoringNotif();
  }
  return 0;
}

#-------------------------------------------------------------------------------

=head3  handleSignal
      It is called the signal is received. It then update the cache with the
      latest data in the monitoring table and start/stop the plug-ins for monitoring
      accordingly.
    Arguments:
      none.
    Returns:
      none
=cut
#-------------------------------------------------------------------------------
sub handleMonSignal {
  print "handleMonSignal: go there\n";
  refreshProductList();

  #setup the signal again  
  $SIG{USR2}=\&handleMonSignal;
}


#-------------------------------------------------------------------------------

=head3  sendMonSignal
      It is called by any module that has made changes to the monitoring table.
    Arguments:
      none.
    Returns:
      none
=cut
#-------------------------------------------------------------------------------
sub sendMonSignal {
  #print "monitorctrl sendMonSignal masterpid=$masterpid\n";
  if ($masterpid) {
    kill('USR2', $masterpid);
  }
}


#--------------------------------------------------------------------------------
=head3    startMonitoring
      It takes a list of monitoring plug-in names as an input and start
      the monitoring process for them.
    Arguments:
       names -- a pointer to an array of monitoring plug-in module names to be started. 
                If non is specified, all the plug-in modules registered in the monitoring 
                table will be used.  
       p_nodes -- a pointer to an arrays of nodes to be monitored. null means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
        A hash table keyed by the plug-in names. The value is an array pointer 
        pointer to a return code and  message pair. For example:
        {rmcmon=>[0, ""], gangliamin=>[1, "something is wrong"]}

=cut
#--------------------------------------------------------------------------------
sub startMonitoring {
  my $nameref=shift;
  if ($nameref =~ /xCAT_monitoring::monitorctrl/) {
    $nameref=shift;
  }
  my $noderef=shift,
  my $scope=shift;
  my $callback=shift;

  refreshProductList();

  my @product_names=@$nameref;
  #print "\nmonitorctrl::startMonitoring called with @product_names\n";

  if (@product_names == 0) {
     @product_names=keys(%PRODUCT_LIST);    
  }
  #print "product_names=@product_names\n";

  my %ret=();
  print "-------startMonitoring: product_names=@product_names\n"; 
  foreach(@product_names) {
    my $aRef=$PRODUCT_LIST{$_};
    if ($aRef) {
      my $module_name=$aRef->[1];

      undef $SIG{CHLD};
      #initialize and start monitoring
      no strict  "refs";
      my @ret1 = ${$module_name."::"}{start}->($noderef, $scope, $callback);
      $ret{$_}=\@ret1;
    } else {
       $ret{$_}=[1, "Monitoring plug-in module $_ is not registered or enabled."];
    }
  }


  return %ret;
}


#--------------------------------------------------------------------------------
=head3    startNodeStatusMonitoring
      It starts the given plug-in for node status monitoring. 
      If no product is specified, use the one in the monitoring table.
    Arguments:
       name -- name of the mornitoring plug-in module to be started for node status monitoring.
        If none is specified, use the one in the monitoring table that has the
        "nodestatmon" column set to be "1", or "Yes".
       p_nodes -- a pointer to an arrays of nodes to be monitored. null means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
        (return_code, error_message)

=cut
#--------------------------------------------------------------------------------
sub startNodeStatusMonitoring {
  my $pname=shift;
  if ($pname =~ /xCAT_monitoring::monitorctrl/) {
    $pname=shift;
  }
  my $noderef=shift,
  my $scope=shift;
  my $callback=shift;

  refreshProductList();

  if (!$pname) {$pname=$NODESTAT_MON_NAME;}
  print "----startNodeStatusMonitoring: pname=$pname\n"; 

  if ($pname) {
    my $aRef=$PRODUCT_LIST{$pname};
    if ($aRef) {
      my $module_name=$aRef->[1];
      undef $SIG{CHLD};
      no strict  "refs";
      my $method = ${$module_name."::"}{supportNodeStatusMon}->();
    print "method=$method\n";
      # return value 0 means not support. 1 means yes. 
      if ($method > 0) {
        #start nodes tatus monitoring
        no strict  "refs";
        my @ret2 = ${$module_name."::"}{startNodeStatusMon}->($noderef, $scope, $callback); 
        return @ret2;
      }         
      else {
	return (1, "$pname does not support node status monitoring.");
      }
    }
    else {
      return (1, "The monitoring plug-in module $pname is not registered.");
    }
  }
  else {
    return (0, "No plug-in is specified for node status monitoring.");
  }
}



#--------------------------------------------------------------------------------
=head3    stopMonitoring
      It takes a list of monitoring plug-in names as an input and stop
      the monitoring process for them.
    Arguments:
       names -- a pointer to an  array of monitoring plug-in names to be stopped. If non is specified,
         all the plug-ins registered in the monitoring table will be stopped.
       p_nodes -- a pointer to an arrays of nodes to be stopped for monitoring. none means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
        A hash table keyed by the plug-in names. The value is ann array pointer
        pointer to a return code and  message pair. For example:
        {rmcmon=>[0, ""], gangliamon=>[1, "something is wrong"]}

=cut
#--------------------------------------------------------------------------------
sub stopMonitoring {
 my $nameref=shift;
  if ($nameref =~ /xCAT_monitoring::monitorctrl/) {
    $nameref=shift;
  }
  my $noderef=shift,
  my $scope=shift;
  my $callback=shift;

  #refreshProductList();

  my @product_names=@$nameref;

  #print "\nmonitorctrl::stopMonitoring called with @product_names\n";

  if (@product_names == 0) {
     @product_names=keys(%PRODUCT_LIST);
  }
  print "-------stopMonitoring: product_names=@product_names\n"; 

  my %ret=();

  #stop each plug-in from monitoring the xcat cluster
  my $count=0;
  foreach(@product_names) {
    
    my $aRef=$PRODUCT_LIST{$_};
    my $module_name;
    if ($aRef) {
      $module_name=$aRef->[1];
    }
    else {
      my $file_name="$::XCATROOT/lib/perl/xCAT_monitoring/$_.pm";
      $module_name="xCAT_monitoring::$_";
      #load the module in memory
      eval {require($file_name)};
      if ($@) {   
        my @ret3=(1, "The file $file_name cannot be located or has compiling errors.\n"); 
        $ret{$_}=\@ret3;
        next;
      }
      #else {
      #  my @a=($file_name, $module_name);
      #  $PRODUCT_LIST{$pname}=\@a;
      #}
    }      
    #stop monitoring
    undef $SIG{CHLD};
    no strict  "refs";
    my @ret2 = ${$module_name."::"}{stop}->($noderef, $scope, $callback);
    $ret{$_}=\@ret2;
  }

  return %ret;
}



#--------------------------------------------------------------------------------
=head3    stopNodeStatusMonitoring
      It stops the given plug-in for node status monitoring. 
      If no plug-in is specified, use the one in the monitoring table.
    Arguments:
       name -- name of the monitoring plu-in module to be stoped for node status monitoring.
        If none is specified, use the one in the monitoring table that has the
        "nodestatmon" column set to be "1", or "Yes".
       p_nodes -- a pointer to an arrays of nodes to be stoped for monitoring. null means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
        (return_code, error_message)

=cut
#--------------------------------------------------------------------------------
sub stopNodeStatusMonitoring {
  my $pname=shift;
  if ($pname =~ /xCAT_monitoring::monitorctrl/) {
    $pname=shift;
  }
  my $noderef=shift,
  my $scope=shift;
  my $callback=shift;
  #refreshProductList();

  if (!$pname) {$pname=$NODESTAT_MON_NAME;}
  print "----stopNodeSatusMonitoring: pname=$pname\n"; 

  if ($pname) {
    my $module_name;
    if (exists($PRODUCT_LIST{$pname})) {
      my $aRef = $PRODUCT_LIST{$pname};
      $module_name=$aRef->[1];
    } else {
      my $file_name="$::XCATROOT/lib/perl/xCAT_monitoring/$pname.pm";
      $module_name="xCAT_monitoring::$pname";
      #load the module in memory
      eval {require($file_name)};
      if ($@) {   
        return (1, "The file $file_name cannot be located or has compiling errors.\n"); 
      }
      #else {
      #  my @a=($file_name, $module_name);
      #  $PRODUCT_LIST{$pname}=\@a;
      #}
    }
    no strict  "refs";
    my @ret2 = ${$module_name."::"}{stopNodeStatusMon}->($noderef, $scope, $callback); 
    return @ret2;
  }
}


#--------------------------------------------------------------------------------
=head3    processMonitoringTableChanges
      It is called when the monitoring table gets changed.
      When a plug-in is added to or removed from the monitoring table, this
      function will start the plug-in to monitor the xCAT cluster or stop the plug-in
      from monitoring the xCAT cluster accordingly. 
    Arguments:
      See processTableChanges.
    Returns:
        0 for successful.
        non-0 for not successful.
=cut
#--------------------------------------------------------------------------------
sub processMonitoringTableChanges {
  #print "monitorctrl::procesMonitoringTableChanges \n";
  my $action=shift;
  if ($action =~ /xCAT_monitoring::monitorctrl/) {
    $action=shift;
  }
  my $tablename=shift;

  #if ($tablename eq "monitoring") { sendMonSignal(); return 0; 
  #}

  # if nothing is being monitored, do not care. 
  if (!$masterpid) { refreshProductList();}
  if (keys(%PRODUCT_LIST) ==0) { return 0; }

  my $old_data=shift;
  my $new_data=shift;
  
  #foreach (keys %$new_data) {
  #  print "new_data{$_}=$new_data->{$_}\n";
  #}

  #for (my $j=0; $j<@$old_data; ++$j) {
  #  my $tmp=$old_data->[$j];
  #  print "old_data[". $j . "]= @$tmp \n";
  #}

  my %namelist=(); #contains the plugin names that get affected by the setting change
  if ($action eq "a") {
    if ($new_data) {
      if (exists($new_data->{name})) {$namelist{$new_data->{name}}=1;}
    }
  }
  elsif (($action eq "d") || (($action eq "u"))) {
    #find out the index of "node" column
    if ($old_data->[0]) {
      my $colnames=$old_data->[0];
      my $name_i=-1;
      for (my $i=0; $i<@$colnames; ++$i) {
        if ($colnames->[$i] eq "name") {
          $name_i=$i;
          last;
        } 
      }
      
      for (my $j=1; $j<@$old_data; ++$j) {
        $namelist{$old_data->[$j]->[$name_i]}=1;
      }
    }
  }

  #print "plugin module setting changed:" . keys(%namelist) . "\n";

  #TODO: need to let monservers handle it too.
  foreach(keys %namelist) {
    if (exists($PRODUCT_LIST{$_})) {
      my $aRef=$PRODUCT_LIST{$_};
      my $module_name=$aRef->[1];
      no strict  "refs";
      if (defined(${$module_name."::"}{processSettingChanges})) {
         ${$module_name."::"}{processSettingChanges}->();
      }
    }   
  }

  return 0;
}





#--------------------------------------------------------------------------------
=head3    setNodeStatusAttributes
      This routine will be called by 
      monitoring plug-in modules to feed the node status back to xcat.
      (callback mode). This function will update the status column of the
      nodelist table with the new node status.
    Arguments:
       status -- a hash pointer of the node status. A key is a status string. The value is 
                an array pointer of nodes that have the same status.
                for example: {active=>["node1", "node1"], inactive=>["node5","node100"]}
    Returns:
        0 for successful.
        non-0 for not successful.
=cut
#--------------------------------------------------------------------------------
sub setNodeStatusAttributes {
  #print "monitorctrl::setNodeStatusAttributes called\n";
  my $temp=shift;
  if ($temp =~ /xCAT_monitoring::monitorctrl/) {
    $temp=shift;
  }

  my %status_hash=%$temp;

  my $tab = xCAT::Table->new('nodelist',-create=>0,-autocommit=>1);
  my %updates;
  if ($tab) {
    foreach (keys %status_hash) {
      my $nodes=$status_hash{$_};
      if (@$nodes > 0) {
        $updates{'status'} = $_;
        my $where_clause="node in ('" . join("','", @$nodes) . "')";
        $tab->setAttribsWhere($where_clause, \%updates );
      }
    }
  } 
  else {
    xCAT::MsgUtils->message("S", "Could not read the nodelist table\n");
  }

  $tab->close;
  return 0;
}

#--------------------------------------------------------------------------------
=head3    getNodeStatus
      This function goes to the xCAT nodelist table to retrieve the saved node status.
    Arguments:
       none.
    Returns:
       a hash that has the node status. The format is: 
          {active=>[node1, node3,...], unreachable=>[node4, node2...], unknown=>[node8, node101...]}
=cut
#--------------------------------------------------------------------------------
sub getNodeStatus {
  my %status=();
  my @inactive_nodes=();
  my @active_nodes=();
  my @unknown_nodes=();
  my $table=xCAT::Table->new("nodelist", -create =>0);
  if ($table) {
    my @tmp1=$table->getAllAttribs(('node','status'));
    if (@tmp1 > 0) {
      foreach(@tmp1) {
        my $node=$_->{node};
        my $status=$_->{status};
        if ($status eq $::STATUS_ACTIVE) { push(@active_nodes, $node);}
        elsif ($status eq $::STATUS_INACTIVE) { push(@inactive_nodes, $node);}
        else { push(@unknown_nodes, $node);}
      }
    }
  }

  $status{$::STATUS_ACTIVE}=\@active_nodes;
  $status{$::STATUS_INACTIVE}=\@inactive_nodes;
  $status{unknown}=\@unknown_nodes;
  return %status;
}



#--------------------------------------------------------------------------------
=head3    refreshProductList
      This function goes to the monitoring table to get the plug-in names 
      and stores the value into the PRODUCT_LIST cache. The cache also stores
      the monitoring plugin module name and file name for each plug-in. This function
      also load the modules in. 
 
    Arguments:
        none
    Returns:
        0 for successful.
        non-0 for not successful.
=cut
#--------------------------------------------------------------------------------
sub refreshProductList {
  #print "monitorctrl::refreshProductList called\n";
  #flush the cache
  %PRODUCT_LIST=();
  $NODESTAT_MON_NAME="";

  #get the monitoring plug-in list from the monitoring table
  my $table=xCAT::Table->new("monitoring", -create =>1);
  if ($table) {
    my @tmp1=$table->getAllAttribs(('name','nodestatmon'));
    if (defined(@tmp1) && (@tmp1 > 0)) {
      foreach(@tmp1) {
        my $pname=$_->{name};

        #get the node status monitoring plug-in name
        my $nodestatmon=$_->{nodestatmon};
        if ((!$NODESTAT_MON_NAME) && ($nodestatmon =~ /1|Yes|yes|YES|Y|y/)) {
           $NODESTAT_MON_NAME=$pname;
        }

        #find out the monitoring plugin file and module name for the product
        my $file_name="$::XCATROOT/lib/perl/xCAT_monitoring/$pname.pm";
        my $module_name="xCAT_monitoring::$pname";
        #load the module in memory
        eval {require($file_name)};
        if ($@) {   
          xCAT::MsgUtils->message('S', "[mon]: The file $file_name cannot be located or has compiling errors.\n"); 
        }
        else {
          my @a=($file_name, $module_name);
          $PRODUCT_LIST{$pname}=\@a;
        }
      } 
    }
  }

  #print "Monitoring PRODUCT_LIST:\n";
  foreach (keys(%PRODUCT_LIST)) {
    my $aRef=$PRODUCT_LIST{$_};
    #print "  $_:@$aRef\n"; 
  }
  #print "NODESTAT_MON_NAME=$NODESTAT_MON_NAME\n";
  return 0;  
}



#--------------------------------------------------------------------------------
=head3    getPluginSettings
      This function goes to the monsetting table to get the settings for a given
      monitoring plug-in. 
 
    Arguments:
        name the name of the monitoring plug-in module. such as snmpmon, rmcmon etc. 
    Returns:
        A hash table containing the key and values of the settings.
=cut
#--------------------------------------------------------------------------------
sub getPluginSettings {
  my $name=shift;
  if ($name =~ /xCAT_monitoring::monitorctrl/) {
    $name=shift;
  }
 
  my %settings=();

  #get the monitoring plug-in list from the monitoring table
  my $table=xCAT::Table->new("monsetting", -create =>1);
  if ($table) {
    my @tmp1=$table->getAllAttribsWhere("name in (\'$name\')", 'key','value');
    if (@tmp1 > 0) {
      foreach(@tmp1) {
	if ($_->{key}) {
	  $settings{$_->{key}}=$_->{value};
        }
      } 
    }
  }

  return %settings;
}
#--------------------------------------------------------------------------------
=head3 isMonServer
      Determines if the local host is a monitoring server.
    Arguments:
      none. 
   Returns: 
      1 if the local host is a moniterring server.
      0 if the local host is not a monitotering server.
=cut
#--------------------------------------------------------------------------------
sub isMonServer {
  my $pHash=getNodeMonServerPair([], 1);

  my @hostinfo=xCAT::Utils->determinehostname();
  my $isSV=xCAT::Utils->isServiceNode();
  my  %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}
  if (!$isSV) { $iphash{'noservicenode'}=1;}
  
  foreach my $pair (keys(%$pHash)) {
    my @a=split(',', $pair);
    if ($iphash{$a[0]} || $iphash{$a[1]}) { return 1;}
  }
  
  return 0;
}
#--------------------------------------------------------------------------------
=head3    getNodeMonServerPair
      It gets the monserver and monmaster for the given nodes.
    Arguments:
      $nodes a pointer to an array of nodes. If the array is empty, all nodes in the 
            nodelist table will be used.
       retfromat 0-- A pointer to a hash table with node as the key and a the monserver pairs
                     string as the value.  
                     For example: { node1=>"sv1,ma1", node2=>"sv1,ma1", node3=>"sv2,ma2"...}
                 1-- A pointer to a hash table with monserver pairs as the key and an array
                     pointer of nodes as the value. 
                     For example: { "sv1,ma1"=>[node1,node2], "sv2,ma2"=>node3...}
                   
         The pair is in the format of "monserver,monmaser". First one is the monitoring service 
      node ip/hostname that faces the mn and the second one is the monitoring service 
      node ip/hostname that faces the cn. 
      The value of the first one can be "noservicenode" meaning that there is no service node 
      for that node. In this case the second one is the site master. 
   Returns: 
      An pointer to a hash.
=cut
#--------------------------------------------------------------------------------
sub getNodeMonServerPair {
  my $pnodes=shift;
  if ($pnodes =~ /xCAT_monitoring::monitorctrl/) { $pnodes=shift; }
  my $retformat=shift;

  my @nodes=@$pnodes;
  my $ret={};

  #get all nodes from the nodelist table if the input has 0 nodes.
  if (@nodes==0) {
    my $table1=xCAT::Table->new("nodelist", -create =>0);
    my @tmp1=$table1->getAllAttribs(('node'));
    foreach(@tmp1) {
      push @nodes, $_->{node};
    }  
    $table1->close();  
  }
  if (@nodes==0) { return $ret; }

  my $table2=xCAT::Table->new("noderes", -create =>0);
  my $tabdata = $table2->getNodesAttribs(\@nodes,['monserver', 'servicenode', 'xcatmaster']);
  foreach my $node (@nodes) {
    my $monserver;
    my $monmaster;
    my $pairs;
    my $tmp2 = $tabdata->{$node}->[0];
    if ($tmp2 && $tmp2->{monserver}) {
        $pairs=$tmp2->{monserver}; 
        #when there is only one hostname specified in noderes.monserver, 
        #both monserver and monmaster take the same hostname.
        if ($pairs !~ /,/) { $pairs=$tmp2->{monserver}.','.$tmp2->{monserver}; } 
    }

    if (!$pairs) {
      if ($tmp2->{servicenode}) {  $monserver=$tmp2->{servicenode}; }
      if ($tmp2->{xcatmaster})  {  $monmaster=$tmp2->{xcatmaster}; } 
      if (!$monserver) { $monserver="noservicenode"; }
      if (!$monmaster) { $monmaster=xCAT::Utils->get_site_attribute('master'); }
      $pairs="$monserver,$monmaster";
    } 
    #print "node=$node, pairs=$pairs\n";

    if ($retformat) {
      if (exists($ret->{$pairs})) {
        my $pa=$ret->{$pairs};
        push(@$pa, $node);
      }
      else {
        $ret->{$pairs}=[$node];
      }
    }
    else { $ret->{$node}=$pairs; }
  }
  $table2->close();
  return $ret;
}

#--------------------------------------------------------------------------------
=head3    getMonHierarchy
      It gets the monnitoring server node for all the nodes within nodelist table.
      The "monserver" attribute is used from the noderes table. If "monserver" is not defined
      for a node, "servicenode" is used. If none is defined, use the local host.
    Arguments:
      None.
    Returns:
      A hash reference keyed by the monitoring server nodes and each value is a ref to
      an array of [nodes, nodetype, status] arrays  monitored by the server. So the format is:
      {monserver1=>[['node1', 'osi', 'active'], ['node2', 'switch', 'booting']...], ...} 
      A key is a pair of hostnames with the first one being the service node ip/hostname 
      that faces the mn and the second one being the service node ip/hostname that faces the cn. 
      The value of the first one can be "noservicenode" meaning that there is no service node 
      for that node. In this case the second one is the site master.  
=cut
#--------------------------------------------------------------------------------
sub getMonHierarchy {
  my $ret={};
  
  #get all from nodelist table and noderes table
  my $table=xCAT::Table->new("nodelist", -create =>0);
  my @tmp1=$table->getAllAttribs(('node','status'));

  my $table2=xCAT::Table->new("noderes", -create =>0);  
  my @tmp2=$table2->getAllNodeAttribs(['node','monserver', 'servicenode', 'xcatmaster']);
  my %temp_hash2=();
  foreach (@tmp2) {
    $temp_hash2{$_->{node}}=$_;
  }

  my $table3=xCAT::Table->new("nodetype", -create =>0);
  my @tmp3=$table3->getAllNodeAttribs(['node','nodetype']);
  my %temp_hash3=();
  foreach (@tmp3) {
    $temp_hash3{$_->{node}}=$_;
  }
  my $sitemaster=xCAT::Utils->get_site_attribute('master');
  
  if (@tmp1 > 0) {
    foreach(@tmp1) {
      my $node=$_->{node};
      my $status=$_->{status};

      my $row3=$temp_hash3{$node};
      my $nodetype=""; #default
      if (defined($row3) && ($row3)) {
        if ($row3->{nodetype}) { $nodetype=$row3->{nodetype}; }
      }

      my $monserver;
      my $monmaster;
      my $pairs;
      my $row2=$temp_hash2{$node};
      if (defined($row2) && ($row2)) {
	if ($row2->{monserver}) {
          $pairs=$row2->{monserver}; 
          #when there is only one hostname specified in noderes.monserver, 
          #both monserver and monmaster take the same hostname.
          if ($pairs !~ /,/) { $pairs=$row2->{monserver}.','.$row2->{monserver}; } 
        }
      }
      
      if (!$pairs) {
        if ($row2->{servicenode}) {  $monserver=$row2->{servicenode}; }
        if ($row2->{xcatmaster})  {  $monmaster=$row2->{xcatmaster}; } 
        if (!$monserver) { $monserver="noservicenode"; }
        if (!$monmaster) { $monmaster=$sitemaster; }
        $pairs="$monserver,$monmaster";
      }

      #print "node=$node, pairs=$pairs\n";

      if (exists($ret->{$pairs})) {
        my $pa=$ret->{$pairs};
        push(@$pa, [$node, $nodetype, $status]);
      }
      else {
        $ret->{$pairs}=[[$node, $nodetype, $status]];
      }
    }
  }
  $table->close();
  $table2->close();
  $table3->close();
  return $ret;
}

#--------------------------------------------------------------------------------
=head3    getMonServerWithInfo
      It gets the monnitoring server node for each of the nodes from the input. 
      The "monserver" attribute is used from the noderes table. If "monserver" is not defined
      for a node, "servicenode" is used. If none is defined, use the local host as the
      the monitoring server. The difference of this function from the getMonServer function
      is that the input of the nodes have 'node' and 'status' info. 
      The other one just has  'node'. The
      names. 
    Arguments:
      nodes: An array ref. Each element is of the format: [node, status]
    Returns:
      A hash reference keyed by the monitoring server nodes and each value is a ref to
      an array of [nodes, nodetype, status] arrays  monitored by the server. So the format is:
      {monserver1=>[['node1', 'osi', 'active'], ['node2', 'switch', 'booting']...], ...} 
      A key is a pair of hostnames with the first one being the service node ip/hostname 
      that faces the mn and the second one being the service node ip/hostname that faces the cn. 
      The value of the first one can be "noservicenode" meaning that there is no service node 
      for that node. In this case the second one is the site master.  
=cut
#--------------------------------------------------------------------------------
sub getMonServerWithInfo {
  my $p_input=shift;
  if ($p_input =~ /xCAT_monitoring::monitorctrl/) {
    $p_input=shift;
  }
  my @in_nodes=@$p_input;

  my $ret={};

  #print "getMonServerWithInfo called with @in_nodes\n";
  #get all from the noderes table
  my @allnodes=();
  foreach (@in_nodes) {
    push(@allnodes, $_->[0]);
  }
  my $table3=xCAT::Table->new("nodetype", -create =>0);
  my $tabdata=$table3->getNodesAttribs(\@allnodes,['nodetype']);
  my $pPairHash=getNodeMonServerPair(\@allnodes, 0);

  foreach (@in_nodes) {
    my $node=$_->[0];
    my $status=$_->[2];
    my $tmp3= $tabdata->{$node}->[0];

    my $nodetype=""; #default
    if (defined($tmp3) && ($tmp3)) {
      if ($tmp3->{nodetype}) { $nodetype=$tmp3->{nodetype}; }
    }

    my $pairs=$pPairHash->{$node};

    if (exists($ret->{$pairs})) {
      my $pa=$ret->{$pairs};
      push(@$pa, [$node, $nodetype, $status]);
    }
    else {
      $ret->{$pairs}=[[$node, $nodetype, $status]];
    }
  }    
  
  $table3->close();
  return $ret;
}


#--------------------------------------------------------------------------------
=head3    getMonServer
      It gets the monnitoring server node for each of the nodes from the input.
      The "monserver" attribute is used from the noderes table. If "monserver" is not defined
      for a node, "servicenode" is used. If none is defined, use the local host as the
      the monitoring server.
    Arguments:
      nodes: An array ref of nodes.
    Returns:
      A hash reference keyed by the monitoring server nodes and each value is a ref to
      an array of [nodes, nodetype, status] arrays  monitored by the server. So the format is:
      {monserver1=>[['node1', 'osi', 'active'], ['node2', 'switch', 'booting']...], ...} 
      A key is a pair of hostnames with the first one being the service node ip/hostname 
      that faces the mn and the second one being the service node ip/hostname that faces the cn. 
      The value of the first one can be "noservicenode" meaning that there is no service node 
      for that node. In this case the second one is the site master.  
=cut
#--------------------------------------------------------------------------------
sub getMonServer {
  my $p_input=shift;
  if ($p_input =~ /xCAT_monitoring::monitorctrl/) {
    $p_input=shift;
  }

  my @in_nodes=@$p_input;

  my $ret={};
  #get all from nodelist table and noderes table
  my @allnodes=();
  foreach (@in_nodes) {
    push(@allnodes, $_->[0]);
  }
  my $table=xCAT::Table->new("nodelist", -create =>0);
  my $tabdata=$table->getNodesAttribs(\@allnodes,['node', 'status']);
  my $table3=xCAT::Table->new("nodetype", -create =>0);
  my $tabdata3=$table3->getNodesAttribs(\@allnodes,['nodetype']);

  my $pPairHash=getNodeMonServerPair(\@allnodes, 0);
  
  foreach my $node (@allnodes) {
    my $tmp1=$tabdata->{$node}->[0];
    if ($tmp1) {
      my $status=$tmp1->{status};

      my $tmp3=$tabdata3->{$node}->[0];
      my $nodetype=""; #default
      if (defined($tmp3) && ($tmp3)) {
	if ($tmp3->{nodetype}) { $nodetype=$tmp3->{nodetype}; }
      }

      my $pairs=$pPairHash->{$node};


      if (exists($ret->{$pairs})) {
        my $pa=$ret->{$pairs};
        push(@$pa, [$node, $nodetype, $status]);
      }
      else {
        $ret->{$pairs}=[[$node, $nodetype, $status]];
      }
    }    
  }
  $table->close();
  $table3->close();
  return $ret;
}




#--------------------------------------------------------------------------------
=head3    nodeStatMonName
      This function returns the current monitoring plug-in name that is assigned for monitroing
      the node status for xCAT cluster.  
     Arguments:
        none
    Returns:
        plug-in name.
=cut
#--------------------------------------------------------------------------------
sub nodeStatMonName {
  return $NODESTAT_MON_NAME;
}


#--------------------------------------------------------------------------------
=head3    getAllRegs
      This function gets all the registered monitoring plug-ins.   
     Arguments:
        none
    Returns:
        a hash with the plug-in name as the key and a integer as value.
        0-- not monitored.
        1-- monitored
        2 -- monitored with node status monitored.
=cut
#--------------------------------------------------------------------------------
sub getAllRegs
{
  my %ret=();
  #get all the module names from monitoring table
  my %names=();   
  my $table=xCAT::Table->new("monitoring", -create =>1);
  if ($table) {
    my $tmp1=$table->getAllEntries();
    if (defined($tmp1) && (@$tmp1 > 0)) {
      foreach(@$tmp1) { 
        my $monnode=0;
        my $disable=1;
        if ($_->{nodestatmon} =~ /1|Yes|yes|YES|Y|y/) { $monnode=1; }
        if ($_->{disable} =~ /0|NO|No|no|N|n/) { $disable=0; }
        if ($disable) { $ret{$_->{name}}=0; }
        else { 
	  if ($monnode) { $ret{$_->{name}}=2; }
          else { $ret{$_->{name}}=1;}
        }
      }
    }
    $table->close();
  } 

  return %ret;
}

#--------------------------------------------------------------------------------
=head3    config
      This function configures the cluster for the given nodes.  
    Arguments:
       names -- a pointer to an  array of monitoring plug-in names. If non is specified,
         all the plug-ins registered in the monitoring table will be notified.
       p_nodes -- a pointer to an arrays of nodes to be added for monitoring. none means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
        ret a hash with plug-in name as the keys and the an arry of 
        [return code, error message] as the values.
=cut
#--------------------------------------------------------------------------------
sub config {
  my $nameref=shift;
  if ($nameref =~ /xCAT_monitoring::monitorctrl/) {
    $nameref=shift;
  }
  my $noderef=shift,
  my $scope=shift;
  my $callback=shift;

  my %ret=();
  my @product_names=@$nameref;

  my %all=getAllRegs();  
  if (@product_names == 0) {
    @product_names=keys(%all);    
  }

  print "------config: product_names=@product_names\n";

  foreach(@product_names) {
    if (exists($all{$_})) {
      my $file_name="$::XCATROOT/lib/perl/xCAT_monitoring/$_.pm";
      my $module_name="xCAT_monitoring::$_";
      #load the module in memory
      eval {require($file_name)};
      if ($@) {   
        my @ret3=(1, "The file $file_name cannot be located or has compiling errors.\n"); 
        $ret{$_}=\@ret3;
        next;
      }
      undef $SIG{CHLD};
      #initialize and start monitoring
      no strict  "refs";
      if (defined(${$module_name."::"}{config})) {
        my @ret1 = ${$module_name."::"}{config}->($noderef, $scope, $callback);
        $ret{$_}=\@ret1;
      }
    } else {
       $ret{$_}=[1, "Monitoring plug-in module $_ is not registered."];
    }
  }
  return %ret;
}

#--------------------------------------------------------------------------------
=head3    deconfig
      This function de-configures the cluster for the given nodes.  
      It function informs all the local active monitoring plug-ins to 
      remove the given nodes to their monitoring domain.  
    Arguments:
       names -- a pointer to an  array of monitoring plug-in names. If non is specified,
         all the plug-ins registered in the monitoring table will be notified.
       p_nodes -- a pointer to an arrays of nodes to be removed for monitoring. none means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both loca lhost and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
        ret a hash with plug-in name as the keys and the an arry of 
        [return code, error message] as the values.
=cut
#--------------------------------------------------------------------------------
sub deconfig {
  my $nameref=shift;
  if ($nameref =~ /xCAT_monitoring::monitorctrl/) {
    $nameref=shift;
  }
  my $noderef=shift,
  my $scope=shift;
  my $callback=shift;

  my @product_names=@$nameref;

  my %ret=();
  my %all=getAllRegs();  
  if (@product_names == 0) {
    @product_names=keys(%all);    
  }
  print "------deconfig: product_names=@product_names\n";
 

  foreach(@product_names) {
    if (exists($all{$_})) {
      my $file_name="$::XCATROOT/lib/perl/xCAT_monitoring/$_.pm";
      my $module_name="xCAT_monitoring::$_";
      #load the module in memory
      eval {require($file_name)};
      if ($@) {   
        my @ret3=(1, "The file $file_name cannot be located or has compiling errors.\n"); 
        $ret{$_}=\@ret3;
        next;
      }
      undef $SIG{CHLD};
      #initialize and start monitoring
      no strict  "refs";
      if (defined(${$module_name."::"}{deconfig})) {
        my @ret1 = ${$module_name."::"}{deconfig}->($noderef, $scope, $callback);
        $ret{$_}=\@ret1;
      }
    } else {
       $ret{$_}=[1, "Monitoring plug-in module $_ is not registered."];
    }
  }
  return %ret;
}


#--------------------------------------------------------------------------------
=head3    getNodeConfData
      This function goes to every monitoring plug-in module and returns a list of
    configuration data that is needed by setting up node monitoring.  
    These data-value pairs will be used as environmental variables 
    on the given node.
    Arguments:
        node  
    Returns:
        ret a hash with enviromental variable name as the key.
=cut
#--------------------------------------------------------------------------------
sub  getNodeConfData {
  my $node=shift;
  if ($node =~ /xCAT_monitoring::monitorctrl/) {
    $node=shift;
  }

  my %ret=();
  #get monitoring server
  my $pHash=xCAT_monitoring::monitorctrl->getNodeMonServerPair([$node], 0);
  my @pair_array=split(',', $pHash->{$node});
  my $monserver=$pair_array[0];
  if ($monserver eq 'noservicenode') { $monserver=hostname(); }
  $ret{MONSERVER}=$monserver;
  $ret{MONMASTER}=$pair_array[1];

  #get all the module names from monitoring table
  my %names=();   
  my $table=xCAT::Table->new("monitoring", -create =>1);
  if ($table) {
    my $tmp1=$table->getAllEntries();
    if (defined($tmp1) && (@$tmp1 > 0)) {
      foreach(@$tmp1) { $names{$_->{name}}=1; }
    }
  } else {
    xCAT::MsgUtils->message('S', "[mon]: getPostScripts for node $node: cannot open monitoring table.\n");
    return %ret; 
  }


  #get node conf data from each plug-in module
  foreach my $pname (keys(%names)) {
    my $file_name="$::XCATROOT/lib/perl/xCAT_monitoring/$pname.pm";
    my $module_name="xCAT_monitoring::$pname";
    #load the module in memory
    eval {require($file_name)};
    if (!$@) {   
      no strict  "refs";
      if (defined(${$module_name."::"}{getNodeConfData})) {
        ${$module_name."::"}{getNodeConfData}->($node, \%ret);
      }  
    }
  } 

  return %ret;
}







































