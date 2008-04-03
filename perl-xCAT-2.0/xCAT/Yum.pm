package xCAT::Yum;
use DBI;
use File::Find;
use File::Spec;
use File::Path;
my $yumrepofile;
my $distname;
my $arch;
my $installpfx;
sub localize_yumrepo {
   my $self = shift;
   my $installroot = shift;
   $distname = shift;
   $arch = shift;
   my $dosqlite = 0;
  my $repomdfile;
  my $primaryxml;
  $installpfx = "$installroot/$distname/$arch";
  mkpath("$installroot/postscripts/repos/$distname/$arch/");
  open($yumrepofile,">","$installroot/postscripts/repos/$distname/$arch/local-repository.tmpl");
  find(\&check_tofix,$installpfx);
  close($yumrepofile);
}
sub check_tofix {
   if (-d $File::Find::name and $File::Find::name =~ /\/repodata$/) {
      fix_directory($File::Find::name);
   }
}
sub fix_directory { 
  my $dirlocation = shift;
  my @dircomps = File::Spec->splitdir($dirlocation);
  pop(@dircomps);
  my $yumurl = File::Spec->catdir(@dircomps);
  $yumurl =~ s!$installpfx!http://#INSTSERVER#/install/$distname/$arch/!;
  my $reponame = $dircomps[$#dircomps];
  print $yumrepofile "[local-$distname-$arch-$reponame]\n";
  print $yumrepofile "name=xCAT configured yum repository for $distname/$arch/$reponame\n";
  print $yumrepofile "baseurl=$yumurl\n";
  print $yumrepofile "enabled=1\n";
  print $yumrepofile "gpgcheck=0\n\n";
  my $oldsha=`/usr/bin/sha1sum $dirlocation/primary.xml.gz`;
  my $olddbsha; 
  my @xmlines;
  @xmlines = ();
  $oldsha =~ s/\s.*//;
  chomp($oldsha);
  unlink("$dirlocation/primary.xml");
  system("/bin/gunzip  $dirlocation/primary.xml.gz");
  my $oldopensha=`/usr/bin/sha1sum $dirlocation/primary.xml`;
  $oldopensha =~ s/\s+.*//;
  chomp($oldopensha);
  open($primaryxml,"+<$dirlocation/primary.xml");
  while (<$primaryxml>) {
     s!xml:base="media://[^"]*"!!g;
     push @xmlines,$_;
  }
  seek($primaryxml,0,0);
  print $primaryxml (@xmlines);
  truncate($primaryxml,tell($primaryxml));
  @xmlines=();
  close($primaryxml);
  my $newopensha=`/usr/bin/sha1sum $dirlocation/primary.xml`;
  system("/bin/gzip $dirlocation/primary.xml");
  my $newsha=`/usr/bin/sha1sum $dirlocation/primary.xml.gz`;
  $newopensha =~ s/\s.*//;
  $newsha =~ s/\s.*//;
  chomp($newopensha);
  chomp($newsha);
  my  $newdbsha;
  my $newdbopensha;
  my $olddbopensha;
  if (-r "$dirlocation/primary.sqlite.bz2") { 
   $olddbsha =`/usr/bin/sha1sum $dirlocation/primary.sqlite.bz2`;
   $olddbsha =~ s/\s.*//;
   chomp($olddbsha);
   unlink("$dirlocation/primary.sqlite");
   system("/usr/bin/bunzip2  $dirlocation/primary.sqlite.bz2");
   $olddbopensha=`/usr/bin/sha1sum $dirlocation/primary.sqlite`;
   $olddbopensha =~ s/\s+.*//;
   chomp($olddbopensha);
   my $pdbh = DBI->connect("dbi:SQLite:$dirlocation/primary.sqlite","","",{AutoCommit=>1});
   $pdbh->do('UPDATE "packages" SET "location_base" = NULL');
   $pdbh->disconnect;
   $newdbopensha=`/usr/bin/sha1sum $dirlocation/primary.sqlite`;
   system("/usr/bin/bzip2 $dirlocation/primary.sqlite");
   $newdbsha=`/usr/bin/sha1sum $dirlocation/primary.sqlite.bz2`;
   $newdbopensha =~ s/\s.*//;
   $newdbsha =~ s/\s.*//;
   chomp($newdbopensha);
   chomp($newdbsha);
  }
  open($primaryxml,"+<$dirlocation/repomd.xml");
  while (<$primaryxml>) { 
     s!xml:base="media://[^"]*"!!g;
     s!$oldsha!$newsha!g;
      s!$oldopensha!$newopensha!g;
      if ($olddbsha) { s!$olddbsha!$newdbsha!g; }
      if ($olddbsha) { s!$olddbopensha!$newdbopensha!g; }
      push @xmlines,$_;
  }
  seek($primaryxml,0,0);
  print $primaryxml (@xmlines);
  truncate($primaryxml,tell($primaryxml));
  close($primaryxml);
  @xmlines=();
}


1;
