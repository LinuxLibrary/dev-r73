#!/usr/bin/perl -w
#
# Copyright (C) 2002 by Mike Gleason, NcFTP Software.
# All Rights Reserved.
#
use strict;
use Config;

my (%opts)			= ();
my ($match_mode) 		= "path";
my ($delim)			= "\n";
my ($pattern);
my ($pid, @pids);
my (@exclude_pids)		= ();
my ($full_pattern)		= "";
my ($output)			= "pids";
my ($psignal)			= "TERM";
my ($is_pkill)			= 0;		# pgrep by default
my ($prog)			= $0;




sub Usage
{
	if ($is_pkill) {
		# pkill
		print STDERR "$prog for $^O using $^X\n";
		print STDERR "Usage: $prog [-f|-x] [-SIG] <pattern> [<pattern>...]\n";
		print STDERR "Options:\n";
		print STDERR "  -f     : Match processes by full pathname.\n";
		print STDERR "  -x     : Match processes only by filename.\n";
		print STDERR "  -X pid : Exclude pid from list of matches.\n";
		print STDERR "Examples:\n";
		print STDERR "  $prog ssh                      # Any program containing ssh (ssh, sshd)\n";
		print STDERR "  $prog -TERM -x ssh             # Match ssh but not sshd nor zssh\n";
		print STDERR "  $prog -HUP -f /usr/sbin/inetd  # Match that but not /etc/inetd\n";
		print STDERR "  $prog -9 -x \'n.*d\'             # Match ntpd, ncftpd, nfsd...\n";
	} else {
		# pgrep
		print STDERR "$prog for $^O using $^X\n";
		print STDERR "Usage: $prog [-f|-x] [-l] [-d delim] <pattern> [<pattern>...]\n";
		print STDERR "Options:\n";
		print STDERR "  -f     : Match processes by full pathname.\n";
		print STDERR "  -x     : Match processes only by filename.\n";
		print STDERR "  -l     : Print detailed output rather than just PIDs.\n";
		print STDERR "Examples:\n";
		print STDERR "  $prog ssh                      # Any program containing ssh (ssh, sshd)\n";
		print STDERR "  $prog -x ssh                   # Match ssh but not sshd nor zssh\n";
		print STDERR "  $prog -f /usr/sbin/inetd       # Match that but not /etc/inetd\n";
		print STDERR "  $prog -l -x \'n.*d\'             # Match ntpd, ncftpd, nfsd...\n";
	}
	exit(2);
}	# Usage




sub SignalNameToNumber
{
	my ($psignal) = $_[0];
	return 0 unless defined($psignal);

	# Be sure to "use Config;"
	if (defined($Config{sig_name})) {
		my (%signames) = ();
		my ($signame);
		my ($i) = 0;

		foreach $signame (split(' ', $Config{sig_name})) {
			$signames{$signame} = $i++;
		}
		if ($psignal =~ /^\d+$/) {
			if (($psignal > 0) && ($psignal < scalar(keys %signames))) {
				return $psignal;
			} else {
				return 0;
			}
		} elsif (! defined($signames{$psignal})) {
			return 0;
		}
		$psignal = $signames{$psignal};
		return ($psignal);
	}
	return 0;
}	# SignalNameToNumber




sub Getopts
{
	my ($arg);
	my ($optarg);
	my ($optind);

	for ($optind = 0; $optind < scalar(@ARGV); $optind++) {
		$arg = $ARGV[$optind];
		$optarg = (($optind + 1) < scalar(@ARGV)) ? $ARGV[$optind + 1] : undef;

		# pgrep, pkill: -X
		if ($arg =~ /^-X(.*)/) {
			if ($1 eq "") {
				return 0 unless defined($optarg);
				$optind++;
			} else {
				$optarg = $1;
			}
			if (defined($opts{"X"})) {
				$opts{"X"} .= "," . $optarg;
			} else {
				$opts{"X"} = $optarg;
			}
			next;
		}

		# pgrep, pkill: -x
		if ($arg eq "-x") {
			$opts{"x"} = 1;
			next;
		}

		# pgrep, pkill: -f
		if ($arg eq "-f") {
			$opts{"f"} = 1;
			next;
		}

		# pgrep: -l
		if ((! $is_pkill) && ($arg eq "-l")) {
			$opts{"l"} = 1;
			next;
		}

		# pgrep: -d XX
		if ((! $is_pkill) && ($arg =~ /^-d(.*)/)) {
			if ($1 eq "") {
				return 0 unless defined($optarg);
				$opts{"d"} = $optarg;
				$optind++;
			} else {
				$optarg = $1;
				$opts{"d"} = $optarg;
			}
			next;
		}

		# pkill: -SIGNAME
		if (($is_pkill) && ($arg =~ /^\-([A-Z]{3,})$/)) {
			$psignal = SignalNameToNumber($1);
			if (! $psignal) {
				$psignal = $1;
				print STDERR "Invalid signal name: \"$psignal\"\n";
				return 0;
			}
			next;
		}

		# pkill: -SIG#
		if (($is_pkill) && ($arg =~ /^\-(\d+)$/)) {
			$psignal = $1;
			$psignal = SignalNameToNumber($1);
			if (! $psignal) {
				$psignal = $1;
				print STDERR "Invalid signal number: \"$psignal\"\n";
				return 0;
			}
			next;
		}

		if ($arg =~ /^(\-.*)$/) {
			$arg = $1;
			print STDERR "Unknown option: ", $arg, "\n";
			return 0;
		}
		last;
	}
	while ($optind-- > 0) {
		shift(@ARGV);
	}
	return 1;
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
			#
			# -o args prints only the command-line arguments
			# -o comm prints only the program name
			# -o command prints both program and args
			#
			$pscmd = "/bin/ps -e -o pid,comm";
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
			$command_pos = index($line, "ARGS") if ($command_pos <= 0);
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




sub Main
{
	my (@pre_pids);
	my ($pid, $xpid);
	my ($exclude);

	$prog = $1 if ($prog =~ /^.*\/(.*)$/);
	if ($prog =~ /^pkill/) {
		$is_pkill = 1;
	}
	Getopts() or Usage();

	@exclude_pids = split(/[,\s]/, $opts{"X"}) if defined($opts{"X"});
	$match_mode = "program" if defined($opts{"x"});
	$match_mode = "full" if defined($opts{"f"});
	$delim = $opts{"d"} if defined($opts{"d"});
	$output = "long" if defined($opts{"l"});

	if (scalar(@ARGV) == 0) {
		print STDERR "$prog: No matching criteria specified\n";
		Usage();
	}

	for $pattern (@ARGV) {
		if (! $full_pattern) {
			$full_pattern = $pattern
		} else {
			$full_pattern .= "|" . $pattern;
		}
	}

	@pids = ();
	@pre_pids = PsGrep($full_pattern, $match_mode, $output);

	for $pid (@pre_pids) {
		$exclude = 0;
		for $xpid (@exclude_pids) {
			$exclude = 1 if ($pid =~ /^\D*$xpid\D*/);
		}
		push(@pids, $pid) unless ($exclude);
	}

	exit(1) if (scalar(@pids) == 0);

	if ($is_pkill) {
		for $pid (@pids) {
			if (! kill($psignal, $pid)) {
				print STDERR "$prog: Failed to signal pid $pid: $!\n";
			}
		}
	} else {
		if ($delim eq "\n") {
			for $pid (@pids) {
				print $pid, $delim;
			}
		} else {
			my ($first) = 1;
			for $pid (@pids) {
				print $delim unless ($first);
				print $pid;
				$first = 0;
			}
			print "\n";
		}
	}
	exit(0);
}	# Main

Main();
exit(3);


#     -d delim
#           Specifies the output delimiter string  to  be  printed
#           between  each  matching process ID. If no -d option is
#           specified, the default is a newline character.  The -d
#           option  is  only  valid when specified as an option to
#           pgrep.
#
#     -f    The  regular  expression  pattern  should  be  matched
#           against  the  full  process  argument string (obtained
#           from the pr_psargs  field  of  the  /proc/nnnnn/psinfo
#           file). If no -f option is specified, the expression is
#           matched only against the name of the  executable  file
#           (obtained    from    the   pr_fname   field   of   the
#           /proc/nnnnn/psinfo file).
#
#     -l    Long output format. Prints the process name along with
#           the  process  ID of each matching process. The process
#           name is obtained from the pr_psargs or pr_fname field,
#           depending  on whether the -f option was specified (see
#           above). The -l option is only valid when specified  as
#           an option to pgrep.
#
#     -x    Considers only processes whose argument string or exe-
#           cutable  file  name exactly matches the specified pat-
#           tern to be matching processes. The  pattern  match  is
#           considered to be exact when all characters in the pro-
#           cess argument string or executable file name match the
#           pattern.


# EXIT STATUS
#     The following exit values are returned:
#
#     0     One or more processes were matched.
#
#     1     No processes were matched.
#
#     2     Invalid command line options were specified.
#
#     3     A fatal error occurred.
