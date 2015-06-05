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

has token => (
  is          => 'ro',
  isa         => 'Str',
  required    => 1,
);

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

has last_mark => (
  is          => 'rw',
  isa         => 'Int',
  required    => 1,
  default     => 0,
);

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

has error_callback => (
  is          => 'ro',
  isa         => 'CodeRef',
  lazy        => 1,
  builder     => '_build_error_callback',
);

sub _build_error_callback {
  return sub {
    my ($self, $conn, $message) = @_;
    carp "Slack Error #$message->{error}{code}: $message->{error}{msg}\n";
  }
}

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

sub user    { shift->whoami->{user} }
sub user_id { shift->whoami->{user_id} }
sub team_id { shift->whoami->{team_id} }

sub initialize {
  my $self = shift;

  $self->rtm->on(
    message => sub { $self->got_message(@_) },
    error   => sub { $self->error_callback->($self, @_) }
  );

  $self->rtm->quiet(1);

  $self->rtm->start;
}

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

sub load_me {
  my $self = shift;
  return $self->load_user(id => $self->user_id);
}

sub load_user_channel {
  my ($self, $by, $value) = @_;

  croak "unknown lookup type $by" unless $by eq 'user' or $by eq 'id';

  my $list = $self->_cached("api.im.list", sub { $self->api->im->list });

  croak "unknown IM $by $value" unless $list->{ok};
  
  my ($im) = grep { $_->{ $by } eq $value } @{ $list->{members} };
  return $im->{id};
}

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

sub got_message {
  my ($self, $conn, $slack_msg) = @_;

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

sub got_direct_message {
  my ($self, $slack_msg) = @_;

  my $message = Bot::Backbone::Message->new({
      chat  => $self,
      from  => $self->load_user(id => $slack_msg->{user}),
      to    => $self->load_user(id => $self->user_id),
      group => undef,
      text  => $slack_msg->{text},
  });

  $self->resent_message($message);
  $self->dispatch_message($message);
}

sub is_to_me {
    my ($self, $me_user, $text) = @_;
 
    my $me_nick = $me_user->nickname;
    return scalar($$text =~ s/^ @?$me_nick \s* [:,\-] \s*
                             |  \s* , \s* @?$me_nick [.!?]? $
                             |  , \s* @?$me_nick \s* , 
                             //x);
}

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

sub got_group_message {
  my ($self, $slack_msg) = @_;

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

  $self->rtm->send({
      type    => 'message',
      channel => $channel,
      text    => $text,
  });
}

__PACKAGE__->meta->make_immutable;
