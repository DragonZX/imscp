#!/usr/bin/perl

=head1 NAME

 Servers::po::dovecot - i-MSCP Dovecot IMAP/POP3 Server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2013 by internet Multi Server Control Panel
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# @category    i-MSCP
# @copyright   2010-2013 by i-MSCP | http://i-mscp.net
# @author      Daniel Andreca <sci2tech@gmail.com>
# @author      Laurent Declercq <l.declercq@nuxwin.com>
# @link        http://i-mscp.net i-MSCP Home Site
# @license     http://www.gnu.org/licenses/gpl-2.0.html GPL v2

package Servers::po::dovecot;

use strict;
use warnings;

use iMSCP::Debug;
use iMSCP::HooksManager;
use iMSCP::Config;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::Dir;
use Tie::File;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Dovecot IMAP/POP3 Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupHooks($hooksManager)

 Register setup hooks.

 Param iMSCP::HooksManager $hooksManager Hooks manager instance
 Return int 0 on success, other on failure

=cut

sub registerSetupHooks
{
	my $self = shift;
	my $hooksManager = shift;

	require Servers::po::dovecot::installer;
	Servers::po::dovecot::installer->getInstance(
		dovecotConfig => \%self::dovecotConfig
	)->registerSetupHooks($hooksManager);
}

=item install()

 Process install tasks.

 Return int 0 on success, other on failure

=cut

sub install
{
	my $self = shift;

	require Servers::po::dovecot::installer;
	Servers::po::dovecot::installer->getInstance(dovecotConfig => \%self::dovecotConfig)->install();
}

=item postinstall()

 Process postinstall tasks.

 Return int 0 on success, other on failure

=cut

sub postinstall
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforePoPostinstall', 'dovecot');
	return $rs if $rs;

	$self->{'restart'} = 'yes';

	$self->{'hooksManager'}->trigger('afterPoPostinstall', 'dovecot');
}

=item postaddMail()

 Create maildir folders and subscription file.

 Return int 0 on success, other on failure

=cut

sub postaddMail
{
	my $self = shift;
	my $data = shift;
	my $rs = 0;

	if($data->{'MAIL_TYPE'} =~ /_mail/) {

		# Getting i-MSCP MTA server implementation instance
		require Servers::mta;
		my $mta = Servers::mta->factory();

		my $mailDir = "$mta->{'MTA_VIRTUAL_MAIL_DIR'}/$data->{'DOMAIN_NAME'}/$data->{'MAIL_ACC'}";
		my $mailUidName =  $mta->{'MTA_MAILBOX_UID_NAME'};
		my $mailGidName = $mta->{'MTA_MAILBOX_GID_NAME'};

		for ("$mailDir/.Drafts", "$mailDir/.Junk", "$mailDir/.Sent", "$mailDir/.Trash") {

			# Creating maildir directory or only set its permissions if already exists
			$rs = iMSCP::Dir->new('dirname' => $_)->make(
				{ 'user' => $mailUidName, 'group' => $mailGidName , 'mode' => 0750 }
			);
			return $rs if $rs;

			# Creating maildir sub folders (cur, new, tmp) or only set there permissions if they already exists
			for my $subdir ('cur', 'new', 'tmp') {
				$rs = iMSCP::Dir->new('dirname' => "$_/$subdir")->make(
					{ 'user' => $mailUidName, 'group' => $mailGidName, 'mode' => 0750 }
				);
				return $rs if $rs;
			}
		}

		# Creating/updating subscriptions file

		my @subscribedFolders = ('Drafts', 'Junk', 'Sent', 'Trash');
		my $subscriptionsFile = iMSCP::File->new('filename' => "$mailDir/subscriptions");

		if(-f "$mailDir/subscriptions") {
			my $subscriptionsFileContent = $subscriptionsFile->get();

			if(! defined $subscriptionsFileContent) {
				error('Unable to read dovecot subscriptions file');
				return 1;
			}

			if($subscriptionsFileContent ne '') {
				@subscribedFolders = (@subscribedFolders, split("\n", $subscriptionsFileContent));
				require List::MoreUtils;
				@subscribedFolders = sort(List::MoreUtils::uniq(@subscribedFolders));
			}
		}

		$rs = $subscriptionsFile->set((join "\n", @subscribedFolders) . "\n");
		return $rs if $rs;

		$rs = $subscriptionsFile->save();
		return $rs if $rs;

		$rs = $subscriptionsFile->mode(0640);
		return $rs if $rs;

		$rs = $subscriptionsFile->owner($mailUidName, $mailGidName);
		return $rs if $rs;
	}

	0;
}

=item uninstall()

 Process uninstall tasks.

 Return int 0 on success, other on failure

=cut

sub uninstall
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforePoUninstall', 'dovecot');
	return $rs if $rs;

	require Servers::po::dovecot::uninstaller;

	$rs = Servers::po::dovecot::uninstaller->getInstance()->uninstall();
	return $rs if $rs;

	$rs = $self->restart();
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterPoUninstall', 'dovecot');
}

=item restart()

 Restart the server.

 Return int 0, other on failure

=cut

sub restart
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforePoRestart');
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute("$self::dovecotConfig{'CMD_DOVECOT'} restart", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $stderr && $rs;
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterPoRestart');
}


=item getTraffic()

 Get server traffic.

 Return int Traffic amount, 0 on failure

=cut

sub getTraffic
{
	my $self = shift;
	my $who = shift;
	my $dbName = "$self->{'wrkDir'}/log.db";
	my $logFile = "$main::imscpConfig{'TRAFF_LOG_DIR'}/mail.log";
	my $wrkLogFile = "$main::imscpConfig{'LOG_DIR'}/mail.po.log";
	my ($rv, $rs, $stdout, $stderr);

	$self->{'hooksManager'}->trigger('beforePoGetTraffic') and return 0;

	# only if files was not already parsed this session
	unless($self->{'logDb'}){
		# use a small conf file to memorize last line readed and his content
		tie %{$self->{'logDb'}}, 'iMSCP::Config','fileName' => $dbName, noerrors => 1;

		# first use? we zero line and content
		$self->{'logDb'}->{'line'} = 0 unless $self->{'logDb'}->{'line'};
		$self->{'logDb'}->{'content'} = '' unless $self->{'logDb'}->{'content'};
		my $lastLineNo = $self->{'logDb'}->{'line'};
		my $lastLine = $self->{'logDb'}->{'content'};

		# copy log file
		$rs = iMSCP::File->new(filename => $logFile)->copyFile($wrkLogFile) if -f $logFile;
		# return 0 traffic if we fail
		return 0 if $rs;

		# link log file to array
		tie my @content, 'Tie::File', $wrkLogFile or return 0;

		# save last line
		$self->{'logDb'}->{'line'} = $#content;
		$self->{'logDb'}->{'content'} = $content[$#content];

		# test for logratation
		if($content[$lastLineNo] && $content[$lastLineNo] eq $lastLine){
			## No logratation ocure. We zero already readed files
			(tied @content)->defer;
			@content = @content[$lastLineNo + 1 .. $#content];
			(tied @content)->flush;
		}

		# Read log file
		my $content = iMSCP::File->new(filename => $wrkLogFile)->get() || '';

		# IMAP
		# Oct 15 13:50:31 daniel dovecot: imap(ndmn@test1.eu.bogus): Disconnected: Logged out bytes=235/1032
		# 1   2     3      4      5                6                      7          8    9      10
		while($content =~ m/^.*imap\([^\@]+\@([^\)]+).*Logged out bytes=(\d+)\/(\d+)$/mg){
					# date time   mailfrom @ domain                    size / size
					#                           1                       2       3
			$self->{'traff'}->{$1} += $2 + $3 if $1 && defined $2 && defined $3 && ($2+$3);
			debug("Traffic for $1 is $self->{'traff'}->{$1} (added IMAP traffic: ". ($2 + $3).")") if $1 && defined $2 && defined $3 && ($2+$3);
		}

		# POP
		# Oct 15 14:23:39 daniel dovecot: pop3(ndmn@test1.eu.bogus): Disconnected: Logged out top=0/0, retr=1/533, del=0/1, size=517
		# 1   2     3      4      5                6                      7          8    9      10       11        12       13
		while($content =~ m/^.*pop3\([^\@]+\@([^\)]+).*Logged out .* retr=(\d+)\/(\d+).*$/mg){
					# date time   mailfrom @ domain                    size / size
					#                           1                       2       3
			$self->{'traff'}->{$1} += $2 + $3 if $1 && defined $2 && defined $3 && ($2+$3);
			debug("Traffic for $1 is $self->{'traff'}->{$1} (added POP traffic: ". ($2 + $3).")") if $1 && defined $2 && defined $3 && ($2+$3);
		}
	}

	$self->{'hooksManager'}->trigger('afterPoGetTraffic') and return 0;

	$self->{'traff'}->{$who} ? $self->{'traff'}->{$who} : 0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Called by getInstance(). Initialize instance.

 Return Servers::po::dovecot

=cut

sub _init
{
	my $self = shift;

	$self->{'hooksManager'} = iMSCP::HooksManager->getInstance();

	$self->{'hooksManager'}->trigger(
		'beforePoInit', $self, 'dovecot'
	) and fatal('dovecot - beforePoInit hook has failed');

	$self->{'cfgDir'} = "$main::imscpConfig{'CONF_DIR'}/dovecot";
	$self->{'bkpDir'} = "$self->{'cfgDir'}/backup";
	$self->{'wrkDir'} = "$self->{'cfgDir'}/working";

	my $conf = "$self->{'cfgDir'}/dovecot.data";

	tie %self::dovecotConfig, 'iMSCP::Config','fileName' => $conf;

	$self->{'hooksManager'}->trigger(
		'afterPoInit', $self, 'dovecot'
	) and fatal('dovecot - afterPoInit hook has failed');

	$self;
}

=item END

 Code triggered at the very end of script execution.

-  Restart server if needed
 - Remove old traffic logs file if exists

 Return int Exit code

=cut

END
{
	my $self = Servers::po::dovecot->getInstance();
	my $wrkLogFile = "$main::imscpConfig{'LOG_DIR'}/mail.po.log";
	my $rs = 0;

	$rs = $self->restart() if $self->{'restart'} && $self->{'restart'} eq 'yes';
	$rs |= iMSCP::File->new(filename => $wrkLogFile)->delFile() if -f $wrkLogFile;

	$? ||= $rs;
}

=back

=head1 AUTHORS

 Daniel Andreca <sci2tech@gmail.com>
 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
