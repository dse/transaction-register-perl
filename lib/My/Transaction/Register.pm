package My::Transaction::Register;
use warnings;
use strict;

require 5.10.1;
use feature "switch";

use POSIX qw(strftime);
use Carp qw(croak);
use List::MoreUtils qw(all);

# We implement these as variables so we can interpolate them into
# regexes.
use vars qw($RX_DATE $RX_AMOUNT $RX_LINE_1 $RX_LINE_2);
BEGIN {
    $RX_DATE =
      qr{\?\?\?\?-\?\?-\?\?|    # unknown dates
         \d\d\d\d-\?\?-\?\?|
         \d\d\d\d-\d\d-\?\?|
         \d\d\d\d-\d\d-\d\d|	# known dates
         \d\d/\d\d
         #}x;
    $RX_AMOUNT =
      qr{\$?\(\$?\d+\.\d\d\)|	# for checking: deposit/credit
         -?\$?-?\d+\.\d\d\b	# for checking: withdrawal/debit
         #}x;

    # optional flag, then date, then amount, then merchant
    $RX_LINE_1 =
      qr{^\s*
         (?:([\-\*\/\+]+)\s*)?	# optional flag (posted, pending, future, etc.)
         ($RX_DATE)\s+
         ($RX_AMOUNT)\s+
         (\S.*?)		# merchant
         \s*$
         #}x;

    # optional flag, then date, then merchant, then amount
    $RX_LINE_2 =
      qr{^\s*
         (?:([\-\*\/\+]+)\s*)?	# optional flag (posted, pending, future, etc.)
         ($RX_DATE)\s+
         (\S.*?)                # merchant
         \s+
         ($RX_AMOUNT)\s*$
         #}x;
}

use Moose;
has 'start_balance'  => (is => 'rw', isa => 'Num',               default => 0);
has 'entries'        => (is => 'rw', isa => 'ArrayRef[HashRef]', default => sub { return []; });
has 'lines'          => (is => 'rw', isa => 'ArrayRef[HashRef]', default => sub { return []; });
has 'checkpoints'    => (is => 'rw', isa => 'ArrayRef[HashRef]', default => sub { return []; });
has 'account_type'   => (is => 'rw', isa => 'Str',               default => "checking");
has 'start_date'     => (is => 'rw', isa => 'Str',               default => "1970-01-01");
has '_stop_parsing'  => (is => 'rw', isa => 'Bool',              default => 0);
has '_last_date'     => (is => 'rw', isa => 'Str');
has '_last_date_fmt' => (is => 'rw', isa => 'Str');

sub multiplier {
    my ($self) = @_;
    my $type = $self->account_type;
    if ($type eq "checking") {
        return 1;
    }
    if ($type eq "credit-card" || $type eq "credit") {
        return -1;
    }
    return 1;
}

sub balance {
    my ($self, %args) = @_;
    my $filter     = $args{filter};
    my $map_amount = $args{map_amount};
    my $offset     = $args{offset} // 0;
    my $length     = $args{length} // (scalar(@{$self->entries}) - $offset);
    my $result     = $args{start}  // $self->start_balance;
    for (my $i = $offset; $i < ($offset + $length); $i += 1) {
        my $entry = $self->entries->[$i];
        if ($filter) {
            next if !($filter->($entry));
        }
        if ($map_amount) {
            $result += $self->multiplier * $map_amount->($entry);
        } else {
            $result += $self->multiplier * $entry->amount;
        }
    }
    return $result;
}

sub running_balance {
    my ($self, $start, $offset, $length) = @_;
    return $self->balance(
        start => $start,
        offset => $offset,
        length => $length,
        filter => sub {
            my ($entry) = @_;
            return !$entry->is_future;
        }
    );
}

sub pending_balance {
    my ($self, $start, $offset, $length) = @_;
    return $self->balance(
        start => $start,
        offset => $offset,
        length => $length,
        filter => sub {
            my ($entry) = @_;
            return ($entry->is_pending || $entry->is_posted) && !$entry->is_future;
        },
        map_amount => sub {
            my ($entry) = @_;
            if ($entry->is_pending) {
                return $entry->pending_amount // $entry->amount;
            } else {
                return $entry->amount;
            }
        }
    );
}

sub posted_balance {
    my ($self, $start, $offset, $length) = @_;
    return $self->balance(
        start => $start,
        offset => $offset,
        length => $length,
        filter => sub {
            my $entry = shift();
            return $entry->is_posted && !$entry->is_future;
        }
    );
}

sub worst_case_balance {
    my ($self, $start, $offset, $length) = @_;
    return $self->balance(
        start => $start,
        offset => $offset,
        length => $length,
        filter => sub {
            my $entry = shift();
            return 0 if $entry->is_future;
            return ($entry->amount < 0) || $entry->is_posted;
        }
    );
}

sub future_balance {
    my ($self, $start, $offset, $length) = @_;
    return $self->balance(
        start => $start,
        offset => $offset,
        length => $length
    );
}

sub parse_amount {
    my ($amount) = @_;
    $amount =~ s{\$+}{}g;
    if ($amount =~ m{^\((.*)\)$}) {
        return 0.0 + $1;        # deposit/credit (casting to double)
    } else {
        return 0.0 - $amount;   # withdrawal/debit (casting to double)
    }
}

sub process_parsed_line {
    my ($self, $entry, $flag, $date, $amount, $merchant) = @_;

    warn("<< $amount\n") if eval { $ENV{DEBUG} && $ENV{DEBUG} >= 2 };
    $amount = parse_amount($amount);
    warn(">> $amount\n") if eval { $ENV{DEBUG} && $ENV{DEBUG} >= 2 };
    if ($merchant =~ m{^\**\s*STARTING BALANCE\s*\**$}) {
        if ($self->start_balance) {
            warn("Second starting balance specified at $ARGV line $.\n");
        }
        $self->start_balance(-$amount);
        return;
    }
    $entry->amount($amount);
    if ($merchant =~ m{\[\s*p(?:reauth|end(?:ing)?)?\s+
                       ($RX_AMOUNT)
                       \s*\]}xi) {
        warn("<<< $1\n") if eval { $ENV{DEBUG} && $ENV{DEBUG} >= 2 };
        $entry->pending_amount(parse_amount($1));
        warn(">>> " . $entry->pending_amount . "\n") if eval { $ENV{DEBUG} && $ENV{DEBUG} >= 2 };
    }
    if ($merchant =~ m{\[\s*
                       ($RX_AMOUNT)
                       \s*\]}xi) {
        $entry->pending_amount(parse_amount($1));
    }
    my $parse_date = $self->parse_date($date);
    my $date_fmt = strftime("%Y-%m-%d", localtime($parse_date));

    $self->_last_date($parse_date);
    $self->_last_date_fmt($date_fmt);

    $entry->date($parse_date);
    $entry->date_fmt($date_fmt);
    $entry->merchant($merchant);

    if (defined($flag) and ($flag ne "")) {
        $flag = substr($flag, 0, 1);
        if ($flag eq "-") {
            $entry->is_pending(1);
        } elsif ($flag eq "*" or $flag eq "/") {
            $entry->is_posted(1);
        } elsif ($flag eq "+") {
            $entry->is_future(1);
        }
    }
    push(@{$self->entries}, $entry);
}

sub parse_line {
    my ($self, $text) = @_;

    return if $self->_stop_parsing;

    local $_ = $text;

    my $line_number = scalar(@{$self->lines}) + 1;
    my $line = My::Transaction::Register::Line->new(
        line_number => $line_number,
        text        => $_
    );
    push(@{$self->lines}, $line);

    my $entry = My::Transaction::Register::Entry->new(
        line_number => $line_number,
        text        => $_
    );

    chomp();
    return if /^\s*\#/;
    return unless /\S/;
    if ($_ =~ $RX_LINE_1) {
        my ($flag, $date, $amount, $merchant) = ($1, $2, $3, $4);
        $self->process_parsed_line($entry, $flag, $date, $amount, $merchant);
    } elsif ($_ =~ $RX_LINE_2) {
        my ($flag, $date, $merchant, $amount) = ($1, $2, $3, $4);
        $self->process_parsed_line($entry, $flag, $date, $amount, $merchant);
    } elsif (m{^\s*\**\s*CHECKPOINT\s*\**\s*}i) {
        my $note = $';
        warn("checkpoint\n") if $ENV{DEBUG};
        push(@{$self->checkpoints}, My::Transaction::Register::Checkpoint->new(
            date => $self->_last_date,
            date_fmt => $self->_last_date_fmt,
            running_balance => $self->running_balance(),
            note => $note
        ));
    } elsif (m{^\s*\**\s*STOP\s*\**\s*}i) {
        $self->_stop_parsing(1);
    } elsif (m{^\s*(\S+)\s*=\s*(.*?)\s*$}i) {
        my ($name, $value) = ($1, $2);
        if ($name eq "account-type") {
            $self->account_type($value);
        } elsif ($name eq "starting-balance") {
            if ($self->start_balance) {
                warn("Second starting balance specified at $ARGV line $.\n");
            }
            $self->start_balance($value);
        } elsif ($name eq "starting-date") {
            $self->start_date($value);
        }
    } else {
        warn("Funny-looking line at $ARGV line $.\n");
    }
}

use Text::ASCIITable;

sub debug {
    my ($self) = @_;
    my $running;
    my $pending;
    my $posted;
    my $worst_case;
    my $future;

    my @cols = qw(Number Date Amount Running Pending Ledger Worst-Case Future);

    my $t = Text::ASCIITable->new();
    $t->setCols(@cols);

    $t->addRow("", "", "", (map { sprintf("%.2f", $_) } (($self->start_balance) x 5)));
    $t->addRowLine();

    for (my $i = 0; $i < scalar(@{$self->entries}); ++$i) {
        $running    = $self->running_balance($running, $i, 1);
        $pending    = $self->pending_balance($pending, $i, 1);
        $posted     = $self->posted_balance($posted, $i, 1);
        $worst_case = $self->worst_case_balance($worst_case, $i, 1);
        $future     = $self->future_balance($future, $i, 1);
        $t->addRow($i,
                   $self->entries->[$i]->date_fmt,
                   sprintf("%.2f", $self->entries->[$i]->amount),
                   (map { sprintf("%.2f", $_) }
                      ($running, $pending, $posted, $worst_case, $future)));
    }

    $t->addRowLine();
    $t->addRow(@cols);

    print($t);
}

sub output_summary {
    my ($self) = @_;
    printf("    Ledger balance: \$%9.2f  (includes posted transactions)\n",
           $self->posted_balance());
    print( "                                CONFIRM: LEDGER BALANCE\n");
    printf("   Pending balance: \$%9.2f  (includes pending transactions)\n",
           $self->pending_balance());
    print( "                                CONFIRM: AVAILABLE BALANCE\n");
    printf("   Running balance: \$%9.2f  (includes all listed transactions)\n",
           $self->running_balance());
    printf("Worst-case balance: \$%9.2f  (excludes deposits not posted)\n",
           $self->worst_case_balance());
    printf("    Future balance: \$%9.2f  (running balance then future transactions)\n",
           $self->future_balance());
}

sub output_checkpoints {
    my ($self) = @_;
    if (scalar(@{$self->checkpoints})) {
        print("Checkpoints:\n");
        foreach my $checkpoint (@{$self->checkpoints}) {
            printf("  \$%9.2f  %s  %s\n",
                   $checkpoint->running_balance,
                   $checkpoint->date_fmt,
                   $checkpoint->note);
        }
    }
}

use Time::ParseDate qw();

sub parse_date {
    my ($self, $date) = @_;
    return Time::ParseDate::parsedate($date, NOW => $self->_last_date);
}

package My::Transaction::Register::Entry;
use warnings;
use strict;

use Moose;
has 'is_future'      => (is => 'rw', isa => 'Bool', default => 0);
has 'is_pending'     => (is => 'rw', isa => 'Bool', default => 0);
has 'is_posted'      => (is => 'rw', isa => 'Bool', default => 0);
has 'pending_amount' => (is => 'rw', isa => 'Num',  required => 0);
has 'amount'         => (is => 'rw', isa => 'Num',  default => 0);
has 'date'           => (is => 'rw', isa => 'Str');
has 'date_fmt'       => (is => 'rw', isa => 'Str');
has 'merchant'       => (is => 'rw', isa => 'Str');

package My::Transaction::Register::Line;
use warnings;
use strict;

use Moose;
has 'line_number' => (is => 'rw', isa => 'Int');
has 'text'        => (is => 'rw', isa => 'Str');

package My::Transaction::Register::Checkpoint;
use warnings;
use strict;

use Moose;
has 'date'            => (is => 'rw', isa => 'Str');
has 'date_fmt'        => (is => 'rw', isa => 'Str');
has 'running_balance' => (is => 'rw', isa => 'Num');
has 'note'            => (is => 'rw', isa => 'Str');

1;
