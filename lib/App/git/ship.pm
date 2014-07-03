package App::git::ship;

=head1 NAME

App::git::ship - Git command for shipping your project

=head1 VERSION

0.01

=head1 DESCRIPTION

L<App::git::ship> is a C<git> command for shipping your project to CPAN or
some other repository.

=head1 SYNOPSIS

=head2 For end user

  $ git ship -h

=head2 For developer

  package App::git::ship::some_language;
  use App::git::ship -base;

  # define attributes
  has some_attribute => sub {
    my $self = shift;
    return "default value";
  };

  # override the methods defined in App::git::ship
  sub build {
    my $self = shift;
  }

  1;

=cut

use feature ':5.10';
use strict;
use warnings;
use Carp;
use Data::Dumper ();
use File::Find ();
use File::Spec ();

use constant DEBUG => $ENV{GIT_SHIP_DEBUG} || 0;

our $VERSION = '0.01';

=head1 ATTRIBUTES

=head2 config

  $hash_ref = $self->config;

Holds the configuration from end user. The config is by default read from
C<.ship.conf> in the root of your project.

=head2 project_name

  $str = $self->project_name;

Holds the name of the current project. This attribute can be read from
L</config>.

=head2 repository

  $str = $self->repository;

Returns the URL to the first repository that point to L<github|http://github.com>.
This attribute can be read from L</config>.

=head2 silent

  $bool = $self->silent;
  $self = $self->silent($bool);

Set this to true if you want less logging. By default it silent is false.

=cut

__PACKAGE__->attr(config => sub {
  my $self = shift;
  my $file = $self->_config_file;
  my $config;

  open my $CFG, '<', $file or $self->abort("git-ship: Read $file: $!");

  while (<$CFG>) {
    chomp;
    warn "[ship::config] $_\n" if DEBUG;
    my ($k, $v) = /^\s*(\S+)\s*=\s*(\w.+)/ or next;
    $config->{$k} = $v;
    $config->{$k} =~ s!\s+\#.*!!;
  }

  return $config;
});

__PACKAGE__->attr(project_name => sub {
  my $self = shift;
  return $self->config->{project_name} if $self->config->{project_name};
  $self->abort('project_name is not defined in config file.');
});

__PACKAGE__->attr(repository => sub {
  my $self = shift;
  open my $GIT, '-|', 'git remote -v | grep github' or $self->abort("git remote -v: $!");
  my $repository = readline $GIT;
  $self->abort('Could not find any repository URL to GitHub.') unless $repository;
  $repository = sprintf 'https://github.com/%s', +(split /[:\s+]/, $repository)[2];
  warn "[ship::repository] $repository\n" if DEBUG;
  $repository;
});

__PACKAGE__->attr(silent => sub { $ENV{GIT_SHIP_SILENT} || 0 });

=head1 METHODS

=head2 abort

  $self->abort($str);
  $self->abort($format, @args);

Will abort the application run with an error message.

=cut

sub abort {
  my ($self, $format, @args) = @_;
  my $message = @args ? sprintf $format, @args : $format;

  Carp::confess("git-ship: $message") if DEBUG;
  die "git-ship: $message\n";
}

=head2 attr

  $class = $class->attr($name => sub { my $self = shift; return $default_value });

or ...

  use App::git::ship -base;
  has $name => sub { my $self = shift; return $default_value };

Used to create an attribute with a lazy builder.

=cut

sub attr {
  my ($self, $name, $default) = @_;
  my $class = ref $self || $self;
  my $code = "";

  $code .= "package $class; sub $name {";
  $code .= "return \$_[0]->{$name} if \@_ == 1 and exists \$_[0]->{$name};";
  $code .= "return \$_[0]->{$name} = \$_[0]->\$default if \@_ == 1;";
  $code .= "\$_[0]->{$name} = \$_[1] if \@_ == 2;";
  $code .= '$_[0];}';

  eval "$code;1" or die "$code: $@";

  return $self;
}

=head2 build

This method builds the project. The default behavior is to L</abort>.
Need to be overridden in the subclass.

=cut

sub build {
  $_[0]->abort('build() is not available for %s', ref $_[0]);
}

=head2 detect

  $class = $self->detect;

Will detect the module which can be used to build the project. This
can be read from the "class" key in L</config> or will in worse
case default to L<App::git::ship>.

=cut

sub detect {
  my ($self, $from_config) = @_;
  my $class = __PACKAGE__;

  if ($from_config // 1 and $self->config->{class}) {
    $class = $self->config->{class};
  }
  else {
    for my $m (qw( _detect_perl )) {
      my $c = $self->$m or next;
      $class = $c;
      last;
    }
  }

  eval "require $class; 1" or $self->abort("Could not load $class: $@");
  return $class;
}

=head2 init

This method is called when initializing the project. The default behavior is
to populate L</config> with default data:

=over 4

=item * bugtracker

URL to the bug tracker. Will be the the L</repository> URL without ".git", but
with "/issues" at the end instead.

=item * homepage

URL to the project homepage. Will be the the L</repository> URL, without ".git".

=item * license

The name of the license. Default to L<artistic_2|http://www.opensource.org/licenses/artistic-license-2.0>.

See L<CPAN::Meta::Spec/license> for alternatives.

=back

=cut

sub init {
  my $self = shift;
  my $class = ref $self eq __PACKAGE__ ? $self->detect(0) : ref $self;

  return $class->new($self)->init(@_) if $class ne ref $self;

  $self->_generate_config;
  $self->_generate_gitignore;
  $self;
}

=head2 new

  $self = $class->new(%attributes);

Creates a new instance of C<$class>.

=cut

sub new {
  my $class = shift;
  bless @_ ? @_ > 1 ? {@_} : {%{$_[0]}} : {}, ref $class || $class;
}

=head2 ship

This method ships the project to some online repository. The default behavior
is to make a new tag and push it to L</repository>.

=cut

sub ship {
  $_[0]->abort('TODO', ref $_[0]);
}

=head2 system

  $self->system($program, @args);

Same as perl's C<system()>, but provides error handling and logging.

=cut

sub system {
  my ($self, $program, @args) = @_;
  my $exit_code;

  local *STDOUT = *STDOUT;
  local *STDERR = *STDERR;
  open STDERR, '>', File::Spec->devnull if $self->silent;
  open STDOUT, '>', File::Spec->devnull if $self->silent;

  say "\$ $program @args\n" unless $self->silent;
  system $program => @args;
  $exit_code = $? >> 8;
  $self->abort("'$program @args' failed: $exit_code") if $exit_code;
  $self;
}

=head2 test

This method test the project. The default behavior is to L</abort>.
Need to be overridden in the subclass.

=cut

sub test {
  $_[0]->abort('test() is not available for %s', ref $_[0]);
}

=head2 import

  use App::git::ship;
  use App::git::ship -base;

Called when this class is used. It will automatically enable L<strict>,
L<warnings>, L<utf8> and Perl 5.10 features.

C<-base> will also make sure the calling class inherit from
L<App::git::ship> and gets the L<has|/attr> function.

=cut

sub import {
  my ($class, $arg) = @_;
  my $caller = caller;

  if ($arg and $arg eq '-base') {
    no strict 'refs';
    push @{"${caller}::ISA"}, __PACKAGE__;
    *{"${caller}::has"} = sub { attr($caller, @_) };
    *{"${caller}::DEBUG"} = \&DEBUG;
  }

  feature->import(':5.10');
  strict->import;
  warnings->import;
}

sub _config_file { $ENV{GIT_SHIP_CONFIG} || '.ship.conf'; }

sub _detect_perl {
  my $self = shift;
  my $class;

  File::Find::find(sub { $class = 'App::git::ship::perl' if /\.pm$/; }, 'lib');

  return $class;
}

sub _generate_config {
  my $self = shift;
  my $config_file = $self->_config_file;
  my $homepage = $self->repository;
  my $class = ref $self;
  my $config = '';

  return if -e $config_file;

  $homepage =~ s!\.git$!!;

  $config .= "# Generated by git-ship. See 'git-ship --man' for help or http://https://metacpan.org/pod/App::git::ship::Manual\n";
  $config .= "class = $class\n";
  $config .= "project_name = \n";
  $config .= "homepage = $homepage\n";
  $config .= "bugtracker = " . +(join '/', $homepage, 'issues') =~ s!(\w)//!$1/!r . "\n";
  $config .= "license = artistic_2\n";

  open my $CFG, '>', $config_file or $self->abort("git-ship: Read $config_file: $!");
  print $CFG $config;

  unless ($self->silent) {
    warn "git-ship: Created config file $config_file\n\n";
    say $config;
  }
}

sub _generate_gitignore {
  my $self = shift;

  return if -e '.gitignore';

  open my $GITIGNORE, '>', '.gitignore' or $self->abort("git-ship: Read .gitignore: $!");
  print $GITIGNORE <<'GITIGNORE';
GITIGNORE
}

=head1 SEE ALSO

=over

=item * L<Dist::Zilla>

This project can probably get you to the moon.

=item * L<Minilla>

This looks really nice for shipping your project. It has the same idea as
this distribution: Guess as much as possible.

=item * L<Shipit>

One magical tool for doing it all in one bang.

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
