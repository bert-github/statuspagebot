# An IRC bot that retrieves the status of various systems from
# status.w3.org (an instance of Atlassian Statuspage) and writes a
# message on IRC whenever there is a change in the status. It can also
# give the current status when asked.
#
# The current implementation gets the information by regularly
# requesting an Atom feed from the status server.
#
# TODO: Make Atom feed URL and update frequency configurable.
#
# TODO: Do the HTTP request in a background process, to avoid that the
# bot becomes unresponsive?
#
# TODO: Subscribe to updates by mail instead of polling the server for
# the Atom feed? In that case the bot can poll a local IMAP server
# instead; or even use the IMAP IDLE command to wait for pushed
# information from the IMAP server.
#
# TODO: Remember joined channels in a file, so the bot can rejoin them
# when it is stopped and restarted.
#
# Author: Bert Bos <bert@w3.org>
# Created: 31 January 2023

package StatuspageBot;
use FindBin;
use lib "$FindBin::Bin";	# Look for modules in statuspagebot's directory
use parent 'Bot::BasicBot::ExtendedBot';
use strict;
use warnings;
use utf8;
use Getopt::Std;
use Scalar::Util 'blessed';
use Term::ReadKey;		# To read a password without echoing
use LWP::UserAgent;
use Net::Netrc;
use XML::Feed;
use POSIX qw(strftime);

use constant VERSION => '0.1';
use constant DEFAULT_STATUSPAGE => 'https://status.w3.org/';
use constant DEFAULT_INTERVAL => 120;


# init -- initialize some parameters
sub init($)
{
  my $self = shift;

  $self->{name} //= blessed($self).'/'.VERSION;
  $self->{nick} //= lc(blessed($self));
  $self->{statuspage} //= DEFAULT_STATUSPAGE;
  $self->{atomfeed} //= $self->{statuspage} . '/history.atom';
  $self->{interval} //= DEFAULT_INTERVAL;
  $self->{ua} = LWP::UserAgent->new;
  $self->{ua}->agent(blessed($self).'/'.VERSION);
  $self->{entries} = {};
  $self->{ongoing} = {};
  $self->{etag} = undef;
  $self->log("Connecting...");
  return 1;
}


# report_changes -- report all changes to entries in the Atom feed on IRC
sub report_changes($$)
{
  my ($self, $feed_content_ref) = @_;

  # Parse the Atom feed.
  my @entries = XML::Feed->parse($feed_content_ref)->entries;

  # For all entries, write to IRC what is new in that entry's content.
  for my $entry (@entries) {
    my $id = $entry->id();
    my $title = $entry->title();
    my $updated = $entry->modified();		# Date of last status change
    my $body = $entry->content()->body;		# Content decoded to HTML

    # Extract the latest message from the entry body.
    my $msg = $body;
    if (defined $self->{etag}) {
      # This is not the first time we get the Atom feed. Subtract the
      # previous entry and use the difference as the message.
      my $old = $self->{entries}->{$id};	# Get remembered entry
      $msg =~ s/\Q$old\E//;			# Get diff between old and new
      $msg =~ s/<br>/ /g;			# Newlines become spaces
      $msg =~ s/<\/p>/\n/g;			# Paragraphs become newlines
      $msg =~ s/<[^>]+>//g;			# Remove all other tags
    } else {
      # This is the first time we get the Atom feed, so we have no
      # previous entry to compare this one to. We assume the first
      # paragraph of the entry is the most recent message.
      $msg =~ s/^.*?<p>(.*)<\/p>.*$/$1/;	# Get first paragraph
      $msg =~ s/<br>/ /g;			# Newlines become spaces
      $msg =~ s/<[^>]+>//g;			# Remove all other tags
    }

    # If there is a new message, report it to all channels we're on.
    if ($msg && defined $self->{etag}) {
      $self->say({channel => $_, body => "$title -- $msg"})
	  foreach $self->{channels};
    }

    # Remember the entry, so we can compute the difference next time.
    $self->{entries}->{$id} = $body;

    # Remember the message for the "status" command.
    if ($msg =~ /^[^-]* (?:Completed|Resolved) -/) {
      # Incident resolved. Delete its last message, if any.
      delete $self->{ongoing}->{$id} && $self->log("Close incident $id");
    } elsif ($msg) {
      # Status changed, but not resolved. Remember this message.
      $self->log("Set incident $id to: $title -- $msg ($updated)");
      $self->{ongoing}->{$id} = "$title -- $msg ($updated)";
    } else {
      # Status unchanged. Keep the last message (if any) unchanged.
    }
  }

  # Remove remembered entries and recent status messages that are no
  # longer present in the Atom feed.
  my %ids = map { $_->id => 1 } @entries; # Get all IDs that are in the feed
  delete $self->{entries}->{$_} && $self->log("Removing incident $_")
      foreach grep !exists $ids{$_}, keys %{$self->{entries}};
  delete $self->{ongoing}->{$_}
      foreach grep !exists $ids{$_}, keys %{$self->{ongoing}};
}


# print_status -- print the last messages of ongoing events
sub print_status($$$)
{
  my ($self, $channel, $who) = @_;
  my $nevents = 0;

  $self->say(channel => $channel, who => $who, body => $_), $nevents++
      for values %{$self->{ongoing}};

  $self->say(channel => $channel, who => $who,
    body => "All systems are operational.") if $nevents == 0;
}


# tick -- called regularly to get the Atom feed
sub tick($)
{
  my $self = shift;
  my ($req, $res, $title, $p, $issue_date, $update_date, $feed, @entries);

  $self->log("Getting $self->{atomfeed} ...");

  # Create an HTTP request for the Atome feed.
  $req = HTTP::Request->new(GET => $self->{atomfeed});

  # Set the If-None-Match header to the ETag of the previous response.
  $req->header('If-None-Match' => $self->{etag}) if defined $self->{etag};

  # Issue the request.
  $res = $self->{ua}->request($req);

  # Check the type of reponse.
  if ($res->code == 304) {
    # Not modified. Do nothing.
    $self->log("Status not modified");
  } elsif ($res->code == 200 && $res->content_is_xml) {
    # We got a 200 response with an XML body, so there is an event to report.
    $self->report_changes(\$res->decoded_content);
    # Remember the ETag for the next request.
    $self->{etag} = $res->header('etag');
  } else {
    $self->log($res->status_line);
  }

  # Next call to tick in $self->{interval} seconds.
  return $self->{interval};
}


# invited -- do something when we are invited
sub invited($$)
{
  my ($self, $info) = @_;
  my $who = $info->{who};
  my $raw_nick = $info->{raw_nick};
  my $channel = $info->{channel};

  $self->log("Invited by $who ($raw_nick) to $channel");
  $self->join_channel($channel);
}


# said -- handle a message
sub said($$)
{
  my ($self, $info) = @_;
  my $who = $info->{who};		# Nick (without the "!domain" part)
  my $text = $info->{body};		# What Nick said
  my $channel = $info->{channel};	# "#channel" or "msg"
  # my $me = $self->nick();		# Our own name
  my $addressed = $info->{address};	# Defined if we're personally addressed

  # return if $channel eq 'msg';	# We do not react to private messages

  return $self->part_channel($channel), undef
      if $addressed && $text =~ /^bye *\.?$/i;

  return $self->print_status($channel, $who), undef
      if $addressed && $text =~ /^status *\??$/i;
}


# help -- return the text to respond to an "statuspagebot, help" message
sub help($$)
{
  my ($self, $info) = @_;
  my $me = $self->nick();		# Our own name
  my $text = $info->{body};		# What Nick said

  return
      "I am an instance of ".blessed($self)." ".VERSION.".\n".
      "I write to IRC when the status of services on $self->{statuspage} changes.\n".
      "Invite me with \"/invite $me\", dismiss me with \"$me, bye\".\n".
      "Ask for the current status with \"$me, status?\".";
}


# log -- print a message to STDERR, but only if -v (verbose) was specified
sub log
{
  my ($self, @messages) = @_;

  if ($self->{'verbose'}) {
    # Prefix all log lines with the current time, unless the line
    # already starts with a time.
    #
    my $now = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;
    $self->SUPER::log(
      map /^\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ/ ? $_ : "$now $_", @messages);
  }
}


# read_netrc -- find login & password for a host and (optional) login in .netrc
sub read_netrc($;$)
{
  my ($host, $login) = @_;

  my $machine = Net::Netrc->lookup($host, $login);
  return ($machine->login, $machine->password) if defined $machine;
  return (undef, undef);
}


# Main body

my (%opts, $ssl, $proto, $user, $password, $host, $port, $channel);

$Getopt::Std::STANDARD_HELP_VERSION = 1;
getopts('f:i:kn:N:s:v', \%opts) or die "Try --help\n";
die "Usage: $0 [options] [--help] irc[s]://server...\n" if $#ARGV != 0;

# The single argument must be an IRC-URL.
#
($proto, $user, $password, $host, $port, $channel) = $ARGV[0] =~
    /^(ircs?):\/\/(?:([^:@\/?#]+)(?::([^@\/?#]*))?@)?([^:\/#?]+)(?::([^\/]*))?(?:\/(.+)?)?$/i
    or die "Argument must be a URI starting with `irc:' or `ircs:'\n";
$ssl = $proto =~ /^ircs$/i;
$user =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $user;
$password =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $password;
$port //= $ssl ? 6697 : 6667;
$channel =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $channel;
$channel = '#' . $channel if defined $channel && $channel !~ /^[#&]/;

# If there was no username, try to find one in ~/.netrc
if (!defined $user) {
  my ($u, $p) = read_netrc($host);
  ($user, $password) = ($u, $p) if defined $u;
}

# If there was a username, but no password, try to find one in ~/.netrc
if (defined $user && !defined $password) {
  my ($u, $p) = read_netrc($host, $user);
  $password = $p if defined $p;
}

# If there was a username, but still no password, prompt for it.
if (defined $user && !defined $password) {
  print "IRC password for user \"$user\": ";
  ReadMode('noecho');
  $password = ReadLine(0);
  ReadMode('restore');
  print "\n";
  chomp $password;
}

STDERR->autoflush(1);		# Write the log without buffering

my $bot = StatuspageBot->new(
  server => $host,
  port => $port,
  ssl => $ssl,
  username => $user,
  password => $password,
  nick => $opts{'n'},
  name => $opts{'N'},
  channels => (defined $channel ? [$channel] : []),
  statuspage => $opts{'s'},
  atomfeed => $opts{'f'},
  interval => $opts{'i'},
  verbose => defined $opts{'v'},
  ssl_verify_hostname => $opts{'k'} ? 0 : 1);

$bot->run();


=encoding utf8

=head1 NAME

statuspagebot - IRC 'bot that displays updates from a statuspage

=head1 SYNOPSIS

statuspagebot [-n I<nick>] [-N I<name>] [-d I<interval>] [-k]
[-s statuspage-url] [-f feed-url] [-v] I<IRC-URL>

=head1 DESCRIPTION

Statuspagebot is an IRC bot that writes on IRC whenever a statuspage
server ("status.w3.org" by default) shows a change in the status of
some systems. Statuspagebot doesn't care what the systems are or what
the status is, it just copies the message and keeps it in memory in
case a user on the IRC asks what the latest status is. The only thing
it looks for is if the message says that the status is completed or
resolved. In that case it erases the message from its memory.

The way the 'bot currently gets the status is by downloading the Atom
feed of the statuspage server at regular interval. (The Atom feed
contains the history of all status changes since a certain time. The
'bot parses it to extract only the latest change in status.)

=head2 Specifying the IRC server

The I<URL> argument specifies the server to connect to. It must be of
the following form:

=over

I<protocol>://I<username>:I<password>@I<server>:I<port>/I<channel>

=back

But many parts are optional. The I<protocol> must be either "irc" or
"ircs", the latter for an SSL-encrypted connection.

If the I<username> is omitted, the I<password> and the "@" must also
be omitted.

If the I<username> is omitted, statuspagebot will try to find a
username and password in the ~/.netrc file, if it exists, and
otherwise try to connect to the IRC server without a username and
password.

If a I<username> is given, but the colon and the I<password> is
omitted, statuspagebot will first see if there is a password for that
username in the ~/.netrc file and otherwise prompt for it.

The I<server> is required.

If the ":" and the I<port> are omitted, the port defaults to 6667 (for
irc) or 6697 (for ircs).

If a I<channel> is given, statuspagebot will join that channel. If the
I<channel> does not start with a "#" or a "&", statuspagebot will add
a "#" itself.

Omitting the password is useful to avoid that the password is visible
in the list of running processes or that somebody can read it over
your shoulder while you type the command.

Note that many characters in the username or password must be
URL-escaped. E.g., a "@" must be written as "%40", ":" must be written
as "%3a", "/" as "%2f", etc.

=head2 IRC commands

To invite statuspagebot to an IRC channel, type

=over

/invite statuspagebot

=back

in that channel.

To ask what the latest status is, type

=over

statuspagebot, status?

=back

The question mark is optional.

To make statuspagebot leave an IRC channel, type

=over

statuspagebot, bye

=back

=head1 OPTIONS

=over

=item B<-n> I<nick>

The nickname the bot runs under. Default is "statuspagebot".

=item B<-N> I<name>

The real name of the bot. Default is "StatuspageBot 0.1".

=item B<-i> I<interval>

Statuspagebot regularly queries the statuspage server to get the
latest status. The B<-i> option sets the interval in seconds between
calls to the statuspage server. Default 120 seconds.

=item B<-s> I<statuspage-url>

The URL of the statuspage, default "https://status.w3.org/".

=item B<-f> I<atomfeed-url>

The URL of the Atom feed that the bot retrieves to learn about the
status of systems. The default is the statuspage URL (option B<-s>)
followed by "history.atom". I.e., the default is
"https://status.w3.org/history.atom".

=item B<-v>

Be verbose. Makes the 'bot print a log to standard error output of
what it is doing.

=back

=head1 BUGS

Probably.

=head1 AUTHOR

Bert Bos E<lt>bert@w3.org>

=head1 SEE ALSO

=cut
