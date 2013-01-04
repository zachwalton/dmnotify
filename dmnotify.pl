#!/usr/bin/perl

########################################################
# A nick hilight/PM notification and response script       
#                              
# Modified from http://github.com/zach-walton/gmnotify
#
# Initial Version - 01/02/2013
########################################################

use Net::Twitter;
use YAML qw(LoadFile DumpFile);
use vars qw($VERSION %IRSSI);
use Irssi qw(command_bind);
use POSIX qw/strftime/;

my $twitter;
my $timer;
my %settings;

my $VERSION = '1.0';
my %IRSSI = (
    authors => 'Zach Walton',
    contact => 'zacwalt@gmail.com',
    name        => 'dmnotify',
    description => 'A nick hilight/PM notification script.  Notifies via Twitter DM, accepts responses.',
    license => 'GPLv2'
);

sub twitter_connect {
    if (!$twitter) {
        eval {
            $twitter = Net::Twitter->new(
                traits              => [qw(OAuth API::REST)],
                consumer_key        => Irssi::settings_get_str('dmnotify_consumer_key'),
                consumer_secret     => Irssi::settings_get_str('dmnotify_consumer_secret'),
                access_token        => Irssi::settings_get_str('dmnotify_access_token'),
                access_token_secret => Irssi::settings_get_str('dmnotify_access_token_secret')
            );
        };
        if ( my $err = $@ && Irssi::settings_get_str('dmnotify_debug') eq "on") {
            Irssi::print("Error: ".$@, MSGLEVEL_CLIENTNOTICES);
        }
    }
}

sub twitter_authorize {
    my $access_token, $access_token_secret, $user_id, $screen_name;
    eval {
        ($access_token, $access_token_secret, $user_id, $screen_name) = $twitter->request_access_token(verifier => Irssi::settings_get_str('dmnotify_auth'));
    };
    if (my $err = $@)  {
        if (Irssi::settings_get_str('dmnotify_debug') eq "on") {
            Irssi::print($@, MSGLEVEL_CLIENTNOTICES);
        }
        return;
    }
    Irssi::settings_set_str("dmnotify_access_token", $access_token);
    Irssi::settings_set_str("dmnotify_access_token_secret", $access_token_secret);
    twitter_connect();
    DumpFile($ENV{HOME}."/.irssi/dmnotify.yaml", \%settings);
}

sub sig_print_text($$$) {
    if (!Irssi::settings_get_str('dmnotify_access_token')) { return }
    my ($destination, $text, $stripped) = @_;
    my $server = $destination->{server};
        my ($hilight) = Irssi::parse_special('$;');
    return unless $server->{usermode_away} eq 1;
    if ($destination->{level} & MSGLEVEL_HILIGHT) {
        $text =~ s/(.*)$hilight(.*)($server->{nick})(.*)/$3$4/;
        send_message($server->{tag},$destination->{target},$hilight,$text);
    }
}

sub sig_message_private($$$$) {
    if (!Irssi::settings_get_str('dmnotify_access_token')) { return }
    my ($server, $data, $nick, $address) = @_;
    return unless $server->{usermode_away} eq 1;
    send_message($server->{tag},"private",$nick,$data);
}

sub send_message($$$$) {
    my ($server, $channel, $nick, $text) = @_;
    my $dm_text = substr("[$server|$channel] <$nick> $text", 0, 140);
    
    Irssi::settings_set_str('dmnotify_last_server', $server);
    Irssi::settings_set_str('dmnotify_last_channel', $channel);
    Irssi::settings_set_str('dmnotify_last_user', $nick);

    my %args = ("user" => Irssi::settings_get_str("dmnotify_destination"), "text" => $dm_text);
    eval {
        my $result = $twitter->new_direct_message(\%args);
    };
    if ( my $err = $@ && Irssi::settings_get_str('dmnotify_debug') eq "on") {
        Irssi::print("Error: ".$@, MSGLEVEL_CLIENTNOTICES);
    }
}

sub poll {
    if (!Irssi::settings_get_str('dmnotify_access_token')) {
        if (Irssi::settings_get_str('dmnotify_auth')) {
            twitter_authorize();
        }
    }
    else {
        # we're always going to poll back at least a day for DMs to make sure
        # we don't miss any sent before midnight
        my %args = ("since" => strftime "%Y-%m-%d", localtime(time() - 24*60*60));
        my $dms;
        eval {
            $dms = $twitter->direct_messages(\%args);
        };
        if ( my $err = $@ ) {
           if (Irssi::settings_get_str('dmnotify_debug') eq "on") {
               Irssi::print("Error: ".$@, MSGLEVEL_CLIENTNOTICES);
           }
           return;
        }
        foreach (@$dms) {
            foreach my $key (keys %$_) {
                if ($_->{sender_screen_name} eq Irssi::settings_get_str('dmnotify_destination')) {
                    post_response($_->{text});

                    # for some reason this returns an error, despite successfully deleting the
                    # DM.  wrapping it in eval() so we can move along.
                    eval { my $response = $twitter->destroy_direct_message($_->{id}); };
                    if ( my $err = $@ && Irssi::settings_get_str('dmnotify_debug') eq "on") {
                        Irssi::print("Error: ".$@, MSGLEVEL_CLIENTNOTICES);
                    } 
                } 
            }
        }
    }
}

sub post_response($) {
    my $response = $_[0];
    if (!Irssi::settings_get_str('dmnotify_last_server')  || 
        !Irssi::settings_get_str('dmnotify_last_channel') || 
        !Irssi::settings_get_str('dmnotify_last_user')) { 
        return; 
    }
    if (Irssi::settings_get_str('dmnotify_last_response') eq $response) {
        return;
    }
    Irssi::settings_set_str('dmnotify_last_response', $response);
    my $last_channel = Irssi::settings_get_str('dmnotify_last_channel');
    my $last_user = Irssi::settings_get_str('dmnotify_last_user');
    my $last_server = Irssi::settings_get_str('dmnotify_last_server');
    my $irssi_server = Irssi::server_find_tag($last_server);

    if (!defined($irssi_server)) { return; }

    if ($last_channel eq "private") {
        $irssi_server->command("msg $last_user $response");
        Irssi::print("Private message sent to \%W$last_user\%n on \%W$last_server\%n: $response", MSGLEVEL_CLIENTNOTICES);
    }
    else {
        $irssi_server->command("msg $last_server $last_user: $response");
        Irssi::print("Message sent to \%W$last_channel\%n on \%W$last_server\%n: $last_user: $response", MSGLEVEL_CLIENTNOTICES);
    }
    return;
}

$settings = LoadFile($ENV{HOME}."/.irssi/dmnotify.yaml");

if (!$settings) {
    die ("Error opening ".$ENV{HOME}."/.irssi/dmnotify.yaml!  Exiting.");
}

Irssi::settings_add_int('DMNotify', 'dmnotify_poll_rate', $settings->{poll_rate});
Irssi::settings_add_str('DMNotify', 'dmnotify_consumer_key', $settings->{consumer_key});
Irssi::settings_add_str('DMNotify', 'dmnotify_consumer_secret', $settings->{consumer_secret});
Irssi::settings_add_str('DMNotify', 'dmnotify_access_token', $settings->{access_token});
Irssi::settings_add_str('DMNotify', 'dmnotify_access_token_secret', $settings->{access_token_secret});
Irssi::settings_add_str('DMNotify', 'dmnotify_destination', $settings->{destination});
Irssi::settings_add_str('DMNotify', 'dmnotify_last_server', "");
Irssi::settings_add_str('DMNotify', 'dmnotify_last_channel', "");
Irssi::settings_add_str('DMNotify', 'dmnotify_last_user', "");
Irssi::settings_add_str('DMNotify', 'dmnotify_auth', "");
Irssi::settings_add_str('DMNotify', 'dmnotify_last_response', "");
Irssi::settings_add_str('DMNotify', 'dmnotify_debug', "off");

Irssi::signal_add_last('print text', \&sig_print_text);
Irssi::signal_add_last('message private', \&sig_message_private);

twitter_connect();

if (!$settings->{access_token} || !$settings->{access_token_secret}) {
    eval {
        Irssi::print("You need to authorize this application.  Retrieve the PIN: ".
                     $twitter->get_authorization_url.
                     "\n\nAfter retrieving the PIN, set it with:\n/set dmnotify_auth <PIN>\n",
                     MSGLEVEL_CLIENTNOTICES);
    };
    if ( my $err = $@ && Irssi::settings_get_str('dmnotify_debug') eq "on") {
        Irssi::print("Error: ".$@, MSGLEVEL_CLIENTNOTICES);
    }
}

poll();
$timer=Irssi::timeout_add(Irssi::settings_get_int('dmnotify_poll_rate')*1000, 'poll', '');
