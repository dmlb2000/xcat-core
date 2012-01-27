Summary: Server and configuration utilities of the xCAT management project
Name: xCAT-server
Version: %(cat Version)
Release: snap%(date +"%Y%m%d%H%M")
Epoch: 4
License: EPL
Group: Applications/System
Source: xCAT-server-%(cat Version).tar.gz
Packager: IBM Corp.
Vendor: IBM Corp.
Distribution: %{?_distribution:%{_distribution}}%{!?_distribution:%{_vendor}}
Prefix: /opt/xcat
BuildRoot: /var/tmp/%{name}-%{version}-%{release}-root

%ifnos linux
AutoReqProv: no
%endif

# AIX will build with an arch of "ppc"
# also need to fix Requires for AIX
%ifos linux
BuildArch: noarch
Requires: perl-IO-Socket-SSL perl-XML-Simple perl-IO-Tty perl-Crypt-SSLeay make
Obsoletes: atftp-xcat
%endif

Requires: perl-xCAT >= %{epoch}:%(cat Version|cut -d. -f 1,2)
Requires: xCAT-client  >= %{epoch}:%(cat Version|cut -d. -f 1,2)

Provides: xCAT-server = %{epoch}:%{version}

%description
xCAT-server provides the core server and configuration management components of xCAT.  This package should be installed on your management server

%define zvm %(if [ "$zvm" = "1" ];then echo 1; else echo 0; fi)

# %define VERBOSE %(if [ "$VERBOSE" = "1" -o "$VERBOSE" = "yes" ];then echo 1; else echo 0; fi)
# %define NOVERBOSE %(if [ "$VERBOSE" = "1" -o "$VERBOSE" = "yes" ];then echo 0; else echo 1; fi)
# %define NOVERBOSE %{?VERBOSE:1}%{!?VERBOSE:0}

%prep
# %if %NOVERBOSE
# echo NOVERBOSE is on
# set +x
# %elseif
# set -x
# %endif

%setup -q -n xCAT-server
%build
%install
rm -rf $RPM_BUILD_ROOT
#cp foo bar
mkdir -p $RPM_BUILD_ROOT/%{prefix}/sbin
mkdir -p $RPM_BUILD_ROOT/%{prefix}/bin
#mkdir -p $RPM_BUILD_ROOT/%{prefix}/rc.d
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/install
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/netboot
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/ca
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/scripts
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/tools
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/cons
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/rollupdate
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/installp_bundles
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/image_data
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/scripts
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/netboot/sles
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/scripts/Mellanox
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/scripts/QLogic
mkdir -p $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin
mkdir -p $RPM_BUILD_ROOT/%{prefix}/xdsh/Context
mkdir -p $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring/samples
mkdir -p $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring/pcp
mkdir -p $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_schema/samples
mkdir -p $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT

%ifos linux
cp -a share/xcat/install/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/install/
cp -a share/xcat/netboot/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/netboot/
%else
cp -hpR share/xcat/install/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/install/
cp -hpR share/xcat/netboot/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/netboot/
%endif

%ifos linux
# pwd
cp -d sbin/* $RPM_BUILD_ROOT/%{prefix}/sbin
chmod 755 $RPM_BUILD_ROOT/%{prefix}/sbin/*
cp -d bin/* $RPM_BUILD_ROOT/%{prefix}/bin
chmod 755 $RPM_BUILD_ROOT/%{prefix}/bin/*
%else
cp -h sbin/* $RPM_BUILD_ROOT/%{prefix}/sbin
chmod -h 755 $RPM_BUILD_ROOT/%{prefix}/sbin/*
cp -h bin/* $RPM_BUILD_ROOT/%{prefix}/bin
chmod -h 755 $RPM_BUILD_ROOT/%{prefix}/bin/*
%endif
#cp rc.d/* $RPM_BUILD_ROOT/%{prefix}/rc.d
#chmod 755 $RPM_BUILD_ROOT/%{prefix}/rc.d/*

cp share/xcat/ca/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/ca
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/xcat/ca/*

cp share/xcat/scripts/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/scripts
cp share/xcat/tools/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/tools
cp share/xcat/rollupdate/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/rollupdate
cp share/xcat/installp_bundles/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/installp_bundles
cp share/xcat/image_data/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/image_data
cp share/xcat/cons/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/cons
cp -r share/xcat/ib/scripts/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/scripts
cp share/xcat/ib/netboot/sles/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/netboot/sles
chmod 755 $RPM_BUILD_ROOT/%{prefix}/share/xcat/cons/*
chmod 755 $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/scripts/*
chmod 755 $RPM_BUILD_ROOT/%{prefix}/share/xcat/ib/netboot/sles/*

cp lib/xcat/plugins/* $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/*

cp lib/perl/xCAT/* $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT/*

chmod 755 $RPM_BUILD_ROOT/%{prefix}/share/xcat/netboot/sles/*.postinstall

# For now, don't ship these plugins on AIX to avoid AIX dependency.
%ifnos linux
rm $RPM_BUILD_ROOT/%{prefix}/sbin/stopstartxcatd
#rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/blade.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/hpblade.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/hpilo.pm
#rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/ipmi.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/nodediscover.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/switch.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/xen.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/kvm.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/vbox.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/activedirectory.pm
%endif

# Don't ship these on zVM, to reduce dependencies
%if %zvm
rm $RPM_BUILD_ROOT/%{prefix}/sbin/stopstartxcatd
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/blade.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/hpblade.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/hpilo.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/ipmi.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/ipmi.pm.legacy
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/nodediscover.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/switch.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/xen.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/kvm.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/vbox.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/activedirectory.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/aixinstall.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/bmcconfig.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/bpa.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/esx.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/FIP.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/fsp.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/hmc.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/ivm.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/lsslp.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/pxe.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/toolscenter.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/windows.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/xcat2nim.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_plugin/xnba.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT/ADUtils.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT/IPMI.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT/MellanoxIB.pm
rm $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT/PPC.pm
%endif

cp lib/xcat/dsh/Context/* $RPM_BUILD_ROOT/%{prefix}/xdsh/Context
chmod 644 $RPM_BUILD_ROOT/%{prefix}/xdsh/Context/*

cp -r lib/xcat/monitoring/* $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring/*

chmod 755 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring/samples
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring/samples/*
chmod 755 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring/pcp
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_monitoring/pcp/*

cp -r lib/xcat/schema/* $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_schema
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_schema/*

chmod 755 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_schema/samples
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/perl/xCAT_schema/samples/*


cp lib/xcat/shfunctions $RPM_BUILD_ROOT/%{prefix}/lib
chmod 644 $RPM_BUILD_ROOT/%{prefix}/lib/shfunctions
mkdir -p $RPM_BUILD_ROOT/etc/init.d
cp etc/init.d/xcatd $RPM_BUILD_ROOT/etc/init.d
#TODO: the next has to me moved to postscript, to detect /etc/xcat vs /etc/opt/xcat
mkdir -p $RPM_BUILD_ROOT/etc/xcat
cp etc/xcat/postscripts.rules $RPM_BUILD_ROOT/etc/xcat/

mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-server
cp LICENSE.html $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-server
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-server/*
#echo $RPM_BUILD_ROOT %{prefix}

# genereate the configuration files for web service (REST API)
mkdir -p $RPM_BUILD_ROOT/%{prefix}/ws
mkdir -p $RPM_BUILD_ROOT/etc/apache2/conf.d
mkdir -p $RPM_BUILD_ROOT/etc/httpd/conf.d
cp xCAT-wsapi/* $RPM_BUILD_ROOT/%{prefix}/ws
echo "ScriptAlias /xcatws %{prefix}/ws/xcatws.cgi" > $RPM_BUILD_ROOT/etc/apache2/conf.d/xcat-ws.conf
cat $RPM_BUILD_ROOT/%{prefix}/ws/xcat-ws.conf.apache2 >>  $RPM_BUILD_ROOT/etc/apache2/conf.d/xcat-ws.conf

echo "ScriptAlias /xcatws %{prefix}/ws/xcatws.cgi" > $RPM_BUILD_ROOT/etc/httpd/conf.d/xcat-ws.conf
cat $RPM_BUILD_ROOT/%{prefix}/ws/xcat-ws.conf.httpd >> $RPM_BUILD_ROOT/etc/httpd/conf.d/xcat-ws.conf
rm -f $RPM_BUILD_ROOT/%{prefix}/ws/xcat-ws.conf.apache2
rm -f $RPM_BUILD_ROOT/%{prefix}/ws/xcat-ws.conf.httpd

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
#%doc LICENSE.html
%{prefix}
/etc/xcat
/etc/init.d/xcatd
/etc/apache2/conf.d/xcat-ws.conf
/etc/httpd/conf.d/xcat-ws.conf

%changelog
* Fri Nov 20 2007 - Jarrod Johnson <jbjohnso@us.ibm.com>
- Changes for relocatible rpm.

* Wed May 2 2007 - Norm Nott <nott@us.ibm.com>
- Made changes to make this work on AIX

* Tue Feb 27 2007 Jarrod Johnson <jbjohnso@us.ibm.com>
- Spawn server rpm for the server half of things, fix requires

* Tue Feb 20 2007 Jarrod Johnson <jbjohnso@us.ibm.com>
- Start core rpm for 1.3 work

%post
%ifos linux
ln -sf $RPM_INSTALL_PREFIX0/sbin/xcatd /usr/sbin/xcatd
 
if [ "$1" = "1" ]; then #Only if installing for the first time..
 if [ -x /usr/lib/lsb/install_initd ]; then
   /usr/lib/lsb/install_initd /etc/init.d/xcatd
 elif [ -x /sbin/chkconfig ]; then
   /sbin/chkconfig --add xcatd
 else
   echo "Unable to register init scripts on this system"
 fi
fi
if [ "$1" -gt "1" ]; then #only on upgrade...
  #migration issue for monitoring
  XCATROOT=$RPM_INSTALL_PREFIX0 $RPM_INSTALL_PREFIX0/sbin/chtab filename=monitorctrl.pm notification -d
 
  if [ -f "/proc/cmdline" ]; then   # prevent running it during install into chroot image
    /etc/init.d/xcatd reload
  fi
fi
%else
if [ "$1" -gt "1" ]; then #only on upgrade for AIX...
    #migration issue for monitoring
    XCATROOT=$RPM_INSTALL_PREFIX0 $RPM_INSTALL_PREFIX0/sbin/chtab filename=monitorctrl.pm notification -d 

  if [ -n "$INUCLIENTS" ] && [ $INUCLIENTS -eq 1 ]; then
    #Do nothing in not running system
    echo "Do not restartxcatd in not running system"
  else
    XCATROOT=$RPM_INSTALL_PREFIX0 $RPM_INSTALL_PREFIX0/sbin/restartxcatd -r
  fi     
fi  
%endif


exit 0

%preun
%ifos linux
if [ $1 == 0 ]; then  #This means only on -e
	if [ -f "/proc/cmdline" ]; then   # prevent running it during install into chroot image
  		/etc/init.d/xcatd stop
  	fi
  if [ -x /usr/lib/lsb/remove_initd ]; then
      /usr/lib/lsb/remove_initd /etc/init.d/xcatd
  elif [ -x /sbin/chkconfig ]; then
    /sbin/chkconfig --del xcatd
  fi
  rm -f /usr/sbin/xcatd  #remove the symbolic

  rm -f /etc/httpd/conf.d/xcat-ws.conf
  rm -f /etc/httpd/conf.d/xcat-ws.conf
fi
%endif

