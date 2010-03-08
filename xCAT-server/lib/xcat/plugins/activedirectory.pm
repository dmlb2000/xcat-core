# IBM(c) 2010 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::activedirectory;
BEGIN
{
      $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
my $callback;
use lib "$::XCATROOT/lib/perl";
use Getopt::Long;
use xCAT::ADUtils;
use Net::DNS;
use strict;

sub handled_commands { 
    return {
        clusteruseradd => 'site:directoryprovider',
        clusteruserdel => 'site:directoryprovider',
        clusteruserlist => 'site:directoryprovider',
        hostaccountlist => 'site:directoryprovider',
        hostaccountadd => 'site:directoryprovider',
        hostaccountdel => 'site:directoryprovider',
    };
}

sub process_request {
    $ENV{LDAPCONF}='/etc/xcat/ad.ldaprc';
    my $request = shift;
    my $command = $request->{command}->[0];
    $callback = shift;
    my $doreq = shift;
    use Data::Dumper;
    my $sitetab = xCAT::Table->new('site');
    my $domain;
    $domain = $sitetab->getAttribs({key=>'domain'},['value']);
    if ($domain and $domain->{value}) { 
        $domain = $domain->{value};
    } else {
        $domain = undef;
    }
    #TODO: if multi-domain support implemented, use the domains table to reference between realm and domain  
    my $server = $sitetab->getAttribs({key=>'directoryserver'},['value']);
    my $realm = $sitetab->getAttribs({key=>'realm'},['value']);
    if ($realm and $realm->{value}) {
        $realm = $realm->{value};
    } else {
        $realm = uc($domain);
        $realm =~ s/\.$//; #remove trailing dot if provided
    }
    my $passtab = xCAT::Table->new('passwd');
    my $adpent = $passtab->getAttribs({key=>'activedirectory'},[qw/username password/]);
    unless ($adpent and $adpent->{username} and $adpent->{password}) {
        sendmsg([1,"activedirectory entry missing from passwd table"]);
        return 1;
    }
    if ($server and $server->{value}) {
        $server = $server->{value};
    } else {
        my $res = Net::DNS::Resolver->new;
        my $query = $res->query("_ldap._tcp.$domain","SRV");
        if ($query) {
            foreach my $srec ($query->answer) {
                $server = $srec->{target};
            }
        }
        unless ($server) {
            sendmsg([1,"Unable to determine a directory server to communicate with, try site.directoryserver"]);
            return;
        }
    }
    if ($command =~ /userlist/) { #user management command, listing
        my $passwdfmt;
        if ($request->{arg}) {
            @ARGV=@{$request->{arg}};
            Getopt::Long::Configure("bundling");
            Getopt::Long::Configure("no_pass_through");
            if (!GetOptions(
                'p' => \$passwdfmt
                )) {
                die "TODO: usage message";
            }
        }
         unless ($domain and $realm) {
             sendmsg([1,"Unable to determine domain from arguments or site table"]);
             return undef;
         }
         my $err = xCAT::ADUtils::krb_login(username=>$adpent->{username},password=>$adpent->{password},realm=>$realm);
         if ($err) {
             sendmsg([1,"Error authenticating to Active Directory"]);
             return 1;
         }
         my $accounts = xCAT::ADUtils::list_user_accounts(
            dnsdomain => $domain,
            directoryserver=> $server,
         );
         if ($passwdfmt) {
             my $account;
             foreach $account (keys %$accounts) {
                 my $textout = ":".$account.":x:"; #first colon is because sendmsg would mistake it for a description
                 foreach (qw/uid gid fullname homedir shell/) {
                     $textout .= $accounts->{$account}->{$_}.":";
                 }
                 $textout =~ s/:$//;
                 sendmsg($textout);
             }
         } else {
             my $account;
             foreach $account (keys %$accounts) {
                 sendmsg($account);
             }
         }
    } elsif ($command =~ /hostaccountlist/) {
         unless ($domain and $realm) {
             sendmsg([1,"Unable to determine domain from arguments or site table"]);
             return undef;
         }
         my $err = xCAT::ADUtils::krb_login(username=>$adpent->{username},password=>$adpent->{password},realm=>$realm);
         if ($err) {
             sendmsg([1,"Error authenticating to Active Directory"]);
             return 1;
         }
         my $accounts = xCAT::ADUtils::list_host_accounts(
            dnsdomain => $domain,
            directoryserver=> $server,
         );
         my $account;
         foreach $account (keys %$accounts) {
             sendmsg($account);
         }
    } elsif ($command =~ /hostaccountdel/) {
         my $accountname;
         my %loggedrealms = ();
         foreach $accountname (@{$request->{node}}) {
             if ($request->{arg} and scalar @{$request->{arg}}) {
                 die "TODO: usage";
             }
             if ($accountname =~ /@/) {
                 ($accountname,$domain) = split /@/,$accountname;
                 $domain = lc($domain);
             } 
              unless ($domain) {
                 sendmsg([1,"Unable to determine domain from arguments or site table"]);
                 return undef;
             }
             #my $domainstab = xCAT::Table->new('domains');
             #$realm = $domainstab->getAttribs({domain=>$domain},
             unless ($realm) {
                $realm = uc($domain);
                $realm =~ s/\.$//; #remove trailing dot if provided
             }
             $ENV{KRB5CCNAME}="/tmp/xcat/krbcache.$realm.$$";
             unless ($loggedrealms{$realm}) {
                my $err = xCAT::ADUtils::krb_login(username=>$adpent->{username},password=>$adpent->{password},realm=>$realm);
                 if ($err) {
                     sendmsg([1,"Error authenticating to Active Directory"],$accountname);
                     next;
                 }
                 $loggedrealms{$realm}=1;
             }
             my %args = (
                account => $accountname,
                dnsdomain => $domain,
                directoryserver=> $server,
                );
             my $ret = xCAT::ADUtils::del_host_account(%args);
         }
         foreach my $realm (keys %loggedrealms) {
             unlink "/tmp/xcat/krbcache.$realm.$$";
         }
    } elsif ($command =~ /userdel/) {
        my $username = shift @{$request->{arg}};
         if (scalar @{$request->{arg}}) {
             die "TODO: usage";
         }
         if ($username =~ /@/) {
             ($username,$domain) = split /@/,$username;
             $domain = lc($domain);
         } 
         unless ($domain) {
             sendmsg([1,"Unable to determine domain from arguments or site table"]);
             return undef;
         }

         #my $domainstab = xCAT::Table->new('domains');
         #$realm = $domainstab->getAttribs({domain=>$domain},
         unless ($realm) {
            $realm = uc($domain);
            $realm =~ s/\.$//; #remove trailing dot if provided
         }
         $ENV{KRB5CCNAME}="/tmp/xcat/krbcache.$realm.$$";

         my $err = xCAT::ADUtils::krb_login(username=>$adpent->{username},password=>$adpent->{password},realm=>$realm);
         if ($err) {
             sendmsg([1,"Error authenticating to Active Directory"]);
             return 1;
         }
         my %args = (
                account => $username,
                dnsdomain => $domain,
                directoryserver=> $server,
                );
         if ($command =~ /userdel/) {
             my $ret = xCAT::ADUtils::del_user_account(%args);
         } elsif ($command =~ /hostaccountdel/) {
             my $ret = xCAT::ADUtils::del_host_account(%args);
         }
    } elsif ($command =~ /useradd$/) { #user management command, adding
        my $homedir;
        my $fullname;
        my $gid;
        my $uid;
        my $ou;
        @ARGV=@{$request->{arg}};
        Getopt::Long::Configure("bundling");
        Getopt::Long::Configure("no_pass_through");

         if (!GetOptions(
            'd=s' => \$homedir,
            'c=s' => \$fullname,
            'g=s' => \$gid,
            'o=s' => \$ou,
            'u=s' => \$uid)) {
             die "TODO: usage message";
         }
         my $username = shift @ARGV;
         if ($username =~ /@/) {
             ($username,$domain) = split /@/,$username;
             $domain = lc($domain);
         } 
         unless ($domain) {
             sendmsg([1,"Unable to determine domain from arguments or site table"]);
             return undef;
         }

         #my $domainstab = xCAT::Table->new('domains');
         #$realm = $domainstab->getAttribs({domain=>$domain},
         unless ($realm) {
            $realm = uc($domain);
            $realm =~ s/\.$//; #remove trailing dot if provided
         }

         my $err = xCAT::ADUtils::krb_login(username=>$adpent->{username},password=>$adpent->{password},realm=>$realm);
         if ($err) {
             sendmsg([1,"Error authenticating to Active Directory"]);
             return 1;
         }
         my %args = ( 
            username => $username,
            dnsdomain => $domain,
            directoryserver=> $server,
         );
         if ($fullname) { $args{fullname} = $fullname };
         if ($ou)  { $args{ou} = $ou };
         if ($request->{environment} and 
             $request->{environment}->[0]->{XCAT_USERPASS}) {
             $args{password} = $request->{environment}->[0]->{XCAT_USERPASS}->[0];
         }
        #TODO: args password
         if (defined $gid) { $args{gid} = $gid };
         if (defined $uid) { $args{uid} = $uid };
        #TODO: smbHome for windows
         if (defined $homedir) { $args{homedir} = $homedir };
         my $ret = xCAT::ADUtils::add_user_account(%args);
         if (ref $ret and $ret->{error}) {
             sendmsg([1,$ret->{error}]);
         }
    } elsif ($command =~ /hostaccountadd$/) { #user management command, adding
        my $ou;
        if ($request->{arg}) {
            @ARGV=@{$request->{arg}};
            Getopt::Long::Configure("bundling");
            Getopt::Long::Configure("no_pass_through");
    
            if (!GetOptions('o=s' => \$ou)) {
                die "TODO: usage message";
            }
        }
        #my $domainents = $domaintab->getNodesAttribs($request->{node},['ou','domain']); #TODO: have this in schema
        my $nodename;
        my %loggedrealms=();
        foreach $nodename (@{$request->{node}}) {
          if ($nodename =~ /\./) {
                 ($nodename,$domain) = split /\./,$nodename,2;
                 $domain = lc($domain);
             } 
             unless ($domain) {
                 sendmsg([1,"Unable to determine domain from arguments or site table"]);
                 return undef;
             }
    
             #my $domainstab = xCAT::Table->new('domains');
             #$realm = $domainstab->getAttribs({domain=>$domain},
             unless ($realm) {
                $realm = uc($domain);
                $realm =~ s/\.$//; #remove trailing dot if provided
             }
             unless ($loggedrealms{$realm}) {
                my $err = xCAT::ADUtils::krb_login(username=>$adpent->{username},password=>$adpent->{password},realm=>$realm);
                 if ($err) {
                     sendmsg([1,"Error authenticating to Active Directory"],$nodename);
                     next;
                 }
                 $loggedrealms{$realm}=1;
             }
    
             my %args = ( 
                node => $nodename,
                dnsdomain => $domain,
                directoryserver=> $server,
             );
             if ($ou)  { $args{ou} = $ou };
             if ($request->{environment} and 
                 $request->{environment}->[0]->{XCAT_HOSTPASS}) {
                 $args{password} = $request->{environment}->[0]->{XCAT_HOSTPASS}->[0];
             }
             my $ret = xCAT::ADUtils::add_host_account(%args);
             if (ref $ret and $ret->{error}) {
                 sendmsg([1,$ret->{error}]);
             } elsif (ref $ret)  {
                 print $ret->{password};
             }
        }
    }
}

sub sendmsg {
    my $text = shift;
    my $node = shift;
    my $descr;
    my $rc;
    if (ref $text eq 'HASH') {
        die "not right now";
    } elsif (ref $text eq 'ARRAY') {
        $rc = $text->[0];
        $text = $text->[1];
    }
    if ($text =~ /:/) {
        ($descr,$text) = split /:/,$text,2;
    }
    $text =~ s/^ *//;
    $text =~ s/ *$//;
    my $msg;
    my $curptr;
    if ($node) {
        $msg->{node}=[{name => [$node]}];
        $curptr=$msg->{node}->[0];
    } else {
        $msg = {};
        $curptr = $msg;
    }
    if ($rc) {
        $curptr->{errorcode}=[$rc];
        $curptr->{error}=[$text];
        $curptr=$curptr->{error}->[0];
    } else {
        $curptr->{data}=[{contents=>[$text]}];
        $curptr=$curptr->{data}->[0];
        if ($descr) { $curptr->{desc}=[$descr]; }
    }
#        print $outfd freeze([$msg]);
#        print $outfd "\nENDOFFREEZE6sK4ci\n";
#        yield;
#        waitforack($outfd);
    $callback->($msg);
}
1;
