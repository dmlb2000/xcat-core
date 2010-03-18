Summary: Install and configuration utilities for IBM HPC products in an xCAT cluster
Name: xCAT-IBMhpc
Version: %(cat Version)
Release: snap%(date +"%Y%m%d%H%M")
Epoch: 4
License: EPL
Group: Applications/System
Source: xCAT-IBMhpc-%(cat Version).tar.gz
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
#Requires: 
%endif

Requires: perl-xCAT >= %{epoch}:%(cat Version|cut -d. -f 1,2)
Requires: xCAT-client  >= %{epoch}:%(cat Version|cut -d. -f 1,2)

Provides: xCAT-IBMhpc = %{epoch}:%{version}

%description
xCAT-IBMhpc provides sample installation and configuration scripts for running the IBM HPC software stack in an xCAT cluser.  Support for the following IBM products is provided:  GPFS, LoadLeveler, Parallel Environment, ESSL and Parallel ESSL libraries, some compilers (vac, xlC, xlf).

%prep
%setup -q -n xCAT-IBMhpc
%build
%install
rm -rf $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/IBMhpc/gpfs

set +x
cp share/xcat/IBMhpc/gpfs/* $RPM_BUILD_ROOT/%{prefix}/share/xcat/IBMhpc/gpfs/
chmod 755 $RPM_BUILD_ROOT/%{prefix}/share/xcat/IBMhpc/gpfs/*

set -x

mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-IBMhpc
cp LICENSE.html $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-IBMhpc
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-IBMhpc/*
#echo $RPM_BUILD_ROOT %{prefix}

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
#%doc LICENSE.html
%{prefix}

%changelog

%post

%preun




