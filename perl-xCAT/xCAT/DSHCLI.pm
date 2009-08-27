#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::DSHCLI;

use File::Basename;

use locale;
use strict;
use File::Path;
use POSIX;
use Socket;
use Getopt::Long;
require xCAT::DSHCore;
use xCAT::MsgUtils;
use xCAT::Utils;
use xCAT::Table;
use lib '/opt/xcat/xdsh';
our @dsh_available_contexts = ();
our @dsh_valid_contexts     = ();

our $dsh_exec_state         = 0;
our $dsh_forked_process     = undef;
our $dsh_options            = undef;
our $dsh_resolved_targets   = undef;
our $dsh_unresolved_targets = undef;
our %dsh_target_status      = undef;
our $dsh_trace              = undef;
our %dsh_stats              = ();
our $signal_interrupt_flag  = 0;
our $dsh_cmd_background     = 0;
$::CONTEXT_DIR = "/opt/xcat/xdsh/Context/";
$::__DCP_DELIM = 'Xcat,DELIMITER,Xcat';

our @dsh_valid_env = (
                      'DCP_NODE_OPTS',      'DCP_NODE_RCP',
                      'DSH_CONTEXT',        'DSH_ENVIRONMENT',
                      'DSH_FANOUT',         'DSH_LOG',
                      'DSH_NODEGROUP_PATH', 'DSH_NODE_LIST',
                      'DSH_NODE_OPTS',      'DSH_NODE_RCP',
                      'DSH_NODE_RSH',       'DSH_OUTPUT',
                      'DSH_PATH',           'DSH_SYNTAX',
                      'DSH_TIMEOUT',        'DSH_REMOTE_PASSWORD',
                      'DSH_TO_USERID',      'DSH_FROM_USERID',
                      'DEVICETYPE',         'RSYNCSN',
                      'DSH_RSYNC_FILE',     'RSYNCSNONLY',
                      );
select(STDERR);
$| = 1;
select(STDOUT);
$| = 1;

#----------------------------------------------------------------------------

=head3
        execute_dcp

        This is the main driver routine for an instance of the dcp command.
        Given the options configured in the $options hash table, the routine
        configures the execution of the dcp instance, executes the remote copy
        commands and processes the output from each target.

        Arguments:
			$options - options hash table describing dcp configuration options

        Returns:
        	The number of targets that failed to execute a remote copy command

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub execute_dcp
{
    my ($class, $options) = @_;

    $::dsh_command = 'dcp';

    my $result = xCAT::DSHCLI->config_dcp($options);
    $result && (return $result);

    my %resolved_targets   = ();
    my %unresolved_targets = ();
    my %context_targets    = ();
    xCAT::DSHCLI->resolve_targets($options, \%resolved_targets,
                                  \%unresolved_targets, \%context_targets);

    if (!scalar(%resolved_targets))
    {
        my $rsp = {};
        $rsp->{data}->[0] = "No hosts in node list 1";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return ++$result;
    }

    $$options{'verify'}
      && xCAT::DSHCLI->verify_targets($options, \%resolved_targets);

    #check if file descriptor number exceeds the max number in ulimit
    #if (
    #     xCAT::DSHCLI->isFdNumExceed(
    #                          2, scalar(keys(%resolved_targets)),
    #                          $$options{'fanout'}
    #    )
    # )
    #{
    #    my $rsp ={};
    #    $rsp->{data}->[0] = " The DSH fanout value has exceeded the system file descriptor upper limit. Please either reduce the fanout value, or increase max file descriptor number by running ulimit.";
    #    xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
    #   return ++$result;
    #}

    my @targets_waiting  = (sort keys(%resolved_targets));
    my %targets_active   = ();
    my @targets_finished = ();
    my @targets_failed   = ();
    my %targets_buffered = ();

    my %output_buffers = ();
    my %error_buffers  = ();
    my %pid_targets    = ();
    my %outfh_targets  = ();
    my %errfh_targets  = ();
    my %forked_process = ();

    my @output_files = ();
    !$$options{'silent'} && push @output_files, *STDOUT;
    my @error_files = ();
    !$$options{'silent'} && push @error_files, *STDERR;

    xCAT::DSHCLI->fork_fanout_dcp(
                                  $options,          \%resolved_targets,
                                  \%forked_process,  \%pid_targets,
                                  \%outfh_targets,   \%errfh_targets,
                                  \@targets_waiting, \%targets_active
                                  );

    while (keys(%targets_active))
    {
        my $rin = $outfh_targets{'bitmap'} | $errfh_targets{'bitmap'};

        my $fh_count =
          select(my $rout = $rin, undef, undef, $$options{'timeout'});

        if ($fh_count == 0)
        {
            my @active_list = keys(%targets_active);
            my $rsp         = {};
            $rsp->{data}->[0] =
              " Timed out waiting for response from child processes for the following nodes.";
            $rsp->{data}->[1] = " @active_list";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            kill 'INT', keys(%pid_targets);
            $result++;
            last;
        }

        my @select_out_fhs =
          xCAT::DSHCLI->util_bit_indexes($rout & $outfh_targets{'bitmap'}, 1);

        (@select_out_fhs)
          && xCAT::DSHCLI->buffer_output(
                     $options,           \%resolved_targets, \%targets_active,
                     \@targets_finished, \@targets_failed,   \%targets_buffered,
                     \%pid_targets,      \%forked_process,   \%outfh_targets,
                     \%output_buffers,   \%error_buffers,    \@output_files,
                     \@error_files,      \@select_out_fhs
                     );

        my @select_err_fhs =
          xCAT::DSHCLI->util_bit_indexes($rout & $errfh_targets{'bitmap'}, 1);

        (@select_err_fhs)
          && xCAT::DSHCLI->buffer_error(
                                        $options,         \%resolved_targets,
                                        \%targets_active, \@targets_finished,
                                        \@targets_failed, \%targets_buffered,
                                        \%pid_targets,    \%forked_process,
                                        \%errfh_targets,  \%output_buffers,
                                        \%error_buffers,  \@output_files,
                                        \@error_files,    \@select_err_fhs
                                        );

        my @targets_buffered_keys = sort keys(%targets_buffered);

        foreach my $user_target (@targets_buffered_keys)
        {
            my $target_properties = $resolved_targets{$user_target};

            if (!$$options{'silent'})
            {
                if ($::DCP_API)
                {
                    $::DCP_API_MESSAGE .=
                        join("", @{$output_buffers{$user_target}})
                      . join("", @{$error_buffers{$user_target}});
                    if ($$options{'display_output'})
                    {
                        print STDOUT @{$output_buffers{$user_target}};
                        print STDERR @{$error_buffers{$user_target}};
                    }
                }
                else
                {
                    print STDOUT @{$output_buffers{$user_target}};
                    print STDERR @{$error_buffers{$user_target}};
                }
            }

            delete $output_buffers{$user_target};
            delete $error_buffers{$user_target};

            my $exit_code = $targets_buffered{$user_target}{'exit-code'};

            if ($exit_code != 0)
            {
                push @targets_failed, $user_target;
                push @{$dsh_target_status{'failed'}}, $user_target;

            }

            else
            {
                push @targets_finished, $user_target;
            }

            delete $targets_buffered{$user_target};
        }

        (@targets_waiting)
          && xCAT::DSHCLI->fork_fanout_dcp(
                        $options,          \%resolved_targets, \%forked_process,
                        \%pid_targets,     \%outfh_targets,    \%errfh_targets,
                        \@targets_waiting, \%targets_active
                        );
    }

    return (scalar(@targets_failed) + scalar(keys(%unresolved_targets)));
}

#----------------------------------------------------------------------------

=head3
        execute_dsh

        This is the main driver routine for an instance of the dsh command.
        Given the options configured in the $options hash table, the routine
        configures the execution of the dsh instance, executes the remote shell
        commands and processes the output from each target.

        Arguments:
			$options - options hash table describing dsh configuration options

        Returns:
        	The number of targets that failed to execute a remote shell command

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub execute_dsh
{
    my ($class, $options) = @_;

    $::dsh_command = 'dsh';
    $dsh_options   = $options;

    xCAT::DSHCLI->config_signals_dsh($options);

    my $rsp = {};
    $rsp->{data}->[0] = "dsh>  Dsh_process_id $$";
    $$options{'monitor'} && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
    $dsh_exec_state++;

    my $result = xCAT::DSHCLI->config_dsh($options);
    $result && (return $result);

    $rsp->{data}->[0] = "dsh>  Dsh_initialization_completed";
    $$options{'monitor'} && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
    $dsh_exec_state++;

    my %resolved_targets = ();
    $dsh_resolved_targets = \%resolved_targets;
    my %unresolved_targets = ();
    $dsh_unresolved_targets = \%unresolved_targets;
    my %context_targets = ();
    xCAT::DSHCLI->resolve_targets($options, \%resolved_targets,
                                  \%unresolved_targets, \%context_targets);
    my @canceled_targets = ();
    $dsh_target_status{'canceled'} = \@canceled_targets;
    my $rsp = {};

    if (scalar(%unresolved_targets))
    {
        foreach my $target (sort keys(%unresolved_targets))
        {
            $rsp->{data}->[0] = "dsh>  Remote_command_cancelled $target";
            $$dsh_options{'monitor'}
              && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
        }
    }

    if (!scalar(%resolved_targets))
    {
        $rsp->{data}->[0] = " No hosts in node list 2";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return ++$result;
    }
    $dsh_exec_state++;

    if ($$options{'verify'})
    {
        $rsp->{data}->[0] = "dsh>  Dsh_verifying_hosts";
        $$options{'monitor'} && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
        xCAT::DSHCLI->verify_targets($options, \%resolved_targets);
    }

    #check if file descriptor number exceeds the max number in ulimit
    #if (
    #    xCAT::DSHCLI->isFdNumExceed(
    #                        2, scalar(keys(%resolved_targets)),
    #                       $$options{'fanout'}
    # )
    #)
    #{
    #    $rsp->{data}->[0] = " The DSH fanout value has exceeded the system file descriptor upper limit. Please either reduce the fanout value, or increase max file descriptor number by running ulimit.";
    #    xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
    #   return ++$result;
    #}

    my @targets_failed = ();
    $dsh_target_status{'failed'} = \@targets_failed;
    @targets_failed =
      xCAT::DSHCLI->_execute_dsh($options, \%resolved_targets,
                                 \%unresolved_targets, \%context_targets);
    if ($::DSH_API)
    {
        if (scalar(@targets_failed) > 0)
        {
            $::DSH_API_NODES_FAILED = join ",", @targets_failed;
        }
    }
    return (scalar(@targets_failed) + scalar(keys(%unresolved_targets)));
}

#----------------------------------------------------------------------------

=head3
        _execute_dsh

        Wrapper routine for execute_dsh 
        to execute actual dsh call

        Arguments:
        	$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$unresolved_targets - hash table of unresolved targets and relevant properties
			$context_targets - hash table of targets grouped by context name

        Returns:
        	@targets_failed - a list of those targets that failed execution

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:
        	Internal Routine only

=cut

#----------------------------------------------------------------------------
sub _execute_dsh
{
    my ($class, $options, $resolved_targets, $unresolved_targets,
        $context_targets)
      = @_;

    my @output_files = ();
    !$$options{'silent'} && push @output_files, *STDOUT;

    my @error_files = ();
    !$$options{'silent'} && push @error_files, *STDERR;
    my @targets_waiting = ();
    @targets_waiting = (sort keys(%$resolved_targets));
    my @dsh_target_status = ();
    $dsh_target_status{'waiting'} = \@targets_waiting;
    my %targets_active = ();
    $dsh_target_status{'active'} = \%targets_active;
    my @targets_finished = ();
    $dsh_target_status{'finished'} = \@targets_finished;
    my @targets_failed   = ();
    my %targets_buffered = ();

    my %output_buffers = ();
    my %error_buffers  = ();
    my %pid_targets    = ();
    my %outfh_targets  = ();
    my %errfh_targets  = ();
    my %forked_process = ();
    $dsh_forked_process = \%forked_process;

    my $rsp = {};
    my $result;
    $rsp->{data}->[0] = "dsh>  Dsh_remote_execution_started";
    $$options{'monitor'} && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
    $dsh_exec_state++;

    xCAT::DSHCLI->fork_fanout_dsh(
                                  $options,          $resolved_targets,
                                  \%forked_process,  \%pid_targets,
                                  \%outfh_targets,   \%errfh_targets,
                                  \@targets_waiting, \%targets_active
                                  );

    while (keys(%targets_active))
    {

        my $rin = $outfh_targets{'bitmap'} | $errfh_targets{'bitmap'};

        my $fh_count =
          select(my $rout = $rin, undef, undef, $$options{'timeout'});

        if ($fh_count == 0)
        {
            my @active_list = keys(%targets_active);
            $rsp->{data}->[0] =
              " Timed out waiting for response from child processes for the following nodes. Terminating the child processes. ";
            $rsp->{data}->[1] = " @active_list";
            xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
            @targets_failed = keys(%targets_active);

            &handle_signal_dsh('INT', 2);
            $result++;

            #last;
        }

        my @select_out_fhs =
          xCAT::DSHCLI->util_bit_indexes($rout & $outfh_targets{'bitmap'}, 1);

        if (@select_out_fhs)
        {
            if ($$options{'streaming'})
            {
                xCAT::DSHCLI->stream_output(
                        $options,           $resolved_targets, \%targets_active,
                        \@targets_finished, \@targets_failed,  \%pid_targets,
                        \%forked_process,   \%outfh_targets,   \%output_buffers,
                        \@output_files,     \@select_out_fhs
                        );
            }

            else
            {
                xCAT::DSHCLI->buffer_output(
                      $options,           $resolved_targets, \%targets_active,
                      \@targets_finished, \@targets_failed,  \%targets_buffered,
                      \%pid_targets,      \%forked_process,  \%outfh_targets,
                      \%output_buffers,   \%error_buffers,   \@output_files,
                      \@error_files,      \@select_out_fhs
                      );
            }
        }

        my @select_err_fhs =
          xCAT::DSHCLI->util_bit_indexes($rout & $errfh_targets{'bitmap'}, 1);

        if (@select_err_fhs)
        {
            if ($$options{'streaming'})
            {
                xCAT::DSHCLI->stream_error(
                        $options,           $resolved_targets, \%targets_active,
                        \@targets_finished, \@targets_failed,  \%pid_targets,
                        \%forked_process,   \%errfh_targets,   \%error_buffers,
                        \@error_files,      \@select_err_fhs
                        );
            }

            else
            {
                xCAT::DSHCLI->buffer_error(
                      $options,           $resolved_targets, \%targets_active,
                      \@targets_finished, \@targets_failed,  \%targets_buffered,
                      \%pid_targets,      \%forked_process,  \%errfh_targets,
                      \%output_buffers,   \%error_buffers,   \@output_files,
                      \@error_files,      \@select_err_fhs
                      );
            }
        }

        my @targets_buffered_keys = sort keys(%targets_buffered);

        foreach my $user_target (@targets_buffered_keys)
        {
            my $target_properties = $$resolved_targets{$user_target};

            my $output_file     = undef;
            my $output_filename = undef;
            my $error_file      = undef;
            my $error_filename  = undef;

            if (!$$options{'silent'})
            {
                if ($::DSH_API)
                {
                    $::DSH_API_MESSAGE =
                        $::DSH_API_MESSAGE
                      . join("", @{$output_buffers{$user_target}})
                      . join("", @{$error_buffers{$user_target}});
                    if ($$options{'display_output'})
                    {
                        print STDOUT @{$output_buffers{$user_target}};
                        print STDERR @{$error_buffers{$user_target}};
                    }
                }
                else
                {
                    print STDOUT @{$output_buffers{$user_target}};
                    print STDERR @{$error_buffers{$user_target}};
                }
            }

            delete $output_buffers{$user_target};
            delete $error_buffers{$user_target};

            my $exit_code = $targets_buffered{$user_target}{'exit-code'};
            my $target_rc = $targets_buffered{$user_target}{'target-rc'};
            my $rsp       = {};

            if ($exit_code != 0)
            {

                $rsp->{data}->[0] =
                  " $user_target remote Command return code = $exit_code.";
                xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);

                $rsp->{data}->[0] = "dsh>  Remote_command_failed $user_target";
                $$options{'monitor'}
                  && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                if (!grep(/$user_target/, @targets_failed))
                {    # not already in list

                    push @targets_failed, $user_target;
                }
                push @{$dsh_target_status{'failed'}}, $user_target
                  if !$signal_interrupt_flag;

            }

            else
            {
                if ($target_rc != 0)
                {

                    $rsp->{data}->[0] =
                      " $user_target remote Command return code = $$target_properties{'target-rc'}.";
                    xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);

                    $rsp->{data}->[0] =
                      "dsh>  Remote_command_failed $user_target";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK, 1);

                    push @targets_failed, $user_target;
                    push @{$dsh_target_status{'failed'}}, $user_target
                      if !$signal_interrupt_flag;
                }

                elsif (!defined($target_rc) && !$dsh_cmd_background)
                {

                    $rsp->{data}->[0] =
                      " A return code for the command run on the host $user_target was not received.";
                    xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
                    my $rsp = {};
                    $rsp->{data}->[0] =
                      "dsh>  Remote_command_failed $user_target";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                    push @targets_failed, $user_target;
                    push @{$dsh_target_status{'failed'}}, $user_target
                      if !$signal_interrupt_flag;
                }

                else
                {
                    $rsp->{data}->[0] =
                      "dsh>  Remote_command_successful $user_target";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                    push @targets_finished, $user_target;
                }
            }

            delete $targets_buffered{$user_target};
        }

        (@targets_waiting)
          && xCAT::DSHCLI->fork_fanout_dsh(
                         $options,          $resolved_targets, \%forked_process,
                         \%pid_targets,     \%outfh_targets,   \%errfh_targets,
                         \@targets_waiting, \%targets_active
                         );

    }

    $dsh_exec_state++;

    if ($$options{'stats'})
    {
        $dsh_stats{'end-time'} = localtime();

        scalar(@targets_finished)
          && ($dsh_stats{'successful-targets'} = \@targets_finished);
        if (scalar(@targets_failed))
        {
            if (scalar(@{$dsh_target_status{'failed'}}))
            {
                $dsh_stats{'failed-targets'} = $dsh_target_status{'failed'};
            }
            else
            {
                $dsh_stats{'failed-targets'} = \@targets_failed;
            }
        }
        scalar(@{$dsh_target_status{'canceled'}})
          && ($dsh_stats{'canceled-targets'} = $dsh_target_status{'canceled'});
    }
    my $rsp = {};
    $rsp->{data}->[0] = "dsh>  Remote_command_execution_completed";
    $$options{'monitor'} && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    return @targets_failed;
}

#----------------------------------------------------------------------------

=head3
        fork_fanout_dcp

        Main process forking routine for an instance of the dcp command.
        The routine creates forked processes of a remote copy command up to
        the configured fanout value.  Then output from each process is
        processed.  The number of currently forked processes is consistently
        maintained up to the configured fanout value

        Arguments:
			$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$forked_process - hash table of process information keyed by target name
        	$pid_targets - hash table of target names keyed by process ID
        	$outfh_targets - hash table of STDOUT pipe handles keyed by target name
        	$errfh_targets - hash table of STDERR pipe handles keyed by target name
        	$targets_waiting - array of targets pending remote execution
        	$targets_active - hash table of currently active targets with output possibly available

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub fork_fanout_dcp
{
    my (
        $class,          $options,         $resolved_targets,
        $forked_process, $pid_targets,     $outfh_targets,
        $errfh_targets,  $targets_waiting, $targets_active
      )
      = @_;

    while (@$targets_waiting
           && (keys(%$targets_active) < $$options{'fanout'}))
    {
        my $user_target       = shift @$targets_waiting;
        my $target_properties = $$resolved_targets{$user_target};

        my @dcp_command;
        my $rsyncfile;

        if (!$$target_properties{'localhost'})
        {
            my $target_type = $$target_properties{'type'};

            my %rcp_config = ();

            my $remote_copy;
            my $rsh_extension = 'RSH';

            if ($target_type eq 'node')
            {
                $remote_copy =
                     $$options{'node-rcp'}{$$target_properties{'context'}}
                  || $$target_properties{'remote-copy'};
                ($remote_copy =~ /\/scp$/)   && ($rsh_extension = 'SSH');
                ($remote_copy =~ /\/rsync$/) && ($rsh_extension = 'RSYNC');
                $rcp_config{'options'} =
                  $$options{'node-options'}{$$target_properties{'context'}};
            }

            $rcp_config{'preserve'}  = $$options{'preserve'};
            $rcp_config{'recursive'} = $$options{'recursive'};

            if ($$options{'pull'})
            {
                $rcp_config{'src-user'} = $$target_properties{'user'}
                  || $$options{'user'};
                $rcp_config{'src-host'} = $$target_properties{'hostname'};
                $rcp_config{'src-file'} = $$options{'source'};

                my @target_file = split '/', $$options{'source'};
                $rcp_config{'dest-file'} =
                  "$$options{'target'}/$target_file[$#target_file]._$$target_properties{'hostname'}";

            }

            else
            {
                $rcp_config{'src-file'}  = $$options{'source'};
                $rcp_config{'dest-host'} = $$target_properties{'hostname'};
                $rcp_config{'dest-file'} = $$options{'target'};
                $rcp_config{'dest-user'} = $$target_properties{'user'}
                  || $$options{'user'};
                $rcp_config{'destDir_srcFile'} =
                  $$options{'destDir_srcFile'}{$user_target};
            }

            #eval "require RemoteShell::$rsh_extension";
            eval "require xCAT::$rsh_extension";
            my $remoteshell = "xCAT::$rsh_extension";
            @dcp_command =
              $remoteshell->remote_copy_command(\%rcp_config, $remote_copy);

        }
        else
        {
            if ($$options{'destDir_srcFile'}{$user_target})
            {
                if ($::SYNCSN == 1)
                {    # syncing service node

                    $rsyncfile = "/tmp/rsync_$user_target";
                    $rsyncfile .= "_s";
                }
                else
                {
                    $rsyncfile = "/tmp/rsync_$user_target";
                }
                open(RSYNCCMDFILE, "> $rsyncfile")
                  or die "can not open file $rsyncfile";
                my $dest_dir_list = join ' ',
                  keys %{$$options{'destDir_srcFile'}{$user_target}};
                print RSYNCCMDFILE "#!/bin/sh\n";
                print RSYNCCMDFILE "/bin/mkdir -p $dest_dir_list\n";
                foreach my $dest_dir (
                             keys %{$$options{'destDir_srcFile'}{$user_target}})
                {
                    my @src_file =
                      @{$$options{'destDir_srcFile'}{$user_target}{$dest_dir}
                          {'same_dest_name'}};
                    @src_file = map { $_ if -e $_; } @src_file;
                    my $src_file_list = join ' ', @src_file;
                    if ($src_file_list)
                    {
                        print RSYNCCMDFILE "/bin/cp $src_file_list $dest_dir\n";
                    }
                    my %diff_dest_hash =
                      %{$$options{'destDir_srcFile'}{$user_target}{$dest_dir}
                          {'diff_dest_name'}};
                    foreach my $src_file_diff_dest (keys %diff_dest_hash)
                    {
                        next if !-e $src_file_diff_dest;
                        my $diff_basename =
                          $diff_dest_hash{$src_file_diff_dest};
                        print RSYNCCMDFILE
                          "/bin/cp $src_file_diff_dest $dest_dir/$diff_basename\n";
                    }
                }

                #print RSYNCCMDFILE "/bin/rm -f $rsyncfile\n";
                close RSYNCCMDFILE;
                chmod 0755, $rsyncfile;
                @dcp_command = ('/bin/sh', '-c', $rsyncfile);
            }
            else
            {
                @dcp_command =
                  ('/bin/cp', '-r', $$options{'source'}, $$options{'target'});
            }
        }

        my $rsp = {};
        $rsp->{data}->[0] = " TRACE: Executing Command:@dcp_command";
        $dsh_trace
          && (xCAT::MsgUtils->message("I", $rsp, $::CALLBACK));

        my @process_info =
          xCAT::DSHCore->fork_output($user_target, @dcp_command);
        vec($$outfh_targets{'bitmap'}, fileno($process_info[1]), 1) = 1;
        vec($$errfh_targets{'bitmap'}, fileno($process_info[2]), 1) = 1;
        $$outfh_targets{fileno($process_info[1])} = $user_target;
        $$errfh_targets{fileno($process_info[2])} = $user_target;

        $$forked_process{$user_target} = \@process_info;
        $$targets_active{$user_target}++;
        $$pid_targets{$process_info[0]} = $user_target;
    }
}

#----------------------------------------------------------------------------

=head3
        fork_fanout_dsh

        Main process forking routine for an instance of the dsh command.
        The routine creates forked processes of a remote shell command up to
        the configured fanout value.  Then output from each process is
        processed.  The number of currently forked processes is consistently
        maintained up to the configured fanout value

        Arguments:
			$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$forked_process - hash table of process information keyed by target name
        	$pid_targets - hash table of target names keyed by process ID
        	$outfh_targets - hash table of STDOUT pipe handles keyed by target name
        	$errfh_targets - hash table of STDERR pipe handles keyed by target name
        	$targets_waiting - array of targets pending remote execution
        	$targets_active - hash table of currently active targets with output possibly available

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub fork_fanout_dsh
{
    my (
        $class,          $options,         $resolved_targets,
        $forked_process, $pid_targets,     $outfh_targets,
        $errfh_targets,  $targets_waiting, $targets_active
      )
      = @_;

    while (@$targets_waiting
           && (keys(%$targets_active) < $$options{'fanout'}))
    {
        my $user_target       = shift @$targets_waiting;
        my $target_properties = $$resolved_targets{$user_target};
        my $localShell        =
          ($$options{'syntax'} eq 'csh') ? '/bin/csh' : '/bin/sh';
        my @dsh_command = ($localShell, '-c');
        $$options{'command'} =~ s/\s*$//;
        $$options{'command'} =~ s/;$//;

        if ($$options{'command'} =~ /\&$/)
        {
            $$options{'post-command'} = "";
            $dsh_cmd_background = 1;
        }

        if ($$options{'environment'})
        {
            push @dsh_command,
              "$$options{'pre-command'} . $$options{'environment'} ; $$options{'command'}$$options{'post-command'}";
        }

        else
        {
            push @dsh_command,
              "$$options{'pre-command'}$$options{'command'}$$options{'post-command'}";
        }

        if ($$target_properties{'localhost'})
        {
            if (my $specified_usr =
                ($$target_properties{'user'} || $$options{'user'}))
            {
                my $current_usr = getpwuid($>);
                if ($specified_usr ne $current_usr)
                {
                    delete $$target_properties{'localhost'};
                }
            }
        }

        if (!$$target_properties{'localhost'})
        {
            @dsh_command = ();

            my $target_type = $$target_properties{'type'};

            my %rsh_config = ();
            $rsh_config{'hostname'} = $$target_properties{'hostname'};
            $rsh_config{'user'}     = $$target_properties{'user'}
              || $$options{'user'};

            my $remote_shell;
            my $rsh_extension = 'RSH';

            if ($target_type eq 'node')
            {
                my $context = $$target_properties{'context'};
                     $remote_shell = $$options{'node-rsh'}{$context}
                  || $$options{'node-rsh'}{'none'}
                  || $$target_properties{'remote-shell'}
                  || $$options{'node-rsh-defaults'}{$context};
                ($remote_shell =~ /\/ssh$/) && ($rsh_extension = 'SSH');
                $rsh_config{'options'} = "-n "
                  . $$options{'node-options'}{$$target_properties{'context'}};
            }

            #eval "require RemoteShell::$rsh_extension";
            eval "require xCAT::$rsh_extension";

            $rsh_config{'command'} = "$$options{'pre-command'}";
            my $tmp_env_file;
            my $rsp = {};
            if ($$options{'environment'})
            {

                $rsp->{data}->[0] = "TRACE: Environment option specified";
                $dsh_trace && (xCAT::MsgUtils->message("I", $rsp, $::CALLBACK));
                my %env_rcp_config = ();
                $tmp_env_file = POSIX::tmpnam . '.dsh';
                $rsh_config{'command'} .= ". $tmp_env_file ; ";

                $env_rcp_config{'src-file'}  = $$options{'environment'};
                $env_rcp_config{'dest-host'} = $$target_properties{'hostname'};
                $env_rcp_config{'dest-file'} = $tmp_env_file;
                $env_rcp_config{'dest-user'} = $$target_properties{'user'}
                  || $$options{'user'};

                my $env_rcp_command   = undef;
                my $env_rcp_extension = $rsh_extension;

                ($$target_properties{'type'} eq 'node')
                  && ($env_rcp_command = $ENV{'DSH_NODE_RCP'});

                if ($env_rcp_command)
                {
                    ($env_rcp_command =~ /\/rcp$/)
                      && ($env_rcp_extension = 'RSH');
                    ($env_rcp_command =~ /\/scp$/)
                      && ($env_rcp_extension = 'SSH');
                }

                #eval "require RemoteShell::$env_rcp_extension";
                eval "require xCAT::$env_rcp_extension";
                my $rcp             = "xCAT::$env_rcp_extension";
                my @env_rcp_command =
                  $rcp->remote_copy_command(\%env_rcp_config);

                $rsp->{data}->[0] =
                  "TRACE:Environment: Exporting File.@env_rcp_command ";
                $dsh_trace && (xCAT::MsgUtils->message("I", $rsp, $::CALLBACK));

                my @env_rcp_process =
                  xCAT::DSHCore->fork_no_output($user_target, @env_rcp_command);
                waitpid($env_rcp_process[0], undef);
            }
            my $tmp_cmd_file;
            if ($$options{'execute'})
            {

                $rsp->{data}->[0] = "TRACE: Execute option specified.";
                $dsh_trace && (xCAT::MsgUtils->message("I", $rsp, $::CALLBACK));

                my %exe_rcp_config = ();
                $tmp_cmd_file = POSIX::tmpnam . ".dsh";

                my ($exe_cmd, @args) = @{$$options{'execute'}};
                my $chmod_cmd = "";
                $rsh_config{'command'} .=
                  "$chmod_cmd $tmp_cmd_file @args$$options{'post-command'}";
                $exe_rcp_config{'src-file'}  = $exe_cmd;
                $exe_rcp_config{'dest-host'} = $$target_properties{'hostname'};
                $exe_rcp_config{'dest-file'} = $tmp_cmd_file;
                $exe_rcp_config{'dest-user'} = $$target_properties{'user'}
                  || $$options{'user'};

                my $exe_rcp_command   = undef;
                my $exe_rcp_extension = $rsh_extension;

                ($$target_properties{'type'} eq 'node')
                  && ($exe_rcp_command = $ENV{'DSH_NODE_RCP'});

                if ($exe_rcp_command)
                {
                    ($exe_rcp_command =~ /\/rcp$/)
                      && ($exe_rcp_extension = 'RSH');
                    ($exe_rcp_command =~ /\/scp$/)
                      && ($exe_rcp_extension = 'SSH');
                }

                #eval "require RemoteShell::$exe_rcp_extension";
                eval "require xCAT::$exe_rcp_extension";
                my $rcp             = "xCAT::$exe_rcp_extension";
                my @exe_rcp_command =
                  $rcp->remote_copy_command(\%exe_rcp_config);

                $rsp->{data}->[0] =
                  "TRACE:Execute: Exporting File:@exe_rcp_command";
                $dsh_trace && (xCAT::MsgUtils->message("I", $rsp, $::CALLBACK));
                my @exe_rcp_process =
                  xCAT::DSHCore->fork_no_output($user_target, @exe_rcp_command);
                waitpid($exe_rcp_process[0], undef);
            }

            else
            {
                $rsh_config{'command'} .=
                  "$$options{'command'}$$options{'post-command'}";
            }
            if ($$options{'environment'})
            {
                $rsh_config{'command'} .= ";rm $tmp_env_file";
            }
            if ($$options{'execute'})
            {
                $rsh_config{'command'} .= ";rm $tmp_cmd_file";
            }

            #eval "require RemoteShell::$rsh_extension";
            eval "require xCAT::$rsh_extension";
            my $remoteshell = "xCAT::$rsh_extension";
            push @dsh_command,
              $remoteshell->remote_shell_command(\%rsh_config, $remote_shell);

        }

        my @process_info;

        my $rsp = {};
        $rsp->{data}->[0] = "Command name: @dsh_command";
        $dsh_trace && (xCAT::MsgUtils->message("I", $rsp, $::CALLBACK));

        $rsp->{data}->[0] = "dsh>  Remote_command_started $user_target";
        $$options{'monitor'} && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

        @process_info = xCAT::DSHCore->fork_output($user_target, @dsh_command);
        if ($process_info[0] == -2)
        {
            $rsp->{data}->[0] =
              "$user_target could not execute this command $dsh_command[0] - $$options{'command'} ,  $! ";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        }

        ($process_info[0] == -3) && (&handle_signal_dsh('INT', 1));

        if ($process_info[0] == -4)
        {

            $rsp->{data}->[0] = "Cannot redirect STDOUT, error= $!";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        }

        if ($process_info[0] == -5)
        {

            $rsp->{data}->[0] = "Cannot redirect STDERR, error= $!";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        }

        vec($$outfh_targets{'bitmap'}, fileno($process_info[1]), 1) = 1;
        vec($$errfh_targets{'bitmap'}, fileno($process_info[2]), 1) = 1;
        $$outfh_targets{fileno($process_info[1])} = $user_target;
        $$errfh_targets{fileno($process_info[2])} = $user_target;

        $$forked_process{$user_target} = \@process_info;
        $$targets_active{$user_target}++;
        $$pid_targets{$process_info[0]} = $user_target;
    }
}

#----------------------------------------------------------------------------

=head3
        buffer_output

        For a given list of targets with output available, this routine buffers
        output from the targets STDOUT pipe handles into buffers grouped by
        target name

        Arguments:
			$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$targets_active - hash table of currently active targets with output possibly available
        	$targets_finished - list of targets with all output processed and have completed execution
        	$targets_failed - list of targets that have unsuccessfully executed
        	$targets_buffered - hash table of buffers with output from active targets
        	$pid_targets - hash table of target names keyed by process ID
        	$forked_process - hash table of process information keyed by target name
        	$errfh_targets - hash table of STDERR pipe handles keyed by target name
        	$output_buffers - hash table of STDOUT buffers keyed by target name
        	$error_buffers - hash table of STDERR buffers keyed by target name
			$output_files - list of output file handles where output is to be written
			$error_files - list of error file handles where error output is to be written
			$select_err_fhs - list of currently available STDERR pipe handles

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub buffer_output
{
    my (
        $class,            $options,          $resolved_targets,
        $targets_active,   $targets_finished, $targets_failed,
        $targets_buffered, $pid_targets,      $forked_process,
        $outfh_targets,    $output_buffers,   $error_buffers,
        $output_files,     $error_files,      $select_out_fhs
      )
      = @_;

    foreach my $select_out_fh (@$select_out_fhs)
    {

        my $user_target       = $$outfh_targets{$select_out_fh};
        my $output_fh         = $$forked_process{$user_target}[1];
        my $error_fh          = $$forked_process{$user_target}[2];
        my $target_properties = $$resolved_targets{$user_target};

        if (!$$output_buffers{$user_target})
        {
            my @buffer = ();
            $$output_buffers{$user_target} = \@buffer;
        }

        if (!$$output_buffers{"${user_target}_tmp"})
        {
            my @buffer_tmp = ();
            $$output_buffers{"${user_target}_tmp"} = \@buffer_tmp;
        }

        my $eof_output =
          xCAT::DSHCore->pipe_handler_buffer(
                                         $target_properties, $output_fh, 4096,
                                         "$user_target: ",
                                         $$output_buffers{"${user_target}_tmp"},
                                         $$output_buffers{$user_target}
                                         );

        if ($eof_output)
        {
            vec($$outfh_targets{'bitmap'}, fileno($output_fh), 1) = 0;
            delete $$outfh_targets{$user_target};

            if (++$$targets_active{$user_target} == 3)

            {
                my $exit_code;
                my $pid = waitpid($$forked_process{$user_target}[0], 0);
                if ($pid == -1)
                {    # no child waiting ignore
                    my $rsp = {};
                    $rsp->{data}->[0] = "waitpid call PID=$pid. Ignore.";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                }
                else
                {    # check return code
                    $exit_code = $? >> 8;
                }
                if (scalar(@{$$output_buffers{$user_target}}) == 1)
                {
                    ($$output_buffers{$user_target}[0] eq '')
                      && (@{$$output_buffers{$user_target}} = ());
                }

                if (scalar(@{$$error_buffers{$user_target}}) == 1)
                {
                    ($$error_buffers{$user_target}[0] eq '')
                      && (@{$$error_buffers{$user_target}} = ());
                }

                my %exit_status = (
                                 'exit-code' => $exit_code,
                                 'target-rc' => $$target_properties{'target-rc'}
                                 );
                $$targets_buffered{$user_target} = \%exit_status;

                delete $$targets_active{$user_target};
                delete $$pid_targets{$$forked_process{$user_target}[0]};

                close $output_fh;
                close $error_fh;
            }
        }
    }
}

#----------------------------------------------------------------------------

=head3
        buffer_error

        For a given list of targets with output available, this routine buffers
        output from the targets STDERR pipe handles into buffers grouped by
        target name

        Arguments:
            $options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$targets_active - hash table of currently active targets with output possibly available
        	$targets_finished - list of targets with all output processed and have completed execution
        	$targets_failed - list of targets that have unsuccessfully executed
        	$targets_buffered - hash table of buffers with output from active targets
        	$pid_targets - hash table of target names keyed by process ID
        	$forked_process - hash table of process information keyed by target name
        	$errfh_targets - hash table of STDERR pipe handles keyed by target name
        	$output_buffers - hash table of STDOUT buffers keyed by target name
        	$error_buffers - hash table of STDERR buffers keyed by target name
			$output_files - list of output file handles where output is to be written
			$error_files - list of error file handles where error output is to be written
			$select_err_fhs - list of currently available STDERR pipe handles

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub buffer_error
{
    my (
        $class,            $options,          $resolved_targets,
        $targets_active,   $targets_finished, $targets_failed,
        $targets_buffered, $pid_targets,      $forked_process,
        $errfh_targets,    $output_buffers,   $error_buffers,
        $output_files,     $error_files,      $select_err_fhs
      )
      = @_;

    foreach my $select_err_fh (@$select_err_fhs)
    {

        my $user_target       = $$errfh_targets{$select_err_fh};
        my $output_fh         = $$forked_process{$user_target}[1];
        my $error_fh          = $$forked_process{$user_target}[2];
        my $target_properties = $$resolved_targets{$user_target};

        if (!$$error_buffers{$user_target})
        {
            my @buffer = ();
            $$error_buffers{$user_target} = \@buffer;
        }

        if (!$$error_buffers{"${user_target}_tmp"})
        {
            my @buffer_tmp = ();
            $$error_buffers{"${user_target}_tmp"} = \@buffer_tmp;
        }

        my $eof_error =
          xCAT::DSHCore->pipe_handler_buffer(
                                          $target_properties, $error_fh, 4096,
                                          "$user_target: ",
                                          $$error_buffers{"${user_target}_tmp"},
                                          $$error_buffers{$user_target}
                                          );

        if ($eof_error)
        {
            vec($$errfh_targets{'bitmap'}, fileno($error_fh), 1) = 0;
            delete $$errfh_targets{$user_target};

            if (++$$targets_active{$user_target} == 3)
            {
                my $exit_code;
                my $pid = waitpid($$forked_process{$user_target}[0], 0);
                if ($pid == -1)
                {    # no child waiting
                    my $rsp = {};
                    $rsp->{data}->[0] = "waitpid call PID=$pid. Ignore.";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                }
                else
                {    # check return code
                    $exit_code = $? >> 8;
                }

                if (scalar(@{$$output_buffers{$user_target}}) == 1)
                {
                    ($$output_buffers{$user_target}[0] eq '')
                      && (@{$$output_buffers{$user_target}} = ());
                }

                if (scalar(@{$$error_buffers{$user_target}}) == 1)
                {
                    ($$error_buffers{$user_target}[0] eq '')
                      && (@{$$error_buffers{$user_target}} = ());
                }

                my %exit_status = (
                                 'exit-code' => $exit_code,
                                 'target-rc' => $$target_properties{'target-rc'}
                                 );
                $$targets_buffered{$user_target} = \%exit_status;

                delete $$targets_active{$user_target};
                delete $$pid_targets{$$forked_process{$user_target}[0]};

                close $output_fh;
                close $error_fh;
            }
        }
    }
}

#----------------------------------------------------------------------------

=head3
        stream_output

        For a given list of targets with output available, this routine writes
        output from the targets STDOUT pipe handles directly to STDOUT as soon
        as it is available from the target

        Arguments:
            $options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$targets_active - hash table of currently active targets with output possibly available
        	$targets_finished - list of targets with all output processed and have completed execution
        	$targets_failed - list of targets that have unsuccessfully executed
        	$targets_buffered - hash table of buffers with output from active targets
        	$pid_targets - hash table of target names keyed by process ID
        	$forked_process - hash table of process information keyed by target name
        	$outfh_targets - hash table of STDOUT pipe handles keyed by target name
        	$output_buffers - hash table of STDOUT buffers keyed by target name
			$output_files - list of error file handles where error output is to be written
			$select_out_fhs - list of currently available STDOUT pipe handles

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub stream_output
{
    my (
        $class,          $options,          $resolved_targets,
        $targets_active, $targets_finished, $targets_failed,
        $pid_targets,    $forked_process,   $outfh_targets,
        $output_buffers, $output_files,     $select_out_fhs
      )
      = @_;

    foreach my $select_out_fh (@$select_out_fhs)
    {

        my $user_target       = $$outfh_targets{$select_out_fh};
        my $output_fh         = $$forked_process{$user_target}[1];
        my $target_properties = $$resolved_targets{$user_target};

        if (!$$output_buffers{$user_target})
        {
            my @buffer = ();
            $$output_buffers{$user_target} = \@buffer;
        }

        my $eof_output =
          xCAT::DSHCore->pipe_handler(
                                      $options,
                                      $target_properties,
                                      $output_fh,
                                      4096,
                                      "$user_target: ",
                                      $$output_buffers{$user_target},
                                      @$output_files
                                      );

        if ($eof_output)
        {
            vec($$outfh_targets{'bitmap'}, fileno($output_fh), 1) = 0;
            delete $$outfh_targets{$user_target};

            my $rsp = {};
            if (++$$targets_active{$user_target} == 3)
            {
                my $exit_code;
                my $pid = waitpid($$forked_process{$user_target}[0], 0);
                if ($pid == -1)
                {    # no child waiting
                    $rsp->{data}->[0] = "waitpid call PID=$pid. Ignore.";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                }
                else
                {    # check return code
                    $exit_code = $? >> 8;
                }

                my $target_rc = $$target_properties{'target-rc'};

                if ($exit_code != 0)
                {
                    $rsp->{data}->[0] =
                      "$user_target remote shell had error code: $exit_code";
                    !$$options{'silent'}
                      && (xCAT::MsgUtils->message("E", $rsp, $::CALLBACK));

                    $rsp->{data}->[0] =
                      "dsh>  Remote_command_failed $user_target";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                    push @$targets_failed, $user_target;
                    push @{$dsh_target_status{'failed'}}, $user_target
                      if !$signal_interrupt_flag;

                }

                else
                {
                    if ($target_rc != 0)
                    {

                        $rsp->{data}->[0] =
                          " $user_target remote Command had return code: $$target_properties{'target-rc'} ";
                        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

                        my $rsp = {};
                        $rsp->{data}->[0] =
                          "dsh>  Remote_command_failed $user_target";
                        $$options{'monitor'}
                          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                        push @$targets_failed, $user_target;
                    }

                    elsif (!defined($target_rc))
                    {

                        $rsp->{data}->[0] =
                          " $user_target a return code run on this host was not received. ";
                        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

                        $rsp->{data}->[0] =
                          "dsh>  Remote_command_failed $user_target";
                        $$options{'monitor'}
                          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                        push @$targets_failed, $user_target;
                    }

                    else
                    {

                        $rsp->{data}->[0] =
                          "dsh>  Remote_command_successful $user_target";
                        $$options{'monitor'}
                          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                        push @$targets_finished, $user_target;
                    }
                }

                delete $$targets_active{$user_target};
                delete $$pid_targets{$$forked_process{$user_target}[0]};
            }

            close $output_fh;
        }
    }
}

#----------------------------------------------------------------------------

=head3
        stream_error

        For a given list of targets with output available, this routine writes
        output from the targets STDERR pipe handles directly to STDERR as soon
        as it is available from the target

        Arguments:
            $options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$targets_active - hash table of currently active targets with output possibly available
        	$targets_finished - list of targets with all output processed and have completed execution
        	$targets_failed - list of targets that have unsuccessfully executed
        	$targets_buffered - hash table of buffers with output from active targets
        	$pid_targets - hash table of target names keyed by process ID
        	$forked_process - hash table of process information keyed by target name
        	$errfh_targets - hash table of STDERR pipe handles keyed by target name
        	$error_buffers - hash table of STDERR buffers keyed by target name
			$error_files - list of error file handles where error output is to be written
			$select_err_fhs - list of currently available STDERR pipe handles

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub stream_error
{
    my (
        $class,          $options,          $resolved_targets,
        $targets_active, $targets_finished, $targets_failed,
        $pid_targets,    $forked_process,   $errfh_targets,
        $error_buffers,  $error_files,      $select_err_fhs
      )
      = @_;

    foreach my $select_err_fh (@$select_err_fhs)
    {

        my $user_target       = $$errfh_targets{$select_err_fh};
        my $error_fh          = $$forked_process{$user_target}[2];
        my $target_properties = $$resolved_targets{$user_target};

        if (!$$error_buffers{$user_target})
        {
            my @buffer = ();
            $$error_buffers{$user_target} = \@buffer;
        }

        my $eof_error =
          xCAT::DSHCore->pipe_handler(
                                      $options,
                                      $target_properties,
                                      $error_fh,
                                      4096,
                                      "$user_target: ",
                                      $$error_buffers{$user_target},
                                      @$error_files
                                      );

        if ($eof_error)
        {
            vec($$errfh_targets{'bitmap'}, fileno($error_fh), 1) = 0;
            delete $$errfh_targets{$user_target};

            my $rsp = {};
            if (++$$targets_active{$user_target} == 3)
            {
                my $exit_code;
                my $pid = waitpid($$forked_process{$user_target}[0], 0);
                if ($pid == -1)
                {    # no child waiting
                    $rsp->{data}->[0] = "waitpid call PID=$pid. Ignore.";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                }
                else
                {    # check return code
                    $exit_code = $? >> 8;
                }

                my $target_rc = $$target_properties{'target-rc'};

                if ($exit_code != 0)
                {
                    $rsp->{data}->[0] =
                      " $user_target remote shell had exit code $exit_code.";
                    !$$options{'silent'}
                      && (xCAT::MsgUtils->message("E", $rsp, $::CALLBACK));

                    $rsp->{data}->[0] =
                      "dsh>  Remote_command_failed $user_target";
                    $$options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                    push @$targets_failed, $user_target;
                    push @{$dsh_target_status{'failed'}}, $user_target
                      if !$signal_interrupt_flag;

                }

                else
                {
                    if ($target_rc != 0)
                    {

                        $rsp->{data}->[0] =
                          "$user_target remote command had return code $$target_properties{'target-rc'}";
                        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

                        $rsp->{data}->[0] =
                          "dsh>  Remote_command_failed $user_target";
                        $$options{'monitor'}
                          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                        push @$targets_failed, $user_target;
                    }

                    elsif (!defined($target_rc))
                    {

                        $rsp->{data}->[0] =
                          "A return code for the command run on $user_target was not received.";
                        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

                        $rsp->{data}->[0] =
                          "dsh>  Remote_command_failed $user_target";
                        $$options{'monitor'}
                          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                        push @$targets_failed, $user_target;
                    }

                    else
                    {

                        $rsp->{data}->[0] =
                          "dsh>  Remote_command_successful $user_target";
                        $$options{'monitor'}
                          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                        push @$targets_finished, $user_target;
                    }
                }

                delete $$targets_active{$user_target};
                delete $$pid_targets{$$forked_process{$user_target}[0]};
            }

            close $error_fh;
        }
    }
}

#----------------------------------------------------------------------------

=head3
        config_default_context

        Return the name of the default context to the caller

        Arguments:
			$options - options hash table describing dsh configuration options

        Returns:
        	The name of the default context

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub config_default_context
{
    my ($class, $options) = @_;

    if (!$$options{'context'})
    {
        my $contextdir = $::CONTEXT_DIR;
        $contextdir .= "XCAT.pm";
        if (-e "$contextdir")
        {
            require Context::XCAT;
            (XCAT->valid_context) && ($$options{'context'} = 'XCAT');
        }

        $$options{'context'} = $ENV{'DSH_CONTEXT'}
          || $$options{'context'}
          || 'DSH';
    }
}

#----------------------------------------------------------------------------

=head3
        config_dcp

        This routine configures the command environment for an instance of the
        dcp command based on the configuration of the DSH Utilities environment
        defined in $options.

        Arguments:
            $options - options hash table describing dsh configuration options

        Returns:
        	Number of configuration errors

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub config_dcp
{
    my ($class, $options) = @_;

    my $result = 0;

    $$options{'trace'} && $dsh_trace++;

    $dsh_trace && xCAT::DSHCLI->show_dsh_config($options);

    xCAT::DSHCLI->config_default_context($options);
    my $rsp = {};

    if (!(-e "$::CONTEXT_DIR$$options{'context'}.pm"))
    {

        $rsp->{data}->[0] = "Invalid context specified:$$options{'context'}.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        return ++$result;
    }

    my $rsp = {};
    $rsp->{data}->[0] = "TRACE:Default context is $$options{'context'}.";
    $dsh_trace
      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    !$$options{'node-rcp'}
      && (   $$options{'node-rcp'} = $ENV{'DCP_NODE_RCP'}
          || $ENV{'DCP_COPY_CMD'}
          || undef);

    if ($$options{'node-rcp'})
    {
        my %node_rcp        = ();
        my @remotecopy_list = split ',', $$options{'node-rcp'};

        foreach my $context_remotecopy (@remotecopy_list)
        {
            my ($context, $remotecopy) = split ':', $context_remotecopy;

            if (!$remotecopy)
            {
                $remotecopy = $context;
                scalar(@dsh_valid_contexts) || xCAT::DSHCLI->get_valid_contexts;

                foreach my $context (@dsh_valid_contexts)
                {
                    !$node_rcp{$context}
                      && ($node_rcp{$context} = $remotecopy);
                }
            }

            else
            {
                $node_rcp{$context} = $remotecopy;
            }
        }

        $$options{'node-rcp'} = \%node_rcp;
    }

    $$options{'fanout'} = $$options{'fanout'} || $ENV{'DSH_FANOUT'} || 64;

    my $rsp = {};
    $rsp->{data}->[0] = "TRACE:Fanout Value is $$options{'fanout'}.";
    $dsh_trace
      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    $$options{'timeout'} = $$options{'timeout'} || $ENV{'DSH_TIMEOUT'} || undef;

    $rsp->{data}->[0] = "TRACE:Timeout Value is $$options{'timeout'}.";
    $dsh_trace
      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    if (   (!$$options{'nodes'})
        && ($ENV{'DSH_NODE_LIST'} || $ENV{'DSH_LIST'}))
    {
        require Context::DSH;

        my $node_list_file = $ENV{'DSH_NODE_LIST'}
          || $ENV{'DSH_LIST'}
          || $ENV{'WCOLL'};
        my $node_list = DSH->read_target_file($node_list_file);
        $$options{'nodes'} = join ',', @$node_list;
    }

    elsif (!$$options{'nodes'} && $ENV{'DSH_NODE_LIST'})
    {
        require Context::DSH;

        my $node_list_file = $ENV{'DSH_NODE_LIST'};
        my $node_list      = DSH->read_target_file($node_list_file);
        $$options{'nodes'} = join ',', @$node_list;
    }

    $$options{'node-options'} = $$options{'node-options'}
      || $ENV{'DCP_NODE_OPTS'}
      || $ENV{'DSH_REMOTE_OPTS'};

    if ($$options{'node-options'})
    {
        my %node_options    = ();
        my @remoteopts_list = split ',', $$options{'node-options'};

        foreach my $context_remoteopts (@remoteopts_list)
        {
            my ($context, $remoteopts) = split ':', $context_remoteopts;

            if (!$remoteopts)
            {
                $remoteopts = $context;
                scalar(@dsh_valid_contexts) || xCAT::DSHCLI->get_valid_contexts;

                foreach my $context (@dsh_valid_contexts)
                {
                    !$node_options{$context}
                      && ($node_options{$context} = $remoteopts);
                }
            }

            else
            {
                $node_options{$context} = $remoteopts;
            }
        }

        $$options{'node-options'} = \%node_options;
    }

    if ($$options{'pull'} && !(-d $$options{'target'}))
    {
        $rsp->{data}->[0] =
          "Cannot copy to target $$options{'target'}. Directory does not exist.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        return ++$result;
    }

    return 0;
}

#----------------------------------------------------------------------------

=head3
        config_dsh

        This routine configures the command environment for an instance of the
        dsh command based on the configuration of the DSH Utilities environment
        defined in $options.

        Arguments:
            $options - options hash table describing dsh configuration options

        Returns:
        	Number of configuration errors

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub config_dsh
{
    my ($class, $options) = @_;

    my $result = 0;

    $$options{'stats'} = $$options{'monitor'};

    if ($$options{'stats'})
    {
        $dsh_stats{'start-time'} = localtime();

        $dsh_stats{'user'} = $$options{'user'} || `whoami`;
        chomp($dsh_stats{'user'});
        $dsh_stats{'successful-targets'}     = ();
        $dsh_stats{'failed-targets'}         = ();
        $dsh_stats{'report-status-messages'} = ();
        $dsh_stats{'specified-targets'}      = ();
        scalar(@dsh_valid_contexts) || xCAT::DSHCLI->get_valid_contexts;
        push @{$dsh_stats{'valid-contexts'}}, @dsh_valid_contexts;

        foreach my $context (@dsh_valid_contexts)
        {
            $dsh_stats{'specified-targets'}{$context} = ();
            $dsh_stats{'specified-targets'}{$context}{'nodes'} = ();
        }

        $$options{'command-name'} = $$options{'command-name'} || 'Unspecified';
        $$options{'command-description'} = $$options{'command-description'}
          || '';

    }

    $$options{'trace'} && $dsh_trace++;

    $dsh_trace && xCAT::DSHCLI->show_dsh_config;

    my $rsp = {};
    xCAT::DSHCLI->config_default_context($options);
    my $test = " $::CONTEXT_DIR$$options{'context'}.pm";
    if (!(-e "$::CONTEXT_DIR$$options{'context'}.pm"))
    {

        $rsp->{data}->[0] = "Invalid context specified: $$options{'context'}";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        return ++$result;
    }

    $rsp->{data}->[0] = "TRACE:Default context is $$options{'context'}";
    $dsh_trace
      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    # Check devicetype attr and try to load device configuration
    $$options{'devicetype'} = $$options{'devicetype'}
      || $ENV{'DEVICETYPE'}
      || undef;
    if ($$options{'devicetype'})
    {
        $ENV{'DEVICETYPE'} = $$options{'devicetype'};
        my $devicepath = $$options{'devicetype'};
        $devicepath =~ s/::/\//g;
        $devicepath = "/var/opt/xcat/" . $devicepath . "/config";

        # Get configuration from $::XCATDEVCFGDIR
        if (-e $devicepath)
        {
            my $deviceconf = get_config($devicepath);

            # Get all dsh section configuration
            foreach my $entry (keys %{$$deviceconf{'xdsh'}})
            {
                my $value = $$deviceconf{'xdsh'}{$entry};
                if ($value)
                {
                    $$options{$entry} = $value;
                }

            }
        }
        else
        {
            $rsp->{data}->[0] = "EMsgMISSING_DEV_CFG";
            xCAT::MsgUtils->message('E', $rsp, $::CALLBACK);
        }
    }

    !$$options{'node-rsh'}
      && (   $$options{'node-rsh'} = $ENV{'DSH_NODE_RSH'}
          || $ENV{'DSH_REMOTE_CMD'}
          || undef);

    $rsp->{data}->[0] = "TRACE:Node RSH is $$options{'node-rsh'}";
    $dsh_trace
      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    my %node_rsh_defaults = ();

    scalar(@dsh_valid_contexts) || xCAT::DSHCLI->get_valid_contexts;

    foreach my $context (@dsh_valid_contexts)
    {
        eval "require Context::$context";
        my $defaults = $context->context_defaults;
        $node_rsh_defaults{$context} = $$defaults{'NodeRemoteShell'}
          || $$defaults{'RemoteShell'};
    }

    $$options{'node-rsh-defaults'} = \%node_rsh_defaults;

    my %node_rsh = ();

    if ($$options{'node-rsh'})
    {

        my @remoteshell_list = split ',', $$options{'node-rsh'};

        foreach my $context_remoteshell (@remoteshell_list)
        {
            my ($context, $remoteshell) = split ':', $context_remoteshell;

            if (!$remoteshell)
            {
                $remoteshell = $context;
                !$node_rsh{'none'} && ($node_rsh{'none'} = $remoteshell);
            }

            else
            {
                !$node_rsh{$context} && ($node_rsh{$context} = $remoteshell);
            }
        }
    }

    $$options{'node-rsh'} = \%node_rsh;

    $$options{'environment'} = $$options{'environment'}
      || $ENV{'DSH_ENVIRONMENT'}
      || undef;

    if ($$options{'environment'} && (-z $$options{'environment'}))
    {
        $rsp->{data}->[0] = "File: $$options{'environment'} is empty.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        $$options{'environment'} = undef;
    }

    $$options{'fanout'} = $$options{'fanout'} || $ENV{'DSH_FANOUT'} || 64;

    $rsp->{data}->[0] = "TRACE: Fanout value is $$options{'fanout'}.";
    $dsh_trace
      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    $$options{'syntax'} = $$options{'syntax'} || $ENV{'DSH_SYNTAX'} || undef;

    if (
        defined($$options{'syntax'})
        && (   ($$options{'syntax'} ne 'csh')
            && ($$options{'syntax'} ne 'ksh'))
      )
    {
        $rsp->{data}->[0] =
          "Incorrect argument \"$$options{'syntax'}\" specified on -S flag. ";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        return ++$result;
    }

    my $env_set    = 'export';
    my $env_assign = '=';

    if ($$options{'syntax'} eq 'csh')
    {
        $env_set    = 'setenv';
        $env_assign = ' ';
    }

    my $path_set;
    $ENV{'DSH_PATH'}
      && ($path_set = "$env_set PATH$env_assign$ENV{'DSH_PATH'};");

    $$options{'timeout'} = $$options{'timeout'} || $ENV{'DSH_TIMEOUT'} || undef;

    $rsp->{data}->[0] = "TRACE: Timeout value is $$options{'timeout'} ";
    $dsh_trace
      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

    # Check if $$options{'pre-command'} has been overwritten
    if (!$$options{'pre-command'})
    {

        # Set a default PATH
        $$options{'pre-command'} = $path_set;

        if (!$$options{'no-locale'})
        {
            my @output = `/usr/bin/locale`;
            chomp(@output);

            my @settings = ();
            !($$options{'syntax'} eq 'csh') && (push @settings, $env_set);

            foreach my $line (@output)
            {
                $line =~ s/=/$env_assign/;

                if ($$options{'syntax'} eq 'csh')
                {
                    push @settings, "$env_set $line;";
                }

                else
                {
                    push @settings, $line;
                }
            }

            if ($$options{'syntax'} eq 'csh')
            {
                push @settings, "$env_set PERL_BADLANG${env_assign}0;";
            }

            else
            {
                push @settings, "PERL_BADLANG${env_assign}0";
            }

            my $locale_settings = join ' ', @settings;
            !($$options{'syntax'} eq 'csh') && ($locale_settings .= ' ; ');

            $$options{'pre-command'} .= $locale_settings;
        }
    }
    else
    {
        $$options{'pre-command'} = '';
    }

    # Check if $$options{'post-command'} has been overwritten.
    if (!$$options{'post-command'})
    {
        if ($$options{'syntax'} eq 'csh')
        {
            $$options{'post-command'} =
              "; $env_set DSH_TARGET_RC$env_assign\$status; echo \":DSH_TARGET_RC=\${DSH_TARGET_RC}:\"";
        }

        else
        {
            $$options{'post-command'} =
              "; $env_set DSH_TARGET_RC$env_assign\$?; echo \":DSH_TARGET_RC=\${DSH_TARGET_RC}:\"";
        }

        $$options{'exit-status'}
          && ($$options{'post-command'} .=
              ' ; echo "Remote_command_rc = $DSH_TARGET_RC"');
    }
    else
    {

        # post-command is overwritten by user , set env $::USER_POST_CMD
        $::USER_POST_CMD = 1;
        if ($$options{'post-command'} =~ /NULL/)
        {
            $$options{'post-command'} = '';
        }
        else
        {

            # $::DSH_EXIT_STATUS ony can be used in DSHCore::pipe_handler_buffer
            # and DSHCore::pipe_handler
            $$options{'exit-status'}
              && ($::DSH_EXIT_STATUS = 1);
            $$options{'post-command'} = ";$$options{'post-command'}";

            # Append "DSH_RC" keyword to mark output
            $$options{'post-command'} = "$$options{'post-command'};echo DSH_RC";
        }
    }

    if (
        !$$options{'nodes'}
        && (   $ENV{'DSH_NODE_LIST'}
            || $ENV{'DSH_LIST'})
      )
    {
        require Context::DSH;

        my $node_list_file = $ENV{'DSH_NODE_LIST'}
          || $ENV{'DSH_LIST'}
          || $ENV{'WCOLL'};
        my $node_list = DSH->read_target_file($node_list_file);
        $$options{'nodes'} = join ',', @$node_list;
    }

    elsif (!$$options{'nodes'} && $ENV{'DSH_NODE_LIST'})
    {
        require Context::DSH;

        my $node_list_file = $ENV{'DSH_NODE_LIST'};
        my $node_list      = DSH->read_target_file($node_list_file);
        $$options{'nodes'} = join ',', @$node_list;
    }

    $$options{'node-options'} = $$options{'node-options'}
      || $ENV{'DSH_NODE_OPTS'}
      || $ENV{'DSH_REMOTE_OPTS'};

    if ($$options{'node-options'})
    {
        my %node_options    = ();
        my @remoteopts_list = split ',', $$options{'node-options'};

        foreach my $context_remoteopts (@remoteopts_list)
        {
            my ($context, $remoteopts) = split ':', $context_remoteopts;

            if (!$remoteopts)
            {
                $remoteopts = $context;
                scalar(@dsh_valid_contexts) || xCAT::DSHCLI->get_valid_contexts;

                foreach my $context (@dsh_valid_contexts)
                {
                    !$node_options{$context}
                      && ($node_options{$context} = $remoteopts);
                }
            }

            else
            {
                $node_options{$context} = $remoteopts;
            }
        }

        $$options{'node-options'} = \%node_options;
    }

    if ($$options{'execute'})
    {
        my @exe_command = split ' ', $$options{'command'};
        $$options{'execute'} = \@exe_command;

        if (!(-e $exe_command[0]))
        {

            $rsp->{data}->[0] = "File $exe_command[0] does not exist";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
            return ++$result;
        }

        if (-z $exe_command[0])
        {

            $rsp->{data}->[0] = "File $exe_command[0] is empty.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
            return ++$result;
        }

        if (!(-x $exe_command[0]))
        {

            $rsp->{data}->[0] = "File $exe_command[0] is not executable.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
            return ++$result;
        }
    }

    return 0;
}

#----------------------------------------------------------------------------

=head3
        config_signals_dsh

        Configures the signal handling routines for each system signal
        and configures which signals should be restored as define in the
        DSH environment options.

        Arguments:
        	$options - options hash table describing dsh configuration options

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub config_signals_dsh
{
    my ($class, $options) = @_;

    $SIG{'STOP'} = 'DEFAULT';
    $SIG{'CONT'} = 'DEFAULT';
    $SIG{'TSTP'} = 'DEFAULT';

    $SIG{'TERM'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'QUIT'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'INT'}  = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'ABRT'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'ALRM'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'FPE'}  = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'ILL'}  = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'PIPE'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'SEGV'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'USR1'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'USR2'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'TTIN'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'TTOU'} = 'xCAT::DSHCLI::handle_signal_dsh';
    $SIG{'BUS'}  = 'xCAT::DSHCLI::handle_signal_dsh';

    my @ignore_signals = split /,/, $$options{'ignore-signal'};

    foreach my $signal (@ignore_signals)
    {

        if (   ($signal ne 'STOP')
            && ($signal ne 'CONT')
            && ($signal ne 'TSTP'))
        {

            $SIG{$signal} = 'IGNORE';
        }

    }
}

#----------------------------------------------------------------------------

=head3
        handle_signal_dsh

        Signal handling routine for an instance of the dsh command.  Depending
        on the state of dsh execution and report configuraion, this routine
        properly writes reports and output files if a termination signal is recieved

        Arguments:
        	$signal - termination signal to handle
        	$fatal - 1 if signal is fatal, 0 otherwise

        Returns:
        	None

        Globals:
        	$dsh_execution_state - current state of dsh execution

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub handle_signal_dsh
{
    my ($signal, $fatal_error) = @_;

    my $DSH_STATE_BEGIN                   = 0;
    my $DSH_STATE_INIT_STARTED            = 1;
    my $DSH_STATE_INIT_COMPLETE           = 2;
    my $DSH_STATE_TARGET_RESOLVE_COMPLETE = 3;
    my $DSH_STATE_REMOTE_EXEC_STARTED     = 4;
    my $DSH_STATE_REMOTE_EXEC_COMPLETE    = 5;

    my $rsp = {};
    if ($dsh_exec_state == $DSH_STATE_BEGIN)
    {
        $rsp->{data}->[0] =
          "Command execution ended prematurely due to a previous error or stop request from the user.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        exit(1);
    }

    elsif ($dsh_exec_state == $DSH_STATE_INIT_STARTED)
    {
        $rsp->{data}->[0] =
          "Command execution ended prematurely due to a previous error or stop request from the user.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

        exit(1);
    }

    elsif ($dsh_exec_state == $DSH_STATE_INIT_COMPLETE)
    {
        if ($$dsh_options{'stats'})
        {
            $dsh_stats{'exec-state'} = $dsh_exec_state;
            $dsh_stats{'end-time'}   = localtime();
        }

        if (@{$dsh_target_status{'waiting'}})
        {
            foreach my $user_target (@{$dsh_target_status{'waiting'}})
            {
                if ($fatal_error)
                {

                    $rsp->{data}->[0] =
                      "Running the command on $user_target has been cancelled due to unrecoverable error.  The command was never sent to the host.";
                    xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
                }

                else
                {

                    $rsp->{data}->[0] =
                      "xdsh>  Remote_command_cancelled $user_target";
                    $$dsh_options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                }

                push @{$dsh_target_status{'canceled'}}, $user_target;
            }
        }

        $rsp->{data}->[0] =
          "Running commands have been cancelled due to unrecoverable error or stop request by user.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

        if ($$dsh_options{'stats'})
        {
            my @empty_targets = ();

            $dsh_stats{'successful-targets'} = \@empty_targets;
            $dsh_stats{'failed-targets'}     = \@empty_targets;
            $dsh_stats{'canceled-targets'}   = $dsh_target_status{'canceled'};
        }

        $rsp->{data}->[0] = "dsh>  Dsh_remote_execution_completed.";
        $$dsh_options{'monitor'}
          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

        exit(1);

    }

    elsif ($dsh_exec_state == $DSH_STATE_TARGET_RESOLVE_COMPLETE)
    {
        if ($$dsh_options{'stats'})
        {
            $dsh_stats{'exec-state'} = $dsh_exec_state;
            $dsh_stats{'end-time'}   = localtime();
        }

        if (@{$dsh_target_status{'waiting'}})
        {
            foreach my $user_target (@{$dsh_target_status{'waiting'}})
            {
                if ($fatal_error)
                {

                    $rsp->{data}->[0] =
                      "$user_target: running of the command on this host has been cancelled due to unrecoverable error.\n The command was never sent to the host.";
                    xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                }

                else
                {

                    $rsp->{data}->[0] =
                      "$user_target: running of the command on this host has been cancelled due to unrecoverable error or stop request by user.\n The command was never sent to the host.";
                    xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                    $rsp->{data}->[0] =
                      "xdsh>  Remote_command_cancelled $user_target";
                    $$dsh_options{'monitor'}
                      && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                }

                push @{$dsh_target_status{'canceled'}}, $user_target;
            }
        }

        @{$dsh_target_status{'waiting'}} = ();

        $rsp->{data}->[0] =
          "Command execution ended prematurely due to a previous unrecoverable error or stop by user.\n No commands were executed on any host.";

        if ($$dsh_options{'stats'})
        {
            my @empty_targets = ();

            $dsh_stats{'successful-targets'} = \@empty_targets;
            $dsh_stats{'failed-targets'}     = \@empty_targets;
            $dsh_stats{'canceled-targets'}   = $dsh_target_status{'canceled'};
        }

        $rsp->{data}->[0] = "xdsh>  Dsh_remote_execution_completed";
        $$dsh_options{'monitor'}
          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

        exit(1);
    }

    elsif ($dsh_exec_state == $DSH_STATE_REMOTE_EXEC_STARTED)
    {
        if ($$dsh_options{'stats'})
        {
            $dsh_stats{'exec-state'} = $dsh_exec_state;
            $dsh_stats{'end-time'}   = localtime();
        }

        my $targets_active      = $dsh_target_status{'active'};
        my @targets_active_list = keys(%$targets_active);

        if (@targets_active_list)
        {
            $rsp->{data}->[0] =
              "Caught SIG$signal - terminating the child processes.";
            !$$dsh_options{'stats'}
              && xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

            my $target_signal = $signal;
            my $last_error    = $!;

            if ($signal ne 'QUIT' && $signal ne 'INT' && $signal ne 'TERM')
            {
                $target_signal = 'TERM';
                $SIG{'TERM'} = 'IGNORE';
            }

            $SIG{$signal} = 'DEFAULT';

            foreach my $user_target (@targets_active_list)
            {
                if ($$dsh_options{'stats'})
                {
                    if ($fatal_error)
                    {

                        $rsp->{data}->[0] =
                          "Running the command on $user_target has been interrupted due to unrecoverable error.  The command may not have completed successfully.";
                        xCAT::MsgUtils->message("V", $rsp, $::CALLBACK);
                    }

                    else
                    {

                        $rsp->{data}->[0] =
                          "Running the command on $user_target has been interrupted due to unrecoverable error or stop request by the user.  The command may not have completed successfully.";
                        xCAT::MsgUtils->message("V", $rsp, $::CALLBACK);
                    }
                }

                my $target_pid = $$dsh_forked_process{$user_target}[0];
                kill $target_signal, $target_pid;
                push @{$dsh_target_status{'failed'}}, $user_target;
                $signal_interrupt_flag = 1;
            }

            $! = $last_error;
        }

        # if 2 input then this was a timeout on one process, we do
        # not want to remove all the rest
        if ($fatal_error != 2)
        {    # remove the waiting processes
            if (@{$dsh_target_status{'waiting'}})
            {
                foreach my $user_target (@{$dsh_target_status{'waiting'}})
                {
                    if ($fatal_error)
                    {

                        $rsp->{data}->[0] =
                          "Running the command on $user_target has been cancelled due to unrecoverable error.  The command was never sent to the host.";
                        xCAT::MsgUtils->message("V", $rsp, $::CALLBACK);
                    }

                    else
                    {

                        $rsp->{data}->[0] =
                          "Running the command on $user_target has been cancelled due to unrecoverable error or stop request by the user.  The command was never sent to the host.";
                        xCAT::MsgUtils->message("V", $rsp, $::CALLBACK);

                        $rsp->{data}->[0] =
                          "dsh>  Remote_command_cancelled $user_target";
                        $$dsh_options{'monitor'}
                          && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
                    }

                    push @{$dsh_target_status{'canceled'}}, $user_target;
                }
            }

            @{$dsh_target_status{'waiting'}} = ();

            $rsp->{data}->[0] =
              "Command execution ended prematurely due to a previous unrecoverable error or stop request by the user.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        }    #end fatal_error != 2
        if ($$dsh_options{'stats'})
        {
            my @empty_targets = ();

            $dsh_stats{'successful-targets'} = $dsh_target_status{'finished'};
            $dsh_stats{'failed-targets'}     = $dsh_target_status{'failed'};
            $dsh_stats{'canceled-targets'}   = $dsh_target_status{'canceled'};
        }

        return;
    }

    elsif ($dsh_exec_state == $DSH_STATE_REMOTE_EXEC_COMPLETE)
    {
        if ($$dsh_options{'stats'})
        {
            $dsh_stats{'exec-state'} = $dsh_exec_state;
            $dsh_stats{'end-time'}   = localtime();
        }

        $rsp->{data}->[0] =
          "Running the command  stopped due to unrecoverable error or stop request by the user.";
        xCAT::MsgUtils->message("V", $rsp, $::CALLBACK);

        return;
    }

    else
    {
        $rsp->{data}->[0] =
          "Running the command  stopped due to unrecoverable error or stop request by the user.";
        xCAT::MsgUtils->message("V", $rsp, $::CALLBACK);
        exit(1);
    }
}

#----------------------------------------------------------------------------

=head3
        resolve_targets

        Main target resolution routine.  This routine calls calls all appropriate
        target resolution routines to resolve target information in the
        dsh command environment.  Currently the routine delegates resolution to
        resolve_nodes.

        Arguments:
        	$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$unresolved_targets - hash table of unresolved targets and target properties
        	$context_targets - hash table of targets grouped by context name

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub resolve_targets
{
    my ($class, $options, $resolved_targets, $unresolved_targets,
        $context_targets)
      = @_;

    $$options{'nodes'}
      && xCAT::DSHCLI->resolve_nodes($options,            $resolved_targets,
                                     $unresolved_targets, $context_targets);
}

#----------------------------------------------------------------------------

=head3
        resolve_nodes

        For a given list of contexts and node names, build a list of
        nodes defined and augment the list with context node information.

        Arguments:
        	$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$unresolved_targets - hash table of unresolved targets and target properties
        	$context_targets - hash table of targets grouped by context name

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub resolve_nodes
{
    my ($class, $options, $resolved_targets, $unresolved_targets,
        $context_targets)
      = @_;

    my @node_list = ();
    @node_list = split ',', $$options{'nodes'};

    foreach my $context_node (@node_list)
    {
        my ($context, $node) = split ':', $context_node;
        !$node
          && (($node = $context) && ($context = $$options{'context'}));

        push @{$dsh_stats{'specified-targets'}{$context}{'nodes'}}, $node;
    }

    xCAT::DSHCLI->_resolve_nodes($options, $resolved_targets,
                                 $unresolved_targets, $context_targets,
                                 @node_list);
}

#----------------------------------------------------------------------------

=head3
        _resolve_nodes

        Wrapper routine for resolve_all_nodes, resolve_nodes and


        Arguments:
            $options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties
        	$unresolved_targets - hash table of unresolved targets and relevant properties
			$context_targets - hash table of targets grouped by context name
			@nodes - a list of nodes to resolve

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub _resolve_nodes
{

    my ($class, $options, $resolved_targets, $unresolved_targets,
        $context_targets, @nodes)
      = @_;

    my %resolved_nodes   = ();
    my %unresolved_nodes = ();

    # this build the resolved nodes hash
    # bypasses the old dsh resolution code
    # unresolved nodes will be determined when the remote shell runs
    xCAT::DSHCLI->bld_resolve_nodes_hash($options, \%resolved_nodes, @nodes);

    foreach my $user_node (keys(%resolved_nodes))
    {
        my $node_properties = $resolved_nodes{$user_node};

        $$node_properties{'type'} = 'node';

        eval "require Context::$$node_properties{'context'}";
        my $result =
          $$node_properties{'context'}->resolve_node($node_properties);

        $result && ($$resolved_targets{$user_node} = $node_properties);
    }
}

#---------------------------------------------------------------------------

=head3
        resolve_nodes_hash

        Builds the resolved nodes hash.

        Arguments:
       	$options - options hash table describing dsh configuration options
       	$resolved_targets - hash table of resolved properties, keyed by target name
       	@target_list - input list of target names to resolve

        Returns:
        	None
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:

        Comments:

=cut

#---------------------------------------------------------------------------

sub bld_resolve_nodes_hash
{
    my ($class, $options, $resolved_targets, @target_list) = @_;

    foreach my $target (@target_list)
    {

        my $hostname = $target;
        my $ip_address;
        my $localhost;
        my $user;
        my $context = "XCAT";
        my %properties = (
                          'hostname'   => $hostname,
                          'ip-address' => $ip_address,
                          'localhost'  => $localhost,
                          'user'       => $user,
                          'context'    => $context,
                          'unresolved' => $target
                          );

        $$resolved_targets{"$target"} = \%properties;
    }

}

#----------------------------------------------------------------------------

=head3
        verify_targets

        Executes a verification test for all targets across all
        available contexts.  If a target cannot be verified it is removed
        from the $resolved_targets list

        Arguments:
        	$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved targets and target properties

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub verify_targets
{
    my ($class, $options, $resolved_targets) = @_;
    my @ping_list;
    foreach my $user_target (keys(%$resolved_targets))
    {

        my $hostname = $$resolved_targets{$user_target}{'hostname'};
        push @ping_list, $hostname;
    }

    if (@ping_list)
    {

        my @no_response = ();
        my $rsp         = {};
        $rsp->{data}->[0] =
          "TRACE:Verifying remaining targets with pping command.";
        $dsh_trace && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
        @no_response = xCAT::DSHCore->pping_hostnames(@ping_list);

        foreach my $hostname (@no_response)
        {
            my @targets = grep /$hostname/, keys(%$resolved_targets);

            foreach my $user_target (@targets)
            {
                $rsp->{data}->[0] =
                  "$user_target is not responding. No command will be issued to this host.";
                xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);

                $rsp->{data}->[0] =
                  "dsh>  Remote_command_cancelled $user_target";
                $$dsh_options{'monitor'}
                  && xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);

                push @{$dsh_target_status{'canceled'}}, $user_target;
                $$dsh_unresolved_targets{$user_target} =
                  $$resolved_targets{$user_target};
                delete $$resolved_targets{$user_target};
            }
        }
    }
}

#----------------------------------------------------------------------------

=head3
        get_available_contexts

        Returns a list of available contexts in the DSH environment

        Arguments:
        	None

        Returns:
        	A list of available contexts in the DSH environment

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub get_available_contexts
{
    opendir(DIR, $::CONTEXT_DIR);
    my @contexts =
      grep { ($_ ne '.') && ($_ ne '..') && ($_ =~ /\.pm$/) } readdir DIR;
    closedir DIR;

    chomp(@contexts);

    foreach my $context (@contexts)
    {
        $context =~ s/\.pm$//;

        push @dsh_available_contexts, $context;
    }
}

#----------------------------------------------------------------------------

=head3
        get_dsh_config

        Get the initial DSH configuration for all available contexts

        Arguments:
        	None

        Returns:
        	A hash table of configuration properties grouped by context

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub get_dsh_config
{
    scalar(@dsh_valid_contexts) || xCAT::DSHCLI->get_valid_contexts;

    my %dsh_config = ();
    foreach my $context (@dsh_valid_contexts)
    {
        $dsh_config{$context} = $context->context_properties;
    }

    return \%dsh_config;
}

#----------------------------------------------------------------------------

=head3
        get_dsh_defaults

        Get the default properties for all available contexts

        Arguments:
        	None

        Returns:
        	A hash table of default properties for each context

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------
sub get_dsh_defaults
{
    scalar(@dsh_valid_contexts) || xCAT::DSHCLI->get_valid_contexts;

    my %dsh_defaults = ();
    foreach my $context (@dsh_valid_contexts)
    {
        $dsh_defaults{$context} = $context->context_defaults;
    }

    return \%dsh_defaults;
}

#----------------------------------------------------------------------------

=head3
        get_valid_contexts

        Returns a list of valid contexts in the DSH environment.
        A valid context is one that is available in the DSH environment
        and whose valid_context routine returns 1

        Arguments:
        	None

        Returns:
        	A list of valid contexts

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------

sub get_valid_contexts
{
    scalar(@dsh_available_contexts) || xCAT::DSHCLI->get_available_contexts;
    @dsh_valid_contexts = ();

    foreach my $context (@dsh_available_contexts)
    {
        eval "require Context::$context";
        ($context->valid_context) && (push @dsh_valid_contexts, $context);
    }
}

#----------------------------------------------------------------------------

=head3
        util_bit_indexes

        Utility routine that converts a bit vector to a corresponding array
        of 1s and 0s

        Arguments:
        	None

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#----------------------------------------------------------------------------

sub util_bit_indexes
{
    my ($class, $vector, $bit) = @_;

    my @bit_indexes = ();
    my @bits        = split(//, unpack("b*", $vector));

    my $index = 0;
    while (@bits)
    {
        ((shift @bits) == $bit) && (push @bit_indexes, $index);
        $index++;
    }

    return @bit_indexes;
}

#-------------------------------------------------------------------------------

=head3
   check_valid_options

    Arguments:
        1 - %options
    Returns:
        1 - there are invalid options
        0 - options are all okay
    Globals:
        none
    Error:
        none
    Comments:
        none

=cut

#--------------------------------------------------------------------------------

sub check_valid_options
{
    my ($pkg, $options) = @_;

    if (scalar(@$options) > 0)
    {
        my @invalid_opts;
        my @valid_longnames = (
                               "continue",           "execute",
                               "fanout",             "help",
                               "user",               "monitor",
                               "nodes",              "node-options",
                               "node-rsh",           "stream",
                               "timeout",            "verify",
                               "exit-status",        "context",
                               "environment",        "ignore-sig",
                               "ignoresig",          "no-locale",
                               "nodegroups",         "silent",
                               "syntax",             "trace",
                               "version",            "command-name",
                               "commandName",        "command-description",
                               "commandDescription", "noFileWriting",
                               "preserve",           "node-rcp",
                               "pull",               "recursive"
                               );

        foreach my $opt (@$options)
        {
            my $tmp_opt = $opt;

            # remove any leading dash first
            $tmp_opt =~ s/^-*//;

            # if this is a long keyword...
            if (grep /^\Q$tmp_opt\E$/, @valid_longnames)
            {

                # there should be two leading dashs
                if ($opt !~ /^--\w+/)
                {
                    push @invalid_opts, $opt;
                }
            }
        }
        if (@invalid_opts)
        {
            my $rsp = {};
            my $badopts = join(',', @invalid_opts);
            $rsp->{data}->[0] = "Invalid options: $badopts";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3
    ignoreEnv


    Remove dsh environment variable.

    Arguments:
        envList: indicates the env vars that seperated by comma
    Returns:
        None
    Globals:
        @dsh_valie_env
    Error:
        none
    Example:
        if ( defined $options{'ignore_env'} ) { xCAT::DSHCLI->ignoreEnv( $options{'ignore_env'}); }
    Comments:
        none

=cut

#--------------------------------------------------------------------------------

sub ignoreEnv
{
    my ($class, $envList) = @_;
    my @env_not_valid = ();
    my @env_to_save = split ',', $envList;
    my $env;
    for $env (@env_to_save)
    {
        if (!grep /$env/, @dsh_valid_env)
        {
            push @env_not_valid, $env;
        }
    }
    if (scalar @env_not_valid > 0)
    {
        $env = join ",", @env_not_valid;
        my $rsp = {};
        $rsp->{data}->[0] = "Invalid Environment Variable: $env";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        return;
    }
    for $env (@dsh_valid_env)
    {
        if (!grep /$env/, @env_to_save)
        {
            delete $ENV{$env};
        }
    }
}

#--------------------------------------------------------------------------------

=head3
    isFdNumExceed

    check if file descriptor number exceed the max number in ulimit

    Arguments:
        $node_fd: indicates the file descriptor number required by each nodes
        $node_num: indicates the target nodes number
        $fanout: indicates the fanout value
        $remain_fd: indicates the file descriptor number remained by main processes
    Returns:
        0: file descriptor number does not exceed the max number
        1: file descriptor number exceed the max number
    Globals:
        None
    Error:
        None
    Example:
        xCAT::DSHCLI->check_fd_num(2, scalar( keys(%resolved_targets)), $$options{'fanout'})

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub isFdNumExceed
{

    my ($class, $node_fs, $node_num, $fanout) = @_;

    # Check the file descriptor number
    my $ulimit_cmd;
    my $ls_cmd;
    if ($^O =~ /^linux$/i)
    {
        $ulimit_cmd =
          "/bin/bash -c \'ulimit -n\'";    #ulimit is embedded in bash on linux
        $ls_cmd = '/bin/ls';
    }
    else
    {
        $ulimit_cmd = '/usr/bin/ulimit -n';    #On AIX
        $ls_cmd     = '/usr/bin/ls';
    }
    my $fdnum = xCAT::Utils->runcmd($ulimit_cmd);

    return 0 if ($fdnum =~ /\s*unlimited\s*/);

    if ($fdnum !~ /\s*\d+\s*/)                 #this should never happen
    {
        my $rsp = {};
        $rsp->{data}->[0] = "Unsupport ulimit return code!";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }

    my $pid = getpid;

    #    print "pid is $pid\n";

    #there are some pid will be remained by dsh main process, such STDIN, STDOUT and others,
    #it can be different on different system. So need to check them everytime
    my @remain_fds    = xCAT::Utils->runcmd($ls_cmd . " /proc/$pid/fd");
    my $remain_fd_num = scalar(@remain_fds);

    #    print "remain fd num is $remain_fd_num\n";
    #   sleep 1000;
    $node_num = ($node_num < $fanout) ? $node_num : $fanout;
    my $max_fd_req = $node_fs * $node_num;  #the max fd number required by nodes

    if (($max_fd_req + $remain_fd_num) > $fdnum)
    {
        my $rsp = {};
        $rsp->{data}->[0] = "Reached fdnum=  $fdnum";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }
    else
    {
        return 0;
    }
}

#-------------------------------------------------------------------------------

=head3
      usage_dsh

        puts out dsh usage message

        Arguments:
          None

        Returns:

        Globals:


        Error:
        	None


=cut

#-------------------------------------------------------------------------------

sub usage_dsh
{
## usage message
    my $usagemsg1  = " xdsh -h \n xdsh -q \n xdsh -V \n";
    my $usagemsg1a = "xdsh  [noderange] -K [-l logonuserid]\n";
    my $usagemsg2  = "      [-B bypass ] [-c] [-e] [-E environment_file]
      [--devicetype type_of_device] [-f fanout]\n";
    my $usagemsg3 = "      [-l user_ID] [-L]  ";
    my $usagemsg4 = "[-m] [-o options][-q] [-Q] [-r remote_shell]
      [-i image path] [-s] [-S ksh | csh] [-t timeout]\n";
    my $usagemsg5 = "      [-T] [-X environment variables] [-v] [-z]\n";
    my $usagemsg6 = "      [command_list]\n";
    my $usagemsg .= $usagemsg1 .= $usagemsg1a .= $usagemsg2 .= $usagemsg3 .=
      $usagemsg4 .= $usagemsg5 .= $usagemsg6;
###  end usage mesage
    if ($::CALLBACK)
    {
        my $rsp = {};
        $rsp->{data}->[0] = $usagemsg;
        xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
    }
    else
    {
        xCAT::MsgUtils->message("I", $usagemsg . "\n");
    }
    return;
}

#-------------------------------------------------------------------------------

=head3
       parse_and_run_dsh

        This parses the dsh input build the call to execute_dsh.

        Arguments:
		  $nodes,$args,$callback,$command,$noderange
		  These may exist, called from xdsh plugin

        Returns:
           Errors if invalid options or the executed dsh command

        Globals:


        Error:
        	None

        Example:

        Comments:

=cut

#-------------------------------------------------------------------------------

sub parse_and_run_dsh
{
    my ($class, $nodes, $args, $callback, $command, $noderange) = @_;

    $::CALLBACK = $callback;
    if (!($args))
    {
        usage_dsh;
        return;
    }
    @ARGV = @{$args};    # get arguments
    if ($ENV{'XCATROOT'})
    {
        $::XCATROOT = $ENV{'XCATROOT'};    # setup xcatroot home directory
    }
    elsif (-d '/opt/xcat')
    {
        $::XCATROOT = "/opt/xcat";
    }
    else
    {
        $::XCATROOT = "/usr";
    }

    # parse the arguments
    Getopt::Long::Configure("posix_default");
    Getopt::Long::Configure("no_gnu_compat");
    Getopt::Long::Configure("bundling");

    my %options = ();

    # check for wrong long options
    if (xCAT::DSHCLI->check_valid_options(\@ARGV))
    {
        usage_dsh;
        return 1;
    }

    if (
        !GetOptions(
            'e|execute'                => \$options{'execute'},
            'f|fanout=i'               => \$options{'fanout'},
            'h|help'                   => \$options{'help'},
            'l|user=s'                 => \$options{'user'},
            'm|monitor'                => \$options{'monitor'},
            'o|node-options=s'         => \$options{'node-options'},
            'q|show-config'            => \$options{'show-config'},
            'r|node-rsh=s'             => \$options{'node-rsh'},
            'i|rootimg=s'              => \$options{'rootimg'},
            's|stream'                 => \$options{'streaming'},
            't|timeout=i'              => \$options{'timeout'},
            'v|verify'                 => \$options{'verify'},
            'z|exit-status'            => \$options{'exit-status'},
            'B|bypass'                 => \$options{'bypass'},
            'C|context=s'              => \$options{'context'},
            'E|environment=s'          => \$options{'environment'},
            'I|ignore-sig|ignoresig=s' => \$options{'ignore-signal'},
            'K|keysetup'               => \$options{'ssh-setup'},
            'L|no-locale'              => \$options{'no-locale'},
            'Q|silent'                 => \$options{'silent'},
            'S|syntax=s'               => \$options{'syntax'},
            'T|trace'                  => \$options{'trace'},
            'V|version'                => \$options{'version'},

            'devicetype|devicetype=s'    => \$options{'devicetype'},
            'command-name|commandName=s' => \$options{'command-name'},
            'command-description|commandDescription=s' =>
              \$options{'command-description'},
            'X:s' => \$options{'ignore_env'}

        )
      )
    {
        xCAT::DSHCLI->usage_dsh;
        return 1;
    }

    if ($options{'help'})
    {
        xCAT::DSHCLI->usage_dsh;
        return 0;
    }

    my $rsp = {};
    if ($options{'show-config'})
    {
        xCAT::DSHCLI->show_dsh_config;
        return 0;
    }
    my $remotecommand = $options{'node-rsh'};
    if ($options{'node-rsh'}
        && (!-f $options{'node-rsh'} || !-x $options{'node-rsh'}))
    {
        $rsp->{data}->[0] =
          "Remote command: $remotecommand does not exist or is not executable.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        return;
    }

    # put rsync on a dsh command
    if ($options{'node-rsh'}
        && (grep /rsync/, $options{'node-rsh'}))
    {
        $rsp->{data}->[0] =
          "Remote command: $remotecommand should be used with the dcp command. ";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
        return;
    }

    if (defined $options{'ignore_env'})
    {
        xCAT::DSHCLI->ignoreEnv($options{'ignore_env'});
    }

    # this was determined in the xdsh client code, because non-root user
    # actions must be taken there.  For those calling xdsh plugin, default
    # is root
    if (!($ENV{'DSH_TO_USERID'}))
    {
        $options{'user'} = "root";
    }
    else
    {
        $options{'user'} = $ENV{'DSH_TO_USERID'};
    }

    if ((!(defined(@$nodes))) && (!(defined($options{'rootimg'}))))
    {    #  no nodes and not -i option, error
        my $rsp = ();
        $rsp->{data}->[0] = "Unless using -i option,  noderange is required.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }

    #
    # build list of nodes
    my @nodelist;
    my $imagename;
    if (defined($options{'rootimg'}))
    {    # running against local host
            # diskless image

        if (!(-e ($options{'rootimg'})))
        {    # directory does not exist
            my $rsp = ();
            $rsp->{data}->[0] =
              "Input image directory $options{'rootimg'} does not exist.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }

        # since we have no input nodes for running xdsh against the image
        # we will use the create the hostname from the directory
        # for the hostname in the output
        my $path = $options{'rootimg'};
        $imagename = xCAT::Utils->get_image_name($path);
        if (@$nodes[0] eq "NO_NODE_RANGE")
        {    # from sinv, discard this name
            undef @$nodes;
        }
        if (defined(@$nodes))
        {
            my $rsp = ();
            $rsp->{data}->[0] =
              "Input noderange:@$nodes and any other xdsh flags or environment variables are not valid with -i flag.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }

    }
    else
    {
        @nodelist = @$nodes;
        $options{'nodes'} = join(',', @nodelist);
    }

    #printf " node list is $options{'nodes'}";
    # build arguments

    $options{'command'} = join ' ', @ARGV;

    #
    # -K option just sets up the ssh keys on the nodes and exits
    #

    if (defined $options{'ssh-setup'})
    {

        if (defined $options{'rootimg'})
        {
            my $rsp = ();
            $rsp->{data}->[0] = "Cannot use -R and -K flag together";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;

        }

        #  IF using the xdsh -K -l option then we are setting up the
        #  --devicetype.   xdsh -K -l is not allowed for users.
        #  This is checked for in the client code.
        #  DSH_REMOTE_PASSWORD env variable must be set to the correct
        #  password for the key update.  This was setup in xdsh client
        #  frontend.  remoteshell.expect depends on this

        if (!($ENV{'DSH_REMOTE_PASSWORD'}))
        {
            my $rsp = ();
            $rsp->{data}->[0] =
              "User password for ssh key exchange has not been supplied./n Cannot complete the -K command./n";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;

        }

        if (!($ENV{'DSH_FROM_USERID'}))
        {
            my $rsp = ();
            $rsp->{data}->[0] =
              "Current Userid has not been supplied./n Cannot complete the -K command./n";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;

        }

        if (!($ENV{'DSH_TO_USERID'}))   # id to logon to the node and update the
                                        # keys
        {
            my $rsp = ();
            $rsp->{data}->[0] =
              "Logon  Userid has not been supplied./n Cannot complete the -K command./n";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;

        }

        my $current_userid = $ENV{'DSH_FROM_USERID'};
        my $to_userid      = $ENV{'DSH_TO_USERID'};

        # if current_userid ne touserid then current_userid
        # must be root
        if (   ($current_userid ne $to_userid)
            && ($current_userid ne "root"))
        {
            my $rsp = ();
            $rsp->{data}->[0] =
              "When touserid:$to_userid is not the same as the current user:$current_userid. The the command must be run by root id.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }

        # setting up IB switch ssh, different interface that ssh for
        # userid on node.  Must build special ssh command to be sent
        # to the IB switch to setup ssh
        if (defined $options{'devicetype'})
        {
            $ENV{'DEVICETYPE'} = $options{'devicetype'};
            my $devicepath = $options{'devicetype'};
            $devicepath =~ s/::/\//g;
            $devicepath = "/var/opt/xcat/" . $devicepath . "/config";
            if (-e $devicepath)
            {
                my $deviceconf = get_config($devicepath);

                # Get ssh-setup-command attribute from configuration
                $ENV{'SSH_SETUP_COMMAND'} =
                  $$deviceconf{'main'}{'ssh-setup-command'};
            }
        }

        #
        # setup ssh keys on the nodes or ib switch
        #
        my $rc      = xCAT::Utils->setupSSH($options{'nodes'});
        my @results = "return code = $rc";
        return (@results);
    }
    if (!(@ARGV))
    {    #  no args , an error

        $rsp->{data}->[0] = "No command argument provided";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }
    my @results;
    if (defined $options{'rootimg'})
    {
        @results = xCAT::DSHCLI->runlocal_on_rootimg(\%options, $imagename);
        if ($::RUNCMD_RC)
        {    # error from dsh
            my $rsp = ();
            $rsp->{data}->[0] = "Error from xdsh. Return Code = $::RUNCMD_RC";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);

        }
    }
    else
    {

        #
        # Execute the dsh api
        @results = xCAT::DSHCLI->runDsh_api(\%options, 0);
        if ($::RUNCMD_RC)
        {    # error from dsh
            $rsp->{data}->[0] = "Error from xdsh. Return Code = $::RUNCMD_RC";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);

        }
    }
    return (@results);
}

#-------------------------------------------------------------------------------

=head3
      usage_dcp

        puts out dcp usage message

        Arguments:
          None

        Returns:

        Globals:


        Error:
        	None


=cut

#-------------------------------------------------------------------------------

sub usage_dcp
{
    ### usage message
    my $usagemsg1 = " xdcp -h \n xdcp -q\n xdcp -V \n xdcp [noderange]\n";
    my $usagemsg2 = "      [-B bypass] [-c] [-f fanout] [-l user_ID]\n";
    my $usagemsg3 =
      "      [-o options] [-p] [-P] [-q] [-Q] [-r node_remote_copy]\n";
    my $usagemsg4 =
      "      [-R] [-t timeout] [-T] [-X environment variables] [-v] \n";
    my $usagemsg5    = "      source_file... target_path\n";
    my $usagemsg5a   = " xdcp [noderange] [-F <rsyncfile>] ";
    my $usagemsg5b   = "[-f fanout] [-t timeout] [-o options] [-v]\n";
    my $usagemsg5aa  = " xdcp [noderange] [-s] [-F <rsyncfile>] ";
    my $usagemsg5bb  = "[-f fanout] [-t timeout]\n";
    my $usagemsg5bbb = "                  [-o options] [-v]\n";
    my $usagemsg5c   = " xdcp [-i imagepath] [-F <rsyncfile>] ";
    my $usagemsg5d   = "[-o options]\n";

    my $usagemsg .= $usagemsg1 .= $usagemsg2 .= $usagemsg3 .= $usagemsg4 .=
      $usagemsg5 .= $usagemsg5a .= $usagemsg5b .= $usagemsg5aa .=
      $usagemsg5bb .= $usagemsg5bbb;

    if ($::CALLBACK)
    {
        my $rsp = {};
        $rsp->{data}->[0] = $usagemsg;
        xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
    }
    else
    {
        xCAT::MsgUtils->message("I", $usagemsg . "\n");
    }
    return;
}

#-------------------------------------------------------------------------------

=head3
       parse_and_run_dcp

        This parses the dcp input build the call to execute_dcp.

        Arguments:
		  $nodes,$args,$callback,$command,$noderange
		  These may exist, called from xdsh plugin

        Returns:
           Errors if invalid options or the executed dcp command

        Globals:


        Error:
        	None

        Example:

        Comments:

=cut

#-------------------------------------------------------------------------------

sub parse_and_run_dcp
{
    my ($class, $nodes, $args, $callback, $command, $noderange) = @_;
    $::CALLBACK = $callback;
    if (!($args))
    {
        usage_dcp;
        return 1;
    }
    @ARGV = @{$args};    # get arguments
    if ($ENV{'XCATROOT'})
    {
        $::XCATROOT = $ENV{'XCATROOT'};    # setup xcatroot home directory
    }
    else
    {
        $::XCATROOT = "/opt/xcat";
    }

    # parse the arguments
    Getopt::Long::Configure("posix_default");
    Getopt::Long::Configure("no_gnu_compat");
    Getopt::Long::Configure("bundling");

    my %options = ();

    # check for wrong long options
    if (xCAT::DSHCLI->check_valid_options(\@ARGV))
    {
        usage_dcp;
        return 1;
    }
    if (
        !GetOptions(
                    'f|fanout=i'       => \$options{'fanout'},
                    'F|File=s'         => \$options{'File'},
                    'h|help'           => \$options{'help'},
                    'l|user=s'         => \$options{'user'},
                    'o|node-options=s' => \$options{'node-options'},
                    'q|show-config'    => \$options{'show-config'},
                    'p|preserve'       => \$options{'preserve'},
                    'r|c|node-rcp=s'   => \$options{'node-rcp'},
                    'i|rootimg=s'      => \$options{'rootimg'},
                    's'                => \$options{'rsyncSN'},
                    't|timeout=i'      => \$options{'timeout'},
                    'v|verify'         => \$options{'verify'},
                    'B|bypass'         => \$options{'bypass'},
                    'C|context=s'      => \$options{'context'},
                    'Q|silent'         => \$options{'silent'},
                    'P|pull'           => \$options{'pull'},
                    'R|recursive'      => \$options{'recursive'},
                    'T|trace'          => \$options{'trace'},
                    'V|version'        => \$options{'version'},
                    'devicetype=s'     => \$options{'devicetype'},
                    'X:s'              => \$options{'ignore_env'}
        )
      )
    {
        usage_dcp;
        return (1);
    }

    my $rsp = {};
    if ($options{'help'})
    {
        usage_dcp;
        return (0);
    }
    if ($options{'show-config'})
    {
        xCAT::DSHCLI->show_dsh_config;
        return 0;
    }

    if (defined($options{'rootimg'}))
    {
        if (xCAT::Utils->isAIX())
        {
            my $rsp = ();
            $rsp->{data}->[0] = "The -i option is not supported on AIX.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }
    }
    if ((!(defined(@$nodes))) && (!(defined($options{'rootimg'}))))
    {    #  no nodes and not -i option, error
        my $rsp = ();
        $rsp->{data}->[0] = "Unless using -i option,  noderange is required.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }

    if ($options{'version'})
    {
        my $version = xCAT::Utils->Version();
        $rsp->{data}->[0] = "$version";
        xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
        return (0);
    }

    if (defined $options{'ignore_env'})
    {
        xCAT::DSHCLI->ignoreEnv($options{'ignore_env'});
    }
    if (defined($options{'rootimg'}))
    {    # running against local host
            # diskless image

        if (!(-e ($options{'rootimg'})))
        {    # directory does not exist
            my $rsp = ();
            $rsp->{data}->[0] =
              "Input image directory $options{'rootimg'} does not exist.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }
        if (!($options{'File'}))
        {    # File not given
            my $rsp = ();
            $rsp->{data}->[0] =
              "If -i option is use, then the -F option must input the file list.\nThe file will contain the list of files to rsync to the image.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }
    }
    if ($options{'File'})
    {

        # input -F file is copied to tmp file on a service node
        if (xCAT::Utils->isServiceNode())
        {    # running on service node
            $options{'File'} = "/tmp/xcatrf.tmp";
        }
        my $syncfile = $options{'File'};
        if (!-f $options{'File'})
        {

            my $rsp->{data}->[0] = "File:$syncfile does not exist.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }
    }

    # invalid to put the -F  with the -r flag
    if ($options{'File'} && $options{'node-rcp'})
    {
        my $rsp = ();
        $rsp->{data}->[0] =
          "If -F option is use, then -r is invalid. The command will always the rsync using ssh.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }

    # invalid to put the -s  without the -F flag
    if (!($options{'File'}) && $options{'rsyncSN'})
    {
        my $rsp = ();
        $rsp->{data}->[0] =
          "If -s option is use, then -F must point to the syncfile.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }

    # -s chosen or -F set rsync path
    if ($options{'rsyncSN'} || $options{'File'})
    {
        if ($^O eq 'aix')
        {
            if (-e ("/usr/bin/rsync"))
            {
                $options{'node-rcp'} = '/usr/bin/rsync';
            }
            else
            {
                $options{'node-rcp'} = '/usr/local/bin/rsync';
            }

        }
        elsif ($^O eq 'linux')
        {
            $options{'node-rcp'} = '/usr/bin/rsync';
        }
    }
    my $remotecopycommand = $options{'node-rcp'};
    if ($options{'node-rcp'}
        && (!-f $options{'node-rcp'} || !-x $options{'node-rcp'}))
    {
        $rsp->{data}->[0] =
          "Remote command: $remotecopycommand does not exist or is not executable.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;
    }

    #
    # build list of nodes
    my @nodelist;
    if (defined(@$nodes))
    {    # there are nodes
        @nodelist = @$nodes;
        $options{'nodes'} = join(',', @nodelist);
    }
    else
    {
        if (!($options{'rootimg'}))
        {
            my $rsp = {};
            $rsp->{data}->[0] = "Noderange missing in command input.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }
    }

    #
    #  if -F flag then we are going to process the file and use
    #  rsync to distribute the files listed in the input file
    #  Format of the file lines are the following, follows the rsync syntax
    #    /.../file   /..../file2 ->  /..../directory
    #    /....file*   /...../sample*  -> /..../directory
    #
    my @results;
    $::SYNCSN = 0;

    # if updating an install image
    # only going to run rsync locally
    if (($options{'File'}) && ($options{'rootimg'}))
    {
        my $image = $options{'rootimg'};
        my $rc = &rsync_to_image($options{'File'}, $image);
        if ($rc != 0)
        {    # error from dcp
            my $rsp = {};
            $rsp->{data}->[0] = "Error running rsync to image:$image.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);

        }
        return;

    }

    # if rsyncing the nodes or service nodes
    if ($options{'File'})
    {

        # if syncing a service node
        if ($options{'rsyncSN'})
        {
            $::SYNCSN = 1;
        }

        # set default sync dir on service node
        my $synfiledir = "/var/xcat/syncfiles";

        # get the directory on the servicenode to put the rsync files in
        my @syndir = xCAT::Utils->get_site_attribute("SNsyncfiledir");
        if ($syndir[0])
        {
            $synfiledir = $syndir[0];
        }

        my $rc;
        my $syncfile = $options{'File'};
        if (xCAT::Utils->isServiceNode())
        {    # running on service node
            $rc =
              &parse_rsync_input_file_on_SN(\@nodelist, \%options, $syncfile,
                                            $synfiledir);
        }
        else
        {    # running on MN
            $rc =
              &parse_rsync_input_file_on_MN(\@nodelist, \%options, $syncfile,
                                            $::SYNCSN, $synfiledir);
        }
        if ($rc == 1)
        {
            $rsp->{data}->[0] = "Error parsing the rsync file:$syncfile.";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }

    }
    else    # source and destination files are from command line
    {
        if (@ARGV < 1)
        {
            $rsp->{data}->[0] = "Missing file arguments";
            xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
            return;
        }

        elsif (@ARGV == 1)
        {
            if ($options{'pull'})
            {
                $rsp->{data}->[0] = "Missing target_path";
                xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
                return;
            }

            else
            {
                $options{'target'} = '';
                $options{'source'} = pop @ARGV;
            }
        }

        elsif ($options{'pull'} && (@ARGV > 2))
        {
            $rsp->{data}->[0] = "Cannot pull more than one file from targets.";
            xCAT::MsgUtils->message("I", $rsp, $::CALLBACK, 1);
            return;
        }

        else
        {
            $options{'target'} = pop @ARGV;
            $options{'source'} = join $::__DCP_DELIM, @ARGV;
        }

    }

    # Execute the dcp api
    @results = xCAT::DSHCLI->runDcp_api(\%options, 0);
    if ($::RUNCMD_RC)
    {    # error from dcp
        my $rsp = {};
        $rsp->{data}->[0] = "Error from xdsh. Return Code = $::RUNCMD_RC";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);

    }

    return (@results);

}

#-------------------------------------------------------------------------------

=head3
       rsync_to_image

        This parses the -F rsync input file. and runs rsync to the input
		image for the files

        File format:
          /.../file1 ->  /.../dir1/filex
          /.../file1 ->  /.../dir1
          /.../file1 /..../filex  -> /...../dir1

       rsync command format
	   /usr/bin/rsync -Lupotz  /etc/services  $pathtoimage/etc/services 
	   /usr/bin/rsync -Lupotz  /tmp/lissa/file1 /tmp/lissa/file $pathtoimage/tmp/lissa

        Arguments:
		  Input:
		  sync file
		  path to image 

        Returns:
           Errors if invalid options or the executed dcp command

        Globals:


        Error:
        	None

        Example:

        Comments:

=cut

#-------------------------------------------------------------------------------

sub rsync_to_image
{
    use File::Basename;

    my ($input_file, $image) = @_;
    my $rc = 0;
    open(INPUTFILE, "< $input_file") || die "File $input_file does not exist\n";
    while (my $line = <INPUTFILE>)
    {
        chomp $line;
        if ($line =~ /(.+) -> (.+)/)
        {
            my $imageupdatedir  = $image;
            my $imageupdatepath = $image;
            my $src_file        = $1;
            my $dest_file       = $2;
            $dest_file =~ s/[\s;]//g;
            my $dest_dir;
            if (-d $dest_file)    # if a directory on the left side
            {                     # if a directory , just use
                $dest_dir = $dest_file;
                $dest_dir =~ s/\s*//g;    #remove blanks
                $imageupdatedir  .= $dest_dir;    # save the directory
                $imageupdatepath .= $dest_dir;    # path is a directory
            }
            else                                  # if a file on the left side
            {                                     # strip off the file
                $dest_dir = dirname($dest_file);
                $dest_dir =~ s/\s*//g;            #remove blanks
                $imageupdatedir  .= $dest_dir;    # save directory
                $imageupdatepath .= $dest_file;   # path to a file
            }
            my @srcfiles = (split ' ', $src_file);
            if (!(-d $imageupdatedir))
            {    # if it does not exist, make it
                my $cmd = "mkdir -p $imageupdatedir";
                my @output = xCAT::Utils->runcmd($cmd, 0);
                if ($::RUNCMD_RC != 0)
                {
                    my $rsp = {};
                    $rsp->{data}->[0] = "Command: $cmd failed.";
                    xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
                    return;
                }
            }

            # for each file on the line
            my $synccmd = "";
            if ($^O eq 'aix')
            {
                if (-e ("/usr/bin/rsync"))
                {
                    $synccmd = "/usr/bin/rsync -Lupotz ";
                }
                else
                {
                    $synccmd = "/usr/local/bin/rsync -Lupotz ";
                }
            }
            else    # linux
            {
                $synccmd = "/usr/bin/rsync -Lupotz ";
            }
            my $syncopt = "";
            foreach my $srcfile (@srcfiles)
            {

                $syncopt .= $srcfile;
                $syncopt .= " ";
            }
            $syncopt .= $imageupdatepath;
            $synccmd .= $syncopt;

            xCAT::MsgUtils->message("S", "rsync2image: $synccmd\n");
            my @output = xCAT::Utils->runcmd($synccmd, 0);
            if ($::RUNCMD_RC != 0)
            {
                my $rsp = {};
                $rsp->{data}->[0] = "Command: $synccmd failed.";
                xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
            }

        }    # valid line
    }    # end reading file

    close INPUTFILE;
    return $rc;
}

#-------------------------------------------------------------------------------

=head3
       parse_rsync_input_file_on_MN
	  

        This parses the -F rsync input file on the Management node.

        File format:
          /.../file1 ->  /.../dir1/filex
          /.../file1 ->  /.../dir1
          /.../file1 /..../filex  -> /...../dir1

        Arguments:
		  Input nodelist,options, pointer to the sync file,flag is 
		  syncing the service node and
		  the directory to syn the files to on the service node
		  based on defaults or the site.SNsyncfiledir attribute,
		  if syncing a service node for hierarchical support. 

        Returns:
           Errors if invalid options or the executed dcp command

        Globals:


        Error:
        	None

        Example:

        Comments:

=cut

#-------------------------------------------------------------------------------

sub parse_rsync_input_file_on_MN
{
    use File::Basename;
    my ($nodes, $options, $input_file, $rsyncSN, $syncdir) = @_;
    my @dest_host    = @$nodes;
    my $process_line = 0;
    open(INPUTFILE, "< $input_file") || die "File $input_file does not exist\n";
    while (my $line = <INPUTFILE>)
    {
        chomp $line;
        if ($line =~ /^#/)    # skip commments
        {
            next;
        }
        if ($line =~ /(.+) -> (.+)/)
        {

            $process_line = 1;
            my $src_file  = $1;
            my $dest_file = $2;
            $dest_file =~ s/[\s;]//g;
            my @srcfiles = (split ' ', $src_file);
            my $arraysize = scalar @srcfiles;    # of source files on the line
            my $dest_dir;

            # if more than one file on the line then
            # the destination  is a directory
            # else assume a file
            if ($arraysize > 1)
            {
                $dest_dir = $dest_file;
            }
            else    # only one file 
            {       # strip off the file
                $dest_dir = dirname($dest_file);
            }
            $dest_dir =~ s/\s*//g;    #remove blanks

            foreach my $target_node (@dest_host)
            {
                $$options{'destDir_srcFile'}{$target_node} ||= {};

                # for each file on the line
                foreach my $srcfile (@srcfiles)
                {

                    #  if syncing the Service Node, file goes to the same place
                    #  where it was on the MN but in the syncdir on the service
                    # node
                    if ($rsyncSN == 1)
                    {    #  syncing the SN
                        $dest_dir = $syncdir;    # the SN sync dir
                        $dest_dir .= dirname($srcfile);
                        $dest_dir =~ s/\s*//g;    #remove blanks
                    }
                    $$options{'destDir_srcFile'}{$target_node}{$dest_dir} ||=
                      {};

                    # can be full file name for destination or just the
                    # directory name
                    my $src_basename = basename($srcfile);    # get file name

                    my $dest_basename;    # destination file name
                    if (-e $dest_file)
                    {                     # if destination file  exist
                        if (-d $dest_file)
                        {    # if a directory, get filename from src
                            $dest_basename = $src_basename;
                        }
                        else
                        {    # get the file name from the destination
                            $dest_basename = basename($dest_file);
                        }
                    }
                    else
                    {        #destination does not exist, get filename from src
                         # does not exist,  if only more than one file on the line
                         # assume that the destination  is a directory
                         # else assume a file
                        if ($arraysize > 1)
                        {
                            $dest_basename = $src_basename;
                        }
                        else
                        {
                            $dest_basename = basename($dest_file);
                        }
                    }
                    if ($rsyncSN == 1)    # dest file will be the same as src
                    {                     #  syncing the SN
                        $dest_basename = $src_basename;
                    }
                    $$options{'destDir_srcFile'}{$target_node}{$dest_dir} ||=
                      $dest_basename =~ s/[\s;]//g;

                    # if the filename will be the same at the destination
                    if ($src_basename eq $dest_basename)
                    {
                        $$options{'destDir_srcFile'}{$target_node}{$dest_dir}
                          {'same_dest_name'} ||= [];
                        push @{$$options{'destDir_srcFile'}{$target_node}
                              {$dest_dir}{'same_dest_name'}}, $srcfile;
                    }
                    else    # changing file names
                    {
                        $$options{'destDir_srcFile'}{$target_node}{$dest_dir}
                          {'diff_dest_name'} ||= {};
                        $$options{'destDir_srcFile'}{$target_node}{$dest_dir}
                          {'diff_dest_name'}{$srcfile} = $dest_basename;
                    }

                }
            }
        }
    }
    close INPUTFILE;
    if ($process_line == 0)
    {    # no valid lines in the file
        my $rsp = {};
        $rsp->{data}->[0] = "Found no lines to process in $input_file.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return 1;
    }
    else
    {
        $$options{'nodes'} = join ',', keys %{$$options{'destDir_srcFile'}};
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3
       parse_rsync_input_file_on_SN

        This parses the -F rsync input file on the Service node.

        File format:
          /.../file1 ->  /.../dir1/filex
          /.../file1 ->  /.../dir1
          /.../file1 /..../filex  -> /...../dir1

        Arguments:
		  Input nodelist,options, pointer to the sync file and
		  the directory to syn the files from 
		  based on defaults or the site.SNsyncfiledir attribute,

        Returns:
           Errors if invalid options or the executed dcp command

        Globals:


        Error:
        	None

        Example:

        Comments:

=cut

#-------------------------------------------------------------------------------

sub parse_rsync_input_file_on_SN
{
    use File::Basename;
    my ($nodes, $options, $input_file, $syncdir) = @_;
    my @dest_host    = @$nodes;
    my $process_line = 0;
    open(INPUTFILE, "< $input_file") || die "File $input_file does not exist\n";
    while (my $line = <INPUTFILE>)
    {
        chomp $line;
        if ($line =~ /(.+) -> (.+)/)
        {
            $process_line = 1;
            my $src_file  = $1;
            my $dest_file = $2;
            $dest_file =~ s/[\s;]//g;
            my @srcfiles = (split ' ', $src_file);
            my $arraysize = scalar @srcfiles;    # of source files on the line
            my $dest_dir;

            # if only more than one file on the line
            # then the destination  is a directory
            # else a file, 
            if ($arraysize > 1)
            {
                $dest_dir = $dest_file;
            }
            else # a file path
            {
                $dest_dir = dirname($dest_file);
            }
            $dest_dir =~ s/\s*//g;    #remove blanks

            foreach my $target_node (@dest_host)
            {
                $$options{'destDir_srcFile'}{$target_node} ||= {};

                # for each file on the line
                foreach my $srcfile (@srcfiles)
                {
                    my $tmpsrcfile = $syncdir;    # add syndir on front
                    $tmpsrcfile .= $srcfile;
                    $srcfile = $tmpsrcfile;
                    $$options{'destDir_srcFile'}{$target_node}{$dest_dir} ||=
                      {};

                    # can be full file name for destination or just the
                    # directory name. For source must be full path
                    my $src_basename = basename($srcfile);    # get file name

                    my $dest_basename;    # destination file name
                    if (-e $dest_file)
                    {                     # if destination file  exist
                        if (-d $dest_file)
                        {    # if a directory, get filename from src
                            $dest_basename = $src_basename;
                        }
                        else
                        {    # get the file name from the destination
                            $dest_basename = basename($dest_file);
                        }
                    }
                    else
                    {        #destination does not exist, get filename from src
                         # does not exist,  if only more than one file on the line
                         # assume that the destination  is a directory
                         # else assume a file
                        if ($arraysize > 1)
                        {
                            $dest_basename = $src_basename;
                        }
                        else
                        {
                            $dest_basename = basename($dest_file);
                        }
                    }
                    $$options{'destDir_srcFile'}{$target_node}{$dest_dir} ||=
                      $dest_basename =~ s/[\s;]//g;

                    # if the filename will be the same at the destination
                    if ($src_basename eq $dest_basename)
                    {
                        $$options{'destDir_srcFile'}{$target_node}{$dest_dir}
                          {'same_dest_name'} ||= [];
                        push @{$$options{'destDir_srcFile'}{$target_node}
                              {$dest_dir}{'same_dest_name'}}, $srcfile;
                    }
                    else    # changing file names
                    {
                        $$options{'destDir_srcFile'}{$target_node}{$dest_dir}
                          {'diff_dest_name'} ||= {};
                        $$options{'destDir_srcFile'}{$target_node}{$dest_dir}
                          {'diff_dest_name'}{$srcfile} = $dest_basename;
                    }

                }
            }
        }
    }
    close INPUTFILE;
    if ($process_line == 0)
    {    # no valid lines in the file
        my $rsp = {};
        $rsp->{data}->[0] = "Found no lines to process in $input_file.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return 1;
    }
    else
    {
        $$options{'nodes'} = join ',', keys %{$$options{'destDir_srcFile'}};
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3
      runlocal_on_rootimg

  This subroutine runs the xdsh command against the input image on the local
  node.
  Arguments:
      $optionRef:
         Specifies a hash in which the xdsh options are provided
      $exitCode:
		  reference to an array for efficiency.
  Example:
      my @outref = xCAT::DSHCLI->runlocal_rootimg(\%options);


=cut

#-------------------------------------------------------------------------------

sub runlocal_on_rootimg
{
    my ($class, $options, $imagename) = @_;
    my $cmd = "chroot $$options{'rootimg'} $$options{'command'}";
    my @output = xCAT::Utils->runcmd($cmd, 0);
    if ($::RUNCMD_RC != 0)
    {
        my $rsp = {};
        $rsp->{data}->[0] = "Command: $cmd failed, unable to process image.";
        xCAT::MsgUtils->message("E", $rsp, $::CALLBACK, 1);
        return;

    }
    my @newoutput;
    foreach my $line (@output)
    {
        my $newline .= $imagename;
        $newline    .= ": ";
        $newline    .= $line;
        $newline    .= "\n";
        push @newoutput, $newline;
    }

    $::DSH_API_MESSAGE = ();
    $::DSH_API_MESSAGE = $::DSH_API_MESSAGE . join("", @newoutput);
    return $::DSH_API_MESSAGE;
}

#-------------------------------------------------------------------------------

=head3
      runDsh_api

  This subroutine provides a concise interface to run remote command on multiple nodes.
  Arguments:
      $optionRef:
         Specifies a hash in which the dsh options are provided
      $exitCode:
        Normally, if there is an error running the cmd,
		it will display the error msg
        and exit with the cmds exit code, unless exitcode is given one of the
        following values:
             0:     display error msg, DO NOT exit on error, but set
                $::RUNCMD_RC to the exit code.
            -1:     DO NOT display error msg and DO NOT exit on error, but set
	                   $::RUNCMD_RC to the exit code.
            -2:    DO the default behavior (display error msg and exit with cmds
                exit code.
        number > 0:    Display error msg and exit with the given code
        $refoutput:
          if refoutput is true, then the output will be returned as a
		  reference to an array for efficiency.
  Example:
      my @outref = xCAT::DSHCLI->runDsh_api(\%options, -2);


=cut

#-------------------------------------------------------------------------------

sub runDsh_api
{
    shift;
    my ($optionsRef, $exitCode, $refoutput) = @_;

    $::DSH_API         = 1;
    $::DSH_API_MESSAGE = "";
    my $verbose_old = $::VERBOSE;
    $::VERBOSE = 0;

    #
    # execute dsh
    #
    $::RUNCMD_RC = 0;
    $::RUNCMD_RC = xCAT::DSHCLI->execute_dsh($optionsRef);

    $::DSH_API = 0;
    $::VERBOSE = $verbose_old;
    my $returnCode;    #command will exit with this code
    if ($::RUNCMD_RC)
    {
        my $dsh_api_displayerr = 1;
        if (defined($exitCode) && length($exitCode) && $exitCode != -2)
        {
            if ($exitCode > 0)
            {
                $returnCode = $exitCode;
            }
            elsif ($exitCode <= 0)
            {
                $returnCode = '';
                if ($exitCode < 0)
                {
                    $dsh_api_displayerr = 0;
                }
            }
        }
        else
        {
            $returnCode = $::RUNCMD_RC;
        }
        if ($dsh_api_displayerr)
        {
            my $errmsg = '';
            if (xCAT::Utils->isLinux() && $::RUNCMD_RC == 139)
            {
                $errmsg = "Return Code = 139  $errmsg";
            }
            else
            {
                $errmsg = $::DSH_API_MESSAGE;
            }
            if ((!$DSHCLI::NO_MESSAGES) && ($::DSH_API_NODES_FAILED))
            {
                xCAT::MsgUtils->message(
                    "E",
                    "xdsh command: $$optionsRef{'command'} failed on  nodes:$::DSH_API_NODES_FAILED."
                    );
            }
        }

    }

    if ($refoutput)
    {
        my $outputRef = [];
        @$outputRef = split "\n", $::DSH_API_MESSAGE;
        chomp @$outputRef;
        return $outputRef;
    }
    elsif (wantarray)
    {
        my @outputLines = split "\n", $::DSH_API_MESSAGE;
        chomp @outputLines;
        return @outputLines;
    }
    else
    {
        return $::DSH_API_MESSAGE;
    }
}

#-------------------------------------------------------------------------------

=head3
  runDcp_api

    This subroutine provides a concise interface to run remote command
	on multiple nodes.
    Arguments:
           $optionRef:
               Specifies a hash in which the dsh options are provided
           $exitCode:
              Normally, if there is an error running the cmd,
			  it will display the error msg
              and exit with the cmds exit code,
			  unless exitcode is given one of the
              following values:
                       0:     display error msg, DO NOT exit on error, but set
                              $::RUNCMD_RC to the exit code.
                      -1:     DO NOT display error msg
							  and DO NOT exit on error, but set
                              $::RUNCMD_RC to the exit code.
                      -2:    DO the default behavior
							 (display error msg and exit with cmds
                             exit code.
              number > 0:    Display error msg and exit with the
							 given code
              $refoutput:
                             if refoutput is true, then the output
							 will be returned as a reference to
                             an array for efficiency.
     Example:
            my @outref = xCAT::DSHCLI->runDcp_api(\%options, -2);

=cut

#-------------------------------------------------------------------------------

sub runDcp_api
{
    shift;
    my ($optionsRef, $exitCode, $refoutput) = @_;

    $::DCP_API         = 1;
    $::DCP_API_MESSAGE = "";
    my $verbose_old = $::VERBOSE;
    $::VERBOSE = 0;
    if (!ref($optionsRef->{'source'}))
    {
        $optionsRef->{'source'} =~ s/\s/$::__DCP_DELIM/g;
    }
    elsif (ref($optionsRef->{'source'} eq "ARRAY"))
    {
        $optionsRef->{'source'} = join $::__DCP_DELIM,
          @{$optionsRef->{'source'}};
    }

    $::RUNCMD_RC = xCAT::DSHCLI->execute_dcp($optionsRef);
    $::DCP_API   = 0;
    $::VERBOSE   = $verbose_old;
    my $returnCode;    #command will exit with this code
    if ($::RUNCMD_RC)
    {
        my $dcp_api_displayerr = 1;
        if (defined($exitCode) && length($exitCode) && $exitCode != -2)
        {
            if ($exitCode > 0)
            {
                $returnCode = $exitCode;
            }
            elsif ($exitCode <= 0)
            {
                $returnCode = '';
                if ($exitCode < 0)
                {
                    $dcp_api_displayerr = 0;
                }
            }
        }
        else
        {
            $returnCode = $::RUNCMD_RC;
        }
        if ($dcp_api_displayerr)
        {
            my $errmsg = '';
            if (xCAT::Utils->isLinux() && $::RUNCMD_RC == 139)
            {
                $errmsg = "Return code=139  $errmsg";
            }
            else
            {
                $errmsg = $::DCP_API_MESSAGE;
            }
            if (!$DSHCLI::NO_MESSAGES)
            {
                xCAT::MsgUtils->message("E",
                               "dcp command failed, Return code=$::RUNCMD_RC.");
            }
        }

    }
    if ($refoutput)
    {
        my $outputRef = [];
        @$outputRef = split "\n", $::DCP_API_MESSAGE;
        chomp @$outputRef;
        return $outputRef;
    }
    elsif (wantarray)
    {
        my @outputLines = split "\n", $::DCP_API_MESSAGE;
        chomp @outputLines;
        return @outputLines;
    }
    else
    {
        return $::DCP_API_MESSAGE;
    }
}

#-------------------------------------------------------------------------------

=head3
        show_dsh_config

        Displays the current configuration of the dsh command environment
        and configuration information for each installed context

        Arguments:
        	$options - options hash table describing dsh configuration options

        Returns:
        	None

        Globals:
        	None

        Error:
        	None

        Example:

        Comments:

=cut

#-------------------------------------------------------------------------------
sub show_dsh_config
{
    my ($class, $options) = @_;
    xCAT::DSHCLI->config_default_context($options);

    my $dsh_config = xCAT::DSHCLI->get_dsh_config;

    foreach my $context (sort keys(%$dsh_config))
    {
        my $context_properties = $$dsh_config{$context};
        foreach my $key (sort keys(%$context_properties))
        {
            print STDOUT "$context:$key=$$context_properties{$key}\n";

        }
    }
}

#-------------------------------------------------------------------------------

=head3 
     get_config

    Substitute specific keywords in hash
        e.g. config file:
        [main]
        cachedir=/var/cache/yum
        keepcache=1
        [base]
        name=Red Hat Linux $releasever - $basearch - Base
        baseurl=http://mirror.dulug.duke.edu/pub/yum-repository/redhat/$releasev
er/$basearch/

        %config = {
                                main => {
                                        'cachedir'  => '/var/cache/yum',
                                        'keepcache' => '1'
                                                },
                                bash => {
                                        'name'          => 'Red Hat Linux $relea
sever - $basearch - Base',
                                        'baseurl'       => 'http://mirror.dulug.
duke.edu/pub/yum-repository/redhat/$releasever/$basearch/'
                                                }
                          }

    Arguments:
          $configfile      - config file
    Returns:
          $config_ref    - reference to config hash
    Comments:

=cut

#-------------------------------------------------------------------------------
sub get_config
{
    my $configfile      = shift;
    my @content         = readFile($configfile);
    my $current_section = "DEFAULT";
    my %config;
    my $xcat_use;
    $xcat_use = 0;
    foreach my $line (@content)
    {
        my ($entry, $value);
        chomp $line;
        if ($line =~ /\QDO NOT ERASE THIS SECTION\E/)
        {

            # reverse flag
            $xcat_use = !$xcat_use;
        }
        if ($xcat_use)
        {

            # Remove leading "#". This line is used by xCAT
            $line =~ s/^#//g;
        }
        else
        {

            # Remove comment line
            $line =~ s/#.*$//g;
        }
        $line =~ s/^\s+//g;
        $line =~ s/\s+$//g;
        next unless $line;
        if ($line =~ /^\s*\[([\w+-\.]+)\]\s*$/)
        {
            $current_section = $1;
        }
        else
        {

            # Ignore line doesn't key/value pair.
            if ($line !~ /=/)
            {
                next;
            }
            $line =~ /^\s*([^=]*)\s*=\s*(.*)\s*$/;
            $entry = $1;
            $value = $2;
            $entry =~ s/^#*//g;

            # Remove leading and trailing spaces
            $entry =~ s/^\s+//g;
            $entry =~ s/\s+$//g;
            $value =~ s/^\s+//g;
            $value =~ s/\s+$//g;
            $config{$current_section}{"$entry"} = $value;
        }
    }
    return \%config;
}

#-------------------------------------------------------------------------------

=head3    readFile

    Read a file and return its content.

    Arguments:
        filename
    Returns:
        file contents or undef
    Globals:
        none
    Error:
        undef
    Example:
        my $blah = readFile('/etc/redhat-release');
    Comments:
        none

=cut

#-------------------------------------------------------------------------------

sub readFile
{
    my $filename = shift;
    open(FILE, "<$filename");
    my @contents = <FILE>;
    close(FILE);
    return @contents;
}

1;
