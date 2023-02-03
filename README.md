# statuspagebot

An IRC bot that writes updates from a statuspage server (by default
https://status.w3.org/) on IRC.

A manual is included in the statuspagebot.pl file. For a nicely
formatted version, use

    perldoc -oman ./statuspagebot.pl

Currently, the bot **polls** the statuspage server (by default every
two minutes), which is not very efficient. The data transferred each
time is less than 1KB, but still. A rewrite to let the statuspage
server **push** updates instead (via email or a webhook) would be
nice. (Although it requires that statuspagebot runs on a server that
can receive email or HTTP requests.)

Short instructions: To get status data from status.w3.org and display
it on the IRC server at irc.w3.org, run something like

    ./statuspagebot.pl -v -s https://status.w3.org/ ircs://mylogin@irc.w3.org/

and enter your password for the IRC server. Then, on IRC, invite the
bot to a channel with

    /invite statuspagebot

It will write a message whenever there is an incident to report
(hopefully very rarely) and you can also ask it explicitly what the
latest status is:

    statuspagebot, status?

To run the bot, you will need perl and some perl modules. The one that
you probably do not have installed by default is XML::Feed. On Debian
and similar systems, you can (as root) install it with a command such
as:

    apt install libxml-feed-perl
