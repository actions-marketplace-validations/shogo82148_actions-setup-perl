package Actions::Core;

use 5.006_001;
use utf8;
use warnings;
use strict;

use Exporter 'import';
our @EXPORT = qw(
    export_variable
    add_secret
    add_path
    get_input
    get_boolean_input
    set_output
    set_command_echo
    set_failed
    is_debug
    debug
    error
    warning
    notice
    info
    start_group
    end_group
    group
    save_state
    get_state
    perl_versions
);

use IO::Handle;
use Encode qw(decode_utf8 encode_utf8);
use JSON::PP qw(decode_json);
use File::Basename qw(dirname);
use File::Spec;
use Carp qw(croak carp);
use Actions::Core::Utils qw(to_command_value prepare_key_value_message);
use Actions::Core::Command qw(issue_command issue);
use Actions::Core::FileCommand qw();

sub export_variable {
    my ($name, $val) = @_;

    my $coverted_val = to_command_value($val);
    $ENV{$name} = $coverted_val;

    if ($ENV{GITHUB_ENV}) {
        my $value = prepare_key_value_message($name, $val);
        Actions::Core::FileCommand::issue_command("ENV", $value);
    } else {
        issue_command('set-env', {name => $name}, $coverted_val);
    }
}

sub add_secret {
    my ($secret) = @_;
    issue_command('add-mask', {}, $secret);
}

sub add_path {
    my ($path) = @_;
    my $del = ":";
    if ($^O eq "MSWin32") {
        $del = ";";
    }
    if ($ENV{GITHUB_PATH}) {
        Actions::Core::FileCommand::issue_command("PATH", $path);
    } else {
        issue_command('add-path', {}, $path);
    }
    $ENV{PATH} = $path . $del . $ENV{PATH};
}

sub get_input {
    my ($name, $options) = @_;
    $name =~ s/ /_/g;
    $name = uc $name;
    my $val = $ENV{"INPUT_$name"} || "";
    if ($options && $options->{required} && !$val) {
        croak "Input required and not supplied: ${name}";
    }
    $val =~ s/\A\s*(.*?)\s*\z/$1/;
    return $val;
}

sub get_boolean_input {
    my ($name, $options) = @_;

    my $val = get_input($name, $options);
    return !!1 if grep { $val eq $_ } qw/true True TRUE/;
    return !!0 if grep { $val eq $_ } qw/false False FALSE/;

    croak "Input does not meet YAML 1.2 \"Core Schema\" specification: $name\n" .
        "Support boolean input list: `true | True | TRUE | false | False | FALSE`";
}

sub set_output {
    my ($name, $value) = @_;
    if ($ENV{GITHUB_OUTPUT}) {
        my $msg = prepare_key_value_message($name, $value);
        Actions::Core::FileCommand::issue_command("OUTPUT", $msg);
    } else {
        print STDOUT "\n";
        STDOUT->flush();
        issue_command('set-output', { name => $name }, $value);
    }
}

sub set_command_echo {
    my ($enabled) = @_;
    issue('echo', $enabled ? 'on' : 'off');
}

my $exit_code = 0;

END {
    # override the exit code
    $? = 1 if $? == 0 && $exit_code != 0;
}

sub set_failed {
    my ($message) = @_;
    $exit_code = 1;
    issue('error', $message);
}

sub is_debug {
    return ($ENV{RUNNER_DEBUG} || '') eq '1';
}

sub debug {
    my ($message) = @_;
    issue('debug', $message);
}

# See IssueCommandProperties: https://github.com/actions/runner/blob/main/src/Runner.Worker/ActionCommandManager.cs#L646
sub _to_command_properties {
    my ($properties) = @_;
    return {} unless $properties;
    return {
        title     => $properties->{title},
        file      => $properties->{file},
        line      => $properties->{start_line},
        endLine   => $properties->{end_line},
        col       => $properties->{start_column},
        endColumn => $properties->{end_column},
    };
}

sub error {
    my ($message, $properties) = @_;
    issue_command('error', _to_command_properties($properties), $message);
}

sub warning {
    my ($message, $properties) = @_;
    issue_command('warning', _to_command_properties($properties), $message);
}

sub notice {
    my ($message, $properties) = @_;
    issue_command('notice', _to_command_properties($properties), $message);
}

sub info {
    my ($message) = @_;
    print STDOUT decode_utf8("$message\n");
    STDOUT->flush();
}

sub start_group {
    my ($name) = @_;
    issue('group', $name);
}

sub end_group {
    issue('endgroup');
}

sub group {
    my ($name, $sub) = @_;
    my $wantarray = wantarray;
    my @ret;
    my $failed = not eval {
        start_group($name);
        if ($wantarray) {
            @ret = $sub->();
        } elsif (defined $wantarray) {
            $ret[0] = $sub->();
        } else {
            $sub->();
        }
        return 1;
    };
    my $err = $@;
    end_group();
    die $err if $failed;
    return $wantarray ? @ret : $ret[0];
}

sub save_state {
    my ($name, $value) = @_;
    if ($ENV{GITHUB_STATE}) {
        my $msg = prepare_key_value_message($name, $value);
        Actions::Core::FileCommand::issue_command("STATE", $msg);
    } else {
        print STDOUT "\n";
        STDOUT->flush();
        issue_command('set-state', { name => $name }, $value);
    }
}

sub get_state {
    my $name = shift;
    return ${"STATE_$name"} || "";
}

sub _perl_versions_default {
    my ($platform, $patch) = @_;
    my $path = File::Spec->catfile(dirname(__FILE__), ("..") x 3, 'versions', "$platform.json");
    open my $fh, '<', $path or die "failed to open $path: $!";
    my $contents = decode_utf8(scalar do { local $/; <$fh> });
    close($fh);

    my $ret = decode_json($contents);
    if (!$patch) {
        # get latest versions for each minor versions
        my %seen;
        my @latest;
        for my $v (@$ret) {
            my ($major, $minor) = split /\./, $v;
            if (!$seen{"$major.$minor"}) {
                push @latest, $v;
            }
            $seen{"$major.$minor"} = 1;
        }
        $ret = \@latest;
    }
    return wantarray ? @$ret : $ret;
}

sub _perl_versions_strawberry {
    my ($platform, $patch) = @_;
    my $path = File::Spec->catfile(dirname(__FILE__), ("..") x 3, 'versions', 'strawberry.json');
    open my $fh, '<', $path or die "failed to open $path: $!";
    my $contents = decode_utf8(scalar do { local $/; <$fh> });
    close($fh);

    my $ret = [map { $_->{version} } @{decode_json($contents)}];
    if (!$patch) {
        # get latest versions for each minor versions
        my %seen;
        my @latest;
        for my $v (@$ret) {
            my ($major, $minor) = split /\./, $v;
            if (!$seen{"$major.$minor"}) {
                push @latest, $v;
            }
            $seen{"$major.$minor"} = 1;
        }
        $ret = \@latest;
    }
    return wantarray ? @$ret : $ret;
}

sub perl_versions {
    my $args = ref $_[0] ? $_[0] : +{@_};
    my $platform = $args->{platform} || $^O;
    $platform = 'win32' if $platform eq 'MSWin32';
    my $distribution = $args->{distribution} || 'default';
    my $patch = $args->{patch} || 0;

    if ($distribution eq 'default') {
        return _perl_versions_default($platform, $patch);
    } elsif ($distribution eq 'strawberry') {
        if ($platform ne 'win32') {
            carp "distribution '$distribution' is not available on $platform, fallback to the default distribution";
            return _perl_versions_default($platform, $patch);
        }
        return _perl_versions_strawberry($platform, $patch);
    } else {
        croak "unknown distribution: '$distribution'";
    }
}

1;
