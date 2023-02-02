# statuspagebot

An IRC bot that writes updates from a statuspage server (by default
https://status.w3.org/) on IRC.

A manual is included in the statuspagebot.pl file. For a nicely
formatted version, use

    perldoc -oman ./statuspagebot.pl

In short: run it with something like

    ./statuspagebot.pl -v -s https://status.w3.org/ ircs://mylogin@irc.w3.org/

and enter your password for the irc.w3.org server. Then, on IRC,
invite the bot to a channel with

    /invite statuspagebot

It will write a message whenever there is an incident to report
(hopefully very rarely) and you can also ask it explicitly what the
latest status is:

    statuspagebot, status?

To run the bot, you will need perl and some perl modules. The one that
is probably not installed yet is XML::Feed. On Debian and similar
systems, you can (as root) use a command such as:

    apt install libxml-feed-perl
