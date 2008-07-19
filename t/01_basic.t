#!/usr/bin/perl
use Filter::Template;
const PCJx POE::Component::Jabber

use warnings;
use strict;

use Test::More tests => 29;
use POE;

BEGIN 
{ 
	use_ok('PCJx');
	use_ok('PCJx::Error');
	use_ok('PCJx::Status');
	use_ok('PCJx::ProtocolFactory');
}

sub test_new_pcj_fail
{
	my ($name, @args) = @_;
	eval { PCJx->new(@args); };
	ok($@ ne '', $name);
}

sub test_new_pcj_succeed
{
	my ($name, @args) = @_;
	eval { PCJx->new(@args); };
	ok($@ eq '', $name);
}

# Lets start by testing constants

can_ok('PCJx::Error', 
	qw/PCJ_SOCKETFAIL PCJ_SOCKETDISCONNECT PCJ_AUTHFAIL PCJ_BINDFAIL 
	PCJ_SESSIONFAIL PCJ_SSLFAIL PCJ_CONNECTFAIL/);

can_ok('PCJx::Status',
	qw/ PCJ_CONNECT PCJ_CONNECTING PCJ_CONNECTED PCJ_STREAMSTART
	PCJ_SSLNEGOTIATE PCJ_SSLSUCCESS PCJ_AUTHNEGOTIATE PCJ_AUTHSUCCESS
	PCJ_BINDNEGOTIATE PCJ_BINDSUCCESS PCJ_SESSIONNEGOTIATE PCJ_SESSIONSUCCESS
	PCJ_RECONNECT PCJ_NODESENT PCJ_NODERECEIVED PCJ_NODEQUEUED PCJ_RTS_START
	PCJ_RTS_FINISH PCJ_INIT_FINISHED PCJ_STREAMEND PCJ_SHUTDOWN_START
	PCJ_SHUTDOWN_FINISH /);

can_ok('PCJx::ProtocolFactory',
	qw/ JABBERD14_COMPONENT JABBERD20_COMPONENT LEGACY XMPP /);

#now lets test ProtocolFactory

my $guts = PCJx::ProtocolFactory::get_guts(+XMPP);
isa_ok($guts, 'PCJx::XMPP');
isa_ok($guts, 'PCJx::Protocol');
$guts = PCJx::ProtocolFactory::get_guts(+LEGACY);
isa_ok($guts, 'PCJx::Legacy');
isa_ok($guts, 'PCJx::Protocol');
$guts = PCJx::ProtocolFactory::get_guts(+JABBERD14_COMPONENT);
isa_ok($guts, 'PCJx::J14');
isa_ok($guts, 'PCJx::Protocol');
$guts = PCJx::ProtocolFactory::get_guts(+JABBERD20_COMPONENT);
isa_ok($guts, 'PCJx::J2');
isa_ok($guts, 'PCJx::Protocol');

#now lets test constructing PCJ

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


test_new_pcj_fail('No current session', %{$config});

POE::Session->create
(
	'inline_states' =>
	{
		'_start' =>
			sub
			{
				$_[KERNEL]->alias_set('basic_testing');
				$_[KERNEL]->yield('continue');
				$_[HEAP] = $config;
			},
		'continue' =>
			sub
			{
				test_new_pcj_fail('No arguments');

				my @keys = keys(%{$_[HEAP]});
				foreach my $key (@keys)
				{
					my %hash = %{$_[HEAP]};
					delete($hash{$key});
					test_new_pcj_fail('No ' . $key, %hash);
				}

				my %hash = %{$_[HEAP]};
				$hash{'ConnectionType'} = 12983;
				test_new_pcj_fail('Invalid ConnectionType', %hash);
				
				test_new_pcj_succeed('Correct construction XMPP', %{$_[HEAP]});

				$hash{'ConnectionType'} = +LEGACY;
				test_new_pcj_succeed('Correct construction LEGACY', %hash);

				$hash{'ConnectionType'} = +JABBERD14_COMPONENT;
				test_new_pcj_succeed('Correct construction J14', %hash);

				$hash{'ConnectionType'} = +JABBERD20_COMPONENT;
				test_new_pcj_succeed('Correct construction J2', %hash);
				
			},
	}
);

POE::Kernel->run();

exit 0;
