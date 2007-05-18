#!/usr/bin/perl
use Filter::Template;
const PCJx POE::Component::Jabber

use warnings;
use strict;

use Test::More tests => 20;
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
	ConnectionType => +XMPP,
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
					
					SKIP: { skip('Network tests were declined', 20); }
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

					#we need to count three stream starts for XMPP
					pass('Stream start');
				
				} elsif($status == +PCJ_SSLNEGOTIATE) {

					pass('Start negotiating SSL');

				} elsif($status == +PCJ_SSLSUCCESS) {

					pass('SSL negotiation success');

				} elsif($status == +PCJ_AUTHNEGOTIATE) {

					pass('Start SASL negotiation');

				} elsif($status == +PCJ_AUTHSUCCESS) {

					pass('SASL negotiation success');

				} elsif($status == +PCJ_BINDNEGOTIATE) {

					$scratch_space->{'BIND'} = 1;

					pass('Start bind negotiation');

				} elsif($status == +PCJ_BINDSUCCESS) {

					pass('bind negotiation success');

				} elsif($status == +PCJ_SESSIONNEGOTIATE) {
					
					$scratch_space->{'SESSION'} = 1;

					pass('Start session negotiation');

				} elsif($status == +PCJ_SESSIONSUCCESS) {

					pass('session negotiation success');
				
				} elsif($status == +PCJ_INIT_FINISHED) {
					
					if(!defined($scratch_space->{'BIND'}))
					{
						SKIP:
						{
							skip('Binding negotiation not asked for', 2);
						}
					
						if(defined($scratch_space->{'SESSION'}))
						{
							fail('Inconsistent state for compliant protocol '.
								'implementation');
							BAIL_OUT('The test server is really wonky or PCJ '.
								'is horribly broken. Please submit an rt '.
								'ticket ASAP');
						}
					}

					if(!defined($scratch_space->{'SESSION'}))
					{
						SKIP:
						{
							skip('Session negotiation not asked for', 2);
						}
					}
					
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
				
				} elsif($error == +PCJ_BINDFAIL) {

					BAIL_OUT('Binding failed for some reason. Since this is, '.
						'for the most part, a dynamic/automatic process, '.
						'there may be a problem with the server.');

				} elsif($error == +PCJ_SESSIONFAIL) {

					BAIL_OUT('Session failed for some reason. Since this is, '.
						'for the most part, a dynamic/automatic process, '.
						'there may be a problem with the server.');

				} elsif($error == +PCJ_SSLFAIL) {

					BAIL_OUT('Session failed for some reason. Since this is, '.
						'for the most part, a dynamic/automatic process, '.
						'there may be a problem with the server.');
				
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
