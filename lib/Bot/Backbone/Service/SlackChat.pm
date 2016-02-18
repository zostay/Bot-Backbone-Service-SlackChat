package Bot::Backbone::Service::SlackChat;

use v5.14;
use Bot::Backbone::Service;

with qw(
    Bot::Backbone::Service::Role::Service
    Bot::Backbone::Service::Role::Dispatch
    Bot::Backbone::Service::Role::BareMetalChat
    Bot::Backbone::Service::Role::GroupJoiner
);

use Bot::Backbone::Message;
use Carp;
use CHI;
use AnyEvent::SlackRTM;
use WebService::Slack::WebApi;

# ABSTRACT: Connect and chat with a Slack server

=head1 SYNOPSIS

    package MyBot;
    use Bot::Backbone;

    service slack_chat => (
        service => 'SlackChat',
        token   => '...', # see slack.com for your tokens
    );

    service dice => (
        service => 'OFun::Dice',
    );

    service "general_chat" => (
        service    => 'GroupChat',
        chat       => 'SlackChat',
        group      => 'C',
        dispatcher => 'general_dispatch',
    );

    dispatcher 'general_dispatch' => as {
        redispatch_to "dice";
    };

    __PACKAGE__->new->run;

=head1 DESCRIPTION

This allows a L<Bot::Backbone> chat bot to be connect to a Slack server using their Real-Time Messaging API.

This is based on L<AnyEvent::SlackRTM> and L<WebService::Slack::WebApi>. It also uses a L<CHI> cache to help avoid contacting the Slack server too often, which could result in your bot becoming rate limited.

=head1 ATTRIBUTES

=head2 token

The C<token> is the access token from Slack to use. This may be either of the following type of tokens:

=over

=item *

L<User Token|https://api.slack.com/tokens>. This is a token to perform actions on behalf of a user account.

=item *

L<Bot Token|https://slack.com/services/new/bot>. If you configure a bot integration, you may use the access token on the bot configuration page to use this library to act on behalf of the bot account. Bot accounts may not have the same features as a user account, so please be sure to read the Slack documentation to understand any differences or limitations.

=back

Which you use will depend on whether you want the bot to control a user account or a bot integration account. You are responsible for adhering to the Slack terms of use in whatever you do.

=cut

has token => (
    is          => 'ro',
    isa         => 'Str',
    required    => 1,
);

=head2 cache

This is a L<CHI> cache to use to temporarily store response from the Slack APIs. By default, this is a memory-only cache that caches data for only 60 seconds. The purpose is mainly to prevent repeated requests to the API, which might result in rate limiting.

=cut

# To avoid Slack rate limiting
has cache => (
    is          => 'ro',
    required    => 1,
    lazy        => 1,
    builder     => '_build_cache',
);

sub _build_cache {
    CHI->new(
        driver     => 'Memory',
        datastore  => {},
        expires_in => 60, # let's not bother to cache for long
    );
}

# This is kind of kludgey. It needs work. Not documenting it in the POD for now
# because it is very likely to change.
has last_mark => (
    is          => 'rw',
    isa         => 'Int',
    required    => 1,
    default     => 0,
);

=head2 api

This is the L<WebService::Slack::WebApi> object used to contact Slack for information about channels, users, etc.

=cut

has api => (
    is          => 'ro',
    isa         => 'WebService::Slack::WebApi',
    lazy        => 1,
    builder     => '_build_api',
);

sub _build_api {
    my $self = shift;
    WebService::Slack::WebApi->new(token => $self->token);
}

=head2 rtm

This is the L<AnyEvent::SlackRTM> object used to communicate with Slack and trigger events from the Real-Time Messaging API.

=cut

has rtm => (
    is          => 'ro',
    isa         => 'AnyEvent::SlackRTM',
    lazy        => 1,
    builder     => '_build_rtm',
);

sub _build_rtm {
    my $self = shift;
    AnyEvent::SlackRTM->new($self->token);
}

=head2 error_callback

This is a callback sub that may be used to report error events from the RTM API. Set it to a sub that will be called as follows:

    sub {
        my ($self, $rtm, $message) = @_;

        ...
    }

Here, C<$self> is the L<Bot::Backbone::Service::SlackChat> object, C<$rtm> is the L<AnyEvent::SlackRTM> object, and C<$message> is a hash containing the error message, as described on the L<Real Time Messaging API|https://api.slack.com/rtm> documentation.

=cut

has error_callback => (
    is          => 'ro',
    isa         => 'CodeRef',
    lazy        => 1,
    builder     => '_build_error_callback',
);

sub _build_error_callback {
    return sub {
        my ($self, $rtm, $message) = @_;
        carp "Slack Error #$message->{error}{code}: $message->{error}{msg}\n";
    }
}

=head2 whoami

This returns a hash containing information about who the bot is.

=cut

has whoami => (
    is          => 'rw',
    isa         => 'HashRef',
    required    => 1,
    lazy        => 1,
    builder     => '_build_whoami',
);

sub _build_whoami {
    my $self = shift;
    my $res = $self->api->auth->test;

    if ($res->{ok}) {
        $res;
    }
    else {
        croak "unable to ask Slack who am I?";
    }
}

=head1 METHODS

=head2 user

Returns the name of the bot.

=head2 user_id

Returns the user ID for the bot.

=head2 team_id

Returns the team ID for the team account.

=cut

sub user    { shift->whoami->{user} }
sub user_id { shift->whoami->{user_id} }
sub team_id { shift->whoami->{team_id} }

=head2 initialize

This connects to Slack and prepares the bot for communication.

=cut

sub initialize {
    my $self = shift;

    $self->rtm->on(
        message => sub { $self->got_message(@_) },
        error   => sub { $self->error_callback->($self, @_) }
    );

    $self->rtm->quiet(1);

    $self->rtm->start;
}

=head2 load_user

    method load_user($by, $value) returns Bot::Backbone::Identity

Fetches information about a user from Slack and returns the user as a L<Bot::Backbone::Identity>. The C<$by> setting determines how the user is looked up, which may either be by "id" or by "name". The value, then, is the value to check.

=cut

sub _cached {
    my ($self, $key, $code) = @_;

    my $cached = $self->cache->get($key);
    return $cached if $cached;

    my $value = $code->();
    $self->cache->set($key, $value);
    return $value;
}

sub load_user {
    my ($self, $by, $value) = @_;

    my $user;
    if ($by eq 'id') {
        my $res = $self->_cached("api.users.info:user=$value", sub {
                $self->api->users->info(user => $value);
            });
        $user = $res->{user} if $res->{ok};
    }
    elsif ($by eq 'name') {
        my $list = $self->_cached("api.users.list", sub { $self->api->users->list });
        if ($list->{ok}) {
            ($user) = grep { $_->{name} eq $value } @{ $list->{members} };
        }
    }
    else {
        croak "unknown lookup type $by";
    }

    if (defined $user) {
        return Bot::Backbone::Identity->new(
            username => $user->{id},
            nickname => $user->{name},
            me       => ($user->{id} eq $self->user_id),
        );
    }
    else {
        croak "unknown user $by $value";
    }
}

=head2 load_me

    method load_me() returns Bot::Backbone::Identity

Returns the identity object for the bot itself.

=cut

sub load_me {
    my $self = shift;
    return $self->load_user(id => $self->user_id);
}

=head2 load_user_channel

    method load_user_channel($by, $value) returns Str

Returns the ID of a user's IM channel. Here C<$by> may be "user" to lookup by user ID.

=cut

sub load_user_channel {
    my ($self, $by, $value) = @_;

    croak "unknown lookup type $by" unless $by eq 'user' or $by eq 'id';

    my $list = $self->_cached("api.im.list", sub { $self->api->im->list });

    croak "unknown IM $by $value" unless $list->{ok};

    my ($im) = grep { $_->{ $by } eq $value } @{ $list->{members} };
    return $im->{id};
}

# Initially, I thought this method would be necessary. Now I'm thinking
# it's completely unnecessary. As such, I don't want to document it for now.
sub load_channel {
    my ($self, $by, $value) = @_;

    # It really has to be by ID since we collapse group/channel notions
    croak "unknown lookup type $by" unless $by eq 'id';

    my $group;
    my $type = substr $value, 0, 1;
    if ($type eq 'G') {
        # TODO When this method is added, bring it back..
        # See https://github.com/mihyaeru21/p5-WebService-Slack-WebApi/issues/4
        #my $res = $self->api->groups->info( channel => $value );
        #$group = $res->{group} if $res->{ok};
        my $res = $self->_cached("api.groups.list", sub { $self->api->groups->list });
        if ($res->{ok}) {
            ($group) = grep { $_->{ $by } eq $value } @{ $res->{groups} };
        }
    }
    elsif ($type eq 'C') {
        my $res = $self->_cached("api.channels.info:channel=$value", sub {
                $self->api->channels->info( channel => $value )
            });
        $group = $res->{channel} if $res->{ok};
    }
    else {
        croak "unknown group type $type";
    }

    if (defined $group) {
        return $group->{id};
    }
    else {
        croak "cannot find group $by $value";
    }
}

=head2 join_group

    method join_group({ group => $group })

Given the ID of a channel or group, this causes the bot to open or join it. Note that Slack bot integration accounts might not be able to join team channels, but may still be invited.

=cut

sub join_group {
    my ($self, $options) = @_;

    my $type = substr $options->{group}, 0, 1;

    if ($type eq 'G') {
        $self->api->groups->open(channel => $options->{group});
    }
    elsif ($type eq 'C') {
        $self->api->channels->join(name => $options->{group});
    }
    else {
        croak "unknown group type $type";
    }
}

=head2 got_message

Handles messages from Slack. Decides whether they are group messages or direct and forwards them on as appropriate. Messages with a "subtype" will be ignored as will messages that are "edited".

This method also marks messages as read.

=cut

sub got_message {
    my ($self, $rtm, $slack_msg) = @_;

    # Mark every message as read as it comes
    $self->mark_read($slack_msg);

    # Ignore messages with a subtype
    return if defined $slack_msg->{subtype};

    # Ignore message edits
    return if defined $slack_msg->{edited};

    # We need to determine the channel type
    my $channel_type = substr $slack_msg->{channel}, 0, 1;

    # IDs for Slack identify type by starting char:
    #
    #   D - IM channel
    #   G - Private Group channel
    #   C - Team channel
    #

    if ($channel_type eq 'D') {
        $self->got_direct_message($slack_msg);
    }
    else {
        $self->got_group_message($slack_msg);
    }
}

=head2 got_direct_message

Handles direct messages received from an IM channel.

=cut

sub got_direct_message {
    my ($self, $slack_msg) = @_;

    # Ignore messages from ourself
    return if $slack_msg->{user} eq $self->whoami->{user_id};

    my $message = Bot::Backbone::Message->new({
            chat  => $self,
            from  => $self->load_user(id => $slack_msg->{user}),
            to    => $self->load_user(id => $self->user_id),
            group => undef,
            text  => $slack_msg->{text},
        });

    $self->resend_message($message);
    $self->dispatch_message($message);
}

=head2 is_to_me

This determines whether or not the message is to the bot.

=cut

sub is_to_me {
    my ($self, $me_user, $text) = @_;

    my $me_nick = $me_user->nickname;
    return scalar($$text =~ s/^ @?$me_nick \s* [:,\-] \s*
        |  \s* , \s* @?$me_nick [.!?]? $
        |  , \s* @?$me_nick \s* ,
        //x);
}

# Not sure I like how this works yet. Leaving out of the docs for now.
sub mark_read {
    my ($self, $slack_msg) = @_;

    # Don't really mark more than every 15 seconds
    return unless time - $self->last_mark > 15;

    my $channel = $slack_msg->{channel};
    my $ts      = $slack_msg->{ts};

    my $type = substr $channel, 0, 1;
    if ($type eq 'C') {
        $self->api->channels->mark( channel => $channel, ts => $ts );
    }
    elsif ($type eq 'G') {
        $self->api->groups->mark( channel => $channel, ts => $ts );
    }
    elsif ($type eq 'D') {
        $self->api->im->mark( channel => $channel, ts => $ts );
    }

    $self->last_mark(time);
}

=head2 got_group_message

This handles message received from private group or team channels.

=cut

sub got_group_message {
    my ($self, $slack_msg) = @_;

    # Ignore messages from ourself
    return if $slack_msg->{user} eq $self->whoami->{user_id};

    my $me_user = $self->load_me;

    my $text = $slack_msg->{text};
    my $to_identity;
    if ($self->is_to_me($me_user, \$text)) {
        $to_identity = $me_user;
    }

    my $message = Bot::Backbone::Message->new({
            chat   => $self,
            from   => $self->load_user(id => $slack_msg->{user}),
            to     => $to_identity,
            group  => $self->load_channel( id => $slack_msg->{channel} ),
            text   => $text,
        });

    $self->resend_message($message);
    $self->dispatch_message($message);
}

=head2 send_message

    method send_message({
        to    => $user_id,
        group => $group_id,
        text  => $message,
    })

This sends a message to a Slack channel. To the named user's IM channel or to a private group or team channel named by C<$group_id>.

=cut

sub send_message {
    my ($self, $params) = @_;

    my $to    = $params->{to};
    my $group = $params->{group};
    my $text  = $params->{text};

    my $channel;
    if (defined $group) {
        $channel = $self->load_channel( id => $group );
    }
    else {
        $channel = $self->load_user_channel( user => $to );
    }

    $self->api->chat->post_message(
        channel => $channel,
        text    => $text,
        as_user => 1,
    );
}

=begin Pod::Coverage

    load_channel
    mark_read

=end Pod::Coverage

=cut

__PACKAGE__->meta->make_immutable;
