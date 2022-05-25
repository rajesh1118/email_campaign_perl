#===============================================================================
#
#         FILE: mailing_list.pm
#
#  DESCRIPTION: A script that will allow for creating and monitoring of
#  a mailing list. Uses mailkit xml-rpc calls to create and monitor said calls.
#  If a mailing list is active, will not create it and will provide only
#  monitoring data.
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Rajesh
#      VERSION: 1.0
#      CREATED: 24/05/2022
#     REVISION: ---
#===============================================================================
use strict;
use warnings;
use Frontier::Client;
use Data::Dumper;
use Try::Tiny;
use Getopt::Std;
use JSON::XS;
use MIME::Base64;
use LWP::Simple;
use HTML::Template;

my $stash = {MAILINGLISTID => 83818};
my $seed = 'MAILLIST_CREATE';
my $operations = {
  'MAILLIST_CREATE'=> { METHOD => "mailkit.mailinglist.create", SUB => \&mail_list_create},
  'MAILLIST_IMPORT'=> {METHOD => "mailkit.mailinglist.import", SUB => \&mail_list_import},
  'CAMPAIGN_CREATE' => {METHOD => "mailkit.campaigns.create", SUB => \&campaign_create},
  'CAMPAIGN_SEND' => {METHOD => "mailkit.sendmail", SUB => \&campaign_send},
  'CAMPAIGN_REPORT' => {METHOD => "mailkit.report.campaign", SUB => \&mailkit_report},
 };

my %opts;
getopts('c:', \%opts);

my $configFileName = $opts{c};
my $configuration = readConfiguration($configFileName);

# Kick start the script.
process(undef, 'MAILLIST_IMPORT');

sub process {
  my ($error, $operation) = @_;
  if ($error) {
    die("Unable to process - $error");
  }
  if ($operation =~   m/completed/i) {
    print "Completed\n";
    exit 0;
  }
  print "Running $operation\n";
  $operations->{$operation}->{SUB}->({
    %$configuration,
    STASH => $stash,
    METHOD => $operations->{$operation}->{METHOD},
  });
}

sub campaign_create {
  my ($args) = @_;
  my ($stash, $method, $allow_email_id) = @{$args}{qw/STASH METHOD ID_ALLOW_EMAIL/};
  my ($name, $subject) = @{$args}{qw/CAMPAIGN_NAME CAMPAIGN_DESCRIPTION/};

  my $client = getRPCClient({
    %$args,
  });

  my $result = $client->call(
    $method,
    $client->{clientid},
    $client->{clientkey},
    {
      name => encode_base64($name),
      subject => encode_base64($subject),
      'ID_allow_email', encode_base64($allow_email_id),
      'type_message' => encode_base64('email'),
      'type_send' => encode_base64('html'),
      'ID_mailing_list' => encode_base64(int($stash->{MAILINGLISTID})),
    }
  );

  if ($result =~ /\d+/) {
    $stash->{CAMPAIGNID} = $result;
    process(undef, 'CAMPAIGN_SEND');
  }
  else {
    process('$result', undef);
  }
}

sub mail_list_create {

  my ($args) = @_;
  my ($stash, $method) = @{$args}{qw/STASH METHOD/};
  my $client = getRPCClient({
    %$args,
  });

  my $result = $client->call(
    $method,
    $client->{clientid},
    $client->{clientkey},
    $args->{MAILLIST_NAME}
  );

  if (ref $result ne 'HASH' || $result =~ /exist/) {
    process(undef, 'CAMPAIGN_REPORT');
  }
  else {
    $stash->{MAILINGLISTID} = $result->{data};
    process(undef, 'MAILLIST_IMPORT');
  }
}

sub mail_list_import {

  my ($args) = @_;
  my ($stash, $method) = @{$args}{qw/STASH METHOD/};
  my $users_url = $args->{USERS_URL};
  my $users_file = $args->{USERS_FILE};

  my $users;
  if ($users_url) {
    print "Fetching users from - $users_url\n";
    $users = decode_json(get($users_url));
  }

  if ($users_file) {
    local $\ = undef;
    open my $usersFH, "<:encoding(UTF-8)", $users_file;
    $users = decode_json(<$usersFH>);
  }

  my $result;
  my $client = getRPCClient({ %$args });
  $result = $client->call(
    $method,
    $client->{clientid},
    $client->{clientkey},
    int($stash->{MAILINGLISTID}),
    $users,
  );

  process(undef, 'CAMPAIGN_CREATE', $result);
}

sub campaign_send {

  my ($args) = @_;
  my ($stash, $method) = @{$args}{qw/STASH METHOD/};
  my ($maillistid, $campaignid) = @{$stash}{qw/MAILINGLISTID CAMPAIGNID/};

  my $client = getRPCClient({%$args});
  my $result = $client->call(
    $method,
    $client->{clientid},
    $client->{clientkey},
    int($maillistid),
    int($campaignid),
    {
      'send_to' => q{$args->{SEND_TO}},
      subject => 'Test Script',
      'message_data' => encode_base64(getHTMLMessage()),
      status => encode_base64('enabled'),
    },
  );

  if (ref $result eq 'HASH') {
    process(undef, "completed");
  }
  else {
    process($result, '');
  }
}

#################################################################
# makeRPCCall
#
# Description -
# This method will make an rpc-xml call and retun the results.
# If for some reason the call fails, returns undef.
#
# Args -
# Hash having the following data.
#  URL -> The service url to make the call to.
#  CLIENTID -> The client ID for authentication.
#  CLIENTKEY -> The client key (password) for authentication.
#  METHOD -> The method that will be invoked remotely.
#  DATA -> A hash of additional data the specific method takes.
#
# Return Value -
# Returns the data if the call is successful, else undef.
#################################################################
sub makeRPCCall {

  my ($args) = @_;
  my ($url, $clientid, $clientkey) = @{$args}{qw/URL CLIENTID CLIENTKEY/};
  my ($method, $data) = @{$args}{qw/METHOD DATA/};
  my $client = getRPCClient({
    URL => $url,
    CLIENT => $clientid,
    CLIENTKEY => encode_base64($clientkey),
  });

  my $encoded_data;
  $encoded_data  = {
    map { $_ => encode_base64($data->{$_}) } keys %{$data}
  } if $data;

  my $result;
  try {
    $result = $client->call(
      $method,
      $clientid,
      $clientkey,
      (
        $data
        ? %$encoded_data
        : ()
      ),
    );
  }
  catch {
  };

  return $result;
}

#################################################################
# getHTMLMessage
#
# Description -
# This method return the HTML message from a given source.
#
# Args -
# Hash having the following data.
#  MESSAGE -> A HTML message.
#
# Return Value -
# Returns the HTML message as string.
#################################################################
sub getHTMLMessage {
  my ($args) = @_;
  my $message = $args->{MESSAGE} || \*DATA;
  my $html = HTML::Template->new(filehandle=>$message);
  return $html->output;
}

#################################################################
#checkForExistingCampaign
# Description -
# Checks if a campaign is already running. So this is achieved by
# creating a lock file when the script runs. We check for the lock
# and stop progress of a new invocation until the running script
# exists.
#
# Args -
# Hash having the following data.
#  LOCKFILELOCATION - The path of the lock file.
#
# Return Value -
# Returns the HTML message as string.
#################################################################
sub checkForExistingCampaign {
  my ($lockFileLocation) = @_;

  -e "${lockFileLocation}$0.lock"
  ? return 1
  : return 0;
}

#################################################################
# lockScriptForExecution
# Description -
# Locks the script for a single run. Any other invocations should
# fail if an instance is already running.
#
# Args -
# Hash having the following data.
#  LOCKFILELOCATION - The path of the lock file.
#
# Return Value -
# Returns 1 if true else exists.
#################################################################
sub lockScriptForExecution {
  my ($lockFileLocation) = @_;

  unless (checkForExistingCampaign($lockFileLocation)) {
    open my $lockFH, ">", "$lockFileLocation$0.lock" or die("$!");
    print {$lockFH} "CAMPAIGNID = \n";
    close $lockFH;
    return 1;
  }
  print <<'MESSAGE';
  Another instance of this script is already running.
  Run this when the running script has completed.
MESSAGE
  exit -1;
}

#################################################################
# readConfiguration
# Description -
# Read in a configuration file and return a hash of config values.
# Config file should have the following syntax -
# CONFIG_NAME = CONFIG_VALUE
#
# Args -
#  configFileName = full path to the config file name.
#
# Return Value -
# Returns hash of configs or undef if unsuccessful..
#################################################################
sub readConfiguration {
  # Read in a config file and return the data..
  my ($configFile) = @_;

  require Config::File;
  try {
      my $config = Config::File::read_config_file($configFile);
      return $config;
  }
  catch {
      if ($_) {
          print "$_";
      }
  }
}

sub getRPCClient {
  my ($args) = @_;

  my $url = $args->{URL};
  my ($clientid, $clientkey) = @{$args}{qw/CLIENTID CLIENTKEY/};

  require Frontier::Client;
  try {
      my $client = Frontier::Client->new(url => $url);
      $client->{clientid} = $clientid;
      $client->{clientkey} = $clientkey;
      return $client;
  }
  catch {
      die("Unable to get RPC Client");
  }
}

1;

__DATA__
<html>
  <head>
    <title>Rajesh's Mail Campaign</title>
  </head>
  <body>
    <h2>Greetings</h2>
    <h3>Happy New Year!!!</h3>
    <h3>Welcome to 2020</h3>
    <p>Another year, another chance, another change and another commitments.
    We are pleased to have you with us for all this time and look forward to
    work with you as we progress along this new year.
    Our growth has been phenomenal these many years and we wish to make this
    a recurring theme of our relationship. It has not always been for the good.
    As we go through things, we learn from our mistakes, look back and see
    what could have been done better, ensure we implement our learnings and
    measure progress.
    In lieu of this we would like to invite you to help us make this relationship
    more fruitful. We would really appreciate it if you could give us a few
    minutes to fill out a short survey that will enable us gauge our performance
    and serve you better. It should not take you more than a couple of minutes.
    <a href="https://links_to_somehwere.com/feedback>Click here</a> to access they
    survey form.
    Again we appreciate you working with us. We vow to make our services for you
    better than ever before and pray for a more involved relationship.</p>

    <p>P.S. <a href="drive.google.com">Click Here</a> to access the code rep..</p>

    <h4>Faithfully, yours</h4>
    <h5>Rajesh</h5>
    <h5>Awsome Tech Firm</h5>
  </body>
</html>