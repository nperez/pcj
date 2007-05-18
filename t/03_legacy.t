#!/usr/bin/perl
use Filter::Template;
const PCJx POE::Component::Jabber

use warnings;
use strict;

use Test::More tests => 12;
use POE;
use PCJx;
use PCJx::Error;
use PCJx::Status;
use PCJx::ProtocolFactory;

my $config = 
{
	IP => 'jabber.org',
	Port => '5222',
	Hostname => 'jabber.org',
	Username => 'PCJTester',
	Password => 'PCJTester',
	ConnectionType => +LEGACY,
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
				$_[KERNEL]->alias_set('xmpp_testing');
				$_[KERNEL]->yield('continue');
			},
		'continue' =>
			sub
			{
				$config->{'Alias'} = 'pcj';
				$_[HEAP]->{'pcj'} = PCJx->new(%$config);
				
				if(-e 'run_network_tests')
				{
					$_[KERNEL]->post('pcj', 'connect');
				
				} else {
					
					SKIP: { skip('Network tests were declined', 12); }
					exit 1;
				}
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

					#we need to count only ONE stream start for Legacy 
					pass('Stream start');
				
				} elsif($status == +PCJ_AUTHNEGOTIATE) {

					pass('Start iq:auth negotiation');

				} elsif($status == +PCJ_AUTHSUCCESS) {

					pass('iq:auth negotiation success');

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
