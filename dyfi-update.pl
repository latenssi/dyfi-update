#!/usr/bin/perl
#
#    dyfi-update.pl
#    by dy.fi admins, admin at dy dot fi
#
#    A perl client for updating dy.fi hostnames automatically
#
#    Only requires perl 5.002 with Socket and strict modules,
#    HTTP and base64 code has been embedded.
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#

#
# TODO list:
#	- add a timeout in the HTTP client
#	- support checking local IP address from an interface
#	  (in case a public dynamic IP is given over PPP or DHCP,
#	  and no NAT is involved, we don't need to poll checkip!)
#

#
# CHANGELOG:
#
# Wed Jan 21 16:46:30 EET 2004 - admin at dy dot fi
#	- initial version 1.0.0
#
# Fri Mar 12 12:30:03 EET 2004 - admin at dy dot fi
#	- tuned timers
#	- version 1.0.1
#
# Mon Apr 12 10:08:47 EEST 2004 - admin at dy dot fi
#	- do not write to STDERR with warn() when we encounter an error,
#	  STDERR is not writable when we're started from an init script on
#	  RH linux, maybe others. Writing there gives us an SIGPIPE, which
#	  causes us to write an error log line, which gives us an SIGPIPE,
#	  which...
#	- try to flock() the PID file so that only one copy of the client
#	  can run at a time - a lot of people accidentally put this
#	  _daemon_ in their crontab, and soon run a hundred or a thousand
#	  copies of this script, eating their bandwidth.
#	- made the pid file a mandatory parameter
#	- export the pid of this process in the user-agent string
#	  (helps spotting multiple copies of the same client on the
#	  same machine hammering the service down - a customer service FAQ)
#	- added a Makefile for installing and uninstalling
#	- added the GPL COPYING file
#	- added a README
#	- version 1.1.0
#
# Wed Nov 10 00:43:36 EET 2004 - admin at dy dot fi
#	- if 'release' is enabled in configuration file, release the
#	  hosts using a release request when shutting down (Thanks for
#	  the patch go to Asko Leivonm�ki)
#	- install K01dyfi-update shutdown SysV init links (Asko)
#	- if /var/lock/subsys exists, create/delete subsys lock files
#	  in the init script so that RH/Fedora init scripts will run
#	  the K01dyfi-update stop scripts (Asko)
#	- create /usr/local/(etc|bin) when installing, if necessary
#	- minor documentation fix (correct config file location)
#	- truncate pid file after successful locking => do not loose
#	  the pid of an older running instance if the locking fails
#	- detect and log 'abuse' replies from the service, and quit
#	  immediately (since the service is denying our requests anyway),
#	  typically caused by script being installed in a crontab and
#	  a hundred copies hammering in parallel
#	- version 1.2.0
#
# Thu Feb 25 2016 - latenssi at gmail dot com
#	- Docker compatible version 2.0.0

#
# PLEASE - if you make modifications to this script, and redistribute the
# modified version, please send a copy to us too, so that we can incorporate
# your changes to the original script. Also, if you redistribute your version
# directly, please rename the script so that we won't get overlapping version
# numbers when we do an 'official' distribution with the same version number.
# Thank you!
#

require 5.002;
use Socket;
use strict;
use Fcntl qw(:flock);

my ($debug, $log, $pidfile, $cfgfile,
	$update_host, $update_uri, $update_port,
	$checkip_host, $checkip_uri, $checkip_port,
	$username, $password, @hosts, $do_release);

# Default settings:

# print lots of stuff?
$debug = 0;
# log to a file, or "-" for stdout?
$log = "-";
# release hosts at shutdown?
$do_release = 0;

# update server location
# use port 8180 if it works for you
# if it doesn't, try port 80 instead (it won't work if you're behind
# a transparent proxy)
$update_host = 'www.dy.fi';
$update_uri = '/nic/update';
$update_port = 8180;
# checkip server
$checkip_host = 'checkip.dy.fi';
$checkip_uri = '/';
$checkip_port = 8180;

######## That should be all you need to touch. ##############

my($me) = "dyfi-update.pl";
my($version) = "v2.0.0";

#
#	parse arguments
#

$username = $ENV{'DYFI_USERNAME'};
$password = $ENV{'DYFI_PASSWORD'};
$do_release = $ENV{'DYFI_RELEASE'};
push @hosts, $ENV{'DYFI_HOST'};

$pidfile = '/var/run/dyfi-update.pid';

#
#	signal handlers
#

sub sighandler {
	my $signame = shift;

	if (($signame == 'TERM') && ($do_release)) {
		info('got SIGTERM - releasing host(s) and quitting');
		release();
	} else {
		error("got SIG$signame - quitting");
	}

	exit;
}

sub pipehandler {
	error('got SIGPIPE');
	return;
}

#
#	Base64 encoding code from MIME::Base64
#	which is Copyright 1995-1999, 2001 Gisle Aas.
#
sub encode_base64 ($) {
	my $res = "";
	pos($_[0]) = 0;                          # ensure start at the beginning

	$res = join '', map( pack('u',$_)=~ /^.(\S*)/, ($_[0]=~/(.{1,45})/gs));

	$res =~ tr|` -_|AA-Za-z0-9+/|;               # # help emacs
	# fix padding at the end
	my $padding = (3 - length($_[0]) % 3) % 3;
	$res =~ s/.{$padding}$/'=' x $padding/e if $padding;
	return $res;
}

#
#	cleanup whitespace
#

sub cleanup {
	$_[0] =~ s/^\s+//;
	$_[0] =~ s/\s+$//;
	$_[0] =~ s/\s+/ /g;
}

#
#	send to socket
#

sub ssend {
	return syswrite(SOCK, $_[0], length($_[0]));
}

#
#	a simple and stupid HTTP GET client
#	included here so that we would not depend on any specific
#	module being installed.
#	TODO: add timeout support!
#

sub htget {
	my($ht_host, $ht_port, $ht_uri, $ht_user, $ht_passwd) = @_;

	my($basicauth) = '';
	if ($ht_user && $ht_passwd) {
		$basicauth = sprintf("Authorization: Basic %s\r\n",
			encode_base64("$ht_user:$ht_passwd"));
	}

	debug("HTTP GET request to $ht_host:$ht_port $ht_uri");
	my($iaddr, $paddr, $proto);
	if (!($iaddr = inet_aton($ht_host))) {
		error("Cannot resolve host address for $ht_host: $!");
		return;
	}
	if (!($paddr = sockaddr_in($ht_port, $iaddr))) {
		error("sockaddr_in() for $ht_host:$ht_port failed: $!");
		return;
	}
	if (!($proto = getprotobyname('tcp'))) {
		error("getprotobyname(tcp) failed: $!");
		return;
	}

	if (!socket(SOCK, PF_INET, SOCK_STREAM, $proto)) {
		error("Cannot get socket: $!");
		return;
	}

	if (!connect(SOCK, $paddr)) {
		error("Cannot connect to $ht_host:$ht_port: $!");
		return;
	}

	my($request)	= "GET $ht_uri HTTP/1.0\r\n"
			. $basicauth
			. "User-Agent: $me $version ($$)\r\n"
			. "Host: $ht_host\r\n"
			. "Pragma: no-cache\r\n"
			. "Cache-Control: no-cache\r\n"
			. "\r\n";

	if (!ssend($request)) {
		error("Could not send request to $ht_host:$ht_port: $!");
		return;
	}

	my($state) = 0;
	my($line, $data) = ("", "");

	my($proto, $rcode, $rtext, %headers);
	while ($line = <SOCK>) {
		if ($state == 0) {
			# waiting for HTTP response
			cleanup($line);
			my @rt;
			($proto, $rcode, @rt) = split(' ', $line);
			$rtext = join(' ', @rt);
			if ($rcode != 200) {
				error("Request failed, server replied: $rcode $rtext");
				return ($rcode, $rtext);
			}
			$state++;
		} elsif ($state eq 1) {
			# reading HTTP headers
			cleanup($line);
			if ($line =~ /^([^:]+):\s+(.*)$/) {
				$headers{lc($1)} = $2;
			}
			if ($line eq "") { $state++; }
		} elsif ($state eq 2) {
			# reading content
			$data .= $line;
		}
	}

	if (!close(SOCK)) {
		error("Closing socket after reading reply failed: $!");
	}

	debug("HTTP GET finished successfully");
	return ($rcode, $rtext, $data, %headers);
}

#
#	logging functions
#

sub write_log {
	my($s) = @_;
	my(@tf) = localtime();
	my($tstamp) = sprintf("%04d.%02d.%02d %02d:%02d:%02d",
		@tf[5]+1900, @tf[4]+1, @tf[3], @tf[2], @tf[1], @tf[0]);

	print "$tstamp [$$] $s\n";
}

sub debug {
	if ($debug) {
		write_log("[DEBUG] @_");
	}
}

sub info {
	write_log("[INFO] @_");
}

sub error {
	# if ($log ne "-") { warn("$me: @_\n"); }
	write_log("[ERROR] @_");
}

sub crash {
	error("Crashed and burned: @_");
	exit(1);
}

#
#	write pid file
#

sub writepid {
	my($f) = @_;
	open(PF, ">>$f") || crash("Could not open $f for writing pid: $!");
	my $ofh = select(PF); $| = 1; select($ofh); # autoflush
	flock(PF, LOCK_EX|LOCK_NB) || crash("Could not flock pid file (other copy already running?): $!");
	truncate(PF, 0) || crash("Could not truncate pid file: $!");
	seek(PF, 0, 0) || crash("Could not seek to beginning of pid file: $!");
	print PF "$$\n" || crash("Could not write pid to $f: $!");
}

#
#	check my current IP address
#	TODO: add support for simply getting the address of an interface
#	in case of direct public IP assignment using DHCP/PPP
#

sub checkip {
	my ($rcode, $rtext, $data, %headers) = htget($checkip_host, $checkip_port, $checkip_uri);

	if ($data =~ /ip\s+address:\s+(\d+\.\d+\.\d+\.\d+)/i) {
		return $1;
	} else {
		error("Current IP address check failed!");
		return;
	}
}

#
#	parse dy.fi error codes
#

sub dyfi_errorcode {
	my(%errorcodes) = (
		'abuse'		=> 'The service feels YOU are ABUSING it!',
		'badauth'	=> 'Authentication failed',
		'nohost'	=> 'No hostname given for update, or hostname not yours',
		'notfqdn'	=> 'The given hostname is not a valid FQDN',
		'badip'		=> 'The client IP address is not valid or permitted',
		'dnserr'	=> 'Update failed due to a problem at dy.fi',
		'good'		=> 'The update was processed successfully',
		'nochg'		=> 'The successful update did not cause a DNS data change'
	);

	my($c) = (split(' ', $_[0]))[0];
	if ($errorcodes{$c}) {
		return $errorcodes{$c};
	} else {
		return $_[0];
	}
}

#
#	make an update request to dy.fi
#

sub update {
	my $uri = $update_uri . "?hostname=" . join(',', @hosts);
	my ($rcode, $rtext, $data, %headers) = htget($update_host, $update_port, $uri, $username, $password);

	if ($rcode ne 200 || lc($headers{'content-type'}) !~ /^text\/plain/ || !$data) {
		error("hostname update failed!");
		if ($rcode > 0) {
			# if this was not a network failure, don't retry quickly
			return 1;
		}
		return;
	}

	my(@rlines) = split("\n", $data);
	my($s);
	my($n) = 0;
	foreach $s (@rlines) {
		cleanup($s);
		if ($s eq "") { next; }
		debug("response for @hosts[$n]: $s");
		if ($s eq "nochg") {
			info("Successful refresh: @hosts[$n]");
		} elsif ($s =~ /good\s+(\d+\.\d+\.\d+\.\d+)/) {
			info("Successful update: @hosts[$n] pointed to $1");
		} else {
			error("Update failed: @hosts[$n] " . dyfi_errorcode($s));
		}
		if ($s eq 'abuse') {
			crash('ABUSE detected by the service, my requests are being denied!');
		}
		$n++;
	}

	return 1;
}

#
#	make a release request to dy.fi
#

sub release {
	my $uri = $update_uri . "?hostname=" . join(',', @hosts) . "&offline=yes";
	my ($rcode, $rtext, $data, %headers) = htget($update_host, $update_port, $uri, $username, $password);

	if ($rcode ne 200 || lc($headers{'content-type'}) !~ /^text\/plain/ || !$data) {
		error("hostname release failed!");
		if ($rcode > 0) {
			# if this was not a network failure, don't retry quickly
			return 1;
		}
		return;
	}

	my(@rlines) = split("\n", $data);
	my($s);
	my($n) = 0;
	foreach $s (@rlines) {
		cleanup($s);
		if ($s eq "") { next; }
		debug("response for @hosts[$n]: $s");
		if ($s eq "good") {
			info("Successful release: @hosts[$n]");
		} else {
			error("Release failed: @hosts[$n] " . dyfi_errorcode($s));
		}
		$n++;
	}

	return 1;
}

#
#	main #####
#

writepid($pidfile);

info("$me $version started up");

# catch signals
$SIG{'INT'} = $SIG{'QUIT'} = $SIG{'HUP'} = $SIG{'TERM'} = 'sighandler';
$SIG{'PIPE'} = 'pipehandler';

#### Please do not tune these significantly. #####
# Do an update when minimum_refresh seconds have passed even though IP
# address has not changed. dy.fi deletes old entries in 7 days, so
# refreshing every 23 hours should be often enough. We add a random
# component of up to 10 minutes to distribute dy.fi's load over time.
#
my($minimum_refresh) = 23 * 60 * 60;
my($minimum_refresh_rand) = 10 * 60;
#
# check ip address every check_interval + a random component of
# up to check_interval rand. 4 to 6 minutes should be often enouh.
my($check_interval) = 4*60;
my($check_interval_rand) = 2*60;

################################################

# time of next refresh
my($next_refresh) = 0;
# current address
my($current_ip);

while (1) {
	my $now = time();
	debug("--- getting current ip address ---");
	my $ip;
	$ip = checkip();
	if (!$ip) {
		# IP check failed
	} elsif ($ip eq $current_ip) {
		debug("current address is $ip, not changed from last check");
		if ($now >= $next_refresh) {
			debug("minimum refresh interval met -> updating anyway");
			if (update()) {
				$next_refresh = sprintf("%d", $now + $minimum_refresh + rand($minimum_refresh_rand));
			}
		}
	} else {
		debug("current address is $ip, changed -> updating");
		$current_ip = $ip;
		if (update()) {
			$next_refresh = sprintf("%d", $now + $minimum_refresh + rand($minimum_refresh_rand));
		}
	}

	my $sleeptime = sprintf("%d", $check_interval + rand($check_interval_rand));
	debug("sleeping for $sleeptime seconds...");
	sleep($sleeptime);
}
