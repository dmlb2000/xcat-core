Summary: Web Client for xCAT 2
Name: xCAT-UI
Version: %(cat Version)
Release: snap%(date +"%Y%m%d%H%M")
License: EPL
Group: Applications/System
URL: http://xcat.sourceforge.net/
Packager: IBM
Vendor: IBM

Source: xCAT-UI-%(cat Version).tar.gz
BuildRoot: /var/tmp/%{name}-%{version}-%{release}-root
BuildArch: noarch
Provides: xCAT-UI = %{version}
Requires: xCAT-UI-deps >= 2.6

Distribution: %{?_distribution:%{_distribution}}%{!?_distribution:%{_vendor}}
Prefix: /opt/xcat

%ifos linux
# httpd is provided as apache2 on SLES and httpd on RHEL
Requires: httpd
%endif

%description
Provides a browser-based interface for xCAT (Extreme Cloud Administration Toolkit).

%prep
%setup -q -n xCAT-UI

%build
#********** Build **********
# Minify Javascript files using Google Compiler
echo "Minifying Javascripts... This will take a couple of minutes."

COMPILER_JAR='/xcat2/build/tools/compiler.jar'
UI_JS="js/"

# Find all Javascript files
declare -a FILES
FILES=`find ${UI_JS} -name '*.js'`

%ifos linux
JAVA='/opt/ibm/java-ppc64-60/jre/bin/java'
for i in ${FILES[*]}; do
	# Ignore Javascripts that are already minified
	if [[ ! $i =~ '.*\.min\.js$' ]]; then
		`${JAVA} -jar ${COMPILER_JAR} --warning_level=QUIET --js=$i --js_output_file=$i.min`
		
		# Remove old Javascript and replace it with minified version
		rm -rf $i
		mv $i.min $i
    fi
done

%else  # AIX
JAVA='/usr/java6_64/bin/java'
for i in ${FILES[*]}; do
	# Ignore Javascripts that are already minified
	if [[ ! $i = @(*.min.js) ]]; then
		`${JAVA} -jar ${COMPILER_JAR} --warning_level=QUIET --js=$i --js_output_file=$i.min`
		
		# Remove old Javascript and replace it with minified version
		rm -rf $i
		mv $i.min $i
    fi
done
%endif

IFS='
'

%install
#********** Install **********
rm -rf $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT%{prefix}/ui
set +x
cp -r * $RPM_BUILD_ROOT%{prefix}/ui
chmod 755 $RPM_BUILD_ROOT%{prefix}/ui/*
set -x

%files
%defattr(-,root,root)
%{prefix}/ui

%pre
#********** Pre-install **********
# Inspect whether PHP related RPM packages are installed
%ifos linux
	if [ -e "/etc/redhat-release" ]; then
		rpm -q php >/dev/null
		if [ $? != 0 ]; then
			echo ""
			echo "Error! php has not been installed. Please run 'yum install php' before installing xCAT-UI.";
			exit -1;
		fi
	else 	# SUSE
		rpm -q apache2-mod_php5 php5 >/dev/null
		if [ $? != 0 ]; then
			echo ""
			echo "Error! apache2-mod_php5 and php5 have not been installed. Please run 'zypper install apache2-mod_php5 php5' before installing xCAT-UI."
			exit -1;
		fi
	fi
%else   # AIX
    if [ -e "/usr/IBM/HTTPServer/conf/httpd.conf" ]; then
        echo "Installing xCAT-UI on AIX..."
    else
        echo ""
        echo "Error! IBM HTTP Server is not installed or not installed in the default directory (/usr/IBM/HTTPServer/)."
        exit -1;
    fi
%endif

%post
#********** Post-install **********
# Get apache name
%ifos linux
	if [ -e "/etc/redhat-release" ]; then
	  	apachedaemon='httpd'
	  	apacheuser='apache'
	else    # SUSE
	  	apachedaemon='apache2'
	  	apacheuser='wwwrun'
	fi

	if [ "$1" = 1 ]    # Install
	then
		# Copy php.ini file into /opt/xcat/ui and turn off output_buffering
		if [ -e "/etc/redhat-release" ]; then
			/bin/sed /etc/php.ini -e 's/output_buffering = 4096/output_buffering = Off/g' > %{prefix}/ui/php.ini
	 	else 	# SUSE
	    	/bin/sed /etc/php5/apache2/php.ini -e 's/output_buffering = 4096/output_buffering = Off/g' > %{prefix}/ui/php.ini
	  	fi
	  	
	  	# Update apache conf
	  	/bin/rm -f /etc/$apachedaemon/conf.d/xcat-ui.conf
	  	/bin/ln -s %{prefix}/ui/etc/apache2/conf.d/xcat-ui.conf /etc/$apachedaemon/conf.d/xcat-ui.conf
	  	/etc/init.d/$apachedaemon reload
	  		  		  
	  	# Automatically put encrypted password into the xCAT passwd database
	  	%{prefix}/sbin/chtab key=xcat,username=root passwd.password=`grep root /etc/shadow|cut -d : -f 2`
	
	  	echo "To use xCAT-UI, point your browser to http://"`hostname -f`"/xcat"
	fi
	
	if [ "$1" = 1 ] || [ "$1" = 2 ]		# Install or upgrade
	then
		# Uncomment this if we change xcat-ui.conf again
		# /etc/init.d/$apachedaemon reload
		true
	fi
%else	# AIX
	ihs_config_dir='/usr/IBM/HTTPServer/conf'
	if [ "$1" = 1 ] #initial install
	then
	    # Check if IBM HTTP Server is installed in the default directory
	    # Update the apache config
	    echo "Updating IBM HTTP server configuration for xCAT..."
	    bin/rm -f /usr/IBM/HTTPServer/conf/xcat-ui.conf
	    cp /usr/IBM/HTTPServer/conf/httpd.conf /usr/IBM/HTTPServer/conf/httpd.conf.xcat.ui.bak
	    cat /opt/xcat/ui/etc/apache2/conf.d/xcat-ui.conf >> /usr/IBM/HTTPServer/conf/httpd.conf
	    /usr/IBM/HTTPServer/bin/apachectl restart
	
	    # Put the encrypted password in /etc/security/passwd into the xcat passwd database
	    CONT=`cat /etc/security/passwd`
	    %{prefix}/sbin/chtab key=xcat,username=root passwd.password=`echo $CONT |cut -d ' ' -f 4`
	fi

	if [ "$1" = 1 ] || [ "$1" = 2 ]      # Install or upgrade
	then
	    # Uncomment this if we change xcat-ui.conf again
	    # /etc/init.d/$apachedaemon reload
	    true
	fi
%endif

%preun
#---------- Pre-uninstall ----------
%ifos linux
	if [ "$1" = 0 ]         # RPM being removed
	then
		if [ -e "/etc/redhat-release" ]; then
			apachedaemon='httpd'
			apacheuser='apache'
		else    # SUSE
			apachedaemon='apache2'
			apacheuser='wwwrun'
		fi
	
		# Remove links made during the post install script
		echo "Undoing $apachedaemon configuration for xCAT..."
		/bin/rm -f /etc/$apachedaemon/conf.d/xcat-ui.conf
		/bin/rm -f %{prefix}/ui/php.ini
		/etc/init.d/$apachedaemon reload
	fi
%else   # AIX
	# Remove links made during the post install script
	echo "Undoing IBM HTTP Server configuration for xCAT..."
	if [ -e "/usr/IBM/HTTPServer/conf/httpd.conf.xcat.ui.bak" ];then
    	cp /usr/IBM/HTTPServer/conf/httpd.conf.xcat.ui.bak /usr/IBM/HTTPServer/conf/httpd.conf
    	rm -rf /usr/IBM/HTTPServer/conf/httpd.conf.xcat.ui.bak
	fi
	/usr/IBM/HTTPServer/bin/apachectl restart
%endif