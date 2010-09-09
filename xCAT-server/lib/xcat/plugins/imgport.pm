# Sumavi Inc (C) 2010

# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

#####################################################
# imgport will export and import xCAT stateless, statelite, and diskful templates.
# This will make it so that you can easily share your images with others.
# All your images are belong to us!
package xCAT_plugin::imgport;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use strict;
use warnings;
#use xCAT::Table;
#use xCAT::Schema;
#use xCAT::NodeRange qw/noderange abbreviate_noderange/;
#use xCAT::Utils;
use Data::Dumper;
use XML::Simple;
use POSIX qw/strftime/;
use Getopt::Long;
use File::Temp;
use File::Copy;
use File::Path qw/mkpath/;
use File::Basename;
use xCAT::NodeRange;
use Cwd;
my $requestcommand;
$::VERBOSE = 0;

1;

#some quick aliases to table/value
my %shortnames = (
                  groups => [qw(nodelist groups)],
                  tags   => [qw(nodelist groups)],
                  mgt    => [qw(nodehm mgt)],
                  #switch => [qw(switch switch)],
                  );

#####################################################
# Return list of commands handled by this plugin
#####################################################
sub handled_commands
{
	return {
		imgexport	=> "imgport",
		imgimport	=> "imgport",
	};
}

#####################################################
# Process the command
#####################################################
sub process_request
{
	#use Getopt::Long;
	Getopt::Long::Configure("bundling");
	#Getopt::Long::Configure("pass_through");
	Getopt::Long::Configure("no_pass_through");

	my $request  = shift;
	my $callback = shift;
	$requestcommand = shift;
	my $command  = $request->{command}->[0];
	my $args     = $request->{arg};

	if ($command eq "imgexport"){
		return xexport($request, $callback);
	}elsif ($command eq "imgimport"){
		return ximport($request, $callback);
	}else{
		print "Error: $command not found in export\n";
		$callback->({error=>["Error: $command not found in this module."],errorcode=>[1]});
		#return (1, "$command not found in sumavinode");
	}
}

# extract the bundle, then add it to the osimage table.  Basically the ying of the yang of the xexport
# function.
sub ximport {
	my $request = shift;
	my $callback = shift;
	my %rsp;	# response
	my $help;
        my $nodes;
        my $new_profile;

	my $xusage = sub {
	    my $ec = shift;
	    push@{ $rsp{data} }, "imgimport: Takes in an xCAT image bundle and defines it to xCAT so you can use it"; 
	    push@{ $rsp{data} }, "Usage: ";
	    push@{ $rsp{data} }, "\timgimport [-h|--help]";
	    push@{ $rsp{data} }, "\timgimport <bundle_file_name> [-p|--postscripts <nodelist>] [-f|--profile <new_profile>] [-v]";
	    if($ec){ $rsp{errorcode} = $ec; }
	    $callback->(\%rsp);
	};
	unless(defined($request->{arg})){ $xusage->(1); return; }
	@ARGV = @{ $request->{arg}};
	if($#ARGV eq -1){
		$xusage->(1);
		return;
	}

	GetOptions(
		'h|?|help' => \$help,
		'v|verbose' => \$::VERBOSE,
	        'p|postscripts=s' => \$nodes,
	        'f|profile=s' => \$new_profile,
	);

	if($help){
		$xusage->(0);
		return;
	}

	# first extract the bundle	
	extract_bundle($request, $callback,$nodes,$new_profile);
	
}


# function to export your image.  The image should already be in production, work well, and have 
# no bugs.  Lots of places will have problems because the image may not be in osimage table
# or they may have hardcoded things, or have post install scripts.
sub xexport { 
	my $request = shift;
	my $callback = shift;
	my %rsp;	# response
	my $help;
	my @extra;
        my $node;

	my $xusage = sub {
		my $ec = shift;
		push@{ $rsp{data} }, "imgexport: Creates a tarball (bundle) of an existing xCAT image";
		push@{ $rsp{data} }, "Usage: ";
		push@{ $rsp{data} }, "\timgexport [-h|--help]";
		push@{ $rsp{data} }, "\timgexport <image_name> [directory] [[-e|--extra <file:dir> ] ... ] [-p|--postscripts <node_name>] [-v]";
		if($ec){ $rsp{errorcode} = $ec; }
		$callback->(\%rsp);
	};
	unless(defined($request->{arg})){ $xusage->(1); return; }
	@ARGV = @{ $request->{arg}};
	if($#ARGV eq -1){
		$xusage->(1);
		return;
	}

	GetOptions(
		'h|?|help' => \$help,
	        'p|postscripts=s' => \$node,
		'e|extra=s' => \@extra,
		'v|verbose' => \$::VERBOSE
	);

	if($help){
		$xusage->(0);
		return;
	}
	
	# ok, we're done with all that.  Now lets actually start doing some work.
	my $img_name = shift @ARGV;	
	my $dest = shift @ARGV;
	my $cwd = $request->{cwd}; #getcwd;
	$cwd = $cwd->[0];

	$callback->( {data => ["Exporting $img_name to $cwd..."]});
	# check if all files are in place
	my $attrs = get_image_info($img_name, $callback, $node, @extra);
	#print Dumper($attrs);

	unless($attrs){
	    return 1;
	}	

	# make manifest and tar it up.
	make_bundle($img_name, $dest, $attrs, $callback,$cwd);
	
}





# verify the image and return the values
sub get_image_info {
	my $imagename = shift;
	my $callback = shift;
	my $node = shift;
	my @extra = @_;
	my $errors = 0;
	
	my $ostab = new xCAT::Table('osimage', -create=>1);
	unless($ostab){
		$callback->(
			{error => ["Unable to open table 'osimage'."],errorcode=>1}
		);
		return 0;
	}
	
	(my $attrs) = $ostab->getAttribs({imagename => $imagename}, 'profile', 'imagetype', 'provmethod', 'osname', 'osvers', 'osdistro', 'osarch', 'synclists');
	if (!$attrs) {
		$callback->({error=>["Cannot find image \'$imagename\' from the osimage table."],errorcode=>[1]});
		return 0;
	}

	unless($attrs->{provmethod}){
		$callback->({error=>["The 'provmethod' field is not set for \'$imagename\' in the osimage table."],errorcode=>[1]});
		$errors++;
	}

	unless($attrs->{profile}){
		$callback->({error=>["The 'profile' field is not set for \'$imagename\' in the osimage table."],errorcode=>[1]});
		$errors++;
	}

	unless($attrs->{osvers}){
		$callback->({error=>["The 'osvers' field is not set for \'$imagename\' in the osimage table."],errorcode=>[1]});
		$errors++;
	}

	unless($attrs->{osarch}){
		$callback->({error=>["The 'osarch' field is not set for \'$imagename\' in the osimage table."],errorcode=>[1]});
		$errors++;
	}

	unless($attrs->{provmethod} =~ /install|netboot|statelite/){
		$callback->({error=>["Exporting images with 'provemethod' " . $attrs->{provmethod} . " is not supported. Hint: install, netboot, or statelite"],errorcode=>[1]});
		$errors++;
	}

	$attrs->{imagename} = $imagename;

	if($errors){
		return 0;
	}


	my $linuximagetab = new xCAT::Table('linuximage', -create=>1);
	unless($linuximagetab){
		$callback->(
			{error => ["Unable to open table 'linuximage'"],errorcode=>1}
		);
		return 0;
	}
	
        #from linuximage table
	(my $attrs1) = $linuximagetab->getAttribs({imagename => $imagename}, 'template', 'pkglist', 'pkgdir', 'otherpkglist', 'otherpkgdir', 'exlist', 'postinstall', 'rootimgdir', 'netdrivers', 'kernelver');
	if (!$attrs1) {
		$callback->({error=>["Cannot find image \'$imagename\' from the linuximage table."],errorcode=>[1]});
		return 0;
	}
        #merge attrs with attrs1    
	foreach (keys %$attrs1) {
	    $attrs->{$_} = $attrs1->{$_};
	}

	$attrs = get_files($imagename, $callback, $attrs);
	if($#extra > -1){
		my $ex = get_extra($callback, @extra);
		if($ex){ 
			$attrs->{extra} = $ex;
		}
	}

        #get postscripts
        if ($node) {
	    $attrs = get_postscripts($node, $callback, $attrs)
	}


	# if we get nothing back, then we couldn't find the files.  How sad, return nuthin'
	return $attrs;	

}

sub get_postscripts {
    my $node = shift;
    my $errors = 0;
    my $callback = shift;
    my $attrs = shift; 
    my @nodes = noderange($node);
    if (@nodes > 0) { $node = $nodes[0]; }
    else {
	$callback->(
	    {error => ["Unable to get postscripts, $node is not a valide node."],errorcode=>1}
	    );
	return 0;
    }
    my $postscripts;
    my $postbootscripts;
    my $ptab = new xCAT::Table('postscripts', -create=>1);
    unless($ptab){
	$callback->(
	    {error => ["Unable to open table 'postscripts'."],errorcode=>1}
	    );
	return 0;
    }
    
    my $ent = $ptab->getNodeAttribs($node, ['postscripts', 'postbootscripts']);
    if ($ent)  
    {
	if ($ent->{postscripts}) { $postscripts = $ent->{postscripts}; }
	if ($ent->{postbootscripts}) { $postbootscripts = $ent->{postbootscripts}; }
	
    }
    
    (my $attrs1) = $ptab->getAttribs({node => "xcatdefaults"}, 'postscripts', 'postbootscripts');
    if ($attrs1) {
	if ($attrs1->{postscripts}) {
	    if ($postscripts) {
		$postscripts = $attrs1->{postscripts} . ",$postscripts";
	    } else {
		$postscripts = $attrs1->{postscripts};
	    }
	}
	if ($attrs1->{postbootscripts}) {
	    if ($postbootscripts) {
		$postbootscripts = $attrs1->{postbootscripts} . ",$postbootscripts";
	    } else {
		$postbootscripts = $attrs1->{postbootscripts};
	    }
	}
	
    }
    if ($postscripts) {
	$attrs->{postscripts} = $postscripts;
    }
    if ($postbootscripts) {
	$attrs->{postbootscripts} = $postbootscripts;
    }
    return $attrs;
}


# returns a hash of files
# extra {
#	  file => dir
#   file => dir
# }

sub get_extra {
    my $callback = shift;
    my @extra = @_;
    my $extra;
    
    # make sure that the extra is formatted correctly:
    foreach my $e (@extra){
	my ($file , $to_dir) = split(/:/, $e);
	unless( -r $file){
	    $callback->({error=>["Can not find Extra file $file.  Argument will be ignored"],errorcode=>[1]});
	    next;
	}
	#print "$file => $to_dir";
	if (! $to_dir) {
	    if (-d $file) {
		$to_dir=$file;
	    } else {
		$to_dir=dirname($file);
	    }
	}
	push @{ $extra}, { 'src' => $file, 'dest' => $to_dir };
    }	
    return $extra;
}



# well we check to make sure the files exist and then we return them.
sub get_files{
	my $imagename = shift;
	my $errors = 0;
	my $callback = shift;
	my $attrs = shift;  # we'll hopefully get a reference to it and modify this variable.
	my @arr;	 # array of directory search paths
	my $template = '';

	# todo is XCATROOT not going to be /opt/xcat/  in normal situations?  We'll always
	# assume it is for now
	my $xcatroot = "/opt/xcat";

	# get the install root
	my $installroot = xCAT::Utils->getInstallDir();
	unless($installroot){
		$installroot = '/install';
	}

	my $provmethod = $attrs->{provmethod};
	my $osvers = $attrs->{osvers};


	# here's the case for the install.  All we need at first is the 
	# template.  That should do it.
	if($provmethod =~ /install/){
	    @arr = ("$installroot/custom/install", "$xcatroot/share/xcat/install");

	    #get .tmpl file
	    if ((! $attrs->{template}) || (! -r $attrs->{template})) {
		my $template = look_for_file('tmpl', $callback, $attrs, @arr);
		unless($template){
			$callback->({error=>["Couldn't find install template for $imagename"],errorcode=>[1]});
			$errors++;
		}else{
			$callback->( {data => ["$template"]});
			$attrs->{template} = $template;
		}
	    }
	    $attrs->{media} = "required";
	}


	# for stateless I need to save the 
	# ramdisk
	# the kernel
	# the rootimg.gz
	if($osvers =~ /esx/){
		# don't do anything because these files don't exist for ESX stateless.
	} elsif($provmethod =~ /netboot/){
	    @arr = ("$installroot/custom/netboot", "$xcatroot/share/xcat/netboot");
	    #get .pkglist file
	    if ((! $attrs->{pkglist}) || (! -f $attrs->{pkglist})) {
		# we need to get the .pkglist for this one!
		my $temp = look_for_file('pkglist', $callback, $attrs, @arr);
		unless($temp){
			$callback->({error=>["Couldn't find pkglist file for $imagename"],errorcode=>[1]});
			$errors++;
		}else{
			$attrs->{pkglist} = $temp;
		}
	    }
	    
	    @arr = ("$installroot/netboot");
	    
	    # look for ramdisk
	    my $ramdisk = look_for_file('initrd.gz', $callback, $attrs, @arr);
	    unless($ramdisk){
		$callback->({error=>["Couldn't find ramdisk (initrd.gz) for  $imagename"],errorcode=>[1]});
		$errors++;
	    }else{
		$attrs->{ramdisk} = $ramdisk;
	    }
	    
	    # look for kernel
	    my $kernel = look_for_file('kernel', $callback, $attrs, @arr);
	    unless($kernel){
		$callback->({error=>["Couldn't find kernel (kernel) for  $imagename"],errorcode=>[1]});
		$errors++;
	    }else{
		$attrs->{kernel} = $kernel;
	    }
	    
	    # look for rootimg.gz
	    my $rootimg = look_for_file('rootimg.gz', $callback, $attrs, @arr);
	    unless($rootimg){
		$callback->({error=>["Couldn't find rootimg (rootimg.gz) for  $imagename"],errorcode=>[1]});
		$errors++;
	    }else{
		$attrs->{rootimg} = $rootimg;
	    }
	}
	

		

	if($errors){
	    $attrs = 0;
	}
	return $attrs;
}


# argument:
# type of file:  This is usually the suffix of the file, or the file name.
# attributes:  These are the paramaters you got from the osimage table in a hash.
# @dirs:  Some search paths where we'll start looking for them.
# then we just return a string of the full path to where the file is.
# mostly because we just ooze awesomeness.
sub look_for_file {
    my $file = shift;
    my $callback = shift;
    my $attrs = shift;
    my @dirs = @_;
    my $r_file = '';
    
    my $profile = $attrs->{profile};
    my $arch = $attrs->{osarch};
    my $distname = $attrs->{osvers};
    
    
    # go through the directories and look for the file.  We hopefully will find it...
    foreach my $d (@dirs){
	# widdle down rhel5.4, rhel5., rhel5, rhel, rhe, rh, r, 
	my $dd = $distname; # dd is distro directory, or disco dave, whichever you prefer.
	if($dd =~ /win/){ $dd = 'windows' };
	until(-r "$d/$dd" or not $dd){
	    $callback->({data=>["not in  $d/$dd..."]}) if $::VERBOSE;
	    chop($dd);	
	}
	if($distname && (($file eq 'tmpl') || ($file eq 'pkglist'))){		
	    $callback->({data=>["looking in $d/$dd..."]}) if $::VERBOSE;
	    # now look for the file name: foo.rhel5.x86_64.tmpl
	    (-r "$d/$dd/$profile.$distname.$arch.$file") && (return "$d/$dd/$profile.$distname.$arch.$file");
	    
	    # now look for the file name: foo.rhel5.tmpl
	    (-r "$d/$dd/$profile.$distname.$file") && (return "$d/$dd/$profile.$distname.$file");
	    
	    # now look for the file name: foo.x86_64.tmpl
	    (-r "$d/$dd/$profile.$arch.$file") && (return "$d/$dd/$profile.$arch.$file");
	    
	    # finally, look for the file name: foo.tmpl
	    (-r "$d/$dd/$profile.$file") && (return "$d/$dd/$profile.$file");
	}else{
	    # this may find the ramdisk: /install/netboot/
	    (-r "$d/$dd/$arch/$profile/$file") && (return "$d/$dd/$arch/$profile/$file");
	}
    }
    
    # I got nothing man.  Can't find it.  Sorry 'bout that.
    # returning nothing:
    return '';
}


# here's where we make the tarball
sub make_bundle {
	my $imagename = shift;
	my $dest = shift;
	my $attribs = shift;
	my $callback = shift;

	# tar ball is made in local working directory.  Sometimes doing this in /tmp 
	# is bad.  In the case of my development machine, the / filesystem was nearly full.
	# so doing it in cwd is easy and predictable.
	my $dir = shift;
	#my $dir = getcwd;

	# get rid of spaces and put in underlines.  
	$imagename =~ s/\s+/_/g;	


	# we may find that cwd doesn't work, so we use the request cwd.
	my $ttpath = mkdtemp("$dir/imgexport.$$.XXXXXX");
	$callback->({data=>["Creating $ttpath..."]}) if $::VERBOSE;
	my $tpath = "$ttpath/$imagename";
	mkdir("$tpath");
	chmod 0755,$tpath;

	# make manifest.xml file.  So easy!  This is why we like XML.  I didn't like
	# the idea at first though.
	my $xml = new XML::Simple(RootName =>'xcatimage');	
	open(FILE,">$tpath/manifest.xml") or die "Could not open $tpath/manifest.xml";
	print FILE  $xml->XMLout($attribs, noattr => 1, xmldecl => '<?xml version="1.0"?>');
	#print $xml->XMLout($attribs, noattr => 1, xmldecl => '<?xml version="1.0">');
	close(FILE);


	# these are the only files we copy in.  (unless you have extras)
	for my $a ("kernel", "template", "ramdisk", "rootimg", "pkglist", "synclists", "otherpkglist", "postinstall", "exlist"){
	    my $fn=$attribs->{$a};
	    if($fn) {
		$callback->({data => ["$fn"]});
		if (-r $fn) {
		    system("cp $fn $tpath");
		} else {
		    $callback->({error=>["Couldn't find file $fn for $imagename. Skip."],errorcode=>[1]});
		}
	    }
	}


	# extra files get copied in the extra directory.
	if($attribs->{extra}){
	    mkdir("$tpath/extra");
	    chmod 0755,"$tpath/extra";
	    foreach(@{ $attribs->{extra} }){
		my $fromf = $_->{src};
		print " $fromf\n";
		if(-d $fromf ){
		    print "fromf is a directory";
		    mkpath("$tpath/extra/$fromf");
		    `cp -a $fromf/* $tpath/extra/$fromf/`;
		}else{
		    `cp $fromf $tpath/extra`;
		}
	    }
	}

	# now get right below all this stuff and tar it up.
	chdir($ttpath);
	$callback->( {data => ["Inside $ttpath."]});
	unless($dest){ 
	    $dest = "$dir/$imagename.tgz";
	}

	# if no absolute path specified put it in the cwd
	unless($dest =~ /^\//){
	    $dest = "$dir/$dest";			
	}

	$callback->( {data => ["Compressing $imagename bundle.  Please be patient."]});
	my $rc;
	if($::VERBOSE){
		 $callback->({data => ["tar czvf $dest . "]});	
		 $rc = system("tar czvf $dest . ");	
	}else{
		 $rc = system("tar czf $dest . ");	
	}
	$callback->( {data => ["Done!"]});
	if($rc) {
		$callback->({error=>["Failed to compress archive!  (Maybe there was no space left?)"],errorcode=>[1]});
		return;
	}
	chdir($dir);	
	$rc = system("rm -rf $ttpath");
	if ($rc) {
		$callback->({error=>["Failed to clean up temp space $ttpath"],errorcode=>[1]});
		return;
	}	
}

sub extract_bundle {
    my $request = shift;
    #print Dumper($request);
    my $callback = shift;
    my $nodes=shift;
    my $new_profile=shift;
    
    @ARGV = @{ $request->{arg} };
    my $xml;
    my $data;
    my $datas;
    my $error = 0;
    
    my $bundle = shift @ARGV;
    # extract the image in temp path in cwd
    my $dir = $request->{cwd}; #getcwd;
    $dir = $dir->[0];
    #print Dumper($dir);
    unless(-r $bundle){
	$bundle = "$dir/$bundle";
    }
    
    unless(-r $bundle){
	$callback->({error => ["Can not find $bundle"],errorcode=>[1]});
	return;
    }
    
    my $tpath = mkdtemp("$dir/imgimport.$$.XXXXXX");
    
    $callback->({data=>["Unbundling image..."]});
    my $rc;
    if($::VERBOSE){
	$callback->({data=>["tar zxvf $bundle -C $tpath"]});
	$rc = system("tar zxvf $bundle -C $tpath");
	$rc = system("tar zxvf $bundle -C $tpath");
    }else{
	$rc = system("tar zxf $bundle -C $tpath");
    }
    if($rc){
	$callback->({error => ["Failed to extract bundle $bundle"],errorcode=>[1]});
    }

    # get all the files in the tpath.  These should be all the image names.
    my @files = < $tpath/* >;
    # go through each image directory.  Find the XML and put it into the array.  If there are any 
    # errors then the whole thing is over and we error and leave.
    foreach my $imgdir (@files){
	#print "$imgdir \n";
	unless(-r "$imgdir/manifest.xml"){
	    $callback->({error=>["Failed to find manifest.xml file in image bundle"],errorcode=>[1]});
	    return;
	}
	$xml = new XML::Simple;
	# get the data!
	# put it in an eval string so that it 
	$data = eval { $xml->XMLin("$imgdir/manifest.xml") };
	if($@){
	    $callback->({error=>["invalid manifest.xml file inside the bundle.  Please verify the XML"],errorcode=>[1]});
	    #my $foo = $@;
	    #$foo =~ s/\n//;
	    #$callback->({error=>[$foo],errorcode=>[1]});
	    #foreach($@){
	    #	last;
	    #}
	    return;
	}
	#print Dumper($data);
	#push @{$datas}, $data;
	
	# now we need to import the files...
	unless(verify_manifest($data, $callback)){
	    $error++;
	    next;		
	}
	
	# check media first
	unless(check_media($data, $callback)){
	    $error++;
	    next;		
	}
	
	#import manifest.xml into xCAT database
	unless(set_config($data, $callback)){
	    $error++;
	    next;
	}
	
	# now place files in appropriate directories.
	unless(make_files($data, $imgdir, $callback)){
	    $error++;
	    next;
	}
	
	# put postscripts in the postsctipts table
	if ($nodes) {
	    unless(set_postscripts($data, $callback, $nodes)){
		$error++;
		next;
	    }
	}
	
	
	my $osimage = $data->{imagename};	
	$callback->({data=>["Successfully imported $osimage"]});
	
    }
    
    # remove temp file only if there were no problems.
    unless($error){
	$rc = system("rm -rf $tpath");
	if ($rc) {
	    $callback->({error=>["Failed to clean up temp space $tpath"],errorcode=>[1]});
	    return;
	}	
    }

}

# return 1 for true 0 for false.
# need to make sure media is copied before importing image.
sub check_media {
	my $data = shift;	
	my $callback = shift;	
	my $rc = 0;
	unless( $data->{'media'}) {
		$rc = 1;
	}elsif($data->{media} eq 'required'){
		my $os = $data->{osvers};
		my $arch = $data->{osarch};
		my $installroot = xCAT::Utils->getInstallDir();
		unless($installroot){
			$installroot = '/install';
		}
		unless(-d "$installroot/$os/$arch"){
			$callback->({error=>["This image requires that you first copy media for $os-$arch"],errorcode=>[1]});
		}else{
			$rc = 1;
		}
	}
	return $rc;
}


sub set_postscripts {
    my $data = shift;
    my $callback = shift;
    my $nodes=shift;

    $callback->({data=>["Adding postscripts..."]});

    my @good_nodes=noderange($nodes);

    if (@good_nodes > 0) {
	my @missed = nodesmissed();
	if (@missed > 0) {
	    $callback->(
		{warning => ["The following nodes will be skipped because they are not in the nodelist table.\n  " . join(',', @missed)],errorcode=>1}
		);
	}
    } else    {
	$callback->(
	    {error => ["The nodes $nodes are not defined in xCAT DB."],errorcode=>1}
	    );
	return 0;
    }

    my $ptab = xCAT::Table->new('postscripts',-create => 1,-autocommit => 0);
    unless($ptab){
	$callback->(
	    {error => ["Unable to open table 'postscripts'"],errorcode=>1}
	    );
	return 0;
    }


    # get xcatdefaults settings
    my @a1=();
    my @a2=();
    (my $attrs1) = $ptab->getAttribs({node => "xcatdefaults"}, 'postscripts', 'postbootscripts');
    if ($attrs1) {
	if ($attrs1->{postscripts}) {
	    @a1=split(',', $attrs1->{postscripts});
	}
	if ($attrs1->{postbootscripts}) {
	    @a2=split(',', $attrs1->{postbootscripts});
	}
    }    

    #remove the script if it is already in xcatdefaults
    my @a3=();
    my @a4=();
    my $postscripts = $data->{postscripts};
    my $postbootscripts = $data->{postbootscripts};
    if ($postscripts) { @a3 = split(',', $postscripts); }
    if ($postbootscripts) { @a4 = split(',', $postbootscripts); }

    my @a30;
    my @a40;
    if (@a1>0 && @a3>0) {
	foreach my $tmp1 (@a3) {
	    if (! grep /^$tmp1$/, @a1) {
		push(@a30, $tmp1);
	    }
	}
	$postscripts=join(',', @a30);
    }
    if (@a2>0 && @a4>0) {
	foreach my $tmp2 (@a4) {
	    if (! grep /^$tmp2$/, @a2) {
		push(@a40, $tmp2);
	    }
	}
        $postbootscripts=join(',', @a40);
    }
    
    #now save to the db
    my %keyhash;
    if ($postscripts || $postbootscripts) {
	$keyhash{postscripts} = $postscripts;
	$keyhash{postbootscripts} = $postbootscripts;
	$ptab->setNodesAttribs(\@good_nodes, \%keyhash );
	$ptab->commit;
    }

    return 1;
}

sub set_config {
	my $data = shift;
	my $callback = shift;
	my $ostab = xCAT::Table->new('osimage',-create => 1,-autocommit => 0);
	my $linuxtab = xCAT::Table->new('linuximage',-create => 1,-autocommit => 0);
	my %keyhash;
	my $osimage = $data->{imagename};

	unless($ostab){
		$callback->(
		    {error => ["Unable to open table 'osimage'"],errorcode=>1}
		);
		return 0;
	}

	unless($linuxtab){
		$callback->(
		    {error => ["Unable to open table 'linuximage'"],errorcode=>1}
		);
		return 0;
	}

	$callback->({data=>["Adding $osimage"]}) if $::VERBOSE;

	# now we make a quick hash of what we want to put into this 
	$keyhash{provmethod} = $data->{provmethod};
	$keyhash{profile} = $data->{profile};
	$keyhash{osvers} = $data->{osvers};
	$keyhash{osarch} = $data->{osarch};
        if ($data->{imagetype}) {
	    $keyhash{imagetype} = $data->{imagetype};
	};
        if ($data->{osname}) {
	    $keyhash{osname} = $data->{osname};
	};
        if ($data->{osdistro}) {
	    $keyhash{osdistro} = $data->{osdistro};
	};
        if ($data->{synclists}) {
	    $keyhash{synclists} = $data->{synclists};
	};
        $ostab->setAttribs({imagename => $osimage }, \%keyhash );
        $ostab->commit;

	%keyhash=();
        if ($data->{template}) {
	    $keyhash{template} = $data->{template};
	};
        if ($data->{pkglist}) {
	    $keyhash{pkglist} = $data->{pkglist};
	};
        if ($data->{pkgdir}) {
	    $keyhash{pkgdir} = $data->{pkgdir};
	};
        if ($data->{otherpkglist}) {
	    $keyhash{otherpkglist} = $data->{otherpkglist};
	};
        if ($data->{otherpkgdir}) {
	    $keyhash{otherpkgdir} = $data->{otherpkgdir};
	};
        if ($data->{exlist}) {
	    $keyhash{exlist} = $data->{exlist};
	};
        if ($data->{postinstall}) {
	    $keyhash{postinstall} = $data->{postinstall};
	};
        if ($data->{rootimgdir}) {
	    $keyhash{rootimgdir} = $data->{rootimgdir};
	};
        if ($data->{netdrivers}) {
	    $keyhash{netdrivers} = $data->{netdrivers};
	};
        if ($data->{kernelver}) {
	    $keyhash{kernelver} = $data->{kernelver};
	};
        $linuxtab->setAttribs({imagename => $osimage }, \%keyhash );
        $linuxtab->commit;
	
	return 1;
}


sub verify_manifest {
	my $data = shift;
	my $callback = shift;
	my $errors = 0;

	# first make sure that the stuff is defined!
	unless($data->{imagename}){
		$callback->({error=>["The 'imagename' field is not defined in manifest.xml."],errorcode=>[1]});
		$errors++;
	}
	unless($data->{provmethod}){
		$callback->({error=>["The 'provmethod' field is not defined in manifest.xml."],errorcode=>[1]});
		$errors++;
	}

	unless($data->{profile}){
		$callback->({error=>["The 'profile' field is not defined in manifest.xml."],errorcode=>[1]});
		$errors++;
	}

	unless($data->{osvers}){
		$callback->({error=>["The 'osvers' field is not defined in manifest.xml."],errorcode=>[1]});
		$errors++;
	}

	unless($data->{osarch}){
		$callback->({error=>["The 'osarch' field is not defined in manifest.xml."],errorcode=>[1]});
		$errors++;
	}

	unless($data->{provmethod} =~ /install|netboot|statelite/){
		$callback->({error=>["Importing images with 'provemethod' " . $data->{provmethod} . " is not supported. Hint: install, netboot, or statelite"],errorcode=>[1]});
		$errors++;
	}

	# if the install method is used, then we need to have certain files in place.
	if($data->{provmethod} =~ /install/){
		# we need to get the template for this one!
		unless($data->{template}){
			$callback->({error=>["The 'osarch' field is not defined in manifest.xml."],errorcode=>[1]});
			$errors++;
		}
		#$attrs->{media} = "required"; (need to do something to verify media!

	}elsif($data->{osvers} =~ /esx/){
		$callback->({info => ['this is an esx image']});
		# do nothing for ESX
		1;
	}elsif($data->{provmethod} =~ /netboot|statelite/){
		unless($data->{ramdisk}){
			$callback->({error=>["The 'ramdisk' field is not defined in manifest.xml."],errorcode=>[1]});
			$errors++;
		}
		unless($data->{kernel}){
			$callback->({error=>["The 'kernel' field is not defined in manifest.xml."],errorcode=>[1]});
			$errors++;
		}
		unless($data->{rootimg}){
			$callback->({error=>["The 'rootimg' field is not defined in manifest.xml."],errorcode=>[1]});
			$errors++;
		}
	
	}	
	
	if($errors){
		# we had problems, error and exit.
		return 0;
	}
	# returning 1 means everything went good!	
	return 1;
}

sub make_files {
    my $data = shift;
    my $imgdir = shift;
    my $callback = shift;
    my $os = $data->{osvers};
    my $arch = $data->{osarch};
    my $profile = $data->{profile};
    my $installroot = xCAT::Utils->getInstallDir();
    unless($installroot){
	$installroot = '/install';
    }
    
    # you'll get a hash like this for install:
    #$VAR1 = { 
    #          'provmethod' => 'install',
    #          'profile' => 'all',
    #          'template' => '/opt/xcat/share/xcat/install/centos/all.tmpl',
    #          'pkglist' => '/opt/xcat/share/xcat/install/centos/all.pkglist',
    #          'otherpkglist' => '/opt/xcat/share/xcat/install/centos/all.othetpkgs.pkglist',
    #          'synclists' => '/opt/xcat/share/xcat/install/centos/all.othetpkgs.synclist',
    #          'imagename' => 'Default_Stateful',
    #          'osarch' => 'x86_64',
    #          'media' => 'required',
    #          'osvers' => 'centos5.4'
    #        };
    
    # data will look something like this for netboot:
    #$VAR1 = { 
    #          'provmethod' => 'netboot',
    #          'profile' => 'compute',
    #          'ramdisk' => '/install/netboot/centos5.4/x86_64/compute/initrd.gz',
    #          'kernel' => '/install/netboot/centos5.4/x86_64/compute/kernel',
    #          'imagename' => 'Default_Stateless_1265981465',
    #          'osarch' => 'x86_64',
    #          'pkglist' => '/opt/xcat/share/xcat/install/centos/compute.pkglist',
    #          'otherpkglist' => '/opt/xcat/share/xcat/install/centos/compute.othetpkgs.pkglist',
    #          'synclists' => '/opt/xcat/share/xcat/install/centos/compute.othetpkgs.synclist',
    #          'exlist' => '/opt/xcat/share/xcat/install/centos/compute.exlist',
    #          'postinstall' => '/opt/xcat/share/xcat/install/centos/compute.postinstall',
    #          'extra' => [
    #                     { 
    #                       'dest' => '/install/custom/netboot/centos',
    #                       'src' => '/opt/xcat/share/xcat/netboot/centos/compute.centos5.4.pkglist'
    #                     },
    #                     { 
    #                       'dest' => '/install/custom/netboot/centos',
    #                       'src' => '/opt/xcat/share/xcat/netboot/centos/compute.exlist'
    #                     }
    #                   ],
    #          'osvers' => 'centos5.4',
    #          'rootimg' => '/install/netboot/centos5.4/x86_64/compute/rootimg.gz'
    #        };
	
    for my $a ("kernel", "template", "ramdisk", "rootimg", "pkglist", "synclists", "otherpkglist", "postinstall", "exlist") {
	my $fn=$data->{$a};
	if($fn) {
	    $callback->({data => ["$fn"]});
	    my $basename=basename($fn);
	    my $dirname=dirname($fn);
	    if (! -r $dirname) {
		mkpath("$dirname", { verbose => 1, mode => 0755 });
	    } 
	    if (-r $fn) {
		$callback->( {data => ["  Moving old $fn to $fn.ORIG..."]});
		move("$fn", "$fn.ORIG");
	    }
	    move("$imgdir/$basename",$fn);
	}
    }
       
    if($data->{extra}){
	# have to copy extras
	print "copying extras...\n" if $::VERBOSE;
	#if its just a hash then there is only one entry.
	if (ref($data->{extra}) eq 'HASH'){
	    my $ex = $data->{extra};
	    #my $f = basename($ex->{src});
	    my $ff = $ex->{src};
	    my $dest = $ex->{dest};
	    unless(moveExtra($callback, $ff, $dest, $imgdir)){
		return 0;
	    }
	    # if its an array go through each item.
	}else{
	    foreach(@{ $data->{extra} }) {
		#my $f = basename($_->{src});
		my $ff = $_->{src};
		my $dest = $_->{dest};
		unless(moveExtra($callback, $ff, $dest, $imgdir)){
		    return 0;
		}
	    }
	}
    }
    
    # return 1 meant everything was successful!	
    return 1;
}


sub moveExtra {
    my $callback = shift;
    my $ff = shift;
    my $dest = shift;
    my $imgdir = shift; 
    my $f = basename($ff);
    
    if(-d "$imgdir/extra/$ff"){
	#print "This is a directory\n";
        # this extra file is a directory, so we are moving the directory over.
	$callback->( {data => ["$dest"]});
	unless(-d $dest){
	    unless(mkpath($dest)){
		$callback->( {error=>["Failed to create $dest"], errorcode => 1});
		return 0;
	    }
	}
	# this could cause some problems.  This is one of the reasons we may not want to 
	# allow copying of directories.  
	`cp -a -f $imgdir/extra/$ff/* $dest`;
	if($?){
	    $callback->( {error=>["Failed to cp -a $imgdir/extra/$ff/* to $dest"], errorcode => 1});
	    return 0;
	}
	
    }else{
	#print "This is a file\n";
	# this extra file is a file and we can just copy to the destination.
	$callback->( {data => ["$dest/$f"]}) ;
	if(-r "$dest/$f"){
	    $callback->( {data => ["  Moving old $dest/$f to $dest/$f.ORIG..."]}); 
	    move("$dest/$f", "$dest/$f.ORIG");
	}
        `cp $imgdir/extra/$f $dest`;
	if ($?) {
	    $callback->( {error=>["Failed to copy $imgdir/extra/$f to $dest"], errorcode => 1});
	    return 0;
	}
    }
    return 1;
}
