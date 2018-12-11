package App::git::ship;
use Mojo::Base -base;

use Carp;
use Data::Dumper ();
use IPC::Run3    ();
use Mojo::File 'path';
use Mojo::Loader;
use Mojo::Template;

use constant DEBUG => $ENV{GIT_SHIP_DEBUG} || 0;

our $VERSION = '0.27';

has next_version => 0;
has project_name => sub { shift->config('project_name') || 'unknown' };

has repository => sub {
  my $self = shift;
  my $repository;

  open my $REPOSITORIES, '-|', qw(git remote -v) or $self->abort("git remote -v: $!");
  while (<$REPOSITORIES>) {
    next unless /^origin\s+(\S+).*push/;
    $repository = $1;
    last;
  }

  $repository ||= lc sprintf 'https://github.com/%s/%s',
    $ENV{GITHUB_USERNAME} || scalar(getpwuid $<), $self->project_name =~ s!::!-!gr;
  $repository =~ s!^[^:]+:!https://github.com/! unless $repository =~ /^http/;
  warn "[ship::repository] $repository\n" if DEBUG;
  $repository;
};

has silent => sub { $ENV{GIT_SHIP_SILENT} // 0 };

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
  my $self = shift;
  my $config = $self->{config} ||= $self->_build_config;

  return $config if @_ == 0;
  return $config->{$_[0]} // '' if @_ == 1;
  $config->{$_[0]} = $_[1] if @_ == 2;
  return $self;
}

sub detect {
  my $self = shift;
  my $file = 'auto-detect';

  if (!@_ and $self->config('class')) {
    my $class = $self->config('class');
    eval "require $class;1" or $self->abort("Could not load $class: $@");
    return $class;
  }
  else {
    $file = shift;
    require Module::Find;
    for my $class (sort { length $b <=> length $a } Module::Find::findallmod(__PACKAGE__)) {
      eval "require $class;1" or next;
      next unless $class->can('can_handle_project');
      warn "[ship::detect] $class->can_handle_project($file)\n" if DEBUG;
      return $class if $class->can_handle_project($file);
    }
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

sub render {
  my ($self, $name, $args) = @_;
  my $template = $self->_get_template($name) or $self->abort("Could not find template for $name");

  # Render to string
  return $template->process({%$args, ship => $self}) if $args->{to_string};

  # Render to file
  my $file = path split '/', $name;
  if (-e $file and !$args->{force}) {
    say "# $file exists" unless $self->silent;
    return $self;
  }

  $file->dirname->make_path unless -d $file->dirname;
  $file->spurt($template->process({%$args, ship => $self}));
  say "# Generated $file" unless $self->silent;
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
  $self->abort("Cannot ship without a version number") unless $self->next_version;
  $self->system(qw(git push origin), $branch) if $remote;
  $self->system(qw(git tag) => $self->next_version);
  $self->system(qw(git push --tags origin)) if $remote;
}

sub start {
  my $self = shift;

  if (@_ and ref($self) eq __PACKAGE__) {
    return $self->detect($_[0])->new($self)->start(@_);
  }

  $self->{config} = {};    # make sure repository() does not die
  $self->system(qw(git init-db)) unless -d '.git' and @_;
  $self->render('.ship.conf', {homepage => $self->repository =~ s!\.git$!!r});
  $self->render('.gitignore');
  $self->system(qw(git add .));
  $self->system(qw(git commit -a -m), "git ship start") if @_;
  delete $self->{config};    # regenerate config from .ship.conf
  $self;
}

sub system {
  my ($self, $program, @args) = @_;
  my @fh = (undef);
  my $exit_code;

  if ($self->silent) {
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

  if ($self->silent) {
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
  my $config;

  open my $CFG, '<', $file or $self->abort("Read $file: $!");

  while (<$CFG>) {
    chomp;
    warn "[ship::config] $_\n" if DEBUG == 2;
    m/\A\s*(?:\#|$)/ and next;    # comments
    s/\s+(?<!\\)\#\s.*$//;        # remove inline comments
    m/^\s*([^\=\s][^\=]*?)\s*=\s*(.*?)\s*$/ or next;
    my ($k, $v) = ($1, $2);
    $config->{$k} = $v;
    $config->{$k} =~ s!\\\#!#!g;
    warn "[ship::config] $1 = $2\n" if DEBUG;
  }

  return $config;
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

0.27

=head1 DESCRIPTION

L<App::git::ship> is a L<git|http://git-scm.com/> command for building and
shipping your project.

The main focus is to automate away the boring steps, but at the same time not
get in your (or any random contributor's) way. Problems should be solved with
sane defaults according to standard rules instead of enforcing more rules.

This project can also L</start> (create) a new project, just L</build> (prepare
for L<shipping|/ship>), L</ship> (upload), and L</clean> projects.

L<App::git::ship> differs from other tools like L<dzil|Dist::Zilla> by not
enforcing new ways to do things, but rather incorporates with the existing
way.

Example structure and how L<App::git::ship> works on your files:

=over 4

=item * my-app/cpanfile and my-app/Makefile.PL

The C<cpanfile> is used to build the "PREREQ_PM" and "BUILD_REQUIRES"
structures in the L<ExtUtils::MakeMaker> based C<Makefile.PL> build file.
The reason for this is that C<cpanfile> is a more powerful format that can
be used by L<Carton> and other tools, so generating C<cpanfile> from
Makefile.PL would simply not be possible. Other data used to generate
Makefile.PL are:

"NAME" and "LICENSE" will have values from .ship.conf L</project_name> and
L</license>. "AUTHOR" will have the name and email from the last git committer.
"ABSTRACT_FROM" and "VERSION_FROM" are fetched from the
L<main_module_path|App::git::ship::perl/main_module_path>.
"EXE_FILES" will be the files in C<bin/> and C<script/> which are executable.
"META_MERGE" will use data from L</bugtracker>, L</homepage>, and L</repository>.
It is important to define your license in your .ship.conf before starting.

Both C<cpanfile> and C<Makefile.PL> are automatically created for you if you set
the class to App::git::ship::perl or you specify the
L<main_module_path|App::git::ship::perl/main_module_path> as an argument to git
start.

=item * my-app/CHANGELOG.md or my-app/Changes

The Changes file will be updated with the correct L<timestamp|/new_version_format>,
from when you ran the L</build> action. The Changes file will also be the source
for L</next_version>. Both C<CHANGELOG.md> and C<Changes> are valid sources.
App::git::ship looks for a version-timestamp line with the case-sensitive text "Not
Released" as the the timestamp.

Changes is automatically created for you if you set the class to
App::git::ship::perl or your specify the
L<main_module_path|App::git::ship::perl/main_module_path> as an argument to git
start.

=item * my-app/README

Will be updated with the main module documentation using the command below:

  $ perldoc -tT $main_module_path > README;

If you don't like this format, you can create and write C<README.md> manually
instead. The presence of that file will prevent "my-app/README" from getting
generated.

Both C<README> and C<README.pod> are automatically created for you if you set
the class to App::git::ship::perl or your specify the
L<main_module_path|App::git::ship::perl/main_module_path> as an argument to git
start.

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
building.

It is important to have a remote setup in your git repository before shipping.
It is important to have a ~/.pause file setup with 'user' and 'password' entries
before shipping.

=back

=head1 SYNOPSIS

=head2 Existing project

  # Set up git ship config and basic files for a Perl repo
  $ cd my-project
  $ git ship start lib/My/Project.pm

  # make changes
  $ $EDITOR lib/My/Project.pm

  # build first if you want to investigate the changes
  $ git ship build

  # ship the project to git (and CPAN)
  $ git ship

=head2 New project

  $ git ship -h
  $ git ship start My/Project.pm
  $ cd my-project

  # make changes
  $ $EDITOR lib/My/Project.pm

  # build first if you want to investigate the changes
  $ git ship build

  # ship the project to git (and CPAN)
  $ git ship

=head2 Git aliases

  # git build
  $ git config --global alias.build = ship build

  # git cl
  $ git config --global alias.cl = ship clean

  # git start
  # git start My/Project.pm
  $ git config --global alias.start = ship start

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

=head1 CONFIG

C<App::git::ship> automatically generates a config file when you L</start> a
new project.

=over 4

=item * bugtracker

URL to the bugtracker for this project.

=item * build_test_options

This holds the arguments for the test program to use when building the
project. The default is to not automatically run the tests. Example value:

  build_test_options = -l -j4

=item * class

This class is used to build the object that runs all the actions on your
project. This is autodetected by looking at the structure and files in
your project. For now this value can be L<App::git::ship> or
L<App::git::ship::perl>, but any customization is allowed.

=item * homepage

URL to the home page for this project.

=item * license

The name of the license to use. Defaults to "artistic_2".

=item * new_version_format

This is optional, but specifies the version format in your "Changes" file.
The example below will result in "## 0.42 (2014-01-28)".

  new_version_format = \#\# %v (%F)

"%v" will be replaced by the version, while the format arguments are passed
on to L<POSIX/strftime>.

The default is "%v %Y-%m-%dT%H:%M:%S%z".

=item * project_name

This name is extracted from either the L<App::git::ship::perl/main_module_path>
or defaults to "unknown" if no project name could be found. Example:

  project_name = My::App

=item * Comments

Comments are made by adding the hash symbol (#) followed by text. If you want
to use the "#" as a value, it needs to be escaped using "\#". Examples:

  # This whole line is skipped
  parameter = 123 # The end of this line is skipped
  parameter = some \# value with hash

=item * Hooks

It is possible to add hooks to the L</CONFIG> file. These hooks are
programs that runs in your shell. Example L<.ship|/CONFIG> file with hooks:

  before_build = bash script/new-release.sh
  after_build = rm -r lib/My/App/templates lib/My/App/public
  after_ship = cat Changes | mail -s "Changes for My::App" all@my-app.com

Possible hooks are C<before_build>, C<after_build>, C<before_ship>, and C<after_ship>.

=back

=head1 ATTRIBUTES

=head2 next_version

  $str = $self->next_version;

Holds the next version to L</ship>.

=head2 project_name

  $str = $self->project_name;

Holds the name of the current project. This attribute can be read from
L</config>.

=head2 repository

  $str = $self->repository;

Returns the URL to the first repository that points to "origin".
This attribute can be read from L</config>.

The username is detected by the uid on your OS, you can override this by
setting GITHUB_USERNAME.

=head2 silent

  $bool = $self->silent;
  $self = $self->silent($bool);

Set this to true if you want less logging. By default silent is false.

=head1 METHODS

=head2 abort

  $self->abort($str);
  $self->abort($format, @args);

Will abort the application run with an error message.

=head2 attr

  $class = $class->attr($name => sub { my $self = shift; return $default_value });

or ...

  use App::git::ship -base;
  has $name => sub { my $self = shift; return $default_value };

Used to create an attribute with a lazy builder.

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

  $hash_ref = $self->config;

Holds the configuration from end user. The config is by default read from
C<.ship.conf> in the root of your project.

=head2 detect

  $class = $self->detect;
  $class = $self->detect($file);

Will detect the module which can be used to build the project. This
can be read from the "class" key in L</config> or will in worse
case default to L<App::git::ship>.

=head2 dump

  $str = $self->dump($any);

Will serialize C<$any> into a perl data structure, using L<Data::Dumper>.

=head2 new

  $self = $class->new(%attributes);

Creates a new instance of C<$class>.

=head2 render

  $self->render($file, \%args);

Used to render a template by the name C<$file> to a C<$file>. The template
needs to be defined in the C<DATA> section of the current class or one of
the super classes.

=head2 run_hook

  $self->run_hook($name);

Used to run a hook before or after an event. The hook is a command which
needs to be defined in the config file. Example config line parameter:

  before_build = echo foo > bar.txt

=head2 ship

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

  $self->system($program, @args);

Same as perl's C<system()>, but provides error handling and logging.

=head2 test_coverage

This method checks test coverage for the project. The default behavior is to
L</abort>. Needs to be overridden in the subclass.

=head2 import

  use App::git::ship;
  use App::git::ship -base;
  use App::git::ship "App::git::ship::perl";

Called when this class is used. It will automatically enable L<strict>,
L<warnings>, L<utf8> and Perl 5.10 features.

C<-base> will also make sure the calling class inherits from L<App::git::ship>
and gets the L<has|/attr> function. Does the same with a class name, except
that it will then inherit from the given class.

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

Copyright (C) 2014-2016, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

__DATA__
@@ .ship.conf
# Generated by git-ship. See 'git-ship --man' for help or https://github.com/jhthorsen/app-git-ship
class = <%= ref $ship %>
project_name = 
homepage = <%= $homepage %>
bugtracker = <%= join('/', $homepage, 'issues') =~ s!(\w)//!$1/!r %>
license = artistic_2
build_test_options = # Example: -l -j8
@@ .gitignore
~$
*.bak
*.old
*.swp
/local
@@ test
<%= $x %>: <%= $ship->repository %> # test
