package App::git::ship::perl;

=head1 NAME

App::git::ship::perl - Ship your Perl module

=head1 DESCRIPTION

L<App::git::ship::perl> is a module that can ship your Perl module.

See L<App::git::ship/SYNOPSIS>

=cut

use App::git::ship -base;
use Cwd ();
use File::Basename qw( dirname basename );
use File::Path 'make_path';
use File::Spec;
use Module::CPANfile;

my $VERSION_RE = qr{\b\d+\.[\d_]+\b};

=head1 ATTRIBUTES

=head2 main_module_path

  $str = $self->main_module_path;

Tries to guess the path to the main module in the repository. This is done by
looking at the repo name and try to find a file by that name. Example:

  ./my-cool-project/.git
  ./my-cool-project/lib/My/Cool/Project.pm

This guessing is case-insensitive.

Instead of guessing, you can put "main_module_path" in the config file.

=cut

has main_module_path => sub {
  my $self = shift;
  return $self->config->{main_module_path} if $self->config->{main_module_path};

  my @path = split /-/, basename(Cwd::getcwd);
  my $path = 'lib';
  my @name;

  PATH_PART:
  for my $p (@path) {
    opendir my $DH, $path or $self->abort("Cannot find project name from $path: $!");

    for my $f (readdir $DH) {
      $f =~ s/\.pm$//;
      next unless lc $f eq lc $p;
      push @name, $f;
      $path = File::Spec->catdir($path, $f);
      next PATH_PART;
    }
  }

  return "$path.pm";
};

=head2 project_name

  $str = $self->project_name;

Tries to figure out the project name from L</main_module_path> unless the
L</project_name> is specified in config file.

Example result: "My::Perl::Project".

=cut

has project_name => sub {
  my $self = shift;

  return $self->config->{project_name} if $self->config->{project_name};

  my @name = File::Spec->splitdir($self->main_module_path);
  shift @name if $name[0] eq 'lib';
  $name[-1] =~ s!\.pm$!!;
  join '::', @name;
};

has _cpanfile => sub { Module::CPANfile->load; };

=head1 METHODS

=head2 build

Used to build a Perl distribution.

=cut

sub build {
  my $self = shift;

  $self->clean(0);
  $self->system(prove => split /\s/, $self->config->{build_test_options}) if $self->config->{build_test_options};
  $self->clean(0);
  $self->_render_makefile_pl;
  $self->_timestamp_to_changes;
  $self->_update_version_info;
  $self->system(sprintf '%s %s > %s', 'perldoc -tT', $self->main_module_path, 'README');
  $self->_make('manifest');
  $self->_make('dist');
  $self;
}

=head2 can_handle_project

See L<App::git::ship/can_handle_project>.

=cut

sub can_handle_project {
  my ($class, $file) = @_;
  my $can_handle_project = 0;

  if ($file) {
    return $file =~ /\.pm$/ ? 1 : 0;
  }
  if (-d 'lib') {
    File::Find::find(sub { $can_handle_project = 1 if /\.pm$/; }, 'lib');
  }

  return $can_handle_project;
}

=head2 clean

Used to clean out build files.

=cut

sub clean {
  my $self = shift;
  my $all = shift // 1;
  my @files = qw( Makefile Makefile.old MANIFEST MYMETA.json MYMETA.yml );

  push @files, qw( Changes.bak META.json META.yml ) if $all;
  $self->_dist_files(sub { push @files, $_; });

  for my $file (@files) {
    next unless -e $file;
    unlink $file or warn "!! rm $file: $!" and next;
    say "\$ rm $file" unless $self->silent;
  }

  return $self;
}

=head2 exe_files

  @files = $self->exe_files;

Returns a list of files in the "bin/" directory that has the executable flag
set.

This method is used to build the C<EXE_FILES> list in C<Makefile.PL>.

=cut

sub exe_files {
  my $self = shift;
  my $BIN;

  return unless opendir $BIN, 'bin';
  return map { "bin/$_" } grep { /^\w/ and -x File::Spec->catfile("bin", $_) } readdir $BIN;
}

=head2 init

Used to generate C<Changes> and C<MANIFEST.SKIP>.

=cut

sub init {
  my $self = shift;

  if (my $file = $_[0]) {
    $file = File::Spec->catfile(lib => $file) unless $file =~ m!^.?lib!;
    $self->config({})->main_module_path($file);
    my $work_dir = lc($self->project_name) =~ s!::!-!gr;
    mkdir $work_dir;
    chdir $work_dir or $self->abort("Could not chdir to $work_dir");
    make_path dirname $self->main_module_path;
    open my $MAINMODULE, '>>', $self->main_module_path or $self->abort("Could not create %s", $self->main_module_path);
  }

  symlink $self->main_module_path, 'README.pod' unless -e 'README.pod';

  $self->SUPER::init(@_);
  $self->render('cpanfile');
  $self->render('Changes');
  $self->render('MANIFEST.SKIP');
  $self->render('t/00-basic.t');
  $self->system(qw( git add cpanfile Changes MANIFEST.SKIP t ));
  $self->system(qw( git commit --amend -C HEAD )) if @_;
  $self;
}

=head2 ship

Use L<App::git::ship/ship> and then push the new release to CPAN
using C<cpan-uploader-http>.

=cut

sub ship {
  my $self = shift;
  my $dist_file = $self->_dist_files(sub { 1 });
  my $uploader;

  require CPAN::Uploader;
  $uploader = CPAN::Uploader->new(CPAN::Uploader->read_config_file);

  unless ($dist_file) {
    $self->build;
    $self->abort("Project built. Run 'git ship' again to post to CPAN and alien repostitory.");
  }

  $self->system(qw( git add Makefile.PL Changes README ));
  $self->system(qw( git commit -a -m ), $self->_changes_to_commit_message);
  $self->SUPER::ship(@_); # after all the changes
  $uploader->upload_file($dist_file);
  $self->clean;
}

sub _author {
  my ($self, $format) = @_;

  open my $GIT, '-|', qw( git log ), "--format=$format" or $self->abort("git log --format=$format: $!");
  my $author = readline $GIT;
  $self->abort("Could not find any author in git log") unless $author;
  chomp $author;
  warn "[ship::author] $format = $author\n" if DEBUG;
  return $author;
}

sub _changes_to_commit_message {
  my $self = shift;
  my ($version, @message);

  close ARGV; # reset <> iterator
  local @ARGV = qw( Changes );
  while (<>) {
    last if @message and /^($VERSION_RE)\s+/;
    push @message, $_ if @message;
    push @message, $_ and $version = $1 if /^($VERSION_RE)\s+/;
  }

  $message[0] =~ s!.*?\n!Released version $version\n\n!s;
  local $" = '';
  return "@message";
}

sub _dist_files {
  my ($self, $cb) = @_;
  my $name = lc($self->project_name) =~ s!::!-!gr;

  opendir(my $DH, Cwd::getcwd);
  while (readdir $DH) {
    next unless /^$name.*\.tar/i;
    return $_ if $self->$cb;
  }

  return undef;
}

sub _make {
  my ($self, @args) = @_;

  $self->_render_makefile_pl unless -e 'Makefile.PL';
  $self->system(perl => 'Makefile.PL') unless -e 'Makefile';
  $self->system(make => @args);
}

sub _render_makefile_pl {
  my $self = shift;
  my $prereqs = $self->_cpanfile->prereqs;
  my $args = { force => 1 };

  $args->{PREREQ_PM} = $prereqs->requirements_for(qw( runtime requires ))->as_string_hash;

  for my $k (qw( build test )) {
    my $r = $prereqs->requirements_for($k, 'requires')->as_string_hash;
    $args->{BUILD_REQUIRES}{$_} = $r->{$_} for keys %$r;
  }

  $self->render('Makefile.PL', $args);
  $self->system(qw( perl -c Makefile.PL )); # test Makefile.PL
}

sub _timestamp_to_changes {
  my $self = shift;
  my $date = localtime;

  local @ARGV = qw( Changes );
  local $^I = '';
  while (<>) {
    $self->next_version($1) if s/^($VERSION_RE)\s*$/{ sprintf "\n%-7s  %s\n", $1, $date }/e;
    print; # print back to same file
  }

  say '# Building version ', $self->next_version unless $self->silent;
  $self->abort('Unable to add timestamp to ./Changes') unless $self->next_version;
}

sub _update_version_info {
  my $self = shift;
  my $version = $self->next_version or $self->abort('Internal error: Are you sure Changes has a timestamp?');
  my %r;

  local @ARGV = ($self->main_module_path);
  local $^I = '';
  while (<>) {
    $r{pod} ||= s/$VERSION_RE/$version/ if /^=head1 VERSION/ .. $r{pod} && /^=(cut|head1)/ || eof;
    $r{var} ||= s/((?:our)?\s*\$VERSION)\s*=.*/$1 = '$version';/;
    print; # print back to same file
  }

  $self->abort('Could not update VERSION in %s', $self->main_module_path) unless $r{var};
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;

__DATA__
@@ .gitignore
~$
*.bak
*.old
*.swp
/blib/
/cover_db
/inc/
/local
/Makefile
/Makefile.old
/MANIFEST$
/MANIFEST.bak
/META*
/MYMETA*
/pm_to_blib
@@ cpanfile
# You can install this projct with curl -L http://cpanmin.us | perl - <%= $_[0]->repository =~ s!\.git$!!r %>/archive/master.tar.gz
requires "perl" => "5.10.0";
test_requires "Test::More" => "0.88";
@@ Changes
Changelog for <%= $self->project_name %>

0.01
       * Started project

@@ Makefile.PL
# Generated by git-ship. See 'git-ship --man' for help or https://github.com/jhthorsen/app-git-ship
use ExtUtils::MakeMaker;
WriteMakefile(
  NAME => '<%= $_[0]->project_name %>',
  AUTHOR => '<%= $_[0]->_author('%an <%ae>') %>',
  LICENSE => '<%= $_[0]->config->{license} %>',
  ABSTRACT_FROM => '<%= $_[0]->main_module_path %>',
  VERSION_FROM => '<%= $_[0]->main_module_path %>',
  EXE_FILES => [qw( <%= join ' ', $_[0]->exe_files %> )],
  META_MERGE => {
    resources => {
      bugtracker => '<%= $_[0]->config->{bugtracker} %>',
      homepage => '<%= $_[0]->config->{homepage} %>',
      repository => '<%= $_[0]->repository %>',
    },
  },
  BUILD_REQUIRES => <%= $_[1]->{BUILD_REQUIRES} %>,
  PREREQ_PM => <%= $_[1]->{PREREQ_PM} %>,
  test => { TESTS => 't/*.t' },
);
@@ MANIFEST.SKIP
#!include_default
\.swp$
^local/
^MANIFEST\.SKIP
^README\.pod
@@ t/00-basic.t
use Test::More;
use File::Find;

if(($ENV{HARNESS_PERL_SWITCHES} || '') =~ /Devel::Cover/) {
  plan skip_all => 'HARNESS_PERL_SWITCHES =~ /Devel::Cover/';
}
if(!eval 'use Test::Pod; 1') {
  *Test::Pod::pod_file_ok = sub { SKIP: { skip "pod_file_ok(@_) (Test::Pod is required)", 1 } };
}
if(!eval 'use Test::Pod::Coverage; 1') {
  *Test::Pod::Coverage::pod_coverage_ok = sub { SKIP: { skip "pod_coverage_ok(@_) (Test::Pod::Coverage is required)", 1 } };
}

find(
  {
    wanted => sub { /\.pm$/ and push @files, $File::Find::name },
    no_chdir => 1
  },
  -e 'blib' ? 'blib' : 'lib',
);

plan tests => @files * 3;

for my $file (@files) {
  my $module = $file; $module =~ s,\.pm$,,; $module =~ s,.*/?lib/,,; $module =~ s,/,::,g;
  ok eval "use $module; 1", "use $module" or diag $@;
  Test::Pod::pod_file_ok($file);
  Test::Pod::Coverage::pod_coverage_ok($module);
}
