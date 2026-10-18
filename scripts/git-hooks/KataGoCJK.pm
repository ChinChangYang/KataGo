# Managed by scripts/git-hooks/install.sh
# Shared by this repo's English-only hooks: what counts as CJK, and how to find
# it in staged changes (pre-commit) and in recorded commits (pre-push).
package KataGoCJK;
use strict;
use warnings;
use Encode ();
use IO::Handle ();
use IPC::Open2 ();

# Pathspec magic must mean what the hooks say, whatever the caller exported.
delete @ENV{qw(GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS)};

# Han, kana, Hangul, Bopomofo, radicals and strokes, CJK punctuation, enclosed
# and compatibility forms, vertical and small forms, fullwidth and halfwidth
# forms, and the supplementary ideograph planes. Explicit ranges cover blocks
# newer than perl's own Unicode tables. Emoji, circled numbers (Go move
# diagrams use them) and squared Latin units are not language and pass.
our $RE = qr/(?![\x{3030}\x{303D}\x{3251}-\x{325F}\x{3297}\x{3299}\x{32B1}-\x{32BF}\x{3371}-\x{33DF}\x{1F201}\x{1F202}\x{1F21A}\x{1F22F}\x{1F232}-\x{1F23A}\x{1F250}\x{1F251}])[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Bopomofo}\x{2E80}-\x{303F}\x{3190}-\x{31FF}\x{3200}-\x{33FF}\x{9FFD}-\x{9FFF}\x{FE10}-\x{FE1F}\x{FE30}-\x{FE6F}\x{FF00}-\x{FFEF}\x{16FE0}-\x{16FFF}\x{1AFF0}-\x{1B16F}\x{1F200}-\x{1F2FF}\x{20000}-\x{3FFFF}]/;

# Vendored trees keep their upstream text.
our @PATHS = ('--', '.', ':(exclude)cpp/external', ':(exclude)ios/KataGo iOS/ThirdParty');
our @GIT = ('git', '-c', 'core.quotePath=false', '-c', 'log.showSignature=false');
our @DIFF_OPTS = ('--no-color', '--no-ext-diff', '--no-textconv',
                  '--src-prefix=a/', '--dst-prefix=b/', '-M', '-l5000');

# Bytes to (text, valid UTF-8?). Malformed bytes become U+FFFD instead of dying.
sub decode_line {
    my ($bytes) = @_;
    my $copy = $bytes;
    my $text = eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK) };
    return ($text, 1) if defined $text;
    return (Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT), 0);
}

# Bytes in a named encoding, falling back to UTF-8 for one perl lacks.
sub decode_as {
    my ($encoding, $bytes) = @_;
    return decode_line($bytes) if !$encoding || $encoding =~ /^utf-?8\z/i;
    my $codec = Encode::find_encoding($encoding) or return decode_line($bytes);
    return ($codec->decode($bytes, Encode::FB_DEFAULT), 1);
}

# Why a piece of text may not be committed, or undef. Text that is not UTF-8
# is refused too: it may be CJK in a legacy encoding (Big5, GBK, Shift_JIS).
sub problem {
    my ($text, $valid) = @_;
    return 'CJK' if $text =~ $RE;
    return 'not UTF-8' unless $valid;
    return undef;
}

# One readable line: control characters shown as '?', long lines clipped
# around the first match.
sub clip {
    my ($text) = @_;
    $text =~ s/[\x00-\x1F\x7F]/?/g;
    return $text if length($text) <= 120;
    my $at = $text =~ $RE ? $-[0] : 0;
    my $start = $at > 40 ? $at - 40 : 0;
    return ($start ? '...' : '') . substr($text, $start, 120) . '...';
}

# Undoes git's C-style quoting of a path ("a\"b", "caf\303\251").
sub unquote_path {
    my ($quoted) = @_;
    return $quoted unless $quoted =~ /^"(.*)"\z/s;
    my $s = $1;
    my %esc = (a => "\a", b => "\b", t => "\t", n => "\n", v => "\x0B", f => "\f", r => "\r");
    $s =~ s{\\([0-7]{3}|.)}{length($1) == 3 ? chr(oct($1)) : (exists $esc{$1} ? $esc{$1} : $1)}ge;
    return $s;
}

# Output lines of a command, as bytes; dies if it fails, so a hook never
# passes because git could not answer.
sub command_lines {
    my @cmd = @_;
    open(my $fh, '-|', @cmd) or die "cannot run @cmd: $!\n";
    binmode $fh;
    my @lines = <$fh>;
    close $fh or die "'@cmd' failed (exit " . ($? >> 8) . ")\n";
    return @lines;
}

sub command_output {
    return join '', command_lines(@_);
}

# Whether a command succeeds, with its output discarded.
sub quiet_ok {
    my @cmd = @_;
    open(my $out, '>&', \*STDOUT) or die "cannot dup stdout: $!\n";
    open(my $err, '>&', \*STDERR) or die "cannot dup stderr: $!\n";
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');
    my $ok = system(@cmd) == 0;
    open(STDOUT, '>&', $out);
    open(STDERR, '>&', $err);
    return $ok;
}

sub null_tree {
    my $tree = command_output('git', 'hash-object', '-t', 'tree', '/dev/null');
    chomp $tree;
    return $tree;
}

# Every path in a commit's tree, looked up once per commit.
my %paths_of;
sub exists_in {
    my ($rev, $path) = @_;
    $paths_of{$rev} //= { map { $_ => 1 } split /\0/, command_output('git', 'ls-tree', '-r', '-z', '--full-tree', '--name-only', $rev) };
    return $paths_of{$rev}{$path};
}

# Lines a unified or combined diff adds, as [path, text, valid, bytes, removed],
# where removed is the text the same file loses in that diff. In a combined
# diff a line counts only when it is new against every parent, that is, when
# all of its prefix columns are '+'.
sub added_lines {
    my @cmd = @_;
    my (@out, %removed);
    my ($file, $in_header, $width) = ('', 0, 1);
    for my $raw (command_lines(@cmd)) {
        $raw =~ s/\r?\n\z//;
        if ($raw =~ /^diff --(?:git|cc|combined) /) { $in_header = 1; next }
        if ($raw =~ /^(\@{2,}) /) { $width = length($1) - 1; $in_header = 0; next }
        if ($in_header) {
            if ($raw =~ /^\+\+\+ (.*?)\t?\z/) {
                ($file = unquote_path($1)) =~ s{^b/}{};
            }
            next;
        }
        next unless length($raw) >= $width;
        my $prefix = substr($raw, 0, $width);
        if ($width == 1 && $prefix eq '-') {
            $removed{$file} .= (decode_line(substr($raw, 1)))[0] . "\n";
            next;
        }
        next unless $prefix eq ('+' x $width);
        my $bytes = substr($raw, $width);
        my ($text, $valid) = decode_line($bytes);
        push @out, [$file, $text, $valid, $bytes];
    }
    push @$_, \$removed{$_->[0]} for @out;
    return @out;
}

# Whether every CJK run in an added line is text the same file loses in that
# diff: an English edit of a line that already held upstream CJK.
sub pre_existing {
    my ($text, $removed) = @_;
    return 0 unless $removed && defined $$removed;
    my @runs = $text =~ /((?:$RE)+)/g;
    return @runs && !grep { index($$removed, $_) < 0 } @runs;
}

# Problems among added lines, as [where, text, why]. A file whose added bytes
# are more than 1% control characters is binary that git took for text (raw
# image fixtures, say) and is skipped rather than reported line by line.
sub line_problems {
    my @lines = @_;
    my (%total, %control);
    for my $line (@lines) {
        my ($file, undef, undef, $bytes) = @$line;
        $total{$file} += length($bytes) + 1;
        $control{$file} += () = $bytes =~ /[\x00-\x08\x0B\x0E-\x1A\x1C-\x1F\x7F]/g;
    }
    my @hits;
    for my $line (@lines) {
        my ($file, $text, $valid, undef, $removed) = @$line;
        next if $control{$file} * 100 > $total{$file};
        my $why = problem($text, $valid) or next;
        next if $why eq 'CJK' && pre_existing($text, $removed);
        push @hits, [$file, $text, $why];
    }
    return @hits;
}

# UTF-16 text (Xcode's classic .strings encoding) is binary to git, so its
# lines never reach a diff. One cat-file process serves every blob; blobs
# without a byte-order mark are streamed past, never held in memory.
my ($batch_pid, $batch_in, $batch_out);
sub utf16_lines {
    my ($name) = @_;
    return () if $name =~ /\n/;
    unless ($batch_pid) {
        $batch_pid = IPC::Open2::open2($batch_out, $batch_in, 'git', 'cat-file', '--batch');
        binmode $batch_out;
        binmode $batch_in;
        $batch_in->autoflush(1);
    }
    print {$batch_in} "$name\n";
    my $header = <$batch_out>;
    die "cat-file --batch gave no answer for $name\n" unless defined $header;
    return () unless $header =~ /^\S+ (\S+) (\d+)\n\z/;
    my ($type, $size) = ($1, $2);
    my $head = '';
    read($batch_out, $head, $size < 2 ? $size : 2) if $size;
    my $bom = $type eq 'blob' && ($head eq "\xFF\xFE" || $head eq "\xFE\xFF");
    my ($rest, $left) = ('', $size - length($head));
    if ($bom) {
        read($batch_out, $rest, $left) == $left or die "short read of $name\n";
    } else {
        while ($left > 0) {
            my $got = read($batch_out, my $chunk, $left > 65536 ? 65536 : $left);
            die "short read of $name\n" unless $got;
            $left -= $got;
        }
    }
    read($batch_out, my $lf, 1);
    return () unless $bom;
    my $text = Encode::decode('UTF-16', $head . $rest, Encode::FB_DEFAULT);
    # A binary that merely starts with FF FE (an overexposed raw image, say)
    # decodes to noise: control characters and replacement characters.
    my $noise = () = $text =~ /[\x00-\x08\x0B\x0E-\x1F\x7F\x{FFFD}]/g;
    return () if $noise * 100 > length($text) || ($text !~ /\n/ && length($text) > 400);
    return split /\r?\n/, $text;
}

# Problems in UTF-16 blobs: lines none of the old versions has. Each change is
# [new object name, old object names...], so a rename compares with its source.
sub utf16_problems {
    my @hits;
    for my $change (@_) {
        my ($new, $where, @old) = @$change;
        my @lines = utf16_lines($new) or next;
        my %seen;
        for my $name (@old) { $seen{$_} = 1 for utf16_lines($name) }
        push @hits, map { ["$where (UTF-16)", $_, 'CJK'] } grep { !$seen{$_} && $_ =~ $RE } @lines;
    }
    return @hits;
}

# Changed blobs from a --raw -z listing, as [status, new oid, source, path].
sub raw_changes {
    my @fields = split /\0/, command_output(@_);
    my @out;
    while (@fields) {
        my $meta = shift @fields;
        my ($oid, $status) = (split / /, $meta)[3, 4];
        my $path = shift @fields;
        my $src = $path;
        $path = shift @fields if $status =~ /^[RC]/;
        push @out, [$status, $oid, $src, $path];
    }
    return @out;
}

# Text that is not the author's own in a merge: what each merged head has that
# the first parent lacks.
sub upstream_text {
    my ($first, @heads) = @_;
    my %upstream;
    for my $head (@heads) {
        for my $line (added_lines(@GIT, 'diff', @DIFF_OPTS, '-U0', $first, $head, @PATHS)) {
            $upstream{$line->[1]} = 1 if problem($line->[1], $line->[2]);
        }
    }
    return \%upstream;
}

# Problems in the staged changes, as [where, text, why]. In a merge, text that
# a merged head brings in passes.
sub staged_problems {
    my @heads = @_;
    my $has_head = quiet_ok('git', 'rev-parse', '-q', '--verify', 'HEAD^{commit}');
    my @hits = line_problems(added_lines(@GIT, 'diff', '--cached', @DIFF_OPTS, '-U0', '--diff-filter=ACMRT', @PATHS));
    for my $path (split /\0/, command_output(@GIT, 'diff', '--cached', @DIFF_OPTS, '--name-only', '-z', '--diff-filter=ACR', @PATHS)) {
        my ($text, $valid) = decode_line($path);
        my $why = problem($text, $valid) or next;
        next if grep { exists_in($_, $path) } @heads;
        push @hits, ['(path)', $text, $why];
    }
    my @olds = (($has_head ? ('HEAD') : ()), @heads);
    push @hits, utf16_problems(map {
        my ($status, $oid, $src, $path) = @$_;
        [$oid, $path, map { ("$_:$path", ($src ne $path ? "$_:$src" : ())) } @olds]
    } raw_changes(@GIT, 'diff', '--cached', '--raw', '-z', '-M', '-l5000', '--diff-filter=ACMRT', @PATHS));
    if (@heads) {
        my $upstream = upstream_text($has_head ? 'HEAD' : null_tree(), @heads);
        @hits = grep { $_->[0] eq '(path)' || !$upstream->{$_->[1]} } @hits;
    }
    return @hits;
}

# Problems in one recorded commit, as [where, text, why]: its message as git
# stores it, the lines it adds against every parent, and the paths it adds.
sub commit_problems {
    my ($sha) = @_;
    my @hits;
    my (undef, @parents) = split ' ', command_output('git', 'rev-list', '--parents', '-n', '1', $sha);
    my $message = command_output(@GIT, '-c', 'i18n.logOutputEncoding=UTF-8', 'log', '-1', '--format=%B', $sha);
    for my $line (split /\n/, $message) {
        my ($text, $valid) = decode_line($line);
        my $why = problem($text, $valid) or next;
        push @hits, ['(message)', $text, $why];
    }
    my @content = line_problems(added_lines(@GIT, 'show', '--format=', @DIFF_OPTS, '-U0', '--diff-merges=dense-combined', $sha, @PATHS));
    my @changed = split /\0/, command_output(@GIT, 'diff-tree', '-r', '-z', '--root', '--no-commit-id', '--name-only', '--no-renames', (@parents > 1 ? ('-c') : ()), $sha, @PATHS);
    for my $path (@changed) {
        my ($text, $valid) = decode_line($path);
        my $why = problem($text, $valid) or next;
        push @hits, ['(path)', $text, $why] unless grep { exists_in($_, $path) } @parents;
    }
    if (@parents > 1) {
        push @content, utf16_problems(map { my $path = $_; ["$sha:$path", $path, map { "$_:$path" } @parents] } @changed);
        if (@content) {
            my $upstream = upstream_text(@parents);
            @content = grep { !$upstream->{$_->[1]} } @content;
        }
    } else {
        push @content, utf16_problems(map {
            my ($status, $oid, $src, $path) = @$_;
            [$oid, $path, (@parents ? ("$parents[0]:$path", ($src ne $path ? "$parents[0]:$src" : ())) : ())]
        } raw_changes('git', 'diff-tree', '-r', '-z', '--root', '--no-commit-id', '--raw', '-M', '-l5000', '--diff-filter=ACMRT', $sha, @PATHS));
    }
    return (@hits, @content);
}

# Prints up to 20 hits under a heading and returns how many there were.
sub report {
    my ($heading, @hits) = @_;
    return 0 unless @hits;
    binmode STDERR, ':encoding(UTF-8)';
    print STDERR "$heading\n";
    my $shown = @hits < 20 ? @hits : 20;
    for my $hit (@hits[0 .. $shown - 1]) {
        my ($where, $text, $why) = @$hit;
        my ($name) = decode_line($where);
        print STDERR '  ' . clip($name) . ': ' . clip($text) . "  [$why]\n";
    }
    print STDERR "  ... and " . (@hits - $shown) . " more\n" if @hits > $shown;
    return scalar @hits;
}

1;
