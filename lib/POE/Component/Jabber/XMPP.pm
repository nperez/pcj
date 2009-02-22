package POE::Component::Jabber::XMPP;
use Filter::Template;
const XNode POE::Filter::XML::Node
use warnings;
use strict;

use POE qw/ Wheel::ReadWrite /;
use POE::Component::Jabber::Utility::SSLify qw/ Client_SSLify /;
use POE::Component::Jabber::Error;
use POE::Component::Jabber::Status;
use POE::Filter::XML;
use POE::Filter::XML::Node;
use POE::Filter::XML::NS qw/ :JABBER :IQ /;
use Digest::MD5 qw/ md5_hex /;
use MIME::Base64;
use Authen::SASL;

use base('POE::Component::Jabber::Protocol');

our $VERSION = '3.00';

sub get_version()
{
	return '1.0';
}

sub get_xmlns()
{
	return +NS_JABBER_CLIENT;
}

sub get_states()
{
	return 
		[ 
			'set_auth', 
			'init_input_handler',
			'build_tls_wheel',
			'challenge_response',
			'binding',
			'session_establish',
		];
}

sub get_input_event()
{
	return 'init_input_handler';
}

sub set_auth()
{
	my ($kernel, $heap, $self, $mech) = @_[KERNEL, HEAP, OBJECT, ARG0];
	
	my $config = $heap->config();

	$self->{'challenge'} = Authen::SASL->new
	(
		mechanism => $mech,
		callback => 
		{
			user => $config->{'username'},
			pass => $config->{'password'},
		}
	);

	my $node = XNode->new('auth', ['xmlns', +NS_XMPP_SASL, 'mechanism', $mech]);

	if ($mech eq 'PLAIN') 
	{
		my $auth_str = '';
		$auth_str .= "\0";
		$auth_str .= $config->{'username'};
		$auth_str .= "\0";
		$auth_str .= $config->{'password'};	   
		$node->appendText(encode_base64($auth_str));	
	}

	$kernel->yield('output_handler', $node, 1);

	return;
}

sub challenge_response()
{
	my ($kernel, $heap, $self, $node) = @_[KERNEL, HEAP, OBJECT, ARG0];

	my $config = $heap->config();

	if ($config->{'debug'}) {
		
		$heap->debug_message("Server sent a challenge.  Decoded Challenge:\n".
			decode_base64($node->textContent()));
	}
	
	my $sasl = $self->{'challenge'};
	my $conn = $sasl->client_new('xmpp', $config->{'hostname'});
	$conn->client_start();

	my $step = $conn->client_step(decode_base64($node->textContent()));
	
	$step ||= '';

	if ($config->{'debug'}) {
		$heap->debug_message("Decoded Response:\n$step");
	}

	$step =~ s/\s+//go;
	$step = encode_base64($step);
	$step =~ s/\s+//go;

	my $response = XNode->new('response', ['xmlns', +NS_XMPP_SASL]);
	$response->appendText($step);

	$kernel->yield('output_handler', $response, 1);
	return;
}

sub init_input_handler()
{
	my ($kernel, $heap, $self, $node) = @_[KERNEL, HEAP, OBJECT, ARG0];
	
	my $attrs = $node->getAttributes();
	my $config = $heap->config();
	my $name = $node->nodeName();

	if ($config->{'debug'})
	{
		$heap->debug_message("Recd: ".$node->toString());
	}
	
	if(exists($attrs->{'id'}))
	{
		my $pending = $heap->pending();	
		if(defined($pending->{$attrs->{'id'}}))
		{
			my $array = delete $pending->{$attrs->{'id'}};
			$kernel->post($array->[0], $array->[1], $node);
		}
	
	} elsif($name eq 'stream:stream') {
	
		$self->{'sid'} = $attrs->{'id'};
	
	} elsif($name eq 'challenge') {
	
		$kernel->yield('challenge_response', $node);
	
	} elsif($name eq 'failure' and $attrs->{'xmlns'} eq +NS_XMPP_SASL) {
		
		$heap->debug_message('SASL Negotiation Failed');
		$kernel->yield('shutdown');
		$kernel->post($heap->parent(), $heap->error(), +PCJ_AUTHFAIL);
	
	} elsif($name eq 'stream:features') {
	
		my $clist = $node->getChildrenHash();

		if(exists($clist->{'starttls'}))
		{
			my $starttls = XNode->new('starttls', ['xmlns', +NS_XMPP_TLS]);
			$kernel->yield('output_handler', $starttls, 1);
			$kernel->post($heap->parent(), $heap->status(), +PCJ_SSLNEGOTIATE);
		
		} elsif(exists($clist->{'mechanisms'})) {
			
			$self->{'MECHANISMS'} = 1;
			my @mechs = $clist->{'mechanisms'}->[0]->getChildrenByTagName('*');
			foreach my $mech (@mechs)
			{
				if($mech->textContent() eq 'DIGEST-MD5' or $mech->textContent() eq 'PLAIN')
				{
					$kernel->yield('set_auth', $mech->textContent());
					$kernel->post(
						$heap->parent(), 
						$heap->status(),
						+PCJ_AUTHNEGOTIATE);
					return;
				}
			}
			
			$heap->debug_message('Unknown mechanism: '.$node->toString());
			$kernel->yield('shutdown');
			$kernel->post($heap->parent(), $heap->error(), +PCJ_AUTHFAIL);
		
		} elsif(exists($clist->{'bind'})) {
		
			my $iq = XNode->new('iq', ['type', +IQ_SET]);
			$iq->appendChild('bind', ['xmlns', +NS_XMPP_BIND])
				->appendChild('resource')
				->appendText($config->{'resource'});
			
			$self->{'STARTSESSION'} = 1 if exists($clist->{'session'});
			$kernel->yield('return_to_sender', 'binding', $iq);
			$kernel->post($heap->parent(), $heap->status(), +PCJ_BINDNEGOTIATE);
		
		} else {

			# If we get here, it means the server has decided TLS isn't 
			# necessary, or that it is a non-compliant server and has skipped
			# SASL negotition. Check for MECHANISMS flag. If it is present then
			# we are finished with connection initialization.
			#
			# See http://www.xmpp.org/rfcs/rfc3920.html for more info
			
			if($self->{'MECHANISMS'})
			{

				$heap->relinquish_states();
				$kernel->post(
					$heap->parent(),
					$heap->status(), 
					+PCJ_INIT_FINISHED);
			
			} else {

				$heap->debug_message('Non-compliant server implementation! '.
					'SASL negotiation not initiated.');
				$kernel->yield('shutdown');
				$kernel->post($heap->parent(), $heap->error(), +PCJ_AUTHFAIL);
			}
		}

	} elsif($name eq 'proceed') {
	
		$kernel->yield('build_tls_wheel');
	
	} elsif($name eq 'success') {
		
		$kernel->yield('initiate_stream');
		$kernel->post($heap->parent(), $heap->status(), +PCJ_AUTHSUCCESS);
	}
	return;	
}

sub binding()
{
	my ($kernel, $heap, $self, $node) = @_[KERNEL, HEAP, OBJECT, ARG0];

	my $attr = $node->getAttribute('type');

	my $config = $heap->config();

	if($attr eq +IQ_RESULT)
	{
		if($self->{'STARTSESSION'})
		{
			my $iq = XNode->new('iq', ['type', +IQ_SET]);
			$iq->appendChild('session', ['xmlns', +NS_XMPP_SESSION]);

			$kernel->yield('return_to_sender', 'session_establish', $iq);
			$kernel->post($heap->parent(),$heap->status(), +PCJ_BINDSUCCESS);
			$kernel->post(
				$heap->parent(),
				$heap->status(),
				+PCJ_SESSIONNEGOTIATE);
		
		} else {
			
			$heap->relinquish_states();
			$kernel->post($heap->parent(),$heap->status(), +PCJ_BINDSUCCESS);
			$kernel->post($heap->parent(),$heap->status(), +PCJ_INIT_FINISHED);
		}
        
		$heap->jid($node->getSingleChildByTagName('bind')->getSingleChildByTagName('jid')->textContent());
	
	} elsif($attr eq +IQ_ERROR) {

		my $error = $node->getSingleChildByTagName('error');

		if($error->getAttribute('type') eq 'modify')
		{
			my $iq = XNode->new('iq', ['type', +IQ_SET]);
			$iq->appendChild('bind', ['xmlns', +NS_XMPP_BIND])
				->appendChild('resource')
				->appendText(md5_hex(time().rand().$$.rand().$^T.rand()));
			$kernel->yield('return_to_sender', 'binding', $iq);
		
		} elsif($error->getAttribute('type') eq 'cancel') {

			my $clist = $error->getChildrenHash();
			
			if(exists($clist->{'conflict'}))
			{
				my $iq = XNode->new('iq', ['type', +IQ_SET]);
				$iq->appendChild('bind', ['xmlns', +NS_XMPP_BIND])
					->appendChild('resource')
					->appendText(md5_hex(time().rand().$$.rand().$^T.rand()));
				$kernel->yield('return_to_sender', 'binding', $iq);
			
			} else {
			
				$heap->debug_message('Unable to BIND, yet binding required: '.
					$node->toString());

				$kernel->yield('shutdown');
				$kernel->post($heap->parent(), $heap->error(), +PCJ_BINDFAIL);
			}
			
		}
	}
	return;
}
		
sub session_establish()
{
	my ($kernel, $heap, $node) = @_[KERNEL, HEAP, ARG0];

	my $attr = $node->getAttribute('type');

	my $config = $heap->config();
	
	if($attr eq +IQ_RESULT)
	{
		$heap->relinquish_states();
		$kernel->post($heap->parent(), $heap->status(), +PCJ_SESSIONSUCCESS);
		$kernel->post($heap->parent(), $heap->status(),	+PCJ_INIT_FINISHED);

	} elsif($attr eq +IQ_ERROR) {

		$heap->debug_message('Unable to intiate SESSION, yet session required');
		$heap->debug_message($node->toString());
		$kernel->yield('shutdown');
		$kernel->post($heap->parent(), $heap->error(), +PCJ_SESSIONFAIL);
	}
	return;
}
		
sub build_tls_wheel()
{
	my ($self, $kernel, $heap) = @_[OBJECT, KERNEL, HEAP];
	
	$heap->wheel(undef);
	eval 
	{	
		$heap->sock(Client_SSLify($heap->sock()));
	};

	if($@)
	{
		if($self->{'SSLTRIES'} > 3)
		{
			$heap->debug_message('Unable to negotiate SSL: '. $@);
			$self->{'SSLTRIES'} = 0;
			$kernel->post($heap->parent(), $heap->error(), +PCJ_SSLFAIL, $@);
		
		} else {
			
			$self->{'SSLTRIES'}++;
			$kernel->yield('build_tls_wheel');
		}
		
	} else {
		$heap->wheel(POE::Wheel::ReadWrite->new
		(
			'Handle'		=> $heap->sock(),
			'Filter'		=> POE::Filter::XML->new(),
			'InputEvent'	=> 'input_handler',
			'ErrorEvent'	=> 'server_error',
			'FlushedEvent'	=> 'flushed',
		));
		$kernel->yield('initiate_stream');
		$kernel->post($heap->parent(), $heap->status(), +PCJ_SSLSUCCESS);
	}
	return;
}

1;

__END__

=pod

=head1 NAME

POE::Component::Jabber::XMPP

=head1 SYNOPSIS

This is a Protocol implementation for the specifics in the XMPP protocol during
connection initialization.

=head1 DESCRIPTION

PCJ::XMPP provides all the mechanisms to negotiate TLS, SASL, resource binding,
and session negotiation that PCJ needs to successfully establish an XMPP 
connection. In essence, it implements XMPP Core and a smidgeon of XMPP IM.

=head1 METHODS

Please see PCJ::Protocol for what methods this class supports.

=head1 EVENTS

Listed are the exported events that make their way into the PCJ session:

=over 2

=item set_auth

This handles the initial SASL authentication portion of the XMPP connection.

=item init_input_handler

This is our entry point. This is what PCJ uses to deliver events to us.

=item build_tls_wheel

If TLS is required by the server, this is where that negotiation process 
happens.

=item challenge_response

This handles the subsequent SASL authentication steps.

=item binding

This handles the resource binding

=item session_establish

This handles session binding.

=back

=head1 NOTES AND BUGS

Currently, only DIGEST-MD5 and PLAIN SASL mechanisms are supported. Server 
implementations are free to include more strigent mechanisms, but these are the
bare minimum required. (And PLAIN isn't /really/ allowed by the spec, but it is
included because it was a requested feature)

The underlying backend has changed this release to now use a new Node
implementation based on XML::LibXML::Element. Please see POE::Filter::XML::Node
documentation for the relevant API changes.

=head1 AUTHOR

Copyright (c) 2003-2009 Nicholas Perez. Distributed under the GPL.

=cut

