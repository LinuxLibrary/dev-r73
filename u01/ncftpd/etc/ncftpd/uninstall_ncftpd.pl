#!/usr/bin/perl -w
#
# This script is Copyright (C) 2002 by Mike Gleason, NcFTP Software.
# All Rights Reserved.
#
use strict;
use Socket;
use File::Copy;
use POSIX qw(strftime);

# Porting checklist:
#   ps behavior
#   userdel program
#

my ($verbose) 				= 1;
my ($force_uninstall)			= 0;
my ($OS)				= "";
my ($SYS)				= "";
my ($linux_distro)			= "";
my ($uninstall_log)			= "";
my ($ftpport)				= 21;
my ($generic_uninstall)			= 0;



sub Usage
{
	print <<EOF;
Usage: $0 [options]
Options: [defaults in brackets after descriptions]
Invocation:
  --force                 Skip verification of uninstallation
  --help                  Print this message
  --quiet, --silent       Do not print `checking...' messages
  --debug                 Print debugging messages
  --log=LOG               Save uninstall messages to LOG
  --generic               Do generic uninstallation (ignore
                            host-specific changes made during
			    original installation)
EOF
	Exit(2);
}	# Usage




sub Getopts
{
	my($i, $arg, $val);

	for ($i = 0; $i < scalar(@ARGV); $i++) {
		$arg = $ARGV[$i];
		if ($arg eq "--help") {
			Usage();
		} elsif ($arg eq "--force") {
			$force_uninstall = 1;
		} elsif ($arg eq "--generic") {
			$generic_uninstall = 1;
		} elsif ($arg eq "--silent") {
			$verbose = 0;
		} elsif ($arg eq "--quiet") {
			$verbose = 0;
		} elsif ($arg eq "--debug") {
			$verbose = 2;
		} elsif ($arg =~ /^--debug=(.*)/) {
			$val = int($1);
			Exit(1, "$val is not a valid debugging level.\n")
				if (($val < 0) || ($val > 10));
			$verbose = $val;
		} elsif ($arg =~ /^--log=(.*)/) {
			$uninstall_log = $1;
		} else {
			printf ("Argument not recognized: \"%s\".\nTry \"%s --help\" command line options.\n", $arg, $0);
			Exit(3);
		}
	}
}	# Getopts




sub PsGrep
{
	my ($pattern, $match_mode, $output, $pscmd) = @_;
	my (@column_headers);
	my (@column_values);
	my ($column_number);
	my ($line, $col);
	my ($pid_column) = 0;
	my ($command_pos) = 0;
	my ($command) = 0;
	my ($two_column_format) = 0;
	my (@pids) = ();

	return () unless (defined($pattern));
	$match_mode = "program" unless (defined($match_mode));
	$output = "pids" unless (defined($output));

	if ((! defined($pscmd)) || (! $pscmd)) {
		if ($^O =~ /^(solaris|aix|dec_osf|sco3.2v5.0|svr4)$/) {
			$pscmd = "/bin/ps -e -o pid,args";
		} elsif ($^O =~ /^(linux)$/) {
			$pscmd = "/bin/ps -w -e -o pid,args";
			if (open(PSCOMMAND, "/bin/ps --version |")) {
				$line = <PSCOMMAND>;
				close(PSCOMMAND);
				$pscmd = "/bin/ps auxw" if ($line =~ /version\s1/);
			}
		} elsif ($^O =~ /^(hpux)$/) {
			$pscmd = "/bin/ps -ef";
		} elsif ($^O =~ /^(unixware|openunix)$/) {
			$pscmd = "/usr/bin/ps -ef";
		} elsif ($^O =~ /^(freebsd|netbsd|openbsd|bsdos)$/) {
			$pscmd = "/bin/ps -axw -o pid,command";
		} elsif ($^O =~ /^(darwin|rhapsody)$/) {
			$pscmd = "/bin/ps -auxw";
		} elsif ($^O eq "irix") {
			$pscmd = "/sbin/ps -e -o pid,args";
		} elsif ($^O eq "sunos") {
			$pscmd = "/bin/ps -axw";
		} else {
			$pscmd = "ps -ef";
		}
	}
	$two_column_format = 1 if ($pscmd =~ /pid,/);

	if (open(PSCOMMAND, "$pscmd 2>/dev/null |")) {
		unless (defined($line = <PSCOMMAND>)) {
			close(PSCOMMAND);
			return ();
		}
		if ($two_column_format) {
			$pid_column = 0;
			if ($match_mode eq "program") {
				$pattern = '^' . $pattern . '$'; 
			}
			while (defined($line = <PSCOMMAND>)) {
				chomp($line);
				@column_values = split(' ', $line, 2);
				$command = $column_values[1];
				$command =~ s/://;
				next unless defined($command);

				if ($match_mode ne "full") {
					my (@a) = split(' ', $command);
					$command = $a[0];
					next unless defined($command);
				}
				if ($match_mode eq "program") {
					my (@a) = split(/\//, $command);
					$command = $a[-1];
					next unless defined($command);
					if ($command =~ /^[\(\[](.*)[\)\]]$/) {
						$command = $1;
						next unless defined($command);
					}
				}
				if ($command =~ /${pattern}/) {
					if ($output eq "long") {
						push(@pids, $line);
					} else {
						push(@pids, $column_values[$pid_column]);
					}
				}
			}
		} else {
			$command_pos = index($line, "COMMAND");
			$command_pos = index($line, "CMD") if ($command_pos <= 0);
			unless ($command_pos > 0) {
				close(PSCOMMAND);
				return ();
			}
			@column_headers = split(' ', $line);
			unless (scalar(@column_headers) > 0) {
				close(PSCOMMAND);
				return ();
			}
			$column_number = 0;
			for $col (@column_headers) {
				$pid_column = $column_number if ($col eq "PID");
				$column_number++;
			}
			unless ($pid_column >= 0) {
				close(PSCOMMAND);
				return ();
			}
			if ($match_mode eq "program") {
				$pattern = '^' . $pattern . '$'; 
			}
			while (defined($line = <PSCOMMAND>)) {
				chomp($line);
				@column_values = split(' ', $line);
				$command = substr($line, $command_pos);
				$command =~ s/://;
				if ($match_mode ne "full") {
					my (@a) = split(' ', $command);
					$command = $a[0];
				}
				if ($match_mode eq "program") {
					my (@a) = split(/\//, $command);
					$command = $a[-1];
					if ($command =~ /^[\(\[](.*)[\)\]]$/) {
						$command = $1;
					}
				}
				if ($command =~ /${pattern}/) {
					if ($output eq "long") {
						push(@pids, $line);
					} else {
						push(@pids, $column_values[$pid_column]);
					}
				}
			}
		}
		close(PSCOMMAND);
	}

	return (@pids);
}	# PsGrep




sub SearchPath 
{
	my ($prog, $pathstotryfirst, $pathstoignore) = @_;
	return ("") if ((! defined($prog)) || (! $prog));

	my (@ignore_paths) = ();
	my ($PATH) = $ENV{"PATH"};
	$PATH = "/bin:/usr/bin" if ((! defined($PATH)) || (! $PATH));
	if ((defined($pathstotryfirst)) && ($pathstotryfirst ne "")) {
		$PATH = "$pathstotryfirst:$PATH";
	}
	if ((defined($pathstoignore)) && ($pathstoignore ne "")) {
		@ignore_paths = split(/:/, $pathstoignore);
	}

	my (@path) = split(/:/, $PATH);
	my ($dir, $pathprog, $idir, $ignore);
	for $dir (@path) {
		$ignore = 0;
		for $idir (@ignore_paths) {
			if ($idir eq $dir) {
				$ignore = 1;
			}
		}
		next if ($ignore);
		$pathprog = "$dir/$prog";
		return ($pathprog) if (-x $pathprog);
	}
	return ("");
}	# SearchPath




sub Log
{
	my ($v, @args) = @_;
	my ($arg);

	return if (! defined($v));
	if ($v !~ /\d+/) {
		$arg = $v;
		print LOG $arg if ($uninstall_log ne "");
		print $arg;
		$v = 0;
		print $arg if ($verbose > $v);
	}

	if (scalar(@args)) {
		for $arg (@args) {
			print LOG $arg if ($uninstall_log ne "");
			print $arg if ($verbose > $v);
		}
	}
}	# Log




sub Exit
{
	my ($es, @reason) = @_;
	if (scalar(@reason)) {
		Log(0, @reason);
	}
	if ($uninstall_log ne "") {
		my ($ltime) = strftime("%Y-%m-%d %H:%M:%S %z", localtime(time()));
		print LOG "--- Log closed at $ltime ---\n";
		close(LOG);
		print "\nUninstallation log saved as $uninstall_log.\n";
		$uninstall_log = "";
	}
	exit($es);
}	# Exit




sub OpenLog
{
	if ($uninstall_log ne "") {
		if (open(LOG, ">$uninstall_log")) {
			my ($ltime) = strftime("%Y-%m-%d %H:%M:%S %z", localtime(time()));
			print LOG "--- Log created at $ltime ---\n";
		}
	}
}	# OpenLog




sub IsThereAnFTPServerServing
{
	my ($v) = @_;
	my ($hardway) = 0;
	my ($serveraddr);

	$v = 0 if (! defined($v));
	$serveraddr = inet_aton("localhost") || inet_aton("127.0.0.1");
	$hardway = 1 if (! defined($serveraddr));

	$hardway = 1 if (! socket(FTPSOCKET, PF_INET, SOCK_STREAM, getprotobyname('tcp')));

	if ($hardway) {
		#
		# This older way doesn't work as well.
		#
		Log(2, "Using alternate method to tell if FTP server is running.\n");
		my ($ftp) = SearchPath("ftp", "/usr/bin");
		my ($echo) = SearchPath("echo", "/bin:/usr/bin");
		if ($ftp eq "") {
			Log(0, "/usr/bin/ftp is not present.\n");
			Log(0, "Cannot tell if FTP server is running.\n");
			return (0);
		}
		if ($echo eq "") {
			Log(0, "/bin/echo is not present.\n");
			$echo = "echo";		# Try anyway
		}
		if (open(FTP, "$echo quit | $ftp -d -n 127.0.0.1 2>/dev/null |")) {
			my (@ftpresult) = <FTP>;
			close(FTP);
			# Connected to localhost.
			# 220 Hurricane NcFTPd Server (free personal license) ready.
			# ftp> quit
			# ---> QUIT
			# 221 Goodbye.
			my (@quitresult) = grep(@ftpresult, "QUIT");
			if (scalar(@quitresult) > 0) {
				Log($v, "An FTP server is running.\n");
				return (1);
			}
		}
		Log($v, "No FTP server is currently running.\n");
		return (0);
	}

	$serveraddr = sockaddr_in($ftpport, $serveraddr);
	if (connect(FTPSOCKET, $serveraddr)) {
		print FTPSOCKET "QUIT\r\n";
		close(FTPSOCKET);
		Log($v, "An FTP server is running.\n");
		return (1);
	}

	close(FTPSOCKET);
	Log($v, "No FTP server is running.\n");
	return (0);
}	# IsThereAnFTPServerServing




sub TellInetdToReloadConfiguration
{
	my (@pids) = PsGrep("inetd", "program", "pids");
	my ($pid) = 0;
	my ($npids) = scalar(@pids);

	if ($npids == 0) {
		Log(1, "Warning: No Inetd process is running?\n");
		return;
	}

	if ($npids > 1) {
		Log(1, "Warning: Multiple Inetd processes detected?\n");
		for $pid (@pids) {
			Log(1, "  PID $pid\n");
		}
	}

	for $pid (@pids) {
		Log(0, "Sending SIGHUP to Inetd running on PID $pid.\n");
		kill HUP => $pid;
	}

	Log(1, "Giving Inetd a few seconds to reload.\n");
	sleep(2);
}	# TellInetdToReloadConfiguration




sub TellXinetdToReloadConfiguration
{
	my (@pids) = PsGrep("xinetd", "program", "pids");
	my ($pid) = 0;
	my ($npids) = scalar(@pids);

	if ($npids == 0) {
		Log(1, "Warning: No Xinetd process is running?\n");
		return;
	}

	if ($npids > 1) {
		Log(1, "Warning: Multiple Xinetd processes detected?\n");
		for $pid (@pids) {
			Log(1, "  PID $pid\n");
		}
	}

	for $pid (@pids) {
		Log(0, "Sending SIGUSR2 to Xinetd running on PID $pid.\n");
		kill USR2 => $pid;
	}

	Log(1, "Giving Xinetd a few seconds to reload.\n");
	sleep(2);
}	# TellXinetdToReloadConfiguration




sub KillFTPd
{
	my ($victim) = @_;
	my (@procs) = PsGrep($victim, "program", "pids");
	my (%origprocs);
	my ($proc);
	my ($nproc) = 0;

	return (0) if (scalar(@procs) == 0);
	Log(0, sprintf("Sending TERM signal to %d $victim processes.\n", scalar(@procs)));

	for $proc (@procs) {
		Log(2, "  ") if (($nproc % 10) == 0);
		Log(2, sprintf("%-7d", $proc));
		Log(2, "\n") if (($nproc % 10) == 9);
		$origprocs{$proc} = 1;
		$nproc++;
	}
	Log(2, "\n") if (($nproc % 10) != 9);

	kill TERM => @procs;
	sleep(3);
	my ($i);
	for ($i = 0; $i < 3; $i ++) {
		sleep(2);
		@procs = PsGrep($victim, "program", "pids");
		return (0) if (scalar(@procs) == 0);	# All are dead, done.
	}

	my ($newinstanceprocs) = 0;
	my (@stragglers) = ();
	for $proc (@procs) {
		if (defined($origprocs{$proc})) {
			push(@stragglers, $proc);
		} else {
			$newinstanceprocs++;
		}
	}

	if ($newinstanceprocs > 0) {
		Log(1, "New processes were born after the old ones were killed!\n");
	}
	return ($newinstanceprocs) if (scalar(@stragglers) == 0);

	Log(0, sprintf("Sending KILL signal to %d $victim processes.\n", scalar(@stragglers)));
	$nproc = 0;
	for $proc (@stragglers) {
		Log(2, "  ") if (($nproc % 10) == 0);
		Log(2, sprintf("%-7d", $proc));
		Log(2, "\n") if (($nproc % 10) == 9);
		$nproc++;
	}
	Log(2, "\n") if (($nproc % 10) != 9);
	kill KILL => @stragglers;			# KiLL 'Em ALL
	return ($newinstanceprocs);
}	# KillFTPd




sub UncommentFile
{
	my ($filename, $prefix) = @_;
	my (@lines, $line, $prefix_len, $newline, $lines_changed, $omode);
	my ($ouid, $ogid);

	$prefix_len = length($prefix);
	($ouid, $ogid) = (stat($filename))[4,5];
	$omode = (stat($filename))[2];
	if (open(CONFIGFILE, "<$filename")) {
		@lines = <CONFIGFILE>;
		close(CONFIGFILE);

		$lines_changed = 0;
		foreach $line (@lines) {
			if (substr($line, 0, $prefix_len) eq $prefix) {
				$newline = substr($line, $prefix_len);
				$line = $newline;
				$lines_changed++;
			}
		}

		if ($lines_changed == 0) {
			Log(0, "Did not need to uncomment lines from $filename.\n");
		} else {
			unlink($filename);
			if (! open(CONFIGFILENEW, ">$filename")) {
				Log(0, "Could not create the file $filename: $!\n");
				close(CONFIGFILENEW);
			} else {
				print CONFIGFILENEW @lines;
				close(CONFIGFILENEW);
				if ((defined($ouid)) && (defined($ogid))) {
					chown($ouid, $ogid, $filename);
				}
				if (defined($omode)) {
					$omode &= 0777;
					chmod($omode, $filename);
				}
				Log(0, "Uncommented $lines_changed line(s) from $filename.\n");
				return (1);
			}
		}
	} else {
		Log(0, "Could not open $filename for uncommenting: $!\n");
	}
	return (0);
}	# UncommentFile




sub RemoveLinesFromFile
{
	my ($filename, $prefix) = @_;
	my (@lines, $line, $prefix_len, $lines_changed, $omode);
	my ($ouid, $ogid);

	$prefix_len = length($prefix);
	($ouid, $ogid) = (stat($filename))[4,5];
	$omode = (stat($filename))[2];
	if (open(CONFIGFILE, "<$filename")) {
		@lines = <CONFIGFILE>;
		close(CONFIGFILE);

		$lines_changed = 0;
		foreach $line (@lines) {
			if (substr($line, 0, $prefix_len) eq $prefix) {
				$line = "";
				$lines_changed++;
			}
		}

		if ($lines_changed == 0) {
			Log(0, "Did not need to remove lines from $filename.\n");
		} else {
			unlink($filename);
			if (! open(CONFIGFILENEW, ">$filename")) {
				Log(0, "Could not create the file $filename: $!\n");
				close(CONFIGFILENEW);
			} else {
				print CONFIGFILENEW @lines;
				close(CONFIGFILENEW);
				if ((defined($ouid)) && (defined($ogid))) {
					chown($ouid, $ogid, $filename);
				}
				if (defined($omode)) {
					$omode &= 0777;
					chmod($omode, $filename);
				}
				Log(0, "Removed $lines_changed line(s) from $filename.\n");
				return (1);
			}
		}
	} else {
		Log(0, "Could not open $filename to remove lines: $!\n");
	}
	return (0);
}	# RemoveLinesFromFile




sub Rmdir
{
	my ($path) = @_;

	if (rmdir($path)) {
		Log(0, "Removed directory \"$path\".\n");
	} else {
		Log(0, "Could not remove directory \"$path\": $!\n");
	}
}	# Rmdir




sub Remove
{
	my ($path) = @_;

	if (unlink($path)) {
		Log(0, "Removed file \"$path\".\n");
	} else {
		Log(0, "Could not remove file \"$path\": $!\n");
	}
}	# Remove




sub Rename
{
	my ($rnfm, $rnto) = @_;
	return ("") if (! -f $rnfm);

	$rnto = "$rnfm.orig" if (! defined($rnto));
#	my ($ornto) = $rnto;
#	my ($i);
#	for ($i = 2; $i < 1000; $i++) {
#		last if (! -f $rnto);
#		$rnto = $ornto . "-$i";
#	}
	if (rename($rnfm, $rnto)) {
		Log(0, "Renamed $rnfm to $rnto.\n");
		return ($rnto);
	} else {
		Log(0, "Could not rename $rnfm to $rnto: $!\n");
		return ("");
	}
}	# Rename




sub RemoveFromEtcServices
{
	my (@services_to_remove) = @_;
	my ($service_to_remove);
	my ($line);
	my ($nchanged) = 0;
	my (@service_lines);

	if (open(ETCSERVICES, "</etc/services")) {
		@service_lines = <ETCSERVICES>;
		close(ETCSERVICES);
		foreach $line (@service_lines) {
			for $service_to_remove (@services_to_remove) {
				if ($line =~ /^$service_to_remove\s/) {
					$line = "#uninstall_ncftpd.pl# $line";
					$nchanged++;
				}
			}
		}
		if (open(ETCSERVICES, ">/etc/services")) {
			print ETCSERVICES @service_lines;
			close(ETCSERVICES);
			Log(0, "Commented out $nchanged lines in /etc/services that had been added.\n");
		}
	}
}	# RemoveFromEtcServices




sub RemoveGroup
{
	my ($ftpgroup) = @_;
	my ($ftpgid);

	if ($SYS eq "macosx") {
		system("niutil", "-destroyprop", "/", "/groups/$ftpgroup", "passwd");
		system("niutil", "-destroyprop", "/", "/groups/$ftpgroup", "gid");
		system("niutil", "-destroy",     "/", "/groups/$ftpgroup");
	} elsif ($SYS eq "bsdos") {
		system("/usr/sbin/rmgroup", $ftpgroup);
	} elsif ($SYS eq "aix") {
		system("/usr/bin/rmgroup", $ftpgroup);
	} elsif ($SYS eq "sco") {
		system("/etc/groupdel", $ftpgroup);
	} elsif (($SYS =~ /^(openbsd|netbsd|solaris|linux|tru64unix|digitalunix|unixware|openunix|hpux)$/) && (-x "/usr/sbin/groupdel")) {
		system("/usr/sbin/groupdel", $ftpgroup);
	}

	$ftpgid = getgrnam($ftpgroup);
	if ((defined($ftpgid)) && ($ftpgid > 0)) {
		Log(0, "Could not remove group $ftpgroup (UID $ftpgid)\n");
	} else {
		Log(0, "Removed group $ftpgroup.\n");
	}
}	# RemoveGroup




sub RemoveUser
{
	my ($ftpuser) = @_;
	my ($ftpuid);

	if ($SYS eq "macosx") {
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "shell");
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "passwd");
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "realname");
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "uid");
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "gid");
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "home");
		# system("niutil", "-destroyprop", "/", "/users/$ftpuser", "_shadow_passwd");
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "expire");
		system("niutil", "-destroyprop", "/", "/users/$ftpuser", "change");
		system("niutil", "-destroy",     "/", "/users/$ftpuser");
	} elsif ($SYS =~ /^irix/) {
		# There doesn't seem to be a corresponding groupmgmt.
		system("/usr/sbin/passmgmt", "-d", $ftpuser);
	} elsif ($SYS eq "bsdos") {
		system("/usr/sbin/rmuser", $ftpuser);
	} elsif ($SYS eq "aix") {
		# User will get created with a regular shell, 
		# but they can't login in since we set su,rlogin,login=false.
		#
		system("/usr/bin/rmuser", $ftpuser);	# rmuser -p ?
	} elsif ($SYS eq "sco") {
		system("/etc/userdel", $ftpuser);
	} elsif (($SYS =~ /^(openbsd|netbsd|linux|tru64unix|digitalunix|solaris|unixware|openunix|hpux)$/) && (-x "/usr/sbin/userdel")) {
		system("/usr/sbin/userdel", $ftpuser);
	}
	
	$ftpuid = getpwnam($ftpuser);
	if ((defined($ftpuid)) && ($ftpuid > 0)) {
		Log(0, "Could not remove user $ftpuser (UID $ftpuid).\n");
	} else {
		Log(0, "Removed user $ftpuser.\n");
	}
}	# RemoveUser




sub UncommentFTPUsers
{
	my ($filename) = @_;
	my ($disableprefix);

	$disableprefix = "#DISABLED by install_ncftpd.pl# ";
	$filename = "/etc/ftpusers" unless (defined($filename));
	UncommentFile($filename, $disableprefix);
}	# UncommentFTPUsers




sub UncommentOutFTPLineInInetdConf
{
	my ($filename) = @_;
	my ($disableprefix);

	$disableprefix = "#DISABLED by install_ncftpd.pl# ";
	$filename = "/etc/inetd.conf" unless (defined($filename));
	if (UncommentFile($filename, $disableprefix)) {
		IsThereAnFTPServerServing();
		TellInetdToReloadConfiguration();
	}
}	# UncommentOutFTPLineInInetdConf




sub UncommentOutFTPLineInXinetdConf
{
	my ($filename) = @_;
	my ($disableprefix);

	$disableprefix = "#DISABLED by install_ncftpd.pl# ";
	$filename = "/etc/xinetd.conf" unless (defined($filename));
	if (UncommentFile($filename, $disableprefix)) {
		IsThereAnFTPServerServing();
		TellXinetdToReloadConfiguration();
	}
}	# UncommentOutFTPLineInXinetdConf




sub UncommentOutFTPLineInXinetdD
{
	my ($filename) = @_;
	my ($disableprefix);

	$disableprefix = "#DISABLED by install_ncftpd.pl# ";
	if (defined($filename)) {
		UncommentFile($filename, $disableprefix);
	}
	if (UncommentFile($filename, $disableprefix)) {
		IsThereAnFTPServerServing();
		TellXinetdToReloadConfiguration();
	}
}	# UncommentOutFTPLineInXinetdD




sub TellInitToReloadConfiguration
{
	my ($init) = SearchPath("init", "/sbin:/usr/sbin:/usr/bin:/bin");

	$init = "init" unless ($init);
	Log(0, "Running \"$init q\" to reload modified /etc/inittab.\n");
	system($init, "q");
}	# TellInitToReloadConfiguration




sub UncommentOutFTPLinesInInittab
{
	my ($filename) = @_;
	my ($disableprefix);

	$disableprefix = "#DISABLED by install_ncftpd.pl# ";
	$filename = "/etc/inittab" unless (defined($filename));
	if (UncommentFile($filename, $disableprefix)) {
		TellInitToReloadConfiguration();
		KillFTPd("ncftpd");
		sleep(3);
		IsThereAnFTPServerServing();
	}
}	# UncommentOutFTPLinesInInittab




sub RemoveInittabEntry
{
	my ($line) = @_;

	$line = "nc:" unless (defined($line));	# Remove lines prefixed with our "nc:" prefix.
	if (RemoveLinesFromFile("/etc/inittab", $line)) {
		TellInitToReloadConfiguration();
		KillFTPd("ncftpd");
		sleep(3);
		IsThereAnFTPServerServing();
	}
}	# RemoveInittabEntry




sub RemoveRcLocalEntry
{
	my ($rc_local, $line) = @_;

	$rc_local = "/etc/rc.local" unless (defined($rc_local));
	$line = "/etc/rc.ncftpd" unless (defined($line));
	RemoveLinesFromFile($rc_local, $line);
}	# RemoveRcLocalEntry




sub GenericUninstall
{
	if ($generic_uninstall) {
		IsThereAnFTPServerServing();
		RemoveRcLocalEntry();

		RemoveInittabEntry();
		UncommentOutFTPLinesInInittab();

		UncommentFTPUsers();

		UncommentOutFTPLineInInetdConf();
		UncommentOutFTPLineInXinetdConf();

		my (@xinetdd_files) = glob("/etc/xinetd.d/*");
		my ($filename);
		for $filename (@xinetdd_files) {
			UncommentOutFTPLineInXinetdD($filename);
		}
		IsThereAnFTPServerServing();
		Exit(0);
	}
}	# GenericUninstall




sub Main
{
#---prologue---#
#---begin prologue set by ./install_ncftpd.pl on 2017-03-27 21:09:04 +0530---#
	$OS = "linux-x86_64";
	$SYS = "linux";
	$linux_distro = "Red Hat";
	$ftpport = 21;
#---end prologue set by ./install_ncftpd.pl on 2017-03-27 21:09:04 +0530---#
	umask(077);
	Getopts();
	if (($> != 0) && (! $force_uninstall)) {
		Exit(1, "You need to be Superuser to uninstall NcFTPd.  You are UID ", $>, ".\n");
	}
	OpenLog();
	GenericUninstall();
#---host-specific---#
#---begin host-specifics set by ./install_ncftpd.pl on 2017-03-27 21:09:04 +0530---#
	IsThereAnFTPServerServing();
	Remove("/u01/ncftpd/etc/ncftpd/install_ncftpd.log");
	system("/bin/systemctl", "stop", "ncftpd.service");
	system("/bin/systemctl", "disable", "ncftpd.service");
	Remove("/lib/systemd/system/ncftpd.service");
	system("/bin/systemctl", "daemon-reload");
	Remove("/u01/ncftpd/sbin/stop_ncftpd");
	Remove("/u01/ncftpd/sbin/restart_ncftpd");
	Remove("/etc/rc.d/init.d/ncftpd");
	Remove("/u01/ncftpd/etc/ncftpd/uninstall_ncftpd.pl");
	Remove("/u01/ncftpd/bin/pkill.pl");
	Remove("/u01/ncftpd/bin/pgrep.pl");
	Remove("/u01/ncftpd/sbin/ncftpd_ping");
	Remove("/u01/ncftpd/sbin/ncftpd_repquota");
	Remove("/u01/ncftpd/sbin/ncftpd_edquota");
	Remove("/u01/ncftpd/sbin/ncftpd_passwd");
	Remove("/u01/ncftpd/sbin/ncftpd_spy");
	Remove("/u01/ncftpd/sbin/ncftpd");
	Remove("/u01/ncftpd/etc/ncftpd/domain.cf");
	Remove("/u01/ncftpd/etc/ncftpd/general.cf");
	Rmdir("/var/log/ncftpd");
	Rmdir("/u01/ncftpd/etc/ncftpd/rptbin");
	Rmdir("/u01/ncftpd/etc/ncftpd");
	Rmdir("/u01/ncftpd/etc");
	Rmdir("/u01/ncftpd/sbin");
	Rmdir("/u01/ncftpd/bin");
	system("/bin/systemctl", "start", "vsftpd.service");
	system("/bin/systemctl", "enable", "vsftpd.service");
	IsThereAnFTPServerServing();
	rename("/u01/ncftpd/etc/ncftpd/uninstall_ncftpd.pl", "/u01/ncftpd/etc/ncftpd/uninstall_ncftpd.pl.ran.once.already.pl");
	Exit(0);
#---end host-specifics set by ./install_ncftpd.pl on 2017-03-27 21:09:04 +0530---#
	Exit(6, "ERROR:\tNo host-specific uninstall information found.\n\tThis script is customized automatically by install_ncftpd.pl.\n\tYou may try \"$0 --generic\"\n\tif you wish to try a generic uninstallation.\n");
}	# Init

Main();
