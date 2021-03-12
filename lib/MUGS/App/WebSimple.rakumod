# ABSTRACT: Core logic to set up and run a MUGS web UI server

use Cro::HTTP::Log::File;
use Cro::HTTP::Server;
use Cro::HTTP::Session::InMemory;

use MUGS::Client;
use MUGS::Server::Stub;
use MUGS::App::WebSimple::Session;
use MUGS::App::WebSimple::Routes;


# Use subcommand MAIN args
%PROCESS::SUB-MAIN-OPTS = :named-anywhere;


#| Create a Cro::HTTP::Server serving the web UI
sub create-web-ui-server(:$application!, Str:D :$host!, UInt:D :$port!,
                         Bool:D :$secure!, :$private-key-file!, :$certificate-file!) {
    my Cro::Service $http = Cro::HTTP::Server.new(
        http => <1.1>, :$host, :$port, :$application,
        |(tls => %( :$private-key-file, :$certificate-file ) if $secure),
        after => [
            Cro::HTTP::Log::File.new(logs => $*OUT, errors => $*ERR)
        ]
    );
}


#| Convenience method to flush a single message to $*OUT without autoflush
sub put-flushed(Str:D $message) {
    put $message;
    $*OUT.flush;
}


#| Launch a MUGS web UI server on host:port, using a MUGS backend at server
sub MAIN(# Web gateway host:port
         Str:D  :$host        = %*ENV<MUGS_WEB_SIMPLE_HOST> || 'localhost',
         UInt:D :$port        = %*ENV<MUGS_WEB_SIMPLE_PORT> || 20_000,

         # TLS keys/certs
         :$private-key-file   = %*ENV<MUGS_WEB_SIMPLE_TLS_KEY>       ||
                                %?RESOURCES<fake-tls/server-key.pem> ||
                                 'resources/fake-tls/server-key.pem',
         :$certificate-file   = %*ENV<MUGS_WEB_SIMPLE_TLS_CERT>      ||
                                %?RESOURCES<fake-tls/server-crt.pem> ||
                                 'resources/fake-tls/server-crt.pem',
         :$server-ca-file     = %*ENV<MUGS_WEBSOCKET_TLS_CA>         ||
                                %?RESOURCES<fake-tls/ca-crt.pem>     ||
                                 'resources/fake-tls/ca-crt.pem',

         # WebSocket backend MUGS server
         Str:D  :$server-host = %*ENV<MUGS_WEBSOCKET_HOST> || 'localhost',
         UInt:D :$server-port = %*ENV<MUGS_WEBSOCKET_PORT> || 0,
         Str:D  :$server      = $server-host && $server-port
                                ?? "wss://$server-host:$server-port/mugs-ws" !! '',

         # Boolean flags
         Bool:D :$secure      = False,
         Bool:D :$debug       = True,
        ) is export {

    $PROCESS::DEBUG = $debug;

    put-flushed 'Loading game client plugins.';
    MUGS::Client.load-game-plugins;
    my @loaded = MUGS::Client.known-implementations.sort;
    put-flushed "Loaded: @loaded[]\n";

    my $mugs-server = do if $server {
        put-flushed "Using server '$server'";
        $server
    }
    else {
        put-flushed 'Using internal stub server.';
        my $stub = create-stub-mugs-server;

        put-flushed 'Loading game server plugins.';
        $stub.load-game-plugins;
        my @loaded = $stub.known-implementations.sort;
        put-flushed "Loaded: @loaded[]\n";

        $stub
    }

    my %mugs-ca        = ca-file => $server-ca-file;
    my $SessionManager = Cro::HTTP::Session::InMemory[MUGSSession];
    my $application    = routes(:root($*PROGRAM.parent(2)), :mugs($mugs-server),
                                :%mugs-ca, :$SessionManager);
    my $ui-server      = create-web-ui-server(:$application, :$host, :$port,
                                              :$secure, :$private-key-file,
                                              :$certificate-file);

    $ui-server.start;
    my $url = "http{'s' if $secure}://$host:$port/";
    put-flushed "Listening at $url";

    react {
        whenever signal(SIGINT) {
            put-flushed 'Shutting down.';
            $ui-server.stop;
            done;
        }
    }
}
