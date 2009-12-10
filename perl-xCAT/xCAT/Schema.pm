# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::Schema;
BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : -d '/opt/xcat' ? '/opt/xcat' : '/usr';
}
use lib "$::XCATROOT/lib/perl";
use xCAT::ExtTab;

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
#  When making additions or deletions to this file please be sure to
#       modify BOTH the tabspec and defspec definitions.  This includes
#       adding descriptions for any new attributes.
#
#  Make sure any new attributes are not SQL reserved words by checking
#  on this site:http://www.petefreitag.com/tools/sql_reserved_words_checker/
#
#  Current SQL reserved words being used in this Schema with special 
#  processing are the
#  following:
#   
#Word     Table                   Databases that will not allow 
# key      site,passwd,prodkey,monsetting      MySQL, DB2,SQL Server 2000
# dump     nimimage                            SQL Server 2000 (microsoft)
# power    nodehm                              SQL Server 2000
# host     policy,ivm                          SQL Server Future Keywords
# parameters  policy              DB2,SQL Server Future Keywords,ISO/ANSI,SQL99
# time        policy              DB2,SQL Server Future Keywords,ISO/ANSI,SQL99
# rule        policy              SQL Server 2000
# value       site,monsetting     ODBC, DB2, SQL Server 
#                                 Future Keywords,ISO/ANSI,SQL99
#
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!


#Note that the SQL is far from imaginative.  Fact of the matter is that
#certain SQL backends don't ascribe meaning to the data types anyway.
#New format, not sql statements, but info enough to describe xcat tables
%tabspec = (
vm => {
    cols => [qw(node host migrationdest storage cfgstore memory cpus nics bootorder clockoffset virtflags vncport textconsole powerstate beacon comments disable)],
    keys => [qw(node)],
    table_desc => 'Virtualization parameters',
    descriptions => {
        'node' => 'The node or static group name',
        'host' => 'The system that currently hosts the VM',
        'migrationdest' => 'A noderange representing candidate destinations for migration (i.e. similar systems, same SAN, or other criteria that xCAT can use',
        'storage' => 'A list of storage files or devices to be used, pipe delimited.  i.e. /cluster/vm/<nodename> for KVM/Xen, or nfs://<server>/path/to/folder/ for VMware',
        'cfgstore' => 'Optional location for persistant storage separate of emulated hard drives for virtualization solutions that require persistant store to place configuration data',
        'memory' => 'Megabytes of memory the VM currently should be set to.',
        'cpus' => 'Number of CPUs the node should see.',
        'nics' => 'Network configuration parameters.  Of the general form [physnet:]interface[=model],.. Generally, interface describes the vlan entity (default for native, tagged for tagged, vl[number] for a specific vlan.  model is the type of device to imitate (i.e. virtio, e1000 (generally default), rtl8139, depending on the virtualization technology.  physnet is a virtual switch name or port description that is used for some virtualization technologies to construct virtual switches.  hypervisor.netmap can map names to hypervisor specific layouts, or the descriptions described there may be used directly here where possible.',
        'bootorder' => 'Boot sequence (i.e. net,hd)',
        'clockoffset' => 'Whether to have guest RTC synced to "localtime" or "utc"  If not populated, xCAT will guess based on the nodetype.os contents.',
        'virtflags' => 'General flags used by the virtualization method.  For example, in Xen it could, among other things, specify paravirtualized setup, or direct kernel boot.  For a hypervisor/dom0 entry, it is the virtualization method (i.e. "xen").  For KVM, the following flag=value pairs are recognized:
            imageformat=[raw|fullraw|qcow2]
                raw is a generic sparse file that allocates storage on demand
                fullraw is a generic, non-sparse file that preallocates all space
                qcow2 is a sparse, copy-on-write capable format implemented at the virtualization layer rather than the filesystem level
            clonemethod=[qemu-img|reflink]
                qemu-img allows use of qcow2 to generate virtualization layer copy-on-write
                reflink uses a generic filesystem facility to clone the files on your behalf, but requires filesystem support such as btrfs ',
        'vncport' => 'Tracks the current VNC display port (currently not meant to be set',
        'textconsole' => 'Tracks the Psuedo-TTY that maps to the serial port or console of a VM',
        'powerstate' => "This flag is used by xCAT to track the last known power state of the VM.",
        'beacon' => "This flag is used by xCAT to track the state of the identify LED with respect to the VM."
    }
},
hypervisor => {
        cols => [qw(node type mgr netmap defaultnet cluster preferdirect comments disable)],
        keys => [qw(node)],
        table_desc => 'Hypervisor parameters',
        descriptions => {
            'node' => 'The node or static group name',
            'type' => 'The plugin associated with hypervisor specific commands such as revacuate',
            mgr => 'The virtualization specific manager of this hypervisor when applicable',
            'netmap' => 'Optional mapping of useful names to relevant physical ports.  For example, 10ge=vmnic_16.0&vmnic_16.1,ge=vmnic1 would be requesting two virtual switches to be created, one called 10ge with vmnic_16.0 and vmnic_16.1 bonded, and another simply connected to vmnic1.  Use of this allows abstracting guests from network differences amongst hypervisors',
            'defaultnet' => 'Optionally specify a default network entity for guests to join to if they do not specify.',
            'cluster' => 'Specify to the underlying virtualization infrastructure a cluster membership for the hypervisor.',
            'preferdirect' => 'If a mgr is declared for a hypervisor, xCAT will default to using the mgr for all operations.  If this is field is set to yes or 1, xCAT will prefer to directly communicate with the hypervisor if possible'
        }
},
websrv => { 
    cols => [qw(node port username password comments disable)],
    keys => [qw(node)],
    table_desc => 'Web service parameters',
	descriptions => {
		'node' => 'The web service hostname.',
		'port' => 'The port of the web service.',
		'username' => 'Userid to use to access the web service.',
		'password' => 'Password to use to access the web service.',
		'comments' => 'Any user-written notes.',
		'disable' => "Set to 'yes' or '1' to comment out this row.",
	 },
  },
boottarget => {
   cols => [qw(bprofile kernel initrd kcmdline comments disable)],
   keys => [qw(bprofile)],
   table_desc => 'Target profiles with their accompanying kernel parameters',
   descriptions => {
      'profile' => 'The name you want this boot target profile to be called',
      'kernel' => 'The kernel that network boot actions should currently acquire and use.  Note this could be a chained boot loader such as memdisk or a non-linux boot loader',
      'initrd' => 'The initial ramdisk image that network boot actions should use (could be a DOS floppy or hard drive image if using memdisk as kernel)',
      'kcmdline' => 'Arguments to be passed to the kernel',
      comments => 'Any user-written notes.',
      disable => "Set to 'yes' or '1' to comment out this row."
    }
},
bootparams => {
   cols => [qw(node kernel initrd kcmdline addkcmdline dhcpstatements adddhcpstatements comments disable)],
   keys => [qw(node)],
   table_desc => 'Current boot settings to be sent to systems attempting network boot for deployment, stateless, or other reasons.  Mostly automatically manipulated by xCAT.',
   descriptions => {
      'node' => 'The node or group name',
      'kernel' => 'The kernel that network boot actions should currently acquire and use.  Note this could be a chained boot loader such as memdisk or a non-linux boot loader',
      'initrd' => 'The initial ramdisk image that network boot actions should use (could be a DOS floppy or hard drive image if using memdisk as kernel)',
      'kcmdline' => 'Arguments to be passed to the kernel',
      'addkcmdline' => 'User specified one or more parameters to be passed to the kernel',
      'dhcpstatements' => 'xCAT manipulated custom dhcp statements (not intended for user manipulation)',
      'adddhcpstatements' => 'Custom dhcp statements for administrator use (not implemneted yet)',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
   }
},
prodkey => {
    cols => [qw(node product key comments disable)],
    keys => [qw(node product)],
    table_desc => 'Specify product keys for products that require them',
    descriptions => {
        node => "The node name or group name.",
        product => "A string to identify the product (for OSes, the osname would be used, i.e. wink28",
        key => "The product key relevant to the aforementioned node/group and product combination",
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
    }
},
chain => {
    cols => [qw(node currstate currchain chain ondiscover comments disable)],
    keys => [qw(node)],
    table_desc => 'Controls what operations are done (and it what order) when a node is discovered and deployed.',
 descriptions => {
  node => 'The node name or group name.',
  currstate => 'The current chain state for this node.  Set by xCAT.',
  currchain => 'The current execution chain for this node.  Set by xCAT.  Initialized from chain and updated as chain is executed.',
  chain => 'A comma-delimited chain of actions to be performed automatically for this node. Valid values:  discover, boot or reboot, install or netboot, runcmd=<cmd>, runimage=<image>, shell, standby. (Default - same as no chain).  Example, for BMC machines use: runcmd=bmcsetup,standby.',
  ondiscover => 'What to do when a new node is discovered.  Valid values: nodediscover.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
deps => {
    cols => [qw(node nodedep msdelay cmd comments disable)],
    keys => [qw(node cmd)],
    required => [qw(node cmd)],
    table_desc => 'Describes dependencies some nodes have on others.  This can be used, e.g., by rpower -d to power nodes on or off in the correct order.',
 descriptions => {
  node => 'The node name or group name.',
  nodedep => 'Comma-separated list of nodes it is dependent on.',
  msdelay => 'How long to wait between operating on the dependent nodes and the primary nodes.',
  cmd => 'Comma-seperated list of which operation this dependency applies to.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
hosts => {
    cols => [qw(node ip hostnames otherinterfaces comments disable)],
    keys => [qw(node)],
    table_desc => 'IP address and hostnames of nodes.  This info can be used to populate /etc/hosts or DNS.',
 descriptions => {
  node => 'The node name or group name.',
  ip => 'The IP address of the node.',
  hostnames => 'Hostname aliases added to /etc/hosts for this node.',
  otherinterfaces => 'Other IP addresses to add for this node.  Format: -<ext>:<ip>,<intfhostname>:ip>,...',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
ipmi => {
    cols => [qw(node bmc bmcport username password comments disable )],
    keys => [qw(node)],
    table_desc => 'Settings for nodes that are controlled by an on-board BMC via IPMI.',
 descriptions => {
  node => 'The node name or group name.',
  bmc => 'The hostname of the BMC adapater.',
  bmcport => 'In systems with selectable shared/dedicated ethernet ports, this parameter can be used to specify the preferred port.  0 means use the shared port, 1 means dedicated, blank is to not assign',
  username => 'The BMC userid.  If not specified, the key=ipmi row in the passwd table is used as the default.',
  password => 'The BMC password.  If not specified, the key=ipmi row in the passwd table is used as the default.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
iscsi => {
    cols => [qw(node server target lun iname file userid passwd kernel kcmdline initrd comments disable)],
    keys => [qw(node)],
    table_desc => 'Contains settings that control how to boot a node from an iSCSI target',
 descriptions => {
  node => 'The node name or group name.',
  server => 'The server containing the iscsi boot device for this node.',
  target => 'The iscsi disk used for the boot device for this node.  Filled in by xCAT.',
  lun => 'LUN of boot device.  Per RFC-4173, this is presumed to be 0 if unset.  tgtd often requires this to be 1',
  iname => 'Initiator name.  Currently unused.',
  file => 'The path on the server of the OS image the node should boot from.',
  userid => 'The userid of the iscsi server containing the boot device for this node.',
  passwd => 'The password for the iscsi server containing the boot device for this node.',
  kernel => 'The path of the linux kernel to boot from.',
  kcmdline => 'The kernel command line to use with iSCSI for this node.',
  initrd => 'The initial ramdisk to use when network booting this node.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
mac => {
    cols => [qw(node interface mac comments disable)],
    keys => [qw(node)],
    table_desc => "The MAC address of the node's install adapter.  Normally this table is populated by getmacs or node discovery, but you can also add entries to it manually.",
 descriptions => {
  node => 'The node name or group name.',
  interface => 'The adapter interface name that will be used to install and manage the node. E.g. eth0 (for linux) or en0 (for AIX).)',
  mac => 'The mac address or addresses for which xCAT will manage static bindings for this node.  This may be simply a mac address, which would be bound to the node name (such as "01:02:03:04:05:0E").  This may also be a "|" delimited string of "mac address!hostname" format (such as "01:02:03:04:05:0E!node5|01:02:03:05:0F!node6-eth1").',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
monitoring => {
    cols => [qw(name nodestatmon comments disable)],
    keys => [qw(name)],
    required => [qw(name)],
    table_desc => 'Controls what external monitoring tools xCAT sets up and uses.  Entries should be added and removed from this table using the provided xCAT commands monstart and monstop.',
 descriptions => {
  name => "The name of the mornitoring plug-in module.  The plug-in must be put in $ENV{XCATROOT}/lib/perl/xCAT_monitoring/.  See the man page for monstart for details.",
  nodestatmon => 'Specifies if the monitoring plug-in is used to feed the node status to the xCAT cluster.  Any one of the following values indicates "yes":  y, Y, yes, Yes, YES, 1.  Any other value or blank (default), indicates "no".',
  comments => 'Any user-written notes.',
  disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
monsetting => {
    cols => [qw(name key value comments disable)],
    keys => [qw(name key)],
    required => [qw(name key)],
    table_desc => 'Specifies the monitoring plug-in specific settings. These settings will be used by the monitoring plug-in to customize the behavior such as event filter, sample interval, responses etc. Entries should be added, removed or modified by chtab command. Entries can also be added or modified by the monstart command when a monitoring plug-in is brought up.',
 descriptions => {
  name => "The name of the mornitoring plug-in module.  The plug-in must be put in $ENV{XCATROOT}/lib/perl/xCAT_monitoring/.  See the man page for monstart for details.",
  key => 'Specifies the name of the attribute. The valid values are specified by each monitoring plug-in. Use "monls name -d" to get a list of valid keys.',
  value => 'Specifies the value of the attribute.',
  comments => 'Any user-written notes.',
  disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
mp => {
    cols => [qw(node mpa id comments disable)],
    keys => [qw(node)],
    table_desc => 'Contains the hardware control info specific to blades.  This table also refers to the mpa table, which contains info about each Management Module.',
 descriptions => {
  node => 'The blade node name or group name.',
  mpa => 'The managment module used to control this blade.',
  id => 'The slot number of this blade in the BladeCenter chassis.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
mpa => {
    cols => [qw(mpa username password comments disable)],
    keys => [qw(mpa)],
    nodecol => "mpa",
    table_desc => 'Contains info about each Management Module and how to access it.',
 descriptions => {
  mpa => 'Hostname of the management module.',
  username => 'Userid to use to access the management module.  If not specified, the key=blade row in the passwd table is used as the default.',
  password => 'Password to use to access the management module.  If not specified, the key=blade row in the passwd table is used as the default.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
networks => {
    cols => [qw(netname net mask mgtifname gateway dhcpserver tftpserver nameservers ntpservers logservers dynamicrange nodehostname comments disable)],
    keys => [qw(net mask)],
    table_desc => 'Describes the networks in the cluster and info necessary to set up nodes on that network.',
 descriptions => {
  netname => 'Name used to identify this network definition.',
  net => 'The network address.',
  mask => 'The network mask.',
  mgtifname => 'The interface name of the management/service node facing this network.  !remote! indicates a non-local network for relay DHCP.',
  gateway => 'The network gateway.',
  dhcpserver => 'The DHCP server that is servicing this network.  Required to be explicitly set for pooled service node operation.',
  tftpserver => 'The TFTP server that is servicing this network.  If not set, the DHCP server is assumed.',
  nameservers => 'The nameservers for this network.  Used in creating the DHCP network definition, and DNS configuration.',
  ntpservers => 'The ntp servers for this network.  Used in creating the DHCP network definition.  Assumed to be the DHCP server if not set.',
  logservers => 'The log servers for this network.  Used in creating the DHCP network definition.  Assumed to be the DHCP server if not set.',
  dynamicrange => 'The IP address range used by DHCP to assign dynamic IP addresses for requests on this network.  This should not overlap with entities expected to be configured with static host declarations, i.e. anything ever expected to be a node with an address registered in the mac table.',
  nodehostname => 'A regular expression used to specify node name to network-specific hostname.  i.e. "/\z/-secondary/" would mean that the hostname of "n1" would be n1-secondary on this network.  By default, the nodename is assumed to equal the hostname, followed by nodename-interfacename.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
nodegroup => {
 cols => [qw(groupname grouptype members wherevals comments disable)],
 keys => [qw(groupname)],
    table_desc => 'Contains group definitions, whose membership is dynamic depending on characteristics of the node.',
 descriptions => {
  groupname => 'Name of the group.',
  grouptype => 'The only current valid value is dynamic.  We will be looking at having the object def commands working with static group definitions in the nodelist table.',
  members => 'The value of the attribute is not used, but the attribute is necessary as a place holder for the object def commands.  (The membership for static groups is stored in the nodelist table.)',
  wherevals => 'A list of "attr*val" pairs that can be used to determine the members of a dynamic group, the delimiter is "::" and the operator * can be ==, =~, != or !~.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
nodehm => {
    cols => [qw(node power mgt cons termserver termport conserver serialport serialspeed serialflow getmac comments disable)],
    keys => [qw(node)],
    table_desc => "Settings that control how each node's hardware is managed.  Typically, an additional table that is specific to the hardware type of the node contains additional info.  E.g. the ipmi, mp, and ppc tables.",
 descriptions => {
  node => 'The node name or group name.',
  power => 'The method to use to control the power of the node. If not set, the mgt attribute will be used.  Valid values: ipmi, blade, hmc, ivm, fsp.  If "ipmi", xCAT will search for this node in the ipmi table for more info.  If "blade", xCAT will search for this node in the mp table.  If "hmc", "ivm", or "fsp", xCAT will search for this node in the ppc table.',
  mgt => 'The method to use to do general hardware management of the node.  This attribute is used as the default if power or getmac is not set.  Valid values: ipmi, blade, hmc, ivm, fsp.  See the power attribute for more details.',
  cons => 'The console method. If nodehm.serialport is set, this will default to the nodehm.mgt setting, otherwise it defaults to unused.  Valid values: cyclades, mrv, or the values valid for the mgt attribute.',
  termserver => 'The hostname of the terminal server.',
  termport => 'The port number on the terminal server that this node is connected to.',
  conserver => 'The hostname of the machine where the conserver daemon is running.  If not set, the default is the xCAT management node.',
  serialport => 'The serial port for this node, in the linux numbering style (0=COM1/ttyS0, 1=COM2/ttyS1).  For SOL on IBM blades, this is typically 1.  For rackmount IBM servers, this is typically 0.',
  serialspeed => 'The speed of the serial port for this node.  For SOL this is typically 19200.',
  serialflow => "The flow control value of the serial port for this node.  For SOL this is typically 'hard'.",
  getmac => 'The method to use to get MAC address of the node with the getmac command. If not set, the mgt attribute will be used.  Valid values: same as values for mgmt attribute.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
nodelist => {
    cols => [qw(node groups status appstatus primarysn comments disable)],
    keys => [qw(node)],
    table_desc => "The list of all the nodes in the cluster, including each node's current status and what groups it is in.",
    descriptions => {
     node => 'The hostname of a node in the cluster.',
     groups => "A comma-delimited list of groups this node is a member of.  Group names are arbitrary, except all nodes should be part of the 'all' group.",
     status => 'The current status of this node.  This attribute will be set by xCAT software.  Valid values: defined, booting, netbooting, booted, discovering, configuring, installing, alive, standingby, powering-off, unreachable. If blank, defined is assumed. The possible status change sequenses are: For installaton: defined->[discovering]->[configuring]->[standingby]->installing->booting->booted->[alive],  For diskless deployment: defined->[discovering]->[configuring]->[standingby]->netbooting->booted->[alive],  For booting: [alive/unreachable]->booting->[alive],  For powering off: [alive]->powering-off->[unreachable], For monitoring: alive->unreachable. Discovering and configuring are for x Series dicovery process. Alive and unreachable are set only when there is a monitoring plug-in start monitor the node status for xCAT. Please note that the status values will not reflect the real node status if you change the state of the node from outside of xCAT (i.e. power off the node using HMC GUI).',
     appstatus => "A comma-delimited list monitored applications that are active on the node. For example 'sshd,rmcd,gmond",
     primarysn => "Not used currently. The primary servicenode, used by this node.",
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
    },
  },
nodepos => {
    cols => [qw(node rack u chassis slot room comments disable)],
    keys => [qw(node)],
    table_desc => 'Contains info about the physical location of each node.  Currently, this info is not used by xCAT, and therefore can be in whatevery format you want.  It will likely be used in xCAT in the future.',
 descriptions => {
  node => 'The node name or group name.',
  rack => 'The frame the node is in.',
  u => 'The vertical position of the node in the frame',
  chassis => 'The BladeCenter chassis the blade is in.',
  slot => 'The slot number of the blade in the chassis.',
  room => 'The room the node is in.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
noderes => {
    cols => [qw(node servicenode netboot tftpserver nfsserver monserver nfsdir installnic primarynic discoverynics cmdinterface xcatmaster current_osimage next_osimage nimserver comments disable)],
    keys => [qw(node)],
    table_desc => 'Resources and settings to use when installing nodes.',
 descriptions => {
  node => 'The node name or group name.',
  servicenode => 'A comma separated list of nodes that provides most services for this node (as known by the management node). The service node to be used will be chosen from the list, starting with the first node on the list. If that service node is not accessable, then the next service node will be chosen from the list, etc.',
  netboot => 'The type of network booting supported by this node.  Valid values:  pxe, yaboot.',
  tftpserver => 'The TFTP server for this node (as known by this node).',
  nfsserver => 'The NFS server for this node (as known by this node).',
  monserver => 'The monitoring aggregation point for this node. The format is "x,y" where x is the ip address as known by the management node and y is the ip address as known by the node.',
  nfsdir => 'Not used!  The path that should be mounted from the NFS server.',
  installnic => 'The network adapter on the node that will be used for OS deployment.  If not set, primarynic will be used.',
  primarynic => 'The network adapter on the node that will be used for xCAT management.  Default is eth0.',
  discoverynics => 'If specified, force discovery to occur on specific network adapters only, regardless of detected connectivity.  Syntax can be simply "eth2,eth3" to restrict discovery to whatever happens to come up as eth2 and eth3, or by driver name such as "bnx2:0,bnx2:1" to specify the first two adapters managed by the bnx2 driver',
  defnetname => 'The host (or ip) by which a node should be addressed (i.e. in psh/pscp). By default, nodename is assumed to be equal to this',
  xcatmaster => 'The hostname of the xCAT service node (as known by this node).  This is the default value if nfsserver or tftpserver are not set.',
  current_osimage => 'Not currently used.  The name of the osimage data object that represents the OS image currently deployed on this node.',
  next_osimage => 'Not currently used.  The name of the osimage data object that represents the OS image that will be installed on the node the next time it is deployed.',
     nimserver => 'Not used for now. The NIM server for this node (as known by this node).',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
    switches => {
        cols => [qw(switch snmpversion username password privacy auth comments disable)],
        keys => [qw(switch)],
        nodecol => "switch",
        table_desc => 'Parameters to use when interrogating switches',
        descriptions => {
         switch => 'The hostname/address of the switch to which the settings apply',
         snmpversion => 'The version to use to communicate with switch.  SNMPv1 is assumed by default.',
         username => 'The username to use for SNMPv3 communication, ignored for SNMPv1',
         password => 'The password or community string to use for SNMPv3 or SNMPv1 respectively.  Falls back to passwd table, and site snmpc value if using SNMPv1',
         privacy => 'The privacy protocol to use for v3.  DES is assumed if v3 enabled, as it is the most readily available.',
         auth => 'The authentication protocol to use for SNMPv3.  SHA is assumed if v3 enabled and this is unspecified',
        },
    },
nodetype => {
    cols => [qw(node os arch profile provmethod supportedarchs nodetype comments disable)],
    keys => [qw(node)],
    table_desc => 'A few hardware and software characteristics of the nodes.',
 descriptions => {
  node => 'The node name or group name.',
  os => 'The operating system deployed on this node.  Valid values: AIX, rh*, centos*, fedora*, sles* (where * is the version #).',
  arch => 'The hardware architecture of this node.  Valid values: x86_64, ppc64, x86, ia64.',
  profile => 'Either the name of an xCAT osimage definition or a pointer to a kickstart or autoyast template to use for OS deployment of this node.',
  provmethod => 'The provisioning method for node deployment. The valid values are install, netboot or an os image name from the osimage table. If install or netboot is specified, the combination of profile, os and arch are used for the name of the template files that are needed to generate the image or kickstart templates. The search order for these files is /install/custom... directory first, then /opt/xcat/share/xcat... directory. However, if the provemethod specifies an image name, the osimage table together with linuximage table (for Linux) or nimimage table (for AIX) are used for the file locations.',
  supportedarchs => 'Comma delimited list of architectures this node can execute.',
  nodetype => 'A comma-delimited list of characteristics of this node.  Valid values: blade, vm (virtual machine), lpar, osi (OS image), hmc, fsp, ivm, bpa, mm, rsa, switch.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
notification => {
    cols => [qw(filename tables tableops comments disable)],
    keys => [qw(filename)],
    required => [qw(tables filename)],
    table_desc => 'Contains registrations to be notified when a table in the xCAT database changes.  Users can add entries to have additional software notified of changes.  Add and remove entries using the provided xCAT commands regnotif and unregnotif.',
 descriptions => {
  filename => 'The path name of a file that implements the callback routine when the monitored table changes.  Can be a perl module or a command.  See the regnotif man page for details.',
  tables => 'Comma-separated list of xCAT database tables to monitor.',
  tableops => 'Specifies the table operation to monitor for. Valid values:  "d" (rows deleted), "a" (rows added), "u" (rows updated).',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
osimage  => {
 cols => [qw(imagename profile imagetype provmethod osname osvers osdistro osarch synclists comments disable)],
 keys => [qw(imagename)],
    table_desc => 'Basic information about an operating system image that can be used to deploy cluster nodes.',
 descriptions => {
  imagename => 'The name of this xCAT OS image definition.',
  imagetype => 'The type of operating system image this definition represents.',
  provmethod => 'The provisioning method for node deployment. The valid values are install or netboot. It is not used by AIX.',
  profile => 'The node usage category. For example compute, service.',
  osname => 'Operating system name- AIX or Linux.',
  osvers => 'Not used.',
  osdistro => 'Not used.',
  osarch => 'Not used.',
  synclists => 'The fully qualified name of a file containing a list of files to synchronize on the nodes.',
  comments => 'Any user-written notes.',
  disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
linuximage  => {
 cols => [qw(imagename template pkglist pkgdir otherpkglist otherpkgdir exlist postinstall rootimgdir comments disable)],
 keys => [qw(imagename)],
    table_desc => 'Information about a Linux operating system image that can be used to deploy cluster nodes.',
 descriptions => {
  imagename => 'The name of this xCAT OS image definition.',
  template => 'The fully qualified name of the template file that is used to create the kick start file for diskful installation.',
  pkglist => 'The fully qualified name of the file that stores the distro  packages list that will be included in the image. It is used for diskless image only.',
  pkgdir => 'The name of the directory where the distro packages are stored.',
  otherpkglist => 'The fully qualified name of the file that stores non-distro package lists that will be included in the image.',
  otherpkgdir => 'The base directory where the non-distro packages are stored.', 
  exlist => 'The fully qualified name of the file that stores the file names and directory names that will be excluded from the image during packimage command.  It is used for diskless image only.',
  postinstall => 'The fully qualified name of the script file that will be run at the end of the packimage command. It is used for diskless image only.',
  rootimgdir => 'The directory name where the image is stored.  It is used for diskless image only.',
  comments => 'Any user-written notes.',
  disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
passwd => {
    cols => [qw(key username password comments disable)],
    keys => [qw(key username)],
    table_desc => 'Contains default userids and passwords for xCAT to access cluster components.  In most cases, xCAT will also actually set the userid/password in the relevant component when it is being configured or installed.  Userids/passwords for specific cluster components can be overidden in other tables, e.g. mpa, ipmi, ppchcp, etc.',
 descriptions => {
  key => 'The type of component this user/pw is for.  Valid values: blade (management module), ipmi (BMC), system (nodes), omapi (DHCP), hmc, ivm, fsp.',
  username => 'The default userid for this type of component',
  password => 'The default password for this type of component',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
policy => {
    cols => [qw(priority name host commands noderange parameters time rule comments disable)],
    keys => [qw(priority)],
    table_desc => 'Not fully implemented!  Controls who has authority to run specific xCAT operations.',
 descriptions => {
  priority => 'The priority value for this rule.  This value is used to identify this policy data object (i.e. this rule).',
  name => 'The username that is allowed to perform the commands specified by this rule.  Default is "*" (all users).',
  host => 'The host from which users may issue the commands specified by this rule.  Default is "*" (all hosts).',
  commands => 'The list of commands that this rule applies to.  Default is "*" (all commands).',
  noderange => 'The Noderange that this rule applies to.  Default is "*" (all nodes).',
  parameters => 'Command parameters that this rule applies to.  Default all parameters.',
  time => 'Time ranges that this command may be executed in.  Default is any time.',
  rule => 'Specifies how this rule should be applied.  Valid values are: allow, accept.  Either of these values will allow the user to run the commands.  Any other value will deny the user access to the commands.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
postscripts => {
    cols => [qw(node postscripts comments disable)],
    keys => [qw(node)],
    table_desc => ' The scripts that should be run on each node after installation or diskless boot.',
 descriptions => {
  node => 'The node name or group name.',
  postscripts => 'Comma separated list of scripts that should be run on this node after installation or diskless boot. xCAT automatically adds the syslog and remoteshell postscripts to the xcatdefaults row of the table. The default scripts will run first on the nodes after install.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
ppc => {
    cols => [qw(node hcp id pprofile parent supernode comments disable)],
    keys => [qw(node)],
    table_desc => 'List of system p hardware: HMCs, IVMs, FSPs, BPCs.',
 descriptions => {
  node => 'The node name or group name.',
  hcp => 'The hardware control point for this node (HMC or IVM).',
  id => 'For LPARs: the LPAR numeric id; for FSPs: the cage number; for BPAs: the frame number.',
  pprofile => 'The LPAR profile that will be used the next time the LPAR is powered on with rpower.',
  parent => 'For LPARs: the FSP/CEC; for FSPs: the BPA (if one exists).',
  supernode => 'Comma separated list of 2 ids. The first one is the id of the supernode the FSP resides in. The second one is the logic location number (0-3) within the supernode for the FSP.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
ppcdirect => {
    cols => [qw(hcp username password comments disable)],
    keys => [qw(hcp username)],
    nodecol => "hcp",
    table_desc => 'Info necessary to use FSPs to control system p CECs.',
 descriptions => {
  hcp => 'Hostname of the FSP.',
  username => 'Userid of the FSP.  If not filled in, xCAT will look in the passwd table for key=fsp.  If not in the passwd table, the default used is admin.',
  password => 'Password of the FSP.  If not filled in, xCAT will look in the passwd table for key=fsp.  If not in the passwd table, the default used is admin.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
ppchcp => {
    cols => [qw(hcp username password comments disable)],
    keys => [qw(hcp)],
    nodecol => "hcp",
    table_desc => 'Info necessary to use HMCs and IVMs as hardware control points for LPARs.',
 descriptions => {
  hcp => 'Hostname of the HMC or IVM.',
  username => 'Userid of the HMC or IVM.  If not filled in, xCAT will look in the passwd table for key=hmc or key=ivm.  If not in the passwd table, the default used is hscroot for HMCs and padmin for IVMs.',
  password => 'Password of the HMC or IVM.  If not filled in, xCAT will look in the passwd table for key=hmc or key=ivm.  If not in the passwd table, the default used is abc123 for HMCs and padmin for IVMs.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
servicenode => {
    cols => [qw(node nameserver dhcpserver tftpserver nfsserver conserver monserver ldapserver ntpserver ftpserver nimserver comments disable)],
    keys => [qw(node)],
    table_desc => 'List of all Service Nodes and services that will be set up on the Service Node.',
 descriptions => {
  node => 'The hostname of the service node as known by the Management Node.',
  nameserver => 'Do we set up DNS on this service node? Valid values:yes or 1, no or 0.',
  dhcpserver => 'Do we set up DHCP on this service node? Valid values:yes or 1, no or 0.',
  tftpserver => 'Do we set up TFTP on this service node? Valid values:yes or 1, no or 0.',
  nfsserver => 'Do we set up file services (HTTP,FTP,or NFS) on this service node? Valid values:yes or 1, no or 0.',
  conserver => 'Do we set up Conserver on this service node? Valid values:yes or 1, no or 0.',
  monserver => 'Is this a monitoring event collection point? Valid values:yes or 1, no or 0.',
  ldapserver => 'Do we set up ldap caching proxy on this service node? Valid values:yes or 1, no or 0.',
  ntpserver => 'Not used presently. Do we set up a ntp server on this service node? Valid values:yes or 1, no or 0.',
  ftpserver => 'Do we set up a ftp server on this service node? Valid values:yes or 1, no or 0.',
  nimserver => 'Do we set up a NIM server on this service node? Valid values:yes or 1, no or 0.',

     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
site => {
    cols => [qw(key value comments disable)],
    keys => [qw(key)],
    table_desc => "Global settings for the whole cluster.  This table is different from the \nother tables in that each attribute is just named in the key column, rather \nthan having a separate column for each attribute. The following is a list of \nthe attributes currently used by xCAT.\n",
 descriptions => {
  key => "Name of the attribute:\tDescription\n".
   "  blademaxp:\tThe maximum number of processes for blade hardware control. Default is 64.\n\n".
   "  consoleondemand:\tWhen set to 'yes', conserver connects and creates the console output only when the user opens the console. Default is no on Linux, yes on AIX.\n\n".
   "  defserialflow:\tThe default serial flow - currently only used by the mknb command.\n\n".
   "  defserialport:\tThe default serial port - currently only used by mknb.\n\n".
   "  defserialspeed:\tThe default serial speed - currently only used by mknb.\n\n".
   "  dhcpinterfaces\tThe network interfaces DHCP should listen on.  If it is the same for all nodes, use simple comma-separated list of NICs.  To specify different NICs for different nodes: mn|eth1,eth2;service|bond0.\n\n".
   "  dhcpsetup:\tIf set to 'n', it'll skip the dhcp setup process in the nodeset command. The default value is 'y'.\n\n".
   "  domain:\tThe DNS domain name used for the cluster.\n\n".
   "  forwarders:\tThe DNS servers at your site that can provide names outside of the cluster.  The DNS on the management node will forward requests it does not know to these servers.\n\n".
   "  fsptimeout:\tThe timeout, in milliseconds, to use when communicating with  FSPs. Default is 0.\n\n".
   "  genmacprefix:\tWhen generating mac addresses automatically, use this manufacturing prefix (i.e. 00:11:aa)\n\n".
   "  genpasswords:\tAutomatically generate random passwords for BMCs when configuring them.\n\n".
   "  installdir:\tThe local directory name used to hold the node deployment packages. Default is /install.\n\n".
   "  installloc:\tThe location that service nodes should mount the install directory from in format hostname:/path.  If hostname is omitted, it defaults to the management node.\n\n".
   "  ipmimaxp:\tThe max # of processes for ipmi hw ctrl. Default is 64.\n\n".
   "  ipmiretries:\tThe # of retries to use when communicating with BMCs. Default is 3.\n\n".
   "  ipmisdrcache -\n\n".
   "  ipmitimeout:\tThe timeout to use when communicating with BMCs. Default is 2 seconds.\n\n".
   "  iscsidir:\tThe path to put the iscsi disks in on the mgmt node.\n\n".
   "  master:\tThe hostname of the xCAT management node, as known by the nodes.\n\n".
   "  maxssh:\tThe max # of SSH connections at any one time to the hw ctrl point for PPC hw ctrl purposes. Default is 8.\n\n".
   "  nameservers:\tA comma delimited list of DNS servers that each node in the cluster should use - often the xCAT management node.\n\n".
   "  nodestatus:\tIf set to 'n', the nodelist.status column will not be updated during the node deployment, node discovery and power operation.\n\n".
   "  ntpservers:\tA comma delimited list of NTP servers for the cluster - often the xCAT management node.\n\n".
   "  ppcmaxp:\tThe max # of processes for PPC hw ctrl. Default is 64.\n\n".
   "  ppcretry:\tThe max # of PPC hw connection attempts before failing. Default is 3.\n\n".
   "  ppctimeout:\tThe timeout, in milliseconds, to use when communicating with PPC hw. Default is 0.\n\n".
   "  pruneservices:\tWhether to enable service pruning when noderm is run (i.e. removing DHCP entries when noderm is executed)\n\n".
   "  sharedtftp:\tSet to no/0 if xCAT should not assume /tftpboot is mounted on all service nodes. Default is 1/yes.\n\n".
   "  timezone:\t(e.g. America/New_York)\n\n".
   "  tftpdir:\ttftp directory path. Default is /tftpdir\n\n".
   "  useSSHonAIX:\t(yes/1 or no/0). If yes, ssh/scp will be setup and used. If no, rsh/rcp will be setup and used on AIX. Default is yes.\n\n".
   "  rsh:\tThis is no longer used. path to remote shell command for xdsh. Default is /usr/bin/ssh.\n\n".
   "  rcp:\tThis is no longer used. path to remote copy command for xdcp. Default is /usr/bin/scp.\n\n".
   "  SNsyncfiledir:\tThe directory on the Service Node, where xdcp will copy the files from the MN that will eventually be copied to the compute nodes. Default is /var/xcat/syncfiles.\n\n".
   "  snmpc:\tThe snmp community string that xcat should use when communicating with the switches.\n\n".
   "  svloglocal:\tsyslog on the service node does not get forwarded to the mgmt node - default is 0.\n\n".
   "  useNmapfromMN:\tWhen set to yes, nodestat command should obtain the node status using nmap (if available) from the management node instead of the service node. This will improve the performance in a flat network. Default is no.\n\n".
   "  xcatconfdir:\t(default /etc/xcat)\n\n".
   "  xcatdport:\tThe port used by the xcatd daemon for client/server communication. Default is 3001.\n\n".
   "  xcatiport:\tThe port used by xcatd to receive install status updates from nodes. Default is 3002.\n\n".
   "  xcatservers:\t(Deprecated!  Will be replaced by the servicenode table.  Li
st service nodes)\n\n",
  value => 'The value of the attribute specified in the "key" column.',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
switch =>  {
    cols => [qw(node switch port vlan interface comments disable)],
    keys => [qw(node switch port)],
    table_desc => 'Contains what switch port numbers each node is connected to.',
 descriptions => {
  node => 'The node name or group name.',
  switch => 'The switch hostname.',
  port => 'The port number in the switch that this node is connected to. On a simple 1U switch, an administrator can generally enter the number as printed next to the ports, and xCAT will understand switch representation differences.  On stacked switches or switches with line cards, administrators should usually use the CLI representation (i.e. 2/0/1 or 5/8).  One notable exception is stacked SMC 8848M switches, in which you must add 56 for the proceeding switch, then the port number.  For example, port 3 on the second switch in an SMC8848M stack would be 59',
  vlan => 'xCAT currently does not make use of this field, however it may do so in the future.  For now, it can be used by administrators for their own purposes, but keep in mind some xCAT feature later may try to enforce this if set',
  interface => 'The interface name from the node perspective.  This is not currently used by xCAT, but administrators may wish to use this for their own purposes',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
vpd => {
    cols => [qw(node serial mtm asset comments disable)],
    keys => [qw(node)],
    table_desc => 'The Machine type, Model, and Serial numbers of each node.',
 descriptions => {
  node => 'The node name or group name.',
  serial => 'The serial number of the node.',
  mtm => 'The machine type and model number of the node.  E.g. 7984-6BU',
  asset => 'A field for administators to use to correlate inventory numbers they may have to accomodate',
     comments => 'Any user-written notes.',
     disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
nimimage  => {
 cols => [qw(imagename nimtype lpp_source spot root dump paging resolv_conf tmp home shared_home res_group nimmethod script bosinst_data installp_bundle mksysb fb_script shared_root otherpkgs comments disable)],
 keys => [qw(imagename)],
    table_desc => 'All the info that specifies a particular AIX operating system image that can be used to deploy AIX nodes.',
 descriptions => {
  imagename => 'User provided name of this xCAT OS image definition.',
  nimtype => 'The NIM client type- standalone, diskless, or dataless.',
  lpp_source => 'The name of the NIM lpp_source resource.',
  spot => 'The name of the NIM SPOT resource.',
  root => 'The name of the NIM root resource.',
  dump => 'The name of the NIM dump resource.',
  paging => 'The name of the NIM paging resource.',
  resolv_conf  => 'The name of the NIM resolv_conf resource.',
  tmp => 'The name of the NIM tmp resource.',
  home => 'The name of the NIM home resource.',
  shared_home => 'The name of the NIM shared_home resource.',
  res_group => 'The name of a NIM resource group.',
  nimmethod => 'The NIM install method to use, (ex. rte, mksysb).',
  script => 'The name of a NIM script resource.',
  fb_script => 'The name of a NIM fb_script resource.',
  bosinst_data => 'The name of a NIM bosinst_data resource.',
  otherpkgs => "One or more comma separated installp or rpm packages.  The rpm packages must have a prefix of 'R:', (ex. R:foo.rpm)",
  installp_bundle => 'One or more comma separated NIM installp_bundle resources.',
  mksysb => 'The name of a NIM mksysb resource.',
  shared_root => 'A shared_root resource represents a directory that can be used as a / (root) directory by one or more diskless clients.',
  comments => 'Any user-provided notes.',
  disable => "Set to 'yes' or '1' to comment out this row.",
 },
  },
performance => {
    cols => [qw(timestamp node attrname attrvalue)],
    keys => [qw(timestamp node attrname)],
    table_desc => 'Describes the system performance every interval unit of time.',
 descriptions => {
   timestamp => 'The time at which the metric was captured.',
   node => 'The node name.',
   attrname => 'The metric name.',
   attrvalue => 'The metric value.'
 },
  },

eventlog => {
    cols => [qw(recid  eventtime eventtype monitor monnode node application component id severity  message rawdata comments disable)], 
    keys => [qw(recid)],
    types => {
	recid => 'INTEGER AUTO_INCREMENT',  
    },
    table_desc => 'Stores the events occurred.',  
    descriptions => {
        recid => 'The record id.',
	eventtime => 'The timestamp for the event.',     
	eventtype => 'The type of the event.',     # for RMC it's either "Event" or "Rearm event".
	monitor => 'The name of the monitor that monitors this event.',    #for RMC, it's the condition name
        monnode => 'The node that monitors this event.',
	node => 'The node where the event occurred.',    
	application => 'The application that reports the event.',        #RMC, Ganglia 
	component  => 'The component where the event occurred.',   #in RMC, it's the resource class name
	id => 'The location or the resource name where the event occurred.', #In RMC it's the resource name and attribute name
	severity => 'The severity of the event. Valid values are: informational, warning, critical.',
	message => 'The full description of the event.',
	rawdata => ' The data that associated with the event. ',    # in RMC, it's the attribute value, it takes the format of attname=attvalue[,atrrname=attvalue....]
	comments => 'Any user-provided notes.',
	disable => "Set to 'yes' or '1' to comment out this row.",
    },
},
prescripts => {
    cols => [qw(node begin end comments disable)],
    keys => [qw(node)],
    table_desc => 'The scripts that should be run at the beginning and the end of the nodeset command.',
    descriptions => {
	node => 'The node name or group name.',
	begin => 
"The scripts to be run at the beginning of the nodeset (Linux) command.\n". 
"\t\tThe format is:\n".
"\t\t[action1:]s1,s2...[|action2:s3,s4,s5...]\n".
"\t\twhere action1 and action2 are the nodeset/nimnodeset actions specified in the command.\n".
"\t\ts1 and s2 are the scripts to run for action1 in order. s3,s4,and s5 are the scripts\n".
"\t\tto run for actions2. If actions are omitted, the scripts apply to all actions.\n".
"\t\tAll the scripts should be copied to /install/prescripts directory.\n".
"\t\tExamples:\n".
"\t\tmyscript1,myscript2\n".
"\t\tinstall:myscript1,myscript2|netboot:myscript3",
        end => 
"The scripts to be run at the end of the nodeset (Linux) command.\n" .
"\t\tThe format is the same as the 'begin' column.",
	comments => 'Any user-written notes.',
	disable => "Set to 'yes' or '1' to comment out this row.",
    },
},

zvm => {
	cols => [qw(node hcp userid comments disable)],
	keys => [qw(node)],
	table_desc => 'List of z/VM virtual servers.',
	descriptions => {
		node => 'The node name.',
		hcp => 'The hardware control point for this node.',
		userid => 'The z/VM userID of this node.',
		comments => 'Any user provided notes.',
		disable => "Set to 'yes' or '1' to comment out this row.",
	},
},

);        # end of tabspec definition




###################################################
# adding user defined external tables
##################################################
foreach my $tabname (keys(%xCAT::ExtTab::ext_tabspec)) {
    if (exists($tabspec{$tabname})) {
	xCAT::MsgUtils->message('ES', "\n  Warning: Conflict when adding user defined tablespec. Duplicate table name: $tabname. \n");
    } else {
      $tabspec{$tabname}=$xCAT::ExtTab::ext_tabspec{$tabname};
    }
}
 




####################################################
#
#  Data abstraction definitions
#    For each table entry added to the database schema,
#    a corresponding attribute should be added to one of
#    the data objects below, or new data objects should
#    be created as needed.
#
#  Definition format:
#    List of data object hashes:
#       <dataobject_name> =>
#          {attrs =>
#             [ {attr_name => '<attribute_name>',
#                only_if => '<attr>=<value>',
#                         # optional, used to define conditional attributes.
#                         # <attr> is a previously resolved attribute from
#                         # this data object.
#                tabentry => '<table.attr>',
#                         # where the data is stored in the database
#                access_tabentry => '<table.attr>=<value>::<table.attr>=<value>',
#      # how to look up tabentry. Now support multiple lookup entries, useful for 'multiple keys" in the table 
#                         For <value>,
#                         # if "attr:<attrname>", use a previously resolved
#                         #    attribute value from the data object
#                         # for now, only supports the objectname in attr:<attrname>
#                         # if "str:<value>" use the value directly
#                description => '<description of this attribute>',
#                },
#                {attr_name => <attribute_name>,
#                    ...
#                } ],
#           attrhash => {}, # internally generated hash of attrs array
#                           # to allow code direct access to an attr def
#           objkey => 'attribute_name'  # key attribute for this data object
#          }
#
#
####################################################
%defspec = (
  node =>    { attrs => [], attrhash => {}, objkey => 'node' },
  osimage => { attrs => [], attrhash => {}, objkey => 'imagename' },
  network => { attrs => [], attrhash => {}, objkey => 'netname' },
  group => { attrs => [], attrhash => {}, objkey => 'groupname' },
  site =>    { attrs => [], attrhash => {}, objkey => 'master' },
  policy => { attrs => [], attrhash => {}, objkey => 'priority' },
  monitoring => { attrs => [], attrhash => {}, objkey => 'name' },
  notification => { attrs => [], attrhash => {}, objkey => 'filename' },
  eventlog => { attrs => [], attrhash => {}, objkey => 'recid' }, 
  boottarget => { attrs => [], attrhash => {}, objkey => 'bprofile' },
);


###############
#   @nodeattrs ia a list of node attrs that can be used for
#  BOTH node and group definitions
##############
my @nodeattrs = (
       {attr_name => 'nodetype',
                 tabentry => 'nodetype.nodetype',
                 access_tabentry => 'nodetype.node=attr:node',
       },
####################
# postscripts table#
####################
        {attr_name => 'postscripts',
                 tabentry => 'postscripts.postscripts',
                 access_tabentry => 'postscripts.node=attr:node',
  },
####################
#  noderes table   #
####################
        {attr_name => 'xcatmaster',
                 tabentry => 'noderes.xcatmaster',
                 access_tabentry => 'noderes.node=attr:node',
  },
###
# TODO:  Need to check/update code to make sure it really uses servicenode as
#        default if other server value not set
###
        {attr_name => 'servicenode',
                 tabentry => 'noderes.servicenode',
                 access_tabentry => 'noderes.node=attr:node',
  },
        {attr_name => 'tftpserver',
                 tabentry => 'noderes.tftpserver',
                 access_tabentry => 'noderes.node=attr:node',
  },
        {attr_name => 'nfsserver',
                 tabentry => 'noderes.nfsserver',
                 access_tabentry => 'noderes.node=attr:node',
  },
        {attr_name => 'nimserver',
                 tabentry => 'noderes.nimserver',
                 access_tabentry => 'noderes.node=attr:node',
  },
###
# TODO:  Is noderes.nfsdir used anywhere?  Could not find any code references
#        to this attribute.
###
        {attr_name => 'nfsdir',
                 tabentry => 'noderes.nfsdir',
                 access_tabentry => 'noderes.node=attr:node',
  },
        {attr_name => 'monserver',
                 tabentry => 'noderes.monserver',
                 access_tabentry => 'noderes.node=attr:node',
  },
 {attr_name => 'kernel',
                 tabentry => 'bootparams.kernel',
                 access_tabentry => 'bootparams.node=attr:node',
                },
 {attr_name => 'initrd',
                 tabentry => 'bootparams.initrd',
                 access_tabentry => 'bootparams.node=attr:node',
                },
 {attr_name => 'kcmdline',
                 tabentry => 'bootparams.kcmdline',
                 access_tabentry => 'bootparams.node=attr:node',
                },
 {attr_name => 'addkcmdline',
                 tabentry => 'bootparams.addkcmdline',
                 access_tabentry => 'bootparams.node=attr:node',
                },
        # Note that the serialport attr is actually defined down below
        # with the other serial*  attrs from the nodehm table
        #{attr_name => 'serialport',
        #         tabentry => 'noderes.serialport',
        #         access_tabentry => 'noderes.node=attr:node',
        # },
        {attr_name => 'primarynic',
                 tabentry => 'noderes.primarynic',
                 access_tabentry => 'noderes.node=attr:node',
  },
        {attr_name => 'installnic',
                 tabentry => 'noderes.installnic',
                 access_tabentry => 'noderes.node=attr:node',
  },
        {attr_name => 'netboot',
                 tabentry => 'noderes.netboot',
                 access_tabentry => 'noderes.node=attr:node',
  },
######################
#  servicenode table #
######################
	{attr_name => 'setupnameserver',
                 tabentry => 'servicenode.nameserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
	{attr_name => 'setupdhcp',
                 tabentry => 'servicenode.dhcpserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
	{attr_name => 'setuptftp',
                 tabentry => 'servicenode.tftpserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
	{attr_name => 'setupnfs',
                 tabentry => 'servicenode.nfsserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
	{attr_name => 'setupconserver',
                 tabentry => 'servicenode.conserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
# - moserver not used yet
#	{attr_name => 'setupmonserver',
#                 tabentry => 'servicenode.monserver',
#                 access_tabentry => 'servicenode.node=attr:node',
#  },
	{attr_name => 'setupldap',
                 tabentry => 'servicenode.ldapserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
	{attr_name => 'setupntp',
                 tabentry => 'servicenode.ntpserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
	{attr_name => 'setupftp',
                 tabentry => 'servicenode.ftpserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
	{attr_name => 'setupnim',
                 tabentry => 'servicenode.nimserver',
                 access_tabentry => 'servicenode.node=attr:node',
  },
######################
#  nodetype table    #
######################
        {attr_name => 'arch',
                 tabentry => 'nodetype.arch',
                 access_tabentry => 'nodetype.node=attr:node',
  },
        {attr_name => 'supportedarchs',
                 tabentry => 'nodetype.supportedarchs',
                 access_tabentry => 'nodetype.node=attr:node',
  },
        {attr_name => 'os',
                 tabentry => 'nodetype.os',
                 access_tabentry => 'nodetype.node=attr:node',
  },
# TODO:  need to decide what to do with the profile attr once the osimage
#        stuff is implemented.  May want to move this to the osimage table.
        {attr_name => 'profile',
                 tabentry => 'nodetype.profile',
                 access_tabentry => 'nodetype.node=attr:node',
  },
  {attr_name => 'provmethod',
                 tabentry => 'nodetype.provmethod',
                 access_tabentry => 'nodetype.node=attr:node',
  },
####################
#  iscsi table     #
####################
 {attr_name => 'iscsiserver',
                 tabentry => 'iscsi.server',
                 access_tabentry => 'iscsi.node=attr:node',
                },
 {attr_name => 'iscsitarget',
                 tabentry => 'iscsi.target',
                 access_tabentry => 'iscsi.node=attr:node',
                },
 {attr_name => 'iscsiuserid',
                 tabentry => 'iscsi.userid',
                 access_tabentry => 'iscsi.node=attr:node',
                },
 {attr_name => 'iscsipassword',
                 tabentry => 'iscsi.passwd',
                 access_tabentry => 'iscsi.node=attr:node',
                },
####################
#  nodehm table    #
####################
        {attr_name => 'mgt',
                 tabentry => 'nodehm.mgt',
                 access_tabentry => 'nodehm.node=attr:node',
  },
        {attr_name => 'power',
                 tabentry => 'nodehm.power',
                 access_tabentry => 'nodehm.node=attr:node',
  },
        {attr_name => 'cons',
                 tabentry => 'nodehm.cons',
                 access_tabentry => 'nodehm.node=attr:node',
  },
        {attr_name => 'termserver',
                 tabentry => 'nodehm.termserver',
                 access_tabentry => 'nodehm.node=attr:node',
  },
        {attr_name => 'termport',
                 tabentry => 'nodehm.termport',
                 access_tabentry => 'nodehm.node=attr:node',
  },
###
# TODO:  is nodehm.conserver used anywhere?  I couldn't find any code references
###
        {attr_name => 'conserver',
                 tabentry => 'nodehm.conserver',
                 access_tabentry => 'nodehm.node=attr:node',
  },
###
# TODO:  is nodehm.getmac used anywhere?  I couldn't find any code references
###
        {attr_name => 'getmac',
                 tabentry => 'nodehm.getmac',
                 access_tabentry => 'nodehm.node=attr:node',
  },
        {attr_name => 'serialport',
                 tabentry => 'nodehm.serialport',
                 access_tabentry => 'nodehm.node=attr:node',
  },
        {attr_name => 'serialspeed',
                 tabentry => 'nodehm.serialspeed',
                 access_tabentry => 'nodehm.node=attr:node',
  },
        {attr_name => 'serialflow',
                 tabentry => 'nodehm.serialflow',
                 access_tabentry => 'nodehm.node=attr:node',
  },
##################
#  vpd table     #
##################
        {attr_name => 'serial',
                 tabentry => 'vpd.serial',
                 access_tabentry => 'vpd.node=attr:node',
  },
        {attr_name => 'mtm',
                 tabentry => 'vpd.mtm',
                 access_tabentry => 'vpd.node=attr:node',
  },
##################
#  mac table     #
##################
 {attr_name => 'interface',
                 tabentry => 'mac.interface',
                 access_tabentry => 'mac.node=attr:node',
                },
 {attr_name => 'mac',
                 tabentry => 'mac.mac',
                 access_tabentry => 'mac.node=attr:node',
                },
##################
#  chain table   #
##################
###
# TODO:  Need user documentation from Jarrod on how to use chain, what each
#        action does, valid ordering, etc.
###
 {attr_name => 'chain',
                 tabentry => 'chain.chain',
                 access_tabentry => 'chain.node=attr:node',
                },
###
# TODO:  What is chain.ondiscover used for?  Could not find any code references
#        to this table entry
###
 {attr_name => 'ondiscover',
                 tabentry => 'chain.ondiscover',
                 access_tabentry => 'chain.node=attr:node',
                },
 {attr_name => 'currstate',
                 tabentry => 'chain.currstate',
                 access_tabentry => 'chain.node=attr:node',
                },
 {attr_name => 'currchain',
                 tabentry => 'chain.currchain',
                 access_tabentry => 'chain.node=attr:node',
                },
####################
#  ppchcp table    #
####################
 {attr_name => 'username',
                 only_if => 'nodetype=ivm',
                 tabentry => 'ppchcp.username',
                 access_tabentry => 'ppchcp.hcp=attr:node',
                },
 {attr_name => 'password',
                 only_if => 'nodetype=ivm',
                 tabentry => 'ppchcp.password',
                 access_tabentry => 'ppchcp.hcp=attr:node',
                },
 {attr_name => 'username',
                 only_if => 'nodetype=hmc',
                 tabentry => 'ppchcp.username',
                 access_tabentry => 'ppchcp.hcp=attr:node',
                },
 {attr_name => 'password',
                 only_if => 'nodetype=hmc',
                 tabentry => 'ppchcp.password',
                 access_tabentry => 'ppchcp.hcp=attr:node',
                },
####################
#  ppc table       #
####################
        {attr_name => 'hcp',
                 tabentry => 'ppc.hcp',
                 access_tabentry => 'ppc.node=attr:node',
  },
 {attr_name => 'id',
                 tabentry => 'ppc.id',
                 access_tabentry => 'ppc.node=attr:node',
                },
 {attr_name => 'pprofile',
                only_if => 'mgt=hmc',
                 tabentry => 'ppc.pprofile',
                 access_tabentry => 'ppc.node=attr:node',
                },
 {attr_name => 'pprofile',
                only_if => 'mgt=ivm',
                 tabentry => 'ppc.pprofile',
                 access_tabentry => 'ppc.node=attr:node',
                },
 {attr_name => 'parent',
                 only_if => 'mgt=hmc',
                 tabentry => 'ppc.parent',
                 access_tabentry => 'ppc.node=attr:node',
                },
 {attr_name => 'parent',
                 only_if => 'mgt=ivm',
                 tabentry => 'ppc.parent',
                 access_tabentry => 'ppc.node=attr:node',
                },
 {attr_name => 'parent',
                 only_if => 'mgt=fsp',
                 tabentry => 'ppc.parent',
                 access_tabentry => 'ppc.node=attr:node',
                },
 {attr_name => 'supernode',
                 tabentry => 'ppc.supernode',
                 access_tabentry => 'ppc.node=attr:node',
                },

#######################
#  ppcdirect table    #
#######################
        {attr_name => 'passwd.HMC',
                 only_if => 'mgt=fsp',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:HMC',
  },
        {attr_name => 'passwd.hscroot',
                 only_if => 'mgt=fsp',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:hscroot',
  },
        {attr_name => 'passwd.admin',
                 only_if => 'mgt=fsp',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:admin',
  },
        {attr_name => 'passwd.general',
                 only_if => 'mgt=fsp',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:general',
  },
        {attr_name => 'passwd.HMC',
                 only_if => 'mgt=bpa',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:HMC',
  },
        {attr_name => 'passwd.hscroot',
                 only_if => 'mgt=bpa',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:hscroot',
  },
        {attr_name => 'passwd.admin',
                 only_if => 'mgt=bpa',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:admin',
  },
        {attr_name => 'passwd.general',
                 only_if => 'mgt=bpa',
                 tabentry => 'ppcdirect.password',
                 access_tabentry => 'ppcdirect.hcp=attr:node::ppcdirect.username=str:general',
  },

####################
#  zvm table       #
####################
	{attr_name => 'hcp',
		only_if => 'mgt=zvm',
		tabentry => 'zvm.hcp',
		access_tabentry => 'zvm.node=attr:node',
	},
	{attr_name => 'userid',
		only_if => 'mgt=zvm',
		tabentry => 'zvm.userid',
		access_tabentry => 'zvm.node=attr:node',
	},
	
##################
#  ipmi table    #
##################
        {attr_name => 'bmc',
                 only_if => 'mgt=ipmi',
                 tabentry => 'ipmi.bmc',
                 access_tabentry => 'ipmi.node=attr:node',
  },
        {attr_name => 'bmcport',
                 only_if => 'mgt=ipmi',
                 tabentry => 'ipmi.bmcport',
                 access_tabentry => 'ipmi.node=attr:node',
  },
        {attr_name => 'bmcusername',
                 only_if => 'mgt=ipmi',
                 tabentry => 'ipmi.username',
                 access_tabentry => 'ipmi.node=attr:node',
  },
        {attr_name => 'bmcpassword',
                 only_if => 'mgt=ipmi',
                 tabentry => 'ipmi.password',
                 access_tabentry => 'ipmi.node=attr:node',
  },
################
#  mp table    #
################
        {attr_name => 'mpa',
                 only_if => 'mgt=blade',
                 tabentry => 'mp.mpa',
                 access_tabentry => 'mp.node=attr:node',
  },
        {attr_name => 'id',
                 only_if => 'mgt=blade',
                 tabentry => 'mp.id',
                 access_tabentry => 'mp.node=attr:node',
  },
#################
#  mpa table    #
#################
        {attr_name => 'username',
                 only_if => 'nodetype=mm',
                 tabentry => 'mpa.username',
                 access_tabentry => 'mpa.mpa=attr:node',
  },
        {attr_name => 'password',
                 only_if => 'nodetype=mm',
                 tabentry => 'mpa.password',
                 access_tabentry => 'mpa.mpa=attr:node',
  },
######################
#  nodepos table     #
######################
        {attr_name => 'rack',
                 tabentry => 'nodepos.rack',
                 access_tabentry => 'nodepos.node=attr:node',
  },
        {attr_name => 'unit',
                 tabentry => 'nodepos.u',
                 access_tabentry => 'nodepos.node=attr:node',
  },
        {attr_name => 'chassis',
                 tabentry => 'nodepos.chassis',
                 access_tabentry => 'nodepos.node=attr:node',
  },
        {attr_name => 'slot',
                 tabentry => 'nodepos.slot',
                 access_tabentry => 'nodepos.node=attr:node',

  },
        {attr_name => 'room',
                 tabentry => 'nodepos.room',
                 access_tabentry => 'nodepos.node=attr:node',
  },
######################
#  vm table          #
######################
		{attr_name => 'vmhost',
                 tabentry => 'vm.host',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'migrationdest',
                 tabentry => 'vm.migrationdest',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmstorage',
                 tabentry => 'vm.storage',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmcfgstore',
                 tabentry => 'vm.cfgstore',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmmemory',
                 tabentry => 'vm.memory',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmcpus',
                 tabentry => 'vm.cpus',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmnics',
                 tabentry => 'vm.nics',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmbootorder',
                 tabentry => 'vm.bootorder',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmvirtflags',
                 tabentry => 'vm.virtflags',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmvncport',
                 tabentry => 'vm.vncport',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmtextconsole',
                 tabentry => 'vm.textconsole',
                 access_tabentry => 'vm.node=attr:node',
                },
		{attr_name => 'vmbeacon',
                 tabentry => 'vm.beacon',
                 access_tabentry => 'vm.node=attr:node',
                },
######################
#  websrv table      #
######################
		{attr_name => 'webport',
                 only_if => 'nodetype=websrv',
                 tabentry => 'websrv.port',
                 access_tabentry => 'websrv.node=attr:node',
                },
		{attr_name => 'username',
                 only_if => 'nodetype=websrv',
                 tabentry => 'websrv.username',
                 access_tabentry => 'websrv.node=attr:node',
                },
		{attr_name => 'password',
                 only_if => 'nodetype=websrv',
                 tabentry => 'websrv.password',
                 access_tabentry => 'websrv.node=attr:node',
                },
  );


####################
#  node definition  - nodelist & hosts table parts #
####################
@{$defspec{node}->{'attrs'}} = (
####################
#  nodelist table  #
####################
        {attr_name => 'node',
                 tabentry => 'nodelist.node',
                 access_tabentry => 'nodelist.node=attr:node',
   },
        {attr_name => 'groups',
                 tabentry => 'nodelist.groups',
                 access_tabentry => 'nodelist.node=attr:node',
             },
        {attr_name => 'status',
                 tabentry => 'nodelist.status',
                 access_tabentry => 'nodelist.node=attr:node',
             },
        {attr_name => 'appstatus',
                 tabentry => 'nodelist.appstatus',
                 access_tabentry => 'nodelist.node=attr:node',
             },
        {attr_name => 'primarysn',
                 tabentry => 'nodelist.primarysn',
                 access_tabentry => 'nodelist.node=attr:node',
             },
####################
#  hosts table    #
####################
        {attr_name => 'ip',
                 tabentry => 'hosts.ip',
                 access_tabentry => 'hosts.node=attr:node',
             },
        {attr_name => 'hostnames',
                 tabentry => 'hosts.hostnames',
                 access_tabentry => 'hosts.node=attr:node',
             },
        {attr_name => 'otherinterfaces',
                 tabentry => 'hosts.otherinterfaces',
                 access_tabentry => 'hosts.node=attr:node',
             },
 {attr_name => 'usercomment',
                 tabentry => 'nodelist.comments',
                 access_tabentry => 'nodelist.node=attr:node',
             },
####################
# prescripts table#
####################
        {attr_name => 'prescripts-begin',
                 tabentry => 'prescripts.begin',
                 access_tabentry => 'prescripts.node=attr:node',
  },
        {attr_name => 'prescripts-end',
                 tabentry => 'prescripts.end',
                 access_tabentry => 'prescripts.node=attr:node',
  },
          );

# add on the node attrs from other tables
push(@{$defspec{node}->{'attrs'}}, @nodeattrs);

#########################
#  osimage data object  #
#########################
@{$defspec{osimage}->{'attrs'}} = (
 {attr_name => 'imagename',
                 tabentry => 'osimage.imagename',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'imagetype',
                 tabentry => 'osimage.imagetype',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'provmethod',
                 tabentry => 'osimage.provmethod',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'profile',
                 tabentry => 'osimage.profile',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'osname',
                 tabentry => 'osimage.osname',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'osvers',
                 tabentry => 'osimage.osvers',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'osdistro',
                 tabentry => 'osimage.osdistro',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'osarch',
                 tabentry => 'osimage.osarch',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
 {attr_name => 'synclists',
                 tabentry => 'osimage.synclists',
                 access_tabentry => 'osimage.imagename=attr:imagename',
                 },
####################
# linuximage table#
####################
 {attr_name => 'template',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.template',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
 {attr_name => 'pkglist',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.pkglist',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
 {attr_name => 'pkgdir',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.pkgdir',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
 {attr_name => 'otherpkglist',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.otherpkglist',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
 {attr_name => 'otherpkgdir',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.otherpkgdir',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
 {attr_name => 'exlist',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.exlist',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
 {attr_name => 'postinstall',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.postinstall',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
 {attr_name => 'rootimgdir',
                 only_if => 'imagetype=linux',
                 tabentry => 'linuximage.rootimgdir',
                 access_tabentry => 'linuximage.imagename=attr:imagename',
                }, 
####################
# nimimage table#
####################
 {attr_name => 'nimtype',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.nimtype',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'nimmethod',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.nimmethod',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'lpp_source',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.lpp_source',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'spot',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.spot',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'root',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.root',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'dump',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.dump',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'paging',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.paging',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'resolv_conf',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.resolv_conf',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'tmp',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.tmp',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'home',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.home',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'shared_home',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.shared_home',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'shared_root',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.shared_root',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'script',
                only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.script',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'fb_script',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.fb_script',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'bosinst_data',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.bosinst_data',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'installp_bundle',
                 only_if => 'imagetype=NIM',                 
                 tabentry => 'nimimage.installp_bundle',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
 {attr_name => 'otherpkgs',
                 only_if => 'imagetype=NIM',
				tabentry => 'nimimage.otherpkgs',
				access_tabentry => 'nimimage.imagename=attr:imagename',
				},
 {attr_name => 'mksysb',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.mksysb',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
# {attr_name => 'res_group',
#                 tabentry => 'nimimage.res_group',
#                 access_tabentry => 'nimimage.imagename=attr:imagename',
#                 },
 {attr_name => 'usercomment',
                 only_if => 'imagetype=NIM',
                 tabentry => 'nimimage.comments',
                 access_tabentry => 'nimimage.imagename=attr:imagename',
                 },
             );

#########################
#  network data object  #
#########################
#     networks table    #
#########################
@{$defspec{network}->{'attrs'}} = (
###
# TODO:  when creating networks table entries, create a default netname
#        See makenetworks command and networks.pm plugin
###
        {attr_name => 'netname',
                 tabentry => 'networks.netname',
                 access_tabentry => 'networks.netname=attr:netname',
                 },
        {attr_name => 'net',
                 tabentry => 'networks.net',
                 access_tabentry => 'networks.netname=attr:netname',
  },
        {attr_name => 'mask',
                 tabentry => 'networks.mask',
                 access_tabentry => 'networks.netname=attr:netname',
  },
        {attr_name => 'mgtifname',
                 tabentry => 'networks.mgtifname',
                 access_tabentry => 'networks.netname=attr:netname',
  },
        {attr_name => 'gateway',
                 tabentry => 'networks.gateway',
                 access_tabentry => 'networks.netname=attr:netname',
  },
        {attr_name => 'dhcpserver',
                 tabentry => 'networks.dhcpserver',
                 access_tabentry => 'networks.netname=attr:netname',
  },
        {attr_name => 'tftpserver',
                 tabentry => 'networks.tftpserver',
                 access_tabentry => 'networks.netname=attr:netname',
  },
        {attr_name => 'nameservers',
                 tabentry => 'networks.nameservers',
                 access_tabentry => 'networks.netname=attr:netname',
  },
        {attr_name => 'dynamicrange',
                 tabentry => 'networks.dynamicrange',
                 access_tabentry => 'networks.netname=attr:netname',
  },
 {attr_name => 'usercomment',
                 tabentry => 'networks.comments',
                 access_tabentry => 'networks.netname=attr:netname',
                },
             );

#####################
#  site data object #
#####################
#     site table    #
#####################
##############
# TODO:  need to figure out how to handle a key for the site table.
#        since this is really implemented differently than all the other
#        data objects, it doesn't map as cleanly.
#        change format of site table so each column is an attr and there
#        is only a single row in the table keyed by xcatmaster name?
#############
@{$defspec{site}->{'attrs'}} = (
        {attr_name => 'master',
                 tabentry => 'site.value',
                 access_tabentry => 'site.key=str:master',
                 description => 'The management node'},
        {attr_name => 'installdir',
                 tabentry => 'site.value',
                 access_tabentry => 'site.key=str:installdir',
                 description => 'The installation directory'},
        {attr_name => 'xcatdport',
                 tabentry => 'site.value',
                 access_tabentry => 'site.key=str:xcatdport',
                 description => 'Port used by xcatd daemon on master'},
             );
#######################
#  groups data object #
#######################
#     groups table    #
#######################
@{$defspec{group}->{'attrs'}} = (
        {attr_name => 'groupname',
                 tabentry => 'nodegroup.groupname',
                 access_tabentry => 'nodegroup.groupname=attr:groupname',
                 },
 {attr_name => 'grouptype',
         tabentry => 'nodegroup.grouptype',
   access_tabentry => 'nodegroup.groupname=attr:groupname',
   },
        {attr_name => 'members',
                 tabentry => 'nodegroup.members',
                 access_tabentry => 'nodegroup.groupname=attr:groupname',
                 },
 {attr_name => 'wherevals',
                 tabentry => 'nodegroup.wherevals',
                 access_tabentry => 'nodegroup.groupname=attr:groupname',
                 },
 {attr_name => 'ip',
                 tabentry => 'hosts.ip',
                 access_tabentry => 'hosts.node=attr:node',
                },
 {attr_name => 'hostnames',
                 tabentry => 'hosts.hostnames',
                 access_tabentry => 'hosts.node=attr:node',
                },
 {attr_name => 'usercomment',
                 tabentry => 'nodegroup.comments',
                 access_tabentry => 'nodegroup.groupname=attr:groupname',
                },

###
# TODO:  Need to copy attrs that are common between nodes and static groups
#        Ideas:  make a separate data structure that is linked/copied here.
#                need to figure out the perl dereferencing to make that work.
###
   );

# add on the generic node attrs
push(@{$defspec{group}->{'attrs'}}, @nodeattrs);

#######################
#  policy data object #
#######################
#     policy table    #
#######################
@{$defspec{policy}->{'attrs'}} = (
###
# TODO:  The policy validate subroutine in the xcatd daemon code does not
#        sort the rules in the policy table in priority order before
#        processing.  Talk to Jarrod - I think it should.
###
        {attr_name => 'priority',
                tabentry => 'policy.priority',
                access_tabentry => 'policy.priority=attr:priority',
  },
        {attr_name => 'name',
                 tabentry => 'policy.name',
                 access_tabentry => 'policy.priority=attr:priority',
  },
        {attr_name => 'host',
                 tabentry => 'policy.host',
                 access_tabentry => 'policy.priority=attr:priority',
  },
        {attr_name => 'commands',
                 tabentry => 'policy.commands',
                 access_tabentry => 'policy.priority=attr:priority',
  },
        {attr_name => 'noderange',
                 tabentry => 'policy.noderange',
                 access_tabentry => 'policy.priority=attr:priority',
  },
        {attr_name => 'parameters',
                 tabentry => 'policy.parameters',
                 access_tabentry => 'policy.priority=attr:priority',
  },
        {attr_name => 'time',
                 tabentry => 'policy.time',
                 access_tabentry => 'policy.priority=attr:priority',
  },
        {attr_name => 'rule',
                tabentry => 'policy.rule',
  access_tabentry => 'policy.priority=attr:priority' ,
  },
 {attr_name => 'usercomment',
                 tabentry => 'policy.comments',
                 access_tabentry => 'policy.priority=attr:priority',
                },
             );

#############################
#  notification data object #
#############################
#     notification table    #
#############################
@{$defspec{notification}->{'attrs'}} = (
        {attr_name => 'filename',
                 tabentry => 'notification.filename',
                 access_tabentry => 'notification.filename=attr:filename',
                 },
        {attr_name => 'tables',
                 tabentry => 'notification.tables',
                 access_tabentry => 'notification.filename=attr:filename',
                 },
        {attr_name => 'tableops',
                 tabentry => 'notification.tableops',
                 access_tabentry => 'notification.filename=attr:filename',
                 },
        {attr_name => 'comments',
                 tabentry => 'notification.comments',
                 access_tabentry => 'notification.filename=attr:filename',
                 },
         );

###########################
#  monitoring data object #
###########################
#     monitoring table    #
###########################
@{$defspec{monitoring}->{'attrs'}} = (
        {attr_name => 'name',
                 tabentry => 'monitoring.name',
                 access_tabentry => 'monitoring.name=attr:name',
                 },
        {attr_name => 'nodestatmon',
                 tabentry => 'monitoring.nodestatmon',
                 access_tabentry => 'monitoring.name=attr:name',
                 },
        {attr_name => 'comments',
                 tabentry => 'monitoring.comments',
                 access_tabentry => 'monitoring.name=attr:name',
                 },
	{attr_name => 'disable',
                 tabentry => 'monitoring.disable',
                 access_tabentry => 'monitoring.name=attr:name',
                 },
);

@{$defspec{eventlog}->{'attrs'}} = (
        {attr_name => 'recid',
                 tabentry => 'eventlog.recid',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'eventtime',
                 tabentry => 'eventlog.eventtime',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'eventtype',
                 tabentry => 'eventlog.eventtype',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'monitor',
                 tabentry => 'eventlog.monitor',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'monnode',
                 tabentry => 'eventlog.monnode',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'node',
                 tabentry => 'eventlog.node',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'application',
                 tabentry => 'eventlog.application',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'component',
                 tabentry => 'eventlog.component',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'id',
                 tabentry => 'eventlog.id',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'severity',
                 tabentry => 'eventlog.severity',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'message',
                 tabentry => 'eventlog.message',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'rawdata',
                 tabentry => 'eventlog.rawdata',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
        {attr_name => 'comments',
                 tabentry => 'eventlog.comments',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
	{attr_name => 'disable',
                 tabentry => 'eventlog.disable',
                 access_tabentry => 'eventlog.recid=attr:recid',
                 },
);





###################################################
# adding user defined external defspec
##################################################
foreach my $objname (keys(%xCAT::ExtTab::ext_defspec)) {
    if (exists($xCAT::ExtTab::ext_defspec{$objname}->{'attrs'})) {
	if (exists($defspec{$objname})) {
	    my @extattr=@{$xCAT::ExtTab::ext_defspec{$objname}->{'attrs'}};
	    my @attr=@{$defspec{$objname}->{'attrs'}};
	    my %tmp_hash=();
	    foreach my $orig (@attr) {
		my $attrname=$orig->{attr_name};
		$tmp_hash{$attrname}=1;
	    }
	    foreach(@extattr) {
		my $attrname=$_->{attr_name};
		if (exists($tmp_hash{$attrname})) {
		    xCAT::MsgUtils->message('ES', "\n  Warning: Conflict when adding user defined defspec. Attribute name $attrname is already defined in object $objname. \n");
		} else {
		    push(@{$defspec{$objname}->{'attrs'}}, $_); 
		}
	    }
	} else {
	    $defspec{$objname}=$xCAT::ExtTab::ext_defspec{$objname};
	}
    }
}


#print "\ndefspec:\n";
#foreach(%xCAT::Schema::defspec) {
#    print "  $_:\n";
#    my @attr=@{$xCAT::Schema::defspec{$_}->{'attrs'}};
#    foreach my $h (@attr) {
#	print "    " . $h->{attr_name} . "\n";
#    }
#}  


# Build a corresponding hash for the attribute names to make
# definition access easier
foreach (keys %xCAT::Schema::defspec) {
   my $dataobj = $xCAT::Schema::defspec{$_};
   my $this_attr;
   foreach $this_attr (@{$dataobj->{'attrs'}}){
      $dataobj->{attrhash}->{$this_attr->{attr_name}} = $this_attr;
   }
};
1;


