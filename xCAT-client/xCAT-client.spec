Summary: Core executables and data of the xCAT management project
Name: xCAT-client
Version: 2.1
Release: snap%(date +"%Y%m%d%H%M")
Epoch: 4
License: EPL
Group: Applications/System
Source: xCAT-client-2.1.tar.gz
Packager: IBM Corp.
Vendor: IBM Corp.
Distribution: %{?_distribution:%{_distribution}}%{!?_distribution:%{_vendor}}
Prefix: /opt/xcat
BuildRoot: /var/tmp/%{name}-%{version}-%{release}-root

# AIX will build with an arch of "ppc"
%ifos linux
BuildArch: noarch
%endif

Provides: xCAT-client = %{version}

%description
xCAT-client provides the fundamental xCAT commands (chtab, chnode, rpower, etc) helpful in administrating systems at scale, with particular attention paid to large HPC clusters.

%prep -n xCAT-client
%setup -q
%build
# This phase is done in (for RH): /usr/src/redhat/BUILD/xCAT-client-2.0
# All of the tarball source has been unpacked there and is in the same file structure
# as it is in svn.

# Convert pods to man pages, e.g.:  pod2man pods/man1/tabdump.1.pod share/man/man1/tabdump.1
# for i in pods/*/*.pod; do
#   man="share/man${i#pods}"         # the substitute form is not supported on aix:  ${i/pods/share\/man}
#   mkdir -p ${man%/*}
#   pod2man $i ${man%.pod}
# done

# Convert pods to man pages and html pages
./xpod2man

%install
# The install phase puts all of the files in the paths they should be in when the rpm is
# installed on a system.  The RPM_BUILD_ROOT is a simulated root file system and usually
# has a value like: /var/tmp/xCAT-client-2.0-snap200802270932-root
rm -rf $RPM_BUILD_ROOT

mkdir -p $RPM_BUILD_ROOT/%{prefix}/bin
mkdir -p $RPM_BUILD_ROOT/%{prefix}/sbin
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/scripts
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/man/man1
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/man/man3
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/man/man5
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/man/man8
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-client
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/man1
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/man3
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/man5
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/doc/man8

cp bin/* $RPM_BUILD_ROOT/%{prefix}/bin
chmod 755 $RPM_BUILD_ROOT/%{prefix}/bin/*
cp sbin/* $RPM_BUILD_ROOT/%{prefix}/sbin
chmod 755 $RPM_BUILD_ROOT/%{prefix}/sbin/*

# These were built dynamically in the build phase
cp share/man/man1/* $RPM_BUILD_ROOT/%{prefix}/share/man/man1
chmod 444 $RPM_BUILD_ROOT/%{prefix}/share/man/man1/*
cp share/man/man3/* $RPM_BUILD_ROOT/%{prefix}/share/man/man3
chmod 444 $RPM_BUILD_ROOT/%{prefix}/share/man/man3/*
cp share/man/man5/* $RPM_BUILD_ROOT/%{prefix}/share/man/man5
chmod 444 $RPM_BUILD_ROOT/%{prefix}/share/man/man5/*
cp share/man/man8/* $RPM_BUILD_ROOT/%{prefix}/share/man/man8
chmod 444 $RPM_BUILD_ROOT/%{prefix}/share/man/man8/*

# %ifos linux
# cp share/doc/xCAT2.0.odt $RPM_BUILD_ROOT/%{prefix}/share/doc
# cp share/doc/xCAT2.0.pdf $RPM_BUILD_ROOT/%{prefix}/share/doc
# %else
# cp share/doc/xCAT2onAIX.odt $RPM_BUILD_ROOT/%{prefix}/share/doc
# cp share/doc/xCAT2onAIX.pdf $RPM_BUILD_ROOT/%{prefix}/share/doc
# %endif
cp -r share/doc/* $RPM_BUILD_ROOT/%{prefix}/share/doc
chmod 755 $RPM_BUILD_ROOT/%{prefix}/share/doc/*
# These were built dynamically during the build phase
# cp share/doc/man1/* $RPM_BUILD_ROOT/%{prefix}/share/doc/man1
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/doc/man1/*
# cp share/doc/man3/* $RPM_BUILD_ROOT/%{prefix}/share/doc/man3
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/doc/man3/*
# cp share/doc/man5/* $RPM_BUILD_ROOT/%{prefix}/share/doc/man5
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/doc/man5/*
# cp share/doc/man8/* $RPM_BUILD_ROOT/%{prefix}/share/doc/man8
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/doc/man8/*

cp LICENSE.html $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-client
chmod 644 $RPM_BUILD_ROOT/%{prefix}/share/doc/packages/xCAT-client/*

#cp usr/share/xcat/scripts/setup-local-client.sh $RPM_BUILD_ROOT/usr/share/xcat/scripts/setup-local-client.sh
#chmod 755 $RPM_BUILD_ROOT/usr/share/xcat/scripts/setup-local-client.sh

# These links get made in the RPM_BUILD_ROOT/prefix area
ln -sf xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rpower
ln -sf xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rscan
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/sbin/makedhcp
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/sbin/makehosts
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/sbin/nodeset
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/sbin/setupiscsidev
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/sbin/makeconservercf
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rbeacon
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rvitals
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/nodestat
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rinv
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rspreset
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rsetboot
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rbootseq
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/reventlog
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/nodels
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/nodech
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/noderm
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rnetboot
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/getmacs
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/mkvm
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/rmvm
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/lsvm
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/chvm
ln -sf ../bin/xcatclient $RPM_BUILD_ROOT/%{prefix}/bin/tabgrep
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/lsslp
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/tabdump
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/packimage
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/makedns
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/gettab
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/nodeadd
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/makenetworks
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/copycds
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/regnotif
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/unregnotif
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/monstart
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/monstop
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/monls
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/monupdate
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/monaddnode
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/sbin/monrmnode
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/mkdsklsnode
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/rmdsklsnode
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/mknimimage
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/rmnimimage
ln -sf ../bin/xcatclientnnr $RPM_BUILD_ROOT/%{prefix}/bin/nimnodeset
ln -sf ../bin/xcatDBcmds $RPM_BUILD_ROOT/%{prefix}/bin/mkdef
ln -sf ../bin/xcatDBcmds $RPM_BUILD_ROOT/%{prefix}/bin/chdef
ln -sf ../bin/xcatDBcmds $RPM_BUILD_ROOT/%{prefix}/bin/lsdef
ln -sf ../bin/xcatDBcmds $RPM_BUILD_ROOT/%{prefix}/bin/rmdef
ln -sf ../bin/xcatDBcmds $RPM_BUILD_ROOT/%{prefix}/bin/xcat2nim
ln -sf ../bin/xdsh $RPM_BUILD_ROOT/%{prefix}/bin/xdcp

%clean
# This step does not happen until *after* the %files packaging below
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
#%doc LICENSE.html
# Just package everything that has been copied into RPM_BUILD_ROOT
%{prefix}

%changelog
* Wed May 2 2007 - Norm Nott <nott@us.ibm.com>
- Made changes to make this work on AIX

* Tue Feb 20 2007 Jarrod Johnson <jbjohnso@us.ibm.com>
- Start core rpm for 1.3 work

%post
%ifos linux
echo "XCATROOT=$RPM_INSTALL_PREFIX0
PATH=\$PATH:\$XCATROOT/bin:\$XCATROOT/sbin
MANPATH=\$MANPATH:\$XCATROOT/share/man
export XCATROOT PATH MANPATH
export PERL_BADLANG=0" >/etc/profile.d/xcat.sh

echo "setenv XCATROOT \"$RPM_INSTALL_PREFIX0\"
setenv PATH \${PATH}:\${XCATROOT}/bin:\${XCATROOT}/sbin
setenv MANPATH \${MANPATH}:\${XCATROOT}/share/man
setenv PERL_BADLANG 0" >/etc/profile.d/xcat.csh
chmod 755 /etc/profile.d/xcat.*

%else
echo "
# xCAT setup
XCATROOT=$RPM_INSTALL_PREFIX0
PATH=\$PATH:\$XCATROOT/bin:\$XCATROOT/sbin
MANPATH=\$MANPATH:\$XCATROOT/share/man
export XCATROOT PATH MANPATH" >>/etc/profile

%endif

%preun
%ifos linux
if [ $1 == 0 ]; then  #This means only on -e
rm /etc/profile.d/xcat.*
fi
%endif

