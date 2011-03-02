# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::debian;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use Storable qw(dclone);
use Sys::Syslog;
use File::Temp qw/tempdir/;
use xCAT::Table;
use xCAT::Utils;
use xCAT::SvrUtils;
use xCAT::MsgUtils;
use Data::Dumper;
use Getopt::Long;
Getopt::Long::Configure("bundling");
Getopt::Long::Configure("pass_through");
use File::Path;
use File::Copy;

use Socket;

#use strict;
my @cpiopid;

##############################################################################
#
# Author:
#
# Arif Ali (OCF plc) <mail@arif-ali.co.uk>
#
# Notes:
# 
# This will not work with Ubuntu Desktop Edition, as all the packages are in
# a compressed image, and not readily available for creating images. So will
# only support Server ISOs.
#
#
#
# ChangeLog:
#
# 13 Aug 2010 - Initial release 
#             - Implementation of only copycd
#             - Tested with 9.10 desktop and server ISOs
# 06 Oct 2010 - Added copycd support for Ubuntu 10.04 Server (LTS releases)
#             - Added support for mkinstall, install successfull for 10.04
#               -> used function from anaconda.pm
#               -> Need to cleanup so that it has no references to rhel
# 07 Oct 2010 - Added preprocess_request (direct copy from anaconda.pm)
#
##############################################################################

sub handled_commands
{
    return {
            copycd    => "debian",
            mknetboot => "nodetype:os=(ubuntu.*)|(debian.*)",
            mkinstall => "nodetype:os=(ubuntu.*)|(debian.*)",
            };
}

sub preprocess_request
{
    my $req      = shift;
    my $callback = shift;
    return [$req]; #calls are only made from pre-farmed out scenarios
    if ($req->{command}->[0] eq 'copycd')
    {    #don't farm out copycd
        return [$req];
    }

    my $stab = xCAT::Table->new('site');
    my $sent;
    ($sent) = $stab->getAttribs({key => 'sharedtftp'}, 'value');
    unless (    $sent
            and defined($sent->{value})
            and ($sent->{value} =~ /no/i or $sent->{value} =~ /0/))
    {

        #unless requesting no sharedtftp, don't make hierarchical call
        return [$req];
    }

    my %localnodehash;
    my %dispatchhash;
    my $nrtab = xCAT::Table->new('noderes');
    my $nrents = $nrtab->getNodesAttribs($req->{node},[qw(tftpserver servicenode)]);
    foreach my $node (@{$req->{node}})
    {
        my $nodeserver;
        my $tent = $nrents->{$node}->[0]; #$nrtab->getNodeAttribs($node, ['tftpserver']);
        if ($tent) { $nodeserver = $tent->{tftpserver} }
        unless ($tent and $tent->{tftpserver})
        {
            $tent = $nrents->{$node}->[0]; #$nrtab->getNodeAttribs($node, ['servicenode']);
            if ($tent) { $nodeserver = $tent->{servicenode} }
        }
        if ($nodeserver)
        {
            $dispatchhash{$nodeserver}->{$node} = 1;
        }
        else
        {
            $localnodehash{$node} = 1;
        }
    }
    my @requests;
    my $reqc = {%$req};
    $reqc->{node} = [keys %localnodehash];
    if (scalar(@{$reqc->{node}})) { push @requests, $reqc }

    foreach my $dtarg (keys %dispatchhash)
    {    #iterate dispatch targets
        my $reqcopy = {%$req};    #deep copy
        $reqcopy->{'_xcatdest'} = $dtarg;
        $reqcopy->{node} = [keys %{$dispatchhash{$dtarg}}];
        push @requests, $reqcopy;
    }
    return \@requests;
}

sub process_request
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $distname = undef;
    my $arch     = undef;
    my $path     = undef;
    if ($request->{command}->[0] eq 'copycd')
    {
        return copycd($request, $callback, $doreq);
    }
    elsif ($request->{command}->[0] eq 'mkinstall')
    {
        return mkinstall($request, $callback, $doreq);
    }
    elsif ($request->{command}->[0] eq 'mknetboot')
    {
        return mknetboot($request, $callback, $doreq);
    }
}

sub copycd
{
    xCAT::MsgUtils->message("S","Doing debian copycds");
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $distname = "";
    my $detdistname = "";
    my $installroot;
    my $arch;
    my $path;
    $installroot = "/install";
    my $sitetab = xCAT::Table->new('site');
    if ($sitetab)
    {
        (my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
        print Dumper($ref);
        if ($ref and $ref->{value})
        {
            $installroot = $ref->{value};
        }
    }

    @ARGV = @{$request->{arg}};
    GetOptions(
               'n=s' => \$distname,
               'a=s' => \$arch,
               'p=s' => \$path,
               );
    unless ($path)
    {

        #this plugin needs $path...
        return;
    }
    
    unless (-r $path . "/.disk/info")
    {
        xCAT::MsgUtils->message("S","The CD doesn't look like a Debian CD, exiting...");
        return;
    }
    my $dinfo;
    open($dinfo, $path . "/.disk/info");
    my $darch;
    my $line = <$dinfo>;
    chomp($line);
    my @line2 = split(/ /,$line);
    $darch = $line2[6];
    close($dinfo);


    # Ubuntu 10.04 doesn't put into the correct place
    # This in essence will pick up the LTS releases
    $darch = $line2[7] if ($darch eq "Release");

    # For debian lenny to work
    $darch = $line2[8] if ($darch eq "Official");

    # Check to see if $darch is defined
    unless ($darch)
    {
        return;
    }

    # The product should be the first word
    my $prod = $line2[0];

    # The version should be the second word
    my $ver = $line2[1];

    # For debian lenny to work
    $ver = $line2[2] if ($ver eq "GNU/Linux");

    if ($prod eq "Ubuntu" or $prod eq "Ubuntu-Server" )
    {
        $distname="ubuntu".$ver;
	$detdistname="ubuntu".$ver;
    }
    elsif ($prod eq "Debian")
    {
        $distname="debian".$ver;
	$detdistname="debian".$ver;
    }
    else {
        return;
    }

    # So that I can use amd64 below 
    my $debarch=$darch;

    if ($darch and $darch =~ /i.86/)
    {
        $darch = "x86";
    }
    elsif ($darch and $darch =~ /ppc/)
    {
        $darch = "ppc64";
    }
    elsif ($darch and $darch =~ /amd64/)
    {
        $darch = "x86_64";
    }

    if ($darch)
    {
        unless ($arch)
        {
            $arch = $darch;
        }
        if ($arch and $arch ne $darch)
        {
            $callback->(
                     {
                      error =>
                        ["Requested Debian architecture $arch, but media is $darch"],
                        errorcode => [1]
                     }
                     );
            return;
        }
    }
    %{$request} = ();    #clear request we've got it.

    $callback->(
         {data => "Copying media to $installroot/$distname/$arch"});
    my $omask = umask 0022;
    mkpath("$installroot/$distname/$arch");
    umask $omask;
    my $rc;
    $SIG{INT} =  $SIG{TERM} = sub { 
       foreach(@cpiopid){
          kill 2, $_; 
       }
       if ($::CDMOUNTPATH) {
            chdir("/");
            system("umount $::CDMOUNTPATH");
       }
    };
    my $kid;
    chdir $path;
    my $numFiles = `find . -print | wc -l`;
    my $child = open($kid,"|-");
    unless (defined $child) {
      $callback->({error=>"Media copy operation fork failure"});
      return;
    }
    if ($child) {
       push @cpiopid,$child;
       my @finddata = `find .`;
       for (@finddata) {
          print $kid $_;
       }
       close($kid);
       $rc = $?;
    } else {
        my $c = "nice -n 20 cpio -vdump $installroot/$distname/$arch";
        my $k2 = open(PIPE, "$c 2>&1 |") ||
           $callback->({error => "Media copy operation fork failure"});
	push @cpiopid, $k2;
        my $copied = 0;
        my ($percent, $fout);
        while(<PIPE>){
          next if /^cpio:/;
          $percent = $copied / $numFiles;
          $fout = sprintf "%0.2f%%", $percent * 100;
          $callback->({sinfo => "$fout"});
          ++$copied;
        }
        exit;
    }
    #  system(
    #    "cd $path; find . | nice -n 20 cpio -dump $installroot/$distname/$arch/"
    #    );
    chmod 0755, "$installroot/$distname/$arch";

    # Need to do this otherwise there will be warning about corrupt Packages file
    # when installing a system

    # Grabs the distribution codename
    my @line=split(" ",`ls -lh $installroot/$distname/$arch/dists/ | grep dr`);
    my $dist = $line[@line-1];

    # touches the Packages file so that deb packaging works
    system("touch $installroot/$distname/$arch/dists/$dist/restricted/binary-$debarch/Packages");

    # removes the links unstable and testing, otherwise the repository does not work for debian
    system("rm -f $installroot/$distname/$arch/dists/unstable");
    system("rm -f $installroot/$distname/$arch/dists/testing");

    if ($rc != 0)
    {
        $callback->({error => "Media copy operation failed, status $rc"});
    }
    else
    {
        $callback->({data => "Media copy operation successful"});
	my @ret=xCAT::SvrUtils->update_tables_with_templates($distname, $arch);
        if ($ret[0] != 0) {
	    $callback->({data => "Error when updating the osimage tables: " . $ret[1]});
	}

    }
}

sub mkinstall
{
    xCAT::MsgUtils->message("S","Doing debian mkinstall");
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my @nodes    = @{$request->{node}};
    my $sitetab  = xCAT::Table->new('site');
    my $linuximagetab;
    my $osimagetab;
    my %img_hash=();

    my $installroot;
    $installroot = "/install";
    if ($sitetab)
    {
        (my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
        if ($ref and $ref->{value})
        {
            $installroot = $ref->{value};
        }
    }

    my $node;
    my $ostab = xCAT::Table->new('nodetype');
    my %doneimgs;
    my $restab = xCAT::Table->new('noderes');
    my $bptab  = xCAT::Table->new('bootparams',-create=>1);
    my $hmtab  = xCAT::Table->new('nodehm');
    my %osents = %{$ostab->getNodesAttribs(\@nodes, ['profile', 'os', 'arch', 'provmethod'])};
    my %rents =
              %{$restab->getNodesAttribs(\@nodes,
                                     ['nfsserver', 'primarynic', 'installnic'])};
    my %hents = 
              %{$hmtab->getNodesAttribs(\@nodes,
                                     ['serialport', 'serialspeed', 'serialflow'])};
    #my $addkcmdhash =
    #    $bptab->getNodesAttribs(\@nodes, ['addkcmdline']);
    require xCAT::Template;
    foreach $node (@nodes)
    {
        my $os;
        my $arch;
	my $darch;
        my $profile;
        my $tmplfile;
        my $pkgdir;
	my $imagename;
	my $platform;

        my $osinst;
        my $ent = $osents{$node}->[0]; #$ostab->getNodeAttribs($node, ['profile', 'os', 'arch']);
        if ($ent and $ent->{provmethod} and ($ent->{provmethod} ne 'install') and ($ent->{provmethod} ne 'netboot') and ($ent->{provmethod} ne 'statelite')) {
	    $imagename=$ent->{provmethod};
	    #print "imagename=$imagename\n";
	    if (!exists($img_hash{$imagename})) {
		if (!$osimagetab) {
		    $osimagetab=xCAT::Table->new('osimage', -create=>1);
		}
		(my $ref) = $osimagetab->getAttribs({imagename => $imagename}, 'osvers', 'osarch', 'profile', 'provmethod');
		if ($ref) {
		    $img_hash{$imagename}->{osver}=$ref->{'osvers'};
		    $img_hash{$imagename}->{osarch}=$ref->{'osarch'};
		    $img_hash{$imagename}->{profile}=$ref->{'profile'};
		    $img_hash{$imagename}->{provmethod}=$ref->{'provmethod'};
		    if (!$linuximagetab) {
			$linuximagetab=xCAT::Table->new('linuximage', -create=>1);
		    }
		    (my $ref1) = $linuximagetab->getAttribs({imagename => $imagename}, 'template', 'pkgdir');
		    if ($ref1) {
			if ($ref1->{'template'}) {
			    $img_hash{$imagename}->{template}=$ref1->{'template'};
			}
			if ($ref1->{'pkgdir'}) {
			    $img_hash{$imagename}->{pkgdir}=$ref1->{'pkgdir'};
			}
		    }
		    # if the install template wasn't found, then lets look for it in the default locations.
		    unless($img_hash{$imagename}->{template}){
	                my $pltfrm=xCAT_plugin::debian::getplatform($ref->{'osvers'});
	    		my $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$installroot/custom/install/$pltfrm", 
		 			$ref->{'profile'}, $ref->{'osvers'}, $ref->{'osarch'}, $ref->{'osvers'});
	    		if (! $tmplfile) { $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$::XCATROOT/share/xcat/install/$pltfrm", 
		 			$ref->{'profile'}, $ref->{'osvers'}, $ref->{'osarch'}, $ref->{'osvers'});
					 }
			# if we managed to find it, put it in the hash:
			if($tmplfile){
			    $img_hash{$imagename}->{template}=$tmplfile;
			}
		    }
		} else {
		    $callback->(
			{error     => ["The os image $imagename does not exists on the osimage table for $node"],
			 errorcode => [1]});
		    next;
		}
	    }
	    my $ph=$img_hash{$imagename};
	    $os = $ph->{osver};
	    $arch  = $ph->{osarch};
	    $profile = $ph->{profile};
	    $platform=xCAT_plugin::debian::getplatform($os);
	
	    $tmplfile=$ph->{template};
            $pkgdir=$ph->{pkgdir};
	    if (!$pkgdir) {
		$pkgdir="$installroot/$os/$arch";
	    }
	}
	else {
	    $os = $ent->{os};
	    $arch    = $ent->{arch};
	    $profile = $ent->{profile};
	    $platform=xCAT_plugin::debian::getplatform($os);
	    my $genos = $os;
	    $genos =~ s/\..*//;
	    
	    $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$installroot/custom/install/$platform", $profile, $os, $arch, $genos);
	    if (! $tmplfile) { $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$::XCATROOT/share/xcat/install/$platform", $profile, $os, $arch, $genos); }

	    $pkgdir="$installroot/$os/$arch";
	}

        if ($arch == "x86_64") {
            $darch = "amd64";
        } elsif ($arch == "x86") {
            $darch = "i386";
        } else {
            xCAT::MsgUtils->message("S","debian.pm: Unknown arch ($arch)");
            $darch = $arch;
        }

        my @missingparms;
        unless ($os) {
	    if ($imagename) { push @missingparms,"osimage.osvers";  }
            else { push @missingparms,"nodetype.os";}
        }
        unless ($arch) {
	    if ($imagename) { push @missingparms,"osimage.osarch";  }
            else { push @missingparms,"nodetype.arch";}
        }
        unless ($profile) {
	    if ($imagename) { push @missingparms,"osimage.profile";  }
            else { push @missingparms,"nodetype.profile";}
        }
        unless ($os and $arch and $profile)
        {
            $callback->(
                        {
                         error => ["Missing ".join(',',@missingparms)." for $node"],
                         errorcode => [1]
                        }
                        );
            next;    #No profile
        }

        unless ( -r "$tmplfile")  
        {
            $callback->(
                        {
                         error => [
                                   "No $platform preseed template exists for "
                                     . $profile
                         ],
                         errorcode => [1]
                        }
                        );
            next;
        }

        #Call the Template class to do substitution to produce a preseed file in the autoinst dir
        my $tmperr;
        my $preerr;
        my $posterr;
	if ($imagename) {
	    $tmperr="Unable to find template file: $tmplfile";
	} else {
          $tmperr="Unable to find template in $installroot/custom/install/$platform or $::XCATROOT/share/xcat/install/$platform (for $profile/$os/$arch combination)";
	}
        if (-r "$tmplfile")
        {
            $tmperr =
              xCAT::Template->subvars(
                    $tmplfile,
                    "$installroot/autoinst/" . $node,
                    $node
                    );
        }

	my $prescript = "$::XCATROOT/share/xcat/install/scripts/pre.$platform";
	my $postscript = "$::XCATROOT/share/xcat/install/scripts/post.$platform";

	if (-r "$prescript")
	{
            $preerr =
              xCAT::Template->subvars(
                    $prescript,
                    "$installroot/autoinst/" . $node . ".pre",
                    $node
                    );
	
	}
	if (-r "$postscript")
	{
            $posterr =
              xCAT::Template->subvars(
                    $postscript,
                    "$installroot/autoinst/" . $node . ".post",
                    $node
                    );
        }

        my $errtmp;

        if ($errtmp=$tmperr or $errtmp=$preerr or $errtmp=$posterr)
        {
            $callback->(
                    {
                     node =>
                       [{name => [$node], error => [$errtmp], errorcode => [1]}]
                    }
                    );
            next;
        }
        my $tftpdir = "/tftpboot";

        # create the node-specific post scripts
        #mkpath "$installroot/postscripts/";
        #xCAT::Postage->writescript($node,"$installroot/postscripts/".$node, "install", $callback);
        my $kernpath;
        my $initrdpath;
        my $maxmem;

        if (
	       (
                 $arch =~ /x86/ and
		 (
                    (
                         -r "$pkgdir/install/netboot/ubuntu-installer/$darch/linux"
                         and $kernpath = "$pkgdir/install/netboot/ubuntu-installer/$darch/linux"
                         and -r "$pkgdir/install/netboot/ubuntu-installer/$darch/initrd.gz"
                         and $initrdpath = "$pkgdir/install/netboot/ubuntu-installer/$darch/initrd.gz"
                    ) or 
		    (
                         -r "$::XCATROOT/share/xcat/install/$platform/".$os."Images/linux"
                         and $kernpath = "$::XCATROOT/share/xcat/install/$platform/".$os."Images/linux"
                         and -r "$::XCATROOT/share/xcat/install/$platform/".$os."Images/initrd.gz"
                         and $initrdpath = "$::XCATROOT/share/xcat/install/$platform/".$os."Images/initrd.gz"

		    )
		 )

		)
          )
        {

            #TODO: driver slipstream, targetted for network.
            unless ($doneimgs{"$os|$arch"})
            {
                mkpath("/tftpboot/xcat/$os/$arch");
                copy($kernpath,"$tftpdir/xcat/$os/$arch/vmlinuz");
                copy($initrdpath,"$tftpdir/xcat/$os/$arch/initrd.img");
                $doneimgs{"$os|$arch"} = 1;
            }

            #We have a shot...
            my $ent    = $rents{$node}->[0];
#              $restab->getNodeAttribs($node,
#                                     ['nfsserver', 'primarynic', 'installnic']);
            my $sent = $hents{$node}->[0];
#              $hmtab->getNodeAttribs(
#                                     $node,
#                                     [
#                                      'serialport', 'serialspeed', 'serialflow'
#                                     ]
#                                     );
            unless ($ent and $ent->{nfsserver})
            {
                $callback->(
                        {
                         error => ["No noderes.nfsserver defined for " . $node],
                         errorcode => [1]
                        }
                        );
                next;
            }
	    #if ($platform eq "ubuntu")
	    #{
            #    my $kcmdline =
            #        "nofb utf8 auto url=http://"
            #      . $ent->{nfsserver}
            #      . "$installroot/autoinst/"
            #      . $node;
            #} else 
	    #{
                my $kcmdline =
                    "nofb utf8 auto url=http://"
                  . $ent->{nfsserver}
                  . "$installroot/autoinst/"
                  . $node;
	    #}
	       
            if ($maxmem) {
                $kcmdline.=" mem=$maxmem";
            }
            my $ksdev = "";
            if ($ent->{installnic})
            {
                if ($ent->{installnic} eq "mac")
                {
                    my $mactab = xCAT::Table->new("mac");
                    my $macref = $mactab->getNodeAttribs($node, ['mac']);
                    $ksdev = $macref->{mac};
                }
                else
                {
                    $ksdev = $ent->{installnic};
                }
            }
            elsif ($ent->{primarynic})
            {
                if ($ent->{primarynic} eq "mac")
                {
                    my $mactab = xCAT::Table->new("mac");
                    my $macref = $mactab->getNodeAttribs($node, ['mac']);
                    $ksdev = $macref->{mac};
                }
                else
                {
                    $ksdev = $ent->{primarynic};
                }
            }
            else
            {
                $ksdev = "eth0";
            }
            if ($ksdev eq "")
            {
                $callback->(
                        {
                         error => ["No MAC address defined for " . $node],
                         errorcode => [1]
                        }
                        );
             }
             $kcmdline .= " netcfg/choose_interface=" . $ksdev;

            #TODO: dd=<url> for driver disks
            if (defined($sent->{serialport}))
            {
                unless ($sent->{serialspeed})
                {
                    $callback->(
                        {
                         error => [
                             "serialport defined, but no serialspeed for $node in nodehm table"
                         ],
                         errorcode => [1]
                        }
                        );
                    next;
                }
                $kcmdline .=
                    " console=tty0 console=ttyS"
                  . $sent->{serialport} . ","
                  . $sent->{serialspeed};
                if ($sent->{serialflow} =~ /(hard|cts|ctsrts)/)
                {
                    $kcmdline .= "n8r";
                }
            }
            $kcmdline .= " noipv6";
            # add the addkcmdline attribute  to the end
            # of the command, if it exists
            #my $addkcmd   = $addkcmdhash->{$node}->[0];
            # add the extra addkcmd command info, if in the table
            #if ($addkcmd->{'addkcmdline'}) {
            #        $kcmdline .= " ";
            #        $kcmdline .= $addkcmd->{'addkcmdline'};
            #}

            # need to add these in, otherwise aptitude will ask questions
	    $kcmdline .= " locale=en_US console-setup/layoutcode=us";
	    #$kcmdline .= " netcfg/wireless_wep= netcfg/get_hostname= netcfg/get_domain=";
	    
            # default answers as much as possible, we don't want any interactiveness :)
	    $kcmdline .= " priority=critical";

            # Automatically detect all HDD
	    #$kcmdline .= " all-generic-ide irqpoll";

	    # by default do text based install
	    #$kcmdline .= " DEBIAN_FRONTEND=text";

	    # Maybe useful for debugging purposes
	    #
	    #$kcmdline .= " BOOT_DEBUG=3";
	    #$kcmdline .= " DEBCONF_DEBUG=5";

	    # I don't need the timeout for ubuntu, but for debian there is a problem with getting dhcp in a timely manner
	    $kcmdline .= " netcfg/dhcp_timeout=120";

            $bptab->setNodeAttribs(
                                   $node,
                                   {
                                    kernel   => "xcat/$os/$arch/vmlinuz",
                                    initrd   => "xcat/$os/$arch/initrd.img",
                                    kcmdline => $kcmdline
                                   }
                                   );
        }
        else
        {
            $callback->(
                    {
                     error => ["Install image not found in $installroot/$os/$arch"],
                     errorcode => [1]
                    }
                    );
        }
    }
    #my $rc = xCAT::Utils->create_postscripts_tar();
    #if ($rc != 0)
    #{
    #    xCAT::MsgUtils->message("S", "Error creating postscripts tar file.");
    #}
}

sub mknetboot
{
    my $xenstyle=0;
    my $req      = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $statelite = 0;
    if($req->{command}->[0] =~ 'mkstatelite'){
        $statelite = "true";
    }
    my $tftpdir  = "/tftpboot";
    my $nodes    = @{$req->{node}};
    my @args     = @{$req->{arg}};
    my @nodes    = @{$req->{node}};
    my $ostab    = xCAT::Table->new('nodetype');
    my $sitetab  = xCAT::Table->new('site');
    my $linuximagetab;
    my $osimagetab;
    my %img_hash=();
    my $installroot;
    $installroot = "/install";
    my $xcatdport = "3001";

    if ($sitetab)
    {
        (my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
        if ($ref and $ref->{value})
        {
            $installroot = $ref->{value};
        }
        ($ref) = $sitetab->getAttribs({key => 'xcatdport'}, 'value');
        if ($ref and $ref->{value})
        {
            $xcatdport = $ref->{value};
        }
    }
    my %donetftp=();
    my %oents = %{$ostab->getNodesAttribs(\@nodes,[qw(os arch profile provmethod)])};
    my $restab = xCAT::Table->new('noderes');
    my $bptab  = xCAT::Table->new('bootparams',-create=>1);
    my $hmtab  = xCAT::Table->new('nodehm');
    my $reshash    = $restab->getNodesAttribs(\@nodes, ['primarynic','tftpserver','xcatmaster','nfsserver','nfsdir']);
    my $hmhash =
          $hmtab->getNodesAttribs(\@nodes,
                                 ['serialport', 'serialspeed', 'serialflow']);
    my $statetab;
    my $stateHash;
    if($statelite){
        $statetab = xCAT::Table->new('statelite',-create=>1);
        $stateHash = $statetab->getNodesAttribs(\@nodes, ['statemnt']);
    }
    #my $addkcmdhash =
    #    $bptab->getNodesAttribs(\@nodes, ['addkcmdline']);
    foreach my $node (@nodes)
    {
        my $osver;
        my $arch;
        my $profile;
	my $platform;
        my $rootimgdir;

        my $ent = $oents{$node}->[0]; #ostab->getNodeAttribs($node, ['os', 'arch', 'profile']);
        if ($ent and $ent->{provmethod} and ($ent->{provmethod} ne 'install') and ($ent->{provmethod} ne 'netboot') and ($ent->{provmethod} ne 'statelite')) {
	    my $imagename=$ent->{provmethod};
	    #print "imagename=$imagename\n";
	    if (!exists($img_hash{$imagename})) {
		if (!$osimagetab) {
		    $osimagetab=xCAT::Table->new('osimage', -create=>1);
		}
		(my $ref) = $osimagetab->getAttribs({imagename => $imagename}, 'osvers', 'osarch', 'profile', 'provmethod');
		if ($ref) {
		    $img_hash{$imagename}->{osver}=$ref->{'osvers'};
		    $img_hash{$imagename}->{osarch}=$ref->{'osarch'};
		    $img_hash{$imagename}->{profile}=$ref->{'profile'};
		    $img_hash{$imagename}->{provmethod}=$ref->{'provmethod'};
		    if (!$linuximagetab) {
			$linuximagetab=xCAT::Table->new('linuximage', -create=>1);
		    }
		    (my $ref1) = $linuximagetab->getAttribs({imagename => $imagename}, 'rootimgdir');
		    if (($ref1) && ($ref1->{'rootimgdir'})) {
			$img_hash{$imagename}->{rootimgdir}=$ref1->{'rootimgdir'};
		    }
		} else {
		    $callback->(
			{error     => ["The os image $imagename does not exists on the osimage table for $node"],
			 errorcode => [1]});
		    next;
		}
	    }
	    my $ph=$img_hash{$imagename};
	    $osver = $ph->{osver};
	    $arch  = $ph->{osarch};
	    $profile = $ph->{profile};
	
	    $rootimgdir=$ph->{rootimgdir};
	    if (!$rootimgdir) {
		$rootimgdir="$installroot/netboot/$osver/$arch/$profile";
	    }
	}
	else {
	    $osver = $ent->{os};
	    $arch    = $ent->{arch};
	    $profile = $ent->{profile};
	    $rootimgdir="$installroot/netboot/$osver/$arch/$profile";
	}

        #print"osvr=$osver, arch=$arch, profile=$profile, imgdir=$rootimgdir\n";
        unless ($osver and $arch and $profile)
        {
            $callback->(
                        {
                         error     => ["Insufficient nodetype entry or osimage entry for $node"],
                         errorcode => [1]
                        }
                        );
            next;
        }

        $platform=xCAT_plugin::debian::getplatform($osver);       
        my $suffix  = 'gz';
        if (-r "$rootimgdir/rootimg.sfs")
        {
            $suffix = 'sfs';
        }
        if (-r "$rootimgdir/rootimg.nfs")
        {
            $suffix = 'nfs';
        }
	#statelite images are not packed.  
        unless (
                (
                    -r "$rootimgdir/rootimg.gz"
                 or -r "$rootimgdir/rootimg.sfs"
                 or -r "$rootimgdir/rootimg.nfs"
		 or $statelite
                )
                and -r "$rootimgdir/kernel"
                and -r "$rootimgdir/initrd.gz"
          )
        {
		if($statelite){
			$callback->({error=> ["$node: statelite image $osver-$arch-statelite-$profile does not exist"], errorcode =>[1] });
		}else{
            		$callback->(
                	{
                 	error => [
                     	"No packed image for platform $osver, architecture $arch, and profile $profile, please run packimage (i.e.  packimage -o $osver -p $profile -a $arch"
                 	],
                 	errorcode => [1]
                	}
                	);
		}
            	next;
        }

        # create the node-specific post scripts
        #mkpath "/install/postscripts/";
        #xCAT::Postage->writescript($node,"/install/postscripts/".$node, "netboot", $callback);

        mkpath("/$tftpdir/xcat/netboot/$osver/$arch/$profile/");

        #TODO: only copy if newer...
        unless ($donetftp{$osver,$arch,$profile}) {
	if (-f "$rootimgdir/hypervisor") {
        	copy("$rootimgdir/hypervisor",
             	"/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
		$xenstyle=1;
	}
        copy("$rootimgdir/kernel",
             "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
        copy("$rootimgdir/initrd.gz",
             "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
            $donetftp{$osver,$arch,$profile} = 1;
        }
        unless (    -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/kernel"
                and -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/initrd.gz")
        {
            $callback->(
                {
                 error => [
                     "Copying to /$tftpdir/xcat/netboot/$osver/$arch/$profile failed"
                 ],
                 errorcode => [1]
                }
                );
            next;
        }
        my $ent    = $reshash->{$node}->[0];#$restab->getNodeAttribs($node, ['primarynic']);
        my $sent   = $hmhash->{$node}->[0];
#          $hmtab->getNodeAttribs($node,
#                                 ['serialport', 'serialspeed', 'serialflow']);

        # determine image server, if tftpserver use it, else use xcatmaster
        # last resort use self
        my $imgsrv;
        my $ient;
        my $xcatmaster;

        $ient = $reshash->{$node}->[0]; #$restab->getNodeAttribs($node, ['tftpserver']);

        if ($ient and $ient->{xcatmaster})
        {
            $xcatmaster = $ient->{xcatmaster};
        } else {
            $xcatmaster = '!myipfn!'; #allow service nodes to dynamically nominate themselves as a good contact point, this is of limited use in the event that xcat is not the dhcp/tftp server
        }

        if ($ient and $ient->{tftpserver})
        {
            $imgsrv = $ient->{tftpserver};
        }
        else
        {
            $ient = $reshash->{$node}->[0]; #$restab->getNodeAttribs($node, ['xcatmaster']);
            #if ($ient and $ient->{xcatmaster})
            #{
            #    $imgsrv = $ient->{xcatmaster};
            #}
            #else
            #{
                # master not correct for service node pools
                #$ient = $sitetab->getAttribs({key => master}, value);
                #if ($ient and $ient->{value})
                #{
                #    $imgsrv = $ient->{value};
                #}
                #else
                #{
            #   $imgsrv = '!myipfn!';
                #}
            #}
            $imgsrv = $xcatmaster;
        }
        unless ($imgsrv)
        {
            $callback->(
                {
                 error => [
                     "Unable to determine or reasonably guess the image server for $node"
                 ],
                 errorcode => [1]
                }
                );
            next;
        }
        my $kcmdline;
        if ($suffix eq "nfs")
        {
            $kcmdline =
              "imgurl=nfs://$imgsrv/install/netboot/$osver/$arch/$profile/rootimg ";
        }
	elsif($statelite){
		# get entry for nfs root if it exists:
		# have to get nfssvr and nfsdir from noderes table
		my $nfssrv = $imgsrv;
		my $nfsdir = $rootimgdir;
		if($ient->{nfsserver} ){
			$nfssrv = $ient->{nfsserver};
		}
		if($ient->{nfsdir} ne ''){	
			$nfsdir = $ient->{nfsdir} . "/netboot/$osver/$arch/$profile";
                        #this code sez, "if nfsdir starts with //, then
                        #use a absolute path, i.e. do not append xCATisms"
                        #this is required for some statelite envs.
                        #still open for debate.

			if($ient->{nfsdir} =~ m!^//!) {
				$nfsdir = $ient->{nfsdir};
				$nfsdir =~ s!^/!!;
			}
		}

		$kcmdline = 
		"NFSROOT=$nfssrv:$nfsdir STATEMNT=";	

        # add support for subVars in the value of "statemnt"
        my $statemnt = "";
		if (exists($stateHash->{$node})) {
            $statemnt = $stateHash->{$node}->[0]->{statemnt};
            if (grep /\$/, $statemnt) {
                my ($server, $dir) = split(/:/, $statemnt);
                
                #if server is blank, then its the directory
                unless($dir) {
                    $dir = $server;
                    $server = '';
                }
                if(grep /\$|#CMD/, $dir) {
                    $dir = subVars($dir, $node, 'dir', $callback);
                    $dir = ~ s/\/\//\//g;
                }
                if($server) { 
                    $server = subVars($server, $node, 'server', $callback);
                }
                $statemnt = $server . ":" . $dir;
            }
		}
		$kcmdline .= $statemnt ." ";
		$kcmdline .=
			"XCAT=$xcatmaster:$xcatdport ";
        # BEGIN service node
        my $isSV = xCAT::Utils->isServiceNode();
        my $res = xCAT::Utils->runcmd("hostname", 0);
        my $sip = inet_ntoa(inet_aton($res));  # this is the IP of service node
        if($isSV and (($xcatmaster eq $sip) or ($xcatmaster eq $res))) {
            # if the NFS directory in litetree is on the service node,
            # and it is not exported, then it will be mounted automatically
            setupNFSTree($node, $sip, $callback);
            # then, export the statemnt directory if it is on the service node
            if($statemnt) {
                setupStatemnt($sip, $statemnt, $callback);
            }
        }
        # END service node
	}
        else
        {
            $kcmdline =
              "imgurl=http://$imgsrv/install/netboot/$osver/$arch/$profile/rootimg.$suffix ";
        }
        if (defined $sent->{serialport})
        {

            #my $sent = $hmtab->getNodeAttribs($node,['serialspeed','serialflow']);
            unless ($sent->{serialspeed})
            {
                $callback->(
                    {
                     error => [
                         "serialport defined, but no serialspeed for $node in nodehm table"
                     ],
                     errorcode => [1]
                    }
                    );
                next;
            }
            $kcmdline .=
              "console=tty0 console=ttyS" . $sent->{serialport} . "," . $sent->{serialspeed};
            if ($sent->{serialflow} =~ /(hard|tcs|ctsrts)/)
            {
                $kcmdline .= "n8r";
            }
        }
        # add the addkcmdline attribute  to the end
        # of the command, if it exists
        #my $addkcmd   = $addkcmdhash->{$node}->[0];
        # add the extra addkcmd command info, if in the table
        #if ($addkcmd->{'addkcmdline'}) {
        #        $kcmdline .= " ";
        #        $kcmdline .= $addkcmd->{'addkcmdline'};
           
        #}
        
	my $kernstr="xcat/netboot/$osver/$arch/$profile/kernel";
	if ($xenstyle) {
	   $kernstr.= "!xcat/netboot/$osver/$arch/$profile/hypervisor";
	}
        $bptab->setNodeAttribs(
                      $node,
                      {
                       kernel => "$kernstr",
                       initrd => "xcat/netboot/$osver/$arch/$profile/initrd.gz",
                       kcmdline => $kcmdline
                      }
                      );
    }

    #my $rc = xCAT::Utils->create_postscripts_tar();
    #if ( $rc != 0 ) {
    #	xCAT::MsgUtils->message( "S", "Error creating postscripts tar file." );
    #}
}

sub getplatform {
    my $os=shift;
    my $platform;
    if ($os =~ /debian.*/) 
    {
	$platform = "debian";
    }
    elsif ($os =~ /ubuntu.*/)
    {
	$platform = "ubuntu";
    }
    return $platform;
}

# sub subVars
# copied from litetreee.pm
# TODO: need to move the function to xCAT::Utils? 

# some directories will have xCAT database values, like:
# $nodetype.os.  If that is the case we need to open up
# the database and look at them.  We need to make sure
# we do this sparingly...  We don't like tons of hits
# to the database.

sub subVars()
{
    my $dir = shift;
    my $node = shift;
    my $type = shift;
    my $callback = shift;

    # parse all the dollar signs...
    # if its a directory then it has a / in it, so you have to parse it.
    # if its a server, it won't have one so don't worry about it.
    my @arr = split("/", $dir);
    my $fdir = "";
    foreach my $p (@arr){
        # have to make this geric so $ can be in the midle of the name: asdf$foobar.sitadsf
        if($p =~ /\$/){
            my $pre;
            my $suf;
            my @fParts;
            if($p =~ /([^\$]*)([^# ]*)(.*)/){
                $pre= $1;
                $p = $2;
                $suf = $3;
            }
            # have to sub here:
            # get rid of the $ sign.
            foreach my $part (split('\$',$p)){
                if($part eq ''){ next; }
                #$callback->({error=>["part is $part"],errorcode=>[1]});
                # check if p is just the node name:
                if($part eq 'node'){
                    # it is so, just return the node.
                    #$fdir .= "/$pre$node$suf";
                    push @fParts, $node;
                }else{
                    # ask the xCAT DB what the attribute is.
                    my ($table, $col) = split('\.', $part);
                    unless($col){ $col = 'UNDEFINED' };
                    my $tab = xCAT::Table->new($table);
                    unless($tab){
                        $callback->({error=>["$table does not exist"],errorcode=>[1]});
                        return;
                    }
                    my $ent;
                    my $val;
                    if($table eq 'site'){
                        $val = $tab->getAttribs( { key => "$col" }, 'value' );
                        $val = $val->{'value'};
                    }else{
                        $ent = $tab->getNodeAttribs($node,[$col]);
                        $val = $ent->{$col};
                    }
                    unless($val){
                        # couldn't find the value!!
                        $val = "UNDEFINED"
                    }
                    push @fParts, $val;
                }
            }
            my $val = join('.', @fParts);
            if($type eq 'dir'){
                    $fdir .= "/$pre$val$suf";
            }else{
                    $fdir .= $pre . $val . $suf;
            }
        }else{
            # no substitution here
            $fdir .= "/$p";
        }
    }
    # now that we've processed variables, process commands
    # this isn't quite rock solid.  You can't name directories with #'s in them.
    if($fdir =~ /#CMD=/){
        my $dir;
        foreach my $p (split(/#/,$fdir)){
            if($p =~ /CMD=/){
                $p =~ s/CMD=//;
                my $cmd = $p;
                #$callback->({info=>[$p]});
                $p = `$p 2>&1`;
                chomp($p);
                #$callback->({info=>[$p]});
                unless($p){
                    $p = "#CMD=$p did not return output#";
                }
            }
            $dir .= $p;
        }
        $fdir = $dir;
    }

    return $fdir;
}

sub setupNFSTree {
    my $node = shift;
    my $sip = shift;
    my $callback = shift;

    my $cmd = "litetree $node";
    my @uris = xCAT::Utils->runcmd($cmd, 0);
    
    foreach my $uri (@uris) {
        # parse the result
        # the result looks like "nodename: nfsserver:directory";
        $uri =~ m/\Q$node\E:\s+(.+):(.+)$/;
        my $nfsserver = $1;
        my $nfsdirectory = $2;

        if($nfsserver eq $sip) { # on the service node
            unless (-d $nfsdirectory) {
                if (-e $nfsdirectory) {
                    unlink $nfsdirectory;
                }
                mkpath $nfsdirectory;
            }


            $cmd = "showmount -e $nfsserver";
            my @entries = xCAT::Utils->runcmd($cmd, 0);
            shift @entries;
            if(grep /\Q$nfsdirectory\E/, @entries) {
                $callback->({data=>["$nfsdirectory has been exported already!"]});
            } else {
                $cmd = "/usr/sbin/exportfs :$nfsdirectory";
                xCAT::Utils->runcmd($cmd, 0);
                # exportfs can export this directory immediately
                $callback->({data=>["now $nfsdirectory is exported!"]});
                $cmd = "cat /etc/exports";
                @entries = xCAT::Utils->runcmd($cmd, 0);
                unless (my $entry = grep /\Q$nfsdirectory\E/, @entries) {
                    # if no entry in /etc/exports, one entry with default options will be added
                    $cmd = qq{echo "$nfsdirectory *(rw,no_root_squash,sync,no_subtree_check)" >> /etc/exports};
                    xCAT::Utils->runcmd($cmd, 0);
                    $callback->({data=>["$nfsdirectory is added to /etc/exports with default option"]});
                }
            }
        }
    }
}

sub setupStatemnt {
    my $sip = shift;
    my $statemnt = shift;
    my $callback = shift;
    
    $statemnt =~ m/^(.+):(.+)$/;
    my $nfsserver = $1;
    my $nfsdirectory = $2;

    if($sip eq inet_ntoa(inet_aton($nfsserver))) {
        unless (-d $nfsdirectory) {
            if (-e $nfsdirectory) {
                unlink $nfsdirectory;
            }
            mkpath $nfsdirectory;
        }

        my $cmd = "showmount -e $nfsserver";
        my @entries = xCAT::Utils->runcmd($cmd, 0);
        shift @entries;
        if(grep /\Q$nfsdirectory\E/, @entries) {
            $callback->({data=>["$nfsdirectory has been exported already!"]});
        } else {
            $cmd = "/usr/sbin/exportfs :$nfsdirectory -o rw,no_root_squash,sync,no_subtree_check";
            xCAT::Utils->runcmd($cmd, 0);
            $callback->({data=>["now $nfsdirectory is exported!"]});
            # add the directory into /etc/exports if not exist
            $cmd = "cat /etc/exports";
            @entries = xCAT::Utils->runcmd($cmd, 0);
            if(my $entry = grep /\Q$nfsdirectory\E/, @entries) {
                unless ($entry =~ m/rw/) {
                    $callback->({data => ["The $nfsdirectory should be with rw option in /etc/exports"]});
                }
            } else {
                xCAT::Utils->runcmd(qq{echo "$nfsdirectory *(rw,no_root_squash,sync,no_subtree_check)" >> /etc/exports}, 0);
                $callback->({data => ["$nfsdirectory is added into /etc/exports with default options"]});
            }
        }
    }
}


1;
