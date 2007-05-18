#!/usr/bin/perl
use Filter::Template;
const PCJx POE::Component::Jabber

use warnings;
use strict;

use Test::More tests => 12;
use IO::File;
use POE;
use PCJx;
use PCJx::Error;
use PCJx::Status;
use PCJx::ProtocolFactory;

my $file;
if(-e 'run_network_tests')
{
	$file = IO::File->new('< run_network_tests');

} else {

	SKIP: { skip('Network tests were declined', 12); }
	exit 1;
}

my $file_config = {};

my @lines = $file->getlines();
if(!@lines)
{
	SKIP: { skip('Component tests were declined', 12); }
	exit 1;
}

for(0..$#lines)
{	
	my $i = $_;

	if($lines[$_] =~ /#/i)
	{
		$lines[$_] =~ s/#+|\s+//g;
		my $hash = {};
		my $subline = $lines[++$i];
		do
		{	
			chomp($subline);
			my ($key, $value) = split(/=/,$subline);
			$hash->{lc($key)} = lc($value);
			$subline = $lines[++$i];
		
		} while(defined($subline) && $subline !~ /#/);

		$file_config->{lc($lines[$_])} = $hash;
	}
}

$file->close();
undef($file);

my $config = 
{
	IP => $file_config->{'jabberd14'}->{'ip'},
	Port => $file_config->{'jabberd14'}->{'port'},
	Hostname => $file_config->{'jabberd14'}->{'host'},
	Username => $file_config->{'jabberd14'}->{'user'},
	Password => $file_config->{'jabberd14'}->{'secret'},
	ConnectionType => +JABBERD14_COMPONENT,
	States => {
		StatusEvent => 'status_event',
		InputEvent => 'input_event',
		ErrorEvent => 'error_event',
	}
};

my $scratch_space = {};

POE::Session->create
(
	'inline_states' =>
	{
		'_start' =>
			sub
			{
				$_[KERNEL]->alias_set('j14_testing');
				$_[KERNEL]->yield('continue');
			},
		'continue' =>
			sub
			{
				$config->{'Alias'} = 'pcj';
				$_[HEAP]->{'pcj'} = PCJx->new(%$config);
				$_[KERNEL]->post('pcj', 'connect');
				
			},
		'status_event' =>
			sub
			{
				my ($kernel, $sender, $status) = @_[KERNEL, SENDER, ARG0];

				if($status == +PCJ_CONNECT)
				{
					pass('Connect started');

				} elsif($status == +PCJ_CONNECTING) {

					pass('Connecting in progress');

				} elsif($status == +PCJ_CONNECTED) {

					pass('Connect finished');

				} elsif($status == +PCJ_STREAMSTART) {

					pass('Stream start');
				
				} elsif($status == +PCJ_AUTHNEGOTIATE) {

					pass('Start handshake negotiation');

				} elsif($status == +PCJ_AUTHSUCCESS) {

					pass('handshake negotiation success');

				} elsif($status == +PCJ_INIT_FINISHED) {
					
					pass('PCJ initialization complete');

					$_[KERNEL]->post('pcj', 'shutdown');
				
				} elsif($status == +PCJ_STREAMEND) {

					$scratch_space->{'STEAMEND'} = 1;
					pass('Stream end sent');

				} elsif($status == +PCJ_SHUTDOWN_START) {
					
					if(!defined($scratch_space->{'STEAMEND'}))
					{
						fail('A stream end was not sent to the server!');
					
					} else {

						$scratch_space->{'SHUTDOWNSTART'} = 1;
						pass('Shutdown in progress');
					}
				
				} elsif($status == +PCJ_SHUTDOWN_FINISH) {

					if(!defined($scratch_space->{'SHUTDOWNSTART'}))
					{
						fail('Shutdown start was never called');
					
					} else {

						pass('Shutdown complete');
					}
				}
			},

		'error_event' =>
			sub
			{
				my $error = $_[ARG0];

				if($error == +PCJ_SOCKETFAIL)
				{
					if(!defined($scratch_space->{'STEAMEND'}))
					{
						BAIL_OUT('There was a socket failure during testing');
					
					} else {

						pass('Socket read error at end of stream okay');
					}
				
				} elsif($error == +PCJ_SOCKETDISCONNECT) {
					
					if(!defined($scratch_space->{'SHUTDOWNSTART'}))
					{
						BAIL_OUT('We were disconnected during testing');
					
					} else {

						pass('Disconnected called at the right time');
					}

				} elsif($error == +PCJ_AUTHFAIL) {

					BAIL_OUT('Authentication failed for some reason. ' .
						'Please check the username and password in this test '.
						'to make sure it is correct.');
				
				} elsif($error == +PCJ_CONNECTFAIL) {

					BAIL_OUT(q|We couldn't connect to the server. Check your |.
						'network connection or rerun Build.PL and say "N" to '.
						'network enabled tests');
				}
			},
	}
);

POE::Kernel->run();

exit 1;
