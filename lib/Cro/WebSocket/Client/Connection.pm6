use Cro;
use Cro::TCP;
use Cro::WebSocket::FrameParser;
use Cro::WebSocket::FrameSerializer;
use Cro::WebSocket::Message;
use Cro::WebSocket::MessageParser;
use Cro::WebSocket::MessageSerializer;

class PromiseFactory {
    has @.promises;

    method get-new(--> Promise) {
        my $p = Promise.new;
        @!promises.push: $p;
        $p;
    }

    method reset() {
        @!promises.map({.keep});
        @!promises = ();
    }
}

class Cro::WebSocket::Client::Connection {
    has Supply $.in;
    has Supplier $.out;
    has Supplier $.sender;
    has Supply $.receiver;
    has Promise $.closer is rw;
    has PromiseFactory $.pong;
    has Bool $.closed is rw;

    method new(:$in, :$out) {
        my $sender = Supplier.new;
        my $receiver = Supplier.new;
        my $closer = Promise.new;
        my $pong = PromiseFactory.new(promises => ());
        my $closed = False;

        my $pp-in = Cro.compose(Cro::WebSocket::FrameParser.new(mask-required => False),
                                Cro::WebSocket::MessageParser.new
                               ).transformer($in.map(-> $data { Cro::TCP::Message.new(:$data) }));

        my $pp-out = Cro.compose(Cro::WebSocket::MessageSerializer.new,
                                 Cro::WebSocket::FrameSerializer.new(mask => True)
                                ).transformer($sender.Supply);

        my $instance = self.bless(:$in, :$out, :$sender, receiver => $receiver.Supply, :$closer, :$pong, :$closed);

        $pp-in.tap(-> $_ {
                          if .is-data {
                              $receiver.emit: $_;
                          } else {
                              when $_.opcode == Cro::WebSocket::Message::Ping {
                                  my $body-byte-stream = $_.body-byte-stream;
                                  my $m = Cro::WebSocket::Message.new(opcode => Cro::WebSocket::Message::Pong,
                                                                      fragmented => False,
                                                                      :$body-byte-stream);
                                  $sender.emit: $m;
                              }
                              when $_.opcode == Cro::WebSocket::Message::Pong {
                                  $pong.reset;
                              }
                              when $_.opcode == Cro::WebSocket::Message::Close {
                                  $instance.closed = True;
                                  $instance.closer.keep($_);
                                  self.close(1000);
                              }
                          }
                      });
        $pp-out.tap(-> $_ {
                           $out.emit: $_.data;
                       });

        $instance;
    }

    method messages(--> Supply) {
        $!receiver;
    }

    multi method send(Cro::WebSocket::Message $m) {
        die if $!closed;
        $!sender.emit($m);
    }
    multi method send($m) {
        die 'Expecting message-like type, $m was sent' unless $m ~~ Str|Blob|Supply;
        self.send(Cro::WebSocket::Message.new($m));
    }

    method close($code = 1000, :$timeout --> Promise) {
        $!closed = True;
        my $p = Promise.new;
        my &body = -> $_ { supply { emit Blob.new($_ +& 0xFF, ($_ +> 8) +& 0xFF); } };

        start {
            my $message = Cro::WebSocket::Message.new(opcode => Cro::WebSocket::Message::Close,
                                                      fragmented => False,
                                                      body-byte-stream => &body($code));
            my $real-timeout = $timeout // 2;
            if $real-timeout == False || $real-timeout == 0 {
                $!sender.emit: $message;
                $!sender.done;
                $p.keep($message);
            } else {
                $!sender.emit: $message;
                await Promise.anyof(Promise.in($timeout), $!closer);
                $!sender.done;
                if $!closer.status == Kept {
                    $p.keep($!closer.result);
                } else {
                    my $close-m = Cro::WebSocket::Message.new(opcode => Cro::WebSocket::Message::Close,
                                                              fragmented => False,
                                                              body-byte-stream => &body(1006));
                    $p.break($close-m);
                }
            }
        }
        $p;
    }

    method ping($data?, Int :$timeout --> Promise) {
        my $p = $!pong.get-new;

        with $timeout {
            start {
                await Promise.in($timeout);
                unless $p.status ~~ Kept {
                    $p.break;
                }
            }
        };

        $!sender.emit(Cro::WebSocket::Message.new(opcode => Cro::WebSocket::Message::Ping,
                                                  fragmented => False,
                                                  body-byte-stream => supply {
                                                         emit $data.encode if $data;
                                                         done;
                                                     }));
        $p;
    }
}
