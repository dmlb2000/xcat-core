Summary: Web Client for xCAT 2
Name: xCAT-UI
Version: %(cat Version)
Release: snap%(date +"%Y%m%d%H%M")
Epoch: 4

License: EPL
Group: Applications/System
Source: xCAT-UI-%(cat Version).tar.gz
Packager: IBM Corp.
Vendor: IBM Corp.
URL: http://xcat.org
Distribution: %{?_distribution:%{_distribution}}%{!?_distribution:%{_vendor}}
Prefix: /opt/xcat
BuildRoot: /var/tmp/%{name}-%{version}-%{release}-root

BuildArch: noarch
Provides: xCAT-UI = %{version}

%ifos linux
# httpd is provided by apache2 on SLES and httpd on RHEL
Requires: httpd
# we also require php4-session on SLES, but this does not exist on RHEL, so do not know how to do the Require
%endif

%description
Provides a browser-based interface for xCAT (extreme Cluster Administration Tool).

%prep
%setup -q -n xCAT-UI
%build
%install

rm -rf $RPM_BUILD_ROOT

mkdir -p $RPM_BUILD_ROOT%{prefix}/ui

cp -r * $RPM_BUILD_ROOT%{prefix}/ui
chmod 755 $RPM_BUILD_ROOT%{prefix}/ui/*

%files
%defattr(-,root,root)
# %defattr( 555, root, root, 755 )
%{prefix}/ui


%post
# Post-install script---------------------------------------------------
%ifos linux
# Set variables for apache because the names vary on redhat and suse
if [ -e "/etc/redhat-release" ]; then
  	apachedaemon='httpd'
  	apacheuser='apache'

	# Note: this was for sudo with xcat 1.3
	#echo "Updating apache userid to allow logins..."
	#cp /etc/passwd /etc/passwd.orig
	#perl -e 'while (<>) { s,^apache:(.*):/sbin/nologin$,apache:$1:/bin/bash,; print $_; }' /etc/passwd.orig >/etc/passwd
else    # SuSE
  	apachedaemon='apache2'
  	apacheuser='wwwrun'
fi

if [ "$1" = 1 ]    # initial install
then
  # Update the apache config
  #echo "Updating $apachedaemon configuration for xCAT..."
  /bin/rm -f /etc/$apachedaemon/conf.d/xcat-ui.conf
  /bin/ln -s %{prefix}/ui/etc/apache2/conf.d/xcat-ui.conf /etc/$apachedaemon/conf.d/xcat-ui.conf
  /etc/init.d/$apachedaemon reload

  # Link to the grpattr cmd.  Note: this was for xcat 1.3.  Do not use this anymore.
  #/bin/rm -f %{prefix}/bin/grpattr
  #mkdir -p %{prefix}/bin
  #/bin/ln -s %{prefix}/ui/cmds/grpattr %{prefix}/bin/grpattr

  # Config sudo.  Note: this was for xcat 1.3.  Do not use this anymore.
  #if ! egrep -q "^$apacheuser ALL=\(ALL\) NOPASSWD:ALL" /etc/sudoers; then
  	#echo "Configuring sudo for $apacheuser..."
  	#echo "$apacheuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
  #fi

  # Authorize the apacheuser to xcatd
  #echo -e "y\ny\ny" | %{prefix}/share/xcat/scripts/setup-local-client.sh $apacheuser
  #XCATROOT=%{prefix} %{prefix}/sbin/chtab priority=5 policy.name=$apacheuser policy.rule=allow

  echo "To use xCAT-UI, point your browser to http://"`hostname`"/xcat"
fi

if [ "$1" = 1 ] || [ "$1" = 2 ]        # initial install, or upgrade and this is the newer rpm
then
  # Uncomment this if we change xcat-ui.conf again
  #/etc/init.d/$apachedaemon reload
  true
fi

%else #on AIX, it's different
ihs_config_dir='/usr/IBM/HTTPServer/conf'
if [ "$1" = 1 ] #initial install
then
    # Update the apache config
    echo "Updating ibm http server configuration for xCAT..."
    /bin/rm -f /usr/IBM/HTTPServer/conf/xcat-ui.conf
    cp /usr/IBM/HTTPServer/conf/httpd.conf /usr/IBM/HTTPServer/conf/httpd.conf.xcat.ui.bak
    cat /opt/xcat/ui/etc/apache2/conf.d/xcat-ui.conf >> /usr/IBM/HTTPServer/conf/httpd.conf
    /usr/IBM/HTTPServer/bin/apachectl restart
fi

if [ "$1" = 1 ] || [ "$1" = 2 ]      # initial install, or upgrade and this is the newer rpm
then
    # Uncomment this if we change xcat-ui.conf again
    #/etc/init.d/$apachedaemon reload
    true
fi

%endif

%preun
# Pre-uninstall script -------------------------------------------------

%ifos linux
if [ "$1" = 0 ]         # final rpm being removed
then
  if [ -e "/etc/redhat-release" ]; then
  	apachedaemon='httpd'
  	apacheuser='apache'

	# Undo change we made to passwd file.  Todo: change this when switch to xcat 2
	#echo "Undoing apache userid login..."
	#cp /etc/passwd /etc/passwd.tmp
	#perl -e 'while (<>) { s,^apache:(.*):/bin/bash$,apache:$1:/sbin/nologin,; print $_; }' /etc/passwd.tmp >/etc/passwd
  else    # SuSE
  	apachedaemon='apache2'
  	apacheuser='wwwrun'
  fi

  # Remove links made during the post install script
  echo "Undoing $apachedaemon configuration for xCAT..."
  /bin/rm -f /etc/$apachedaemon/conf.d/xcat-ui.conf
  /etc/init.d/$apachedaemon reload
  #/bin/rm -f %{prefix}/bin/grpattr

  # Remove change we made to sudoers config.  Todo: remove this when switch to xcat 2
  #if egrep -q "^$apacheuser ALL=\(ALL\) NOPASSWD:ALL" /etc/sudoers; then
  	#echo "Undoing sudo configuration for $apacheuser..."
  	#cp -f /etc/sudoers /etc/sudoers.tmp
  	#egrep -v "^$apacheuser ALL=\(ALL\) NOPASSWD:ALL" /etc/sudoers.tmp > /etc/sudoers
  	#rm -f /etc/sudoers.tmp
  #fi

fi
%else   #for AIX
# Remove links made during the post install script
echo "Undoing IBM HTTP Server configuration for xCAT..."
cp /usr/IBM/HTTPServer/conf/httpd.conf.xcat.ui.conf /usr/IBM/HTTPServer/conf/httpd.conf
rm -rf /usr/IBM/HTTPServer/conf/httpd.conf.xcat.ui.conf
/usr/IBM/HTTPServer/bin/apachectl restart
%endif

