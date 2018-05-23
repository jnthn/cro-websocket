use Base64;
use Cro::HTTP::Client;
use Cro::HTTP::Header;
use Cro::Uri;
use Cro::WebSocket::BodyParsers;
use Cro::WebSocket::BodySerializers;
use Cro::WebSocket::Client::Connection;
use Crypt::Random;
use Digest::SHA1::Native;

class X::Cro::WebSocket::Client::CannotUpgrade is Exception {
    has $.reason;
    method message() { "Upgrade to WebSocket failed: $!reason" }
}

class Cro::WebSocket::Client {
    has $.uri;
    has $.body-serializers;
    has $.body-parsers;

    submethod BUILD(:$!uri, :$body-serializers, :$body-parsers, :$json --> Nil) {
        if $json {
            if $body-parsers === Any {
                $!body-parsers = Cro::WebSocket::BodyParser::JSON;
            }
            else {
                die "Cannot use :json together with :body-parsers";
            }
            if $body-serializers === Any {
                $!body-serializers = Cro::WebSocket::BodySerializer::JSON;
            }
            else {
                die "Cannot use :json together with :body-serializers";
            }
        }
        else {
            $!body-parsers = $body-parsers;
            $!body-serializers = $body-serializers;
        }
    }

    method connect($uri = '', :%ca? --> Promise) {
        my $parsed-url;
        if self && self.uri {
            $parsed-url = Cro::Uri.parse($uri ~~ Cro::Uri
                                         ?? self.uri ~ $uri.Str
                                         !! self.uri ~ $uri);
        } else {
            $parsed-url = $uri ~~ Cro::Uri ?? $uri !! Cro::Uri.parse($uri);
        }

        start {
            my $out  = Supplier::Preserving.new;

            my $key = encode-base64(crypt_random_buf(16), :str);
            my $magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
            my $answer = encode-base64(sha1($key ~ $magic), :str);

            my %options = headers => (Cro::HTTP::Header.new(name => 'Upgrade', value => 'websocket'),
                Cro::HTTP::Header.new(name => 'Connection', value => 'Upgrade'),
                Cro::HTTP::Header.new(name => 'Sec-WebSocket-Version', value => '13'),
                Cro::HTTP::Header.new(name => 'Sec-WebSocket-Key', value => $key),
                Cro::HTTP::Header.new(name => 'Sec-WebSocket-Protocol', value => 'echo-protocol'));

            %options<body-byte-stream> = $out.Supply;
            %options<http> = '1.1';
            my $resp = await Cro::HTTP::Client.get($parsed-url, |%options, :%ca);
            if $resp.status == 101 {
                # Headers check;
                unless $resp.header('upgrade') && $resp.header('upgrade') ~~ m:i/'websocket'/ {
                    die X::Cro::WebSocket::Client::CannotUpgrade.new(reason => "got {$resp.header('upgrade')} for 'upgrade' header");
                }
                unless $resp.header('connection') && $resp.header('connection') ~~ m:i/^Upgrade$/ {
                    die X::Cro::WebSocket::Client::CannotUpgrade.new(reason => "got {$resp.header('connection')} for 'connection' header");
                }
                with $resp.header('Sec-WebSocket-Accept') {
                    die X::Cro::WebSocket::Client::CannotUpgrade.new(reason => "wanted '$answer', but got $_") unless .trim eq $answer;
                } else {
                    die X::Cro::WebSocket::Client::CannotUpgrade.new(reason => "no Sec-WebSocket-Accept header included");
                }
                # No extensions for now
                # die unless $resp.header('Sec-WebSocket-Extensions') eq Nil;
                # die unless $resp.header('Sec-WebSocket-Protocol') eq 'echo-protocol'; # XXX
                Cro::WebSocket::Client::Connection.new(
                    in => $resp.body-byte-stream, :$out,
                    |(%(:$!body-parsers, :$!body-serializers) with self)
                )
            } else {
                die X::Cro::WebSocket::Client::CannotUpgrade.new(reason => "Response status is {$resp.status}, not 101");
            }
        }
    }
}
