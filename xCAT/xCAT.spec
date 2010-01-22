Summary: Meta-package for a common, default xCAT setup
Name: xCAT
Version: %(cat Version)
Release: snap%(date +"%Y%m%d%H%M")
License: EPL
Group: Applications/System
Vendor: IBM Corp.
Packager: IBM Corp.
Distribution: %{?_distribution:%{_distribution}}%{!?_distribution:%{_vendor}}
Prefix: /opt/xcat
BuildRoot: /var/tmp/%{name}-%{version}-%{release}-root
#BuildArch: noarch
Source1: xcat.conf
Source2: postscripts.tar.gz
Source3: templates.tar.gz

%ifos linux
Source4: prescripts.tar.gz
%endif

Provides: xCAT = %{version}
Conflicts: xCATsn
Requires: xCAT-server xCAT-client perl-DBD-SQLite

%ifos linux
Requires: atftp dhcp httpd nfs-utils expect nmap fping bind perl-XML-Parser vsftpd
%ifarch s390x
# No additional requires for zLinux right now
%else
# yaboot-xcat is pulled in so any MN can manage ppc nodes
Requires: conserver yaboot-xcat perl-Net-Telnet
%endif
%ifarch ppc64
Requires: perl-IO-Stty
%endif
%endif

%ifarch i386 i586 i686 x86 x86_64
# All versions of the nb rpms are pulled in so an x86 MN can manage nodes of any arch.
# The nb rpms are used for dhcp-based discovery, and flashing, so for now we do not need them on a ppc MN.
Requires: xCAT-nbroot-oss-x86 xCAT-nbroot-core-x86 xCAT-nbkernel-x86 xCAT-nbroot-oss-x86_64 xCAT-nbroot-core-x86_64 xCAT-nbkernel-x86_64 xCAT-nbroot-oss-ppc64 xCAT-nbroot-core-ppc64 xCAT-nbkernel-ppc64 syslinux
Requires: ipmitool >= 1.8.9
Requires: xnba-undi syslinux-xcat
%endif

%description
xCAT is a server management package intended for at-scale management, including
hardware management and software management.

%prep
%ifos linux
tar zxf %{SOURCE2}
tar zxf %{SOURCE4}
%else
rm -rf postscripts
cp %{SOURCE2} /opt/freeware/src/packages/BUILD
gunzip -f postscripts.tar.gz
tar -xf postscripts.tar
%endif

%build

%install
mkdir -p $RPM_BUILD_ROOT/etc/apache2/conf.d
mkdir -p $RPM_BUILD_ROOT/etc/httpd/conf.d
mkdir -p $RPM_BUILD_ROOT/install/postscripts
mkdir -p $RPM_BUILD_ROOT/install/prescripts
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/
cd $RPM_BUILD_ROOT/%{prefix}/share/xcat/

%ifos linux
tar zxf %{SOURCE3}
%else
cp %{SOURCE3} $RPM_BUILD_ROOT/%{prefix}/share/xcat
gunzip -f templates.tar.gz
tar -xf templates.tar
rm templates.tar
%endif

cd -
cd $RPM_BUILD_ROOT/install

%ifos linux
tar zxf %{SOURCE2}
tar zxf %{SOURCE4}
%else
cp %{SOURCE2} $RPM_BUILD_ROOT/install
gunzip -f postscripts.tar.gz
tar -xf postscripts.tar
rm postscripts.tar
%endif

rm LICENSE.html
mkdir -p postscripts/hostkeys
cd -
cp %{SOURCE1} $RPM_BUILD_ROOT/etc/apache2/conf.d/xcat.conf
cp %{SOURCE1} $RPM_BUILD_ROOT/etc/httpd/conf.d/xcat.conf

mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT
cp LICENSE.html $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT

%post
%ifnos linux
. /etc/profile
%else
. /etc/profile.d/xcat.sh
%endif
if [ "$1" = "1" ]; then #Only if installing for the first time..
$RPM_INSTALL_PREFIX0/sbin/xcatconfig -i
else
$RPM_INSTALL_PREFIX0/sbin/xcatconfig -u
fi
%clean

%files
%{prefix}
# one for sles, one for rhel. yes, it's ugly...
/etc/httpd/conf.d/xcat.conf
/etc/apache2/conf.d/xcat.conf
/install/postscripts
/install/prescripts
%defattr(-,root,root)
%postun
# removes MN file
  rm /etc/xCATMN

