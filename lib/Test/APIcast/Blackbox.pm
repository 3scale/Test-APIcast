package Test::APIcast::Blackbox;
use strict;
use warnings FATAL => 'all';
use v5.10.1;
use JSON;

use Test::APIcast -Base;
use File::Copy "move";
use File::Temp qw/ tempfile /;
use File::Slurp qw(read_file);

BEGIN {
    $ENV{APICAST_OPENRESTY_BINARY} = $ENV{TEST_NGINX_BINARY};
}

our $ApicastBinary = $ENV{TEST_NGINX_APICAST_BINARY} || 'bin/apicast';

our %EnvToNginx = ();
our %ResetEnv = ();

sub env_to_apicast (@) {
    my %env = (@_);

    # merge two hashes, new %env takes precedence
    %EnvToNginx = (%EnvToNginx, %env);
};

my $original_server_port_for_client;

sub set_server_port_for_client (@) {
    $original_server_port_for_client = $Test::Nginx::Util::ServerPortForClient;
    Test::Nginx::Util::server_port_for_client(shift);
    if ($Test::Nginx::Util::Verbose) {
        warn("changed ServerPortForClient from $original_server_port_for_client to $Test::Nginx::Util::ServerPortForClient");
    }
}

add_block_preprocessor(sub {
    my $block = shift;
    my $seq = $block->seq_num;
    my $name = $block->name;
    my $configuration = $block->configuration;
    my $backend = $block->backend;
    my $backend_name = $block->backend_name || 'test_backend';
    my $upstream = $block->upstream;
    my $upstream_name = $block->upstream_name || 'test';
    my $test = $block->test;
    my $sites_d = $block->sites_d || '';
    my $ServerPort = $Test::Nginx::Util::ServerPort;

    if (defined($test) && !defined($block->request) && !defined($block->raw_request) ) {
        my $test_port = Test::APIcast::get_random_port();
        $sites_d .= <<_EOC_;
        server {
            listen $test_port;

            server_name test default_server;

            set \$apicast_port $ServerPort;

            location / {
                $test
            }
        }
_EOC_

        set_server_port_for_client($test_port);
        $block->set_value('raw_request', "GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")
    }

    if (defined $backend) {
        $sites_d .= <<_EOC_;
        server {
            listen $ServerPort;

            server_name $backend_name backend;

            $backend
        }

        upstream $backend_name {
            server 127.0.0.1:$ServerPort;
        }

_EOC_
        $ENV{BACKEND_ENDPOINT_OVERRIDE} = "http://test_backend:$ServerPort";
    }

    if (defined $upstream) {
        $sites_d .= <<_EOC_;
        server {
            listen $ServerPort;

            server_name $upstream_name;

            $upstream
        }

        upstream $upstream_name {
            server 127.0.0.1:$ServerPort;
        }
_EOC_
    }

    my $configuration_format = $block->configuration_format || 'json';

    if (defined $configuration) {
        $configuration = Test::Nginx::Util::expand_env_in_config($configuration);
        {
            local $SIG{__DIE__} = sub {
                Test::More::fail("$name - configuration block JSON") || Test::More::diag $_[0];
            };

            if ($configuration_format eq 'json') {
                decode_json($configuration);
            }
        }
        $block->set_value("configuration", $configuration);
        $block->set_value("configuration_format", $configuration_format);
    }

    $block->set_value("config", "$name ($seq)");
    $block->set_value('sites_d', $sites_d)
});

my $write_nginx_config = sub {
    my $block = shift;

    my $FilterHttpConfig = $Test::Nginx::Util::FilterHttpConfig;
    my $ConfFile = $Test::Nginx::Util::ConfFile;
    my $Workers = $Test::Nginx::Util::Workers;
    my $MasterProcessEnabled = $Test::Nginx::Util::MasterProcessEnabled;
    my $DaemonEnabled = $Test::Nginx::Util::DaemonEnabled;
    my $err_log_file = $block->error_log_file || $Test::Nginx::Util::ErrLogFile;
    my $LogLevel = $Test::Nginx::Util::LogLevel;
    my $PidFile = $Test::Nginx::Util::PidFile;
    my $AccLogFile = $Test::Nginx::Util::AccLogFile;
    my $ServerPort = $Test::Nginx::Util::ServerPort;
    my $backend_port = Test::APIcast::get_random_port();
    my $echo_port = Test::APIcast::get_random_port();

    my $management_server_name = $ENV{TEST_NGINX_MANAGEMENT_SERVER_NAME};

    my $management_port;
    if (defined $management_server_name) {
        $management_port = $ServerPort;
        $management_server_name = "'$management_server_name'"
    } else {
        $management_port = Test::APIcast::get_random_port();
        $management_server_name = 'nil'
    }

    my $environment = $block->environment;
    my @environments;
    my $environment_file = $block->environment_file;

    if (defined $environment_file && ref $environment_file eq 'ARRAY') {
        @environments = @$environment_file;
    } elsif (defined($environment_file)) {
        @environments = $environment_file;
    }

    unshift @environments, 'production';

    my $sites_d = $block->sites_d;
    my $apicast_cli = $block->apicast || $ApicastBinary;

    my $configuration = $block->configuration;
    my $conf;
    my $configuration_file = $block->configuration_file;
    my $configuration_format = $block->configuration_format;

    if (defined $configuration_file) {
        chomp($configuration_file);
        $configuration_file = "$configuration_file";
    } else {
        if (defined $configuration) {
            ($conf, $configuration_file) = tempfile(SUFFIX => ".$configuration_format");
            print $conf $configuration;
            close $conf;

            $configuration_file = "$configuration_file";
        }
    }

    my %env = (%EnvToNginx, $block->env);

    # reset ENV to memorized state
    for my $key (keys %ResetEnv) {
        if (defined $ResetEnv{$key}) {
            $ENV{$key} = $ResetEnv{$key};
        } else {
            delete $ENV{$key};
        }
        delete $ResetEnv{$key};
    }

    for my $key (keys %env) {
        # memorize ENV before changing it
        $ResetEnv{$key} = $ENV{$key};
        # change ENV to state desired by the test
        $ENV{$key} = $env{$key};
    }

    my ($env, $env_file) = tempfile();
    push @environments, $env_file;

    my $apicast_cmd = "APICAST_CONFIGURATION_LOADER='test' $apicast_cli start --test";

    if (defined $configuration_file && $configuration_file) {
        $apicast_cmd .= " --configuration $configuration_file"
    } else {
        $configuration_file = "";
    }

    foreach my $ef (@environments) {
        $apicast_cmd .= " --environment $ef"
    }

    if (defined $environment) {
        print $env $environment;
    } else {
        print $env <<_EOC_;
return {
    worker_processes = '$Workers',
    master_process = '$MasterProcessEnabled',
    daemon = '$DaemonEnabled',
    error_log = '$err_log_file',
    timer_resolution = false,
    log_level = '$LogLevel',
    pid = '$PidFile',
    lua_code_cache = 'on',
    access_log = '$AccLogFile',
    port = {
      apicast = '$ServerPort',
      management = '$management_port',
      backend = '$backend_port',
      echo = '$echo_port',
      metrics = '$ServerPort',
    },
    env = {
        THREESCALE_CONFIG_FILE = [[$configuration_file]],
        APICAST_CONFIGURATION_LOADER = 'boot'
    },
    server_name = {
        management = $management_server_name
    },
    sites_d = [============================[$sites_d]============================],
}
_EOC_
    }
    close $env;

    if ($ENV{DEBUG}) {
        warn $apicast_cmd;
    }

    Test::Nginx::Util::setup_server_root();
    my $log = `${apicast_cmd} 2>$Test::Nginx::Util::ErrLogFile; cat $Test::Nginx::Util::ErrLogFile`;

    if ($log =~ /configuration file (?<file>.+?) test/)
    {
        open(my $fh, '+>', $ConfFile) or die "cannot open $ConfFile: $!";

        my $nginx_config = read_file($+{file});

        if ($FilterHttpConfig) {
            $nginx_config = $FilterHttpConfig->($nginx_config);
        }

        print { $fh } $nginx_config;
        close($fh);
    } else {
        bail_out("Missing config file: $Test::Nginx::Util::ConfFile");
        warn $log;
    }

    if ($PidFile && -f $PidFile) {
        unlink $PidFile or warn "Couldn't remove $PidFile.\n";
    }

    $ENV{APICAST_LOADED_ENVIRONMENTS} = join('|',@environments);
};

sub ignore_missing_directives($) {
    my $block = shift;
    my $ServRoot = $Test::Nginx::Util::ServRoot;
    my $ConfFile = $Test::Nginx::Util::ConfFile;
    my $NginxBinary = $Test::Nginx::Util::NginxBinary;
    my $ErrLogFile = $Test::Nginx::Util::ErrLogFile;

    if (defined $ENV{TEST_NGINX_IGNORE_MISSING_DIRECTIVES}) {
        Test::Nginx::Util::setup_server_root();

        $write_nginx_config->($block);

        my $test = system("$NginxBinary -p $ServRoot -c $ConfFile -t 2> $ErrLogFile");

        if ( $test != 0) {

            if (my $directive = Test::Nginx::Util::check_if_missing_directives())
            {
                return $directive;
            }
        }
    }
}

add_block_preprocessor(sub {
    if (defined $original_server_port_for_client) {
        Test::Nginx::Util::server_port_for_client($original_server_port_for_client);
        undef $original_server_port_for_client;
    }
});

BEGIN {
    no warnings 'redefine';

    *original_run_test = \&Test::Nginx::Util::run_test;
    *Test::Nginx::Util::run_test = sub ($) {
        my $block = shift;

        SKIP: {
            my $missing_directive = ignore_missing_directives($block);
            my $name = $block->name;
            skip "$name -- tests skipped because of the lack of directive $missing_directive" if $missing_directive;

            original_run_test($block);
        }

    };

    sub Test::Nginx::Util::write_config_file ($$) {
        my $block = shift;
        $write_nginx_config->($block);

        Test::APIcast::close_random_ports();
    }


    # Copy-paste from Test::Nginx::Util

    sub Test::Nginx::Util::check_if_missing_directives () {
        my $logfile = $Test::Nginx::Util::ErrLogFile;

        open my $in, $logfile or
            bail_out "check_if_missing_directives: Cannot open $logfile for reading: $!\n";

        while (<$in>) {
            # warn "LINE: $_";
            # This is changed as the format is following: [emerg] unknown directive "name"
            if (/\[emerg\] unknown directive "([^"]+)"/) {
                return $1;
            }
        }

        close $in;

        return 0;
    }

}

our @EXPORT = qw(
    env_to_apicast
);

1;
