# NAME

Bot::Backbone::Service::SlackChat - Connect and chat with a Slack server

# VERSION

version 0.151570

# SYNOPSIS

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

# DESCRIPTION

This allows a [Bot::Backbone](https://metacpan.org/pod/Bot::Backbone) chat bot to be connect to a Slack server using their Real-Time Messaging API.

This is based on [AnyEvent::SlackRTM](https://metacpan.org/pod/AnyEvent::SlackRTM) and [WebService::Slack::WebApi](https://metacpan.org/pod/WebService::Slack::WebApi). It also uses a [CHI](https://metacpan.org/pod/CHI) cache to help avoid contacting the Slack server too often, which could result in your bot becoming rate limited.

# ATTRIBUTES

## token

The `token` is the access token from Slack to use. This may be either of the following type of tokens:

- [User Token](https://api.slack.com/tokens). This is a token to perform actions on behalf of a user account.
- [Bot Token](https://slack.com/services/new/bot). If you configure a bot integration, you may use the access token on the bot configuration page to use this library to act on behalf of the bot account. Bot accounts may not have the same features as a user account, so please be sure to read the Slack documentation to understand any differences or limitations.

Which you use will depend on whether you want the bot to control a user account or a bot integration account. You are responsible for adhering to the Slack terms of use in whatever you do.

## cache

This is a [CHI](https://metacpan.org/pod/CHI) cache to use to temporarily store response from the Slack APIs. By default, this is a memory-only cache that caches data for only 60 seconds. The purpose is mainly to prevent repeated requests to the API, which might result in rate limiting.

## api

This is the [WebService::Slack::WebApi](https://metacpan.org/pod/WebService::Slack::WebApi) object used to contact Slack for information about channels, users, etc.

## rtm

This is the [AnyEvent::SlackRTM](https://metacpan.org/pod/AnyEvent::SlackRTM) object used to communicate with Slack and trigger events from the Real-Time Messaging API.

## error\_callback

This is a callback sub that may be used to report error events from the RTM API. Set it to a sub that will be called as follows:

    sub {
        my ($self, $rtm, $message) = @_;

        ...
    }

Here, `$self` is the [Bot::Backbone::Service::SlackChat](https://metacpan.org/pod/Bot::Backbone::Service::SlackChat) object, `$rtm` is the [AnyEvent::SlackRTM](https://metacpan.org/pod/AnyEvent::SlackRTM) object, and `$message` is a hash containing the error message, as described on the [Real Time Messaging API](https://api.slack.com/rtm) documentation.

## whoami

This returns a hash containing information about who the bot is.

# METHODS

## user

Returns the name of the bot.

## user\_id

Returns the user ID for the bot.

## team\_id

Returns the team ID for the team account.

## initialize

This connects to Slack and prepares the bot for communication.

## load\_user

    method load_user($by, $value) returns Bot::Backbone::Identity

Fetches information about a user from Slack and returns the user as a [Bot::Backbone::Identity](https://metacpan.org/pod/Bot::Backbone::Identity). The `$by` setting determines how the user is looked up, which may either be by "id" or by "name". The value, then, is the value to check.

## load\_me

    method load_me() returns Bot::Backbone::Identity

Returns the identity object for the bot itself.

## load\_user\_channel

    method load_user_channel($by, $value) returns Str

Returns the ID of a user's IM channel. Here `$by` may be "user" to lookup by user ID.

## join\_group

    method join_group({ group => $group })

Given the ID of a channel or group, this causes the bot to open or join it. Note that Slack bot integration accounts might not be able to join team channels, but may still be invited.

## got\_message

Handles messages from Slack. Decides whether they are group messages or direct and forwards them on as appropriate. Messages with a "subtype" will be ignored as will messages that are "edited".

This method also marks messages as read. 

## got\_direct\_message

Handles direct messages received from an IM channel.

## is\_to\_me

This determines whether or not the message is to the bot.

## got\_group\_message

This handles message received from private group or team channels.

## send\_message

    method send_message({
        to    => $user_id,
        group => $group_id,
        text  => $message,
    })

This sends a message to a Slack channel. To the named user's IM channel or to a private group or team channel named by `$group_id`.

# AUTHOR

Andrew Sterling Hanenkamp <hanenkamp@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by Qubling Software LLC.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
