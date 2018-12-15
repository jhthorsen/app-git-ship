package App::git::ship;
use Mojo::Base -base;

use Carp;
use Data::Dumper ();
use IPC::Run3    ();
use Mojo::File 'path';
use Mojo::Loader;
use Mojo::Template;

use constant DEBUG  => $ENV{GIT_SHIP_DEBUG}  || 0;
use constant SILENT => $ENV{GIT_SHIP_SILENT} || 0;

our $VERSION = '0.28';

# Need to be overridden in subclass
sub build              { $_[0]->abort('build() is not available for %s',              ref $_[0]) }
sub can_handle_project { $_[0]->abort('can_handle_project() is not available for %s', ref $_[0]) }
sub test_coverage      { $_[0]->abort('test_coverage() is not available for %s',      ref $_[0]) }

sub abort {
  my ($self, $format, @args) = @_;
  my $message = @args ? sprintf $format, @args : $format;

  Carp::confess("!! $message") if DEBUG;
  die "!! $message\n";
}

sub config {
  my ($self, $key, $value) = @_;
  my $config = $self->{config} ||= $self->_build_config;

  # Get all
  return $config if @_ == 1;

  # Get single key
  if (@_ == 2) {
    return $config->{$key} if exists $config->{$key};

    my $param_method = "_build_config_param_$key";
    return $self->$param_method if $self->can($param_method);

    my $env_key = uc "GIT_SHIP_$key";
    return $ENV{$env_key} // '';
  }

  # Set single key
  $config->{$key} = $value;
  return $self;
}

sub detect {
  my ($self, $file) = (@_, '');

  if (!$file and $self->config('class')) {
    my $class = $self->config('class');
    eval "require $class;1" or $self->abort("Could not load $class: $@");
    return $class;
  }

  require Module::Find;
  for my $class (sort { length $b <=> length $a } Module::Find::findallmod(__PACKAGE__)) {
    eval "require $class;1" or next;
    next unless $class->can('can_handle_project');
    warn "[ship::detect] $class->can_handle_project($file)\n" if DEBUG;
    return $class if $class->can_handle_project($file);
  }

  $self->abort("Could not figure out what kind of project this is from '$file'");
}

sub dump {
  return Data::Dumper->new([$_[1]])->Indent(1)->Terse(1)->Sortkeys(1)->Dump;
}

sub new {
  my $self = shift->SUPER::new(@_);
  open $self->{STDOUT}, '>&STDOUT';
  open $self->{STDERR}, '>&STDERR';
  return $self;
}

sub render_template {
  my ($self, $name, $args) = @_;
  my $template = $self->_get_template($name) or $self->abort("Could not find template for $name");

  # Render to string
  return $template->process({%$args, ship => $self}) if $args->{to_string};

  # Render to file
  my $file = path split '/', $name;
  if (-e $file and !$args->{force}) {
    say "# $file exists" unless SILENT;
    return $self;
  }

  $file->dirname->make_path unless -d $file->dirname;
  $file->spurt($template->process({%$args, ship => $self}));
  say "# Generated $file" unless SILENT;
  return $self;
}

sub run_hook {
  my ($self, $name) = @_;
  my $cmd = $self->config($name) or return;
  $self->system($cmd);
}

sub ship {
  my $self     = shift;
  my ($branch) = qx(git branch) =~ /\* (.+)$/m;
  my ($remote) = qx(git remote -v) =~ /^origin\s+(.+)\s+\(push\)$/m;

  $self->abort("Cannot ship without a current branch") unless $branch;
  $self->abort("Cannot ship without a version number") unless $self->config('next_version');
  $self->system(qw(git push origin), $branch) if $remote;
  $self->system(qw(git tag) => $self->config('next_version'));
  $self->system(qw(git push --tags origin)) if $remote;
}

sub start {
  my $self = shift;

  if (@_ and ref($self) eq __PACKAGE__) {
    return $self->detect($_[0])->new($self)->start(@_);
  }

  $self->system(qw(git init-db)) unless -d '.git' and @_;
  $self->render_template('.gitignore');
  $self->system(qw(git add .));
  $self->system(qw(git commit -a -m), "git ship start") if @_;
  $self;
}

sub system {
  my ($self, $program, @args) = @_;
  my @fh = (undef);
  my $exit_code;

  if (SILENT) {
    my $output = '';
    push @fh, (\$output, \$output);
  }
  else {
    my $log = "$program @args";
    $log =~ s!\n\r?!\\n!g;
    say "\$ $log";
  }

  warn "[ship]\$ $program @args\n" if DEBUG == 2;
  IPC::Run3::run3(@args ? [$program => @args] : $program, @fh);
  $exit_code = $? >> 8;
  return $self unless $exit_code;

  if (SILENT) {
    chomp $fh[1];
    $self->abort("'$program @args' failed: $exit_code (${$fh[1]})");
  }
  else {
    $self->abort("'$program @args' failed: $exit_code");
  }
}

sub _build_config {
  my $self = shift;

  my $file = $ENV{GIT_SHIP_CONFIG} || '.ship.conf';
  my $config = {};
  return $config unless open my $CFG, '<', $file;

  while (<$CFG>) {
    chomp;
    warn "[ship::config] $_\n" if DEBUG == 2;
    m/\A\s*(?:\#|$)/ and next;    # comments
    s/\s+(?<!\\)\#\s.*$//;        # remove inline comments
    m/^\s*([^\=\s][^\=]*?)\s*=\s*(.*)$/ or next;
    my ($k, $v) = ($1, $2);
    $v =~ s!\s+$!!g;
    next unless length $v;
    $config->{$k} = $v;
    $config->{$k} =~ s!\\\#!#!g;
    warn "[ship::config] $1 = $2\n" if DEBUG;
  }

  return $config;
}

sub _build_config_param_author {
  my $self = shift;
  my $format = shift || '%an <%ae>';

  open my $GIT, '-|', qw(git log), "--format=$format"
    or $self->abort("git log --format=$format: $!");
  my $author = readline $GIT;
  $self->abort("Could not find any author in git log") unless $author;
  chomp $author;
  warn "[ship::author] $format = $author\n" if DEBUG;
  return $author;
}

sub _build_config_param_bugtracker {
  return $ENV{GIT_SHIP_BUGTRACKER}
    || join('/', shift->config('homepage'), 'issues') =~ s!(\w)//!$1/!r;
}

sub _build_config_param_homepage {
  return $ENV{GIT_SHIP_HOMEPAGE} || shift->config('repository') =~ s!\.git$!!r;
}

sub _build_config_param_license      { $ENV{GIT_SHIP_LICENSE}      || 'artistic_2' }
sub _build_config_param_project_name { $ENV{GIT_SHIP_PROJECT_NAME} || 'unknown' }

sub _build_config_param_repository {
  my $self = shift;
  my $repository;

  open my $REPOSITORIES, '-|', qw(git remote -v) or $self->abort("git remote -v: $!");
  while (<$REPOSITORIES>) {
    next unless /^origin\s+(\S+).*push/;
    $repository = $1;
    last;
  }

  $repository ||= lc sprintf 'https://github.com/%s/%s',
    $self->config('username') || $ENV{GITHUB_USERNAME} || scalar(getpwuid $<),
    $self->config('project_name') =~ s!::!-!gr;
  $repository =~ s!^[^:]+:!https://github.com/! unless $repository =~ /^http/;
  warn "[ship::repository] $repository\n" if DEBUG;

  return $repository;
}

sub _get_template {
  my ($self, $name) = @_;

  my $class = ref $self;
  my $str;
  no strict 'refs';
  for my $package ($class, @{"$class\::ISA"}) {
    $str = Mojo::Loader::data_section($package, $name) or next;
    $name = "$package/$name";
    last;
  }

  return $str ? Mojo::Template->new->name($name)->vars(1)->parse($str) : undef;
}

1;

=encoding utf8

=head1 NAME

App::git::ship - Git command for shipping your project

=head1 VERSION

0.28

=head1 DESCRIPTION

L<App::git::ship> is a L<git|http://git-scm.com/> command for building and
shipping your project.

The main focus is to automate away the boring steps, but at the same time not
get in your (or any random contributor's) way. Problems should be solved with
sane defaults according to standard rules instead of enforcing more rules.

L<App::git::ship> differs from other tools like L<dzil|Dist::Zilla> by not
requiring any configuration except for a file containing the credentials for
uploading to CPAN.

Example structure and how L<App::git::ship> works on your files:

=over 4

=item * my-app/cpanfile and my-app/Makefile.PL

The C<cpanfile> is used to build the "PREREQ_PM" and "BUILD_REQUIRES"
structures in the L<ExtUtils::MakeMaker> based C<Makefile.PL> build file.
The reason for this is that C<cpanfile> is a more powerful format that can
be used by L<Carton> and other tools, so generating C<cpanfile> from
Makefile.PL would simply not be possible. Other data used to generate
Makefile.PL are:

"NAME" and "LICENSE" will have values from L</GIT_SHIP_PROJECT_NAME> and
L</GIT_SHIP_LICENSE>.  "AUTHOR" will have the name and email from
L</GIT_SHIP_AUTHOR> or the last git committer.  "ABSTRACT_FROM" and
"VERSION_FROM" are fetched from the L<App::git::ship::perl/main_module_path>.
"EXE_FILES" will be the files in C<bin/> and C<script/> which are executable.
"META_MERGE" will use data from L</GIT_SHIP_BUGTRACKER>, L</GIT_SHIP_HOMEPAGE>,
and L</repository>.

=item * my-app/Changes or my-app/CHANGELOG.md

The Changes file will be updated with the correct
L<GIT_SHIP_NEW_VERSION_FORMAT>, from when you ran the L</build> action. The
Changes file will also be the source for L</GIT_SHIP_NEXT_VERSION>. Both
C<CHANGELOG.md> and C<Changes> are valid sources.  L<App::git::ship> looks for
a version-timestamp line with the case-sensitive text "Not Released" as the the
timestamp.

=item * my-app/lib/My/App.pm

This L<file|App::git::ship::perl/main_module_path> will be updated with the
version number from the Changes file.

=item * .gitignore and MANIFEST.SKIP

Unless these files exist, they will be generated from a template which skips
the most common files. The default content of these two files might change over
time if new temp files are created by new editors or some other formats come
along.

=item * t/00-basic.t

Unless this file exists, it will be created with a test for checking
that your modules can compile and that the POD is correct. The file can be
customized afterwards and will not be overwritten.

=item * .git

It is important to commit any uncommitted code to your git repository beforing
building and that you have a remote setup in your git repository before
shipping.

=item * .pause

You have to have a C<$HOME/.pause> file before shipping. It should look like this:

  user yourcpanusername
  password somethingsupersecret

=back

=head1 SYNOPSIS

=head2 git ship

  # Set up basic files for a Perl repo
  # (Not needed if you already have an existing repo)
  $ git ship start lib/My/Project.pm
  $ git ship start

  # Make changes
  $ $EDITOR lib/My/Project.pm

  # Build first if you want to investigate the changes
  $ git ship build

  # Ship the project to git (and CPAN)
  $ git ship ship

=head2 Git aliases

  # git build
  $ git config --global alias.build = ship build

  # git cl
  $ git config --global alias.cl = ship clean

  # git start
  # git start My/Project.pm
  $ git config --global alias.start = ship start

=head1 ENVIRONMENT VARIABLES

Environment variables can also be set in a config file named C<.ship.conf>, in
the root of the project directory. The format is:

  # some comment
  bugtracker = whatever
  new_version_format = %v %Y-%m-%dT%H:%M:%S%z

Any of the keys are the same as all the L</ENVIRONMENT VARIABLES>, but without
"GIT_SHIP_".

=head2 GIT_SHIP_AFTER_SHIP

It is possible to add hooks. These hooks are
programs that runs in your shell. Example hooks:

  GIT_SHIP_AFTER_SHIP="bash script/new-release.sh"
  GIT_SHIP_AFTER_BUILD="rm -r lib/My/App/templates lib/My/App/public"
  GIT_SHIP_AFTER_SHIP="cat Changes | mail -s "Changes for My::App" all@my-app.com"

=head2 GIT_SHIP_AFTER_BUILD

See L</GIT_SHIP_AFTER_SHIP>.

=head2 GIT_SHIP_AUTHOR

See L</author>.

=head2 GIT_SHIP_BEFORE_BUILD

See L</GIT_SHIP_AFTER_SHIP>.

=head2 GIT_SHIP_BEFORE_SHIP

See L</GIT_SHIP_AFTER_SHIP>.

=head2 GIT_SHIP_BUGTRACKER

URL to the bugtracker for this project.

=head2 GIT_SHIP_BUILD_TEST_OPTIONS

This holds the arguments for the test program to use when building the
project. The default is to not automatically run the tests. Example value:

  build_test_options = -l -j4

=head2 GIT_SHIP_CHANGELOG_FILENAME

Defaults to either "CHANGELOG.md" or "Changes".

=head2 GIT_SHIP_CLASS

This class is used to build the object that runs all the actions on your
project. This is autodetected by looking at the structure and files in
your project. For now this value can be L<App::git::ship> or
L<App::git::ship::perl>, but any customization is allowed.

=head2 GIT_SHIP_DEBUG

Setting this variable will make "git ship" output more information.

=head2 GIT_SHIP_HOMEPAGE

URL to the home page for this project.

=head2 GIT_SHIP_LICENSE

The name of the license to use. Defaults to "artistic_2".

=head2 GIT_SHIP_MAIN_MODULE_PATH

Path tot the main module in your project.

=head2 GIT_SHIP_NEW_VERSION_FORMAT

This is optional, but specifies the version format in your "Changes" file.
The example below will result in "## 0.42 (2014-01-28)".

  new_version_format = \#\# %v (%F)

"%v" will be replaced by the version, while the format arguments are passed
on to L<POSIX/strftime>.

The default is "%v %Y-%m-%dT%H:%M:%S%z".

=head2 GIT_SHIP_NEXT_VERSION

Defaults to the version number in L</GIT_SHIP_MAIN_MODULE_PATH> + "0.01".

=head2 GIT_SHIP_PROJECT_NAME

This name is extracted from either the L<App::git::ship::perl/main_module_path>
or defaults to "unknown" if no project name could be found. Example:

=head2 GIT_SHIP_SILENT

Setting this variable will make "git ship" output less information.

=head2 GIT_SHIP_USERNAME

=head1 METHODS

=head2 abort

  $ship->abort($str);
  $ship->abort($format, @args);

Will abort the application run with an error message.

=head2 build

This method builds the project. The default behavior is to L</abort>.
Needs to be overridden in the subclass.

=head2 can_handle_project

  $bool = $class->can_handle_project($file);

This method is called by L<App::git::ship/detect> and should return boolean
true if this module can handle the given git project.

This is a class method which gets a file as input to detect or have to
auto-detect from current working directory.

=head2 config

  $hash_ref = $ship->config;
  $str      = $ship->config($name);
  $self     = $ship->config($name => $value);

Holds the configuration from end user. The config is by default read from
C<.ship.conf> in the root of your project.

=head2 detect

  $class = $ship->detect;
  $class = $ship->detect($file);

Will detect the module which can be used to build the project. This
can be read from the "class" key in L</config> or will in worse
case default to L<App::git::ship>.

=head2 dump

  $str = $ship->dump($any);

Will serialize C<$any> into a perl data structure, using L<Data::Dumper>.

=head2 new

  $ship = App::git::ship->new(\%attributes);

Creates a new instance of C<$class>.

=head2 render_template

  $ship->render_template($file, \%args);

Used to render a template by the name C<$file> to a C<$file>. The template
needs to be defined in the C<DATA> section of the current class or one of
the super classes.

=head2 run_hook

  $ship->run_hook($name);

Used to run a hook before or after an event. The hook is a command which
needs to be defined in the config file. Example config line parameter:

  before_build = echo foo > bar.txt

=head2 ship

  $ git ship ship

This method ships the project to some online repository. The default behavior
is to make a new tag and push it to "origin". Push occurs only if origin is
defined in git.

=head2 start 

This method is called when initializing the project. The default behavior is
to populate L</config> with default data:

=over 4

=item * bugtracker

URL to the bug tracker. Will be the the L</repository> URL without ".git", but
with "/issues" at the end instead.

=item * homepage

URL to the project homepage. Will be the the L</repository> URL, without ".git".

=item * license

The name of the license. Defaults to L<artistic_2|http://www.opensource.org/licenses/artistic-license-2.0>.

See L<CPAN::Meta::Spec/license> for alternatives.

=back

=head2 system

  $ship->system($program, @args);

Same as perl's C<system()>, but provides error handling and logging.

=head2 test_coverage

This method checks test coverage for the project. The default behavior is to
L</abort>. Needs to be overridden in the subclass.

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

Copyright (C) 2014-2018, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

__DATA__
@@ .gitignore
~$
*.bak
*.old
*.swp
/local
@@ test
<%= $x %>: <%= $ship->config('repository') %> # test
