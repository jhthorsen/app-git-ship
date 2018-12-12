package App::git::ship::perl;
use Mojo::Base 'App::git::ship';

use Module::CPANfile;
use Mojo::File 'path';
use POSIX qw(setlocale strftime LC_TIME);

use constant DEBUG => $ENV{GIT_SHIP_DEBUG} || 0;

my $VERSION_RE = qr{\W*\b(\d+\.[\d_]+)\b};

sub build {
  my $self = shift;

  $self->clean(0);
  $self->system(prove => split /\s/, $self->config('build_test_options'))
    if $self->config('build_test_options');
  $self->clean(0);
  $self->run_hook('before_build');
  $self->_render_makefile_pl;
  $self->_timestamp_to_changes;
  $self->_update_version_info;
  $self->_make('manifest');
  $self->_make('dist');
  $self->run_hook('after_build');
  $self;
}

sub can_handle_project {
  my ($class, $file) = @_;
  return $file =~ /\.pm$/ ? 1 : 0 if $file;
  return path('lib')->list_tree->grep(sub {/\.pm$/})->size;
}

sub clean {
  my $self  = shift;
  my $all   = shift // 1;
  my @files = qw(Makefile Makefile.old MANIFEST MYMETA.json MYMETA.yml);

  push @files, qw(Changes.bak META.json META.yml) if $all;
  push @files, $self->_dist_files->each;

  for my $file (@files) {
    next unless -e $file;
    unlink $file or warn "!! rm $file: $!" and next;
    say "\$ rm $file" unless $self->SILENT;
  }

  return $self;
}

sub ship {
  my $self      = shift;
  my $dist_file = $self->_dist_files->[0];
  my $changelog = $self->config('changelog_filename');
  my $uploader;

  require CPAN::Uploader;
  $uploader = CPAN::Uploader->new(CPAN::Uploader->read_config_file);

  unless ($dist_file) {
    $self->build;
    $self->abort(
      "Project built. Run 'git ship' again to post dist to CPAN and remote repostitory.");
  }
  unless ($self->config('next_version')) {
    close ARGV;
    local @ARGV = $changelog;
    while (<>) {
      /^$VERSION_RE\s*/ or next;
      $self->config(next_version => $1);
      last;
    }
  }

  $self->run_hook('before_ship');
  $self->system(qw(git add Makefile.PL), $changelog);
  $self->system(qw(git commit -a -m),    $self->_changes_to_commit_message);
  $self->SUPER::ship(@_);    # after all the changes
  $uploader->upload_file($dist_file);
  $self->run_hook('after_ship');
  $self->clean;
}

sub start {
  my $self      = shift;
  my $changelog = $self->config('changelog_filename');

  if (my $file = $_[0]) {
    $file = $file =~ m!^.?lib! ? path($file) : path(lib => $file);
    $self->config(main_module_path => $file);
    unless (-e $file) {
      my $work_dir = lc($self->config('project_name')) =~ s!::!-!gr;
      mkdir $work_dir;
      chdir $work_dir or $self->abort("Could not chdir to $work_dir");
      $self->config('main_module_path')->dirname->make_path;
      open my $MAINMODULE, '>>', $self->config('main_module_path')
        or $self->abort("Could not create %s", $self->config('main_module_path'));
    }
  }

  $self->SUPER::start(@_);
  $self->render_template('cpanfile');
  $self->render_template('Changes') if $changelog eq 'Changes';
  $self->render_template('MANIFEST.SKIP');
  $self->render_template('t/00-basic.t');
  $self->system(qw(git add cpanfile MANIFEST.SKIP t), $changelog);
  $self->system(qw(git commit --amend -C HEAD --allow-empty)) if @_;
  $self;
}

sub test_coverage {
  my $self = shift;

  unless (eval 'require Devel::Cover; 1') {
    $self->abort(
      'Devel::Cover is not installed. Install it with curl -L http://cpanmin.us | perl - Devel::Cover'
    );
  }

  local $ENV{DEVEL_COVER_OPTIONS} = $ENV{DEVEL_COVER_OPTIONS} || '+ignore,^t\b';
  local $ENV{HARNESS_PERL_SWITCHES} = '-MDevel::Cover';
  $self->system(qw(cover -delete));
  $self->system(qw(prove -l));
  $self->system(qw(cover));
}

sub update {
  my $self    = shift;
  my $changes = $self->config('changelog_filename');

  $self->abort("Cannot update with .git directory. Forgot to run 'git ship start'?")
    unless -d '.git';

  $self->_render_makefile_pl;
  $self->_update_changes if $changes eq 'Changes';
  $self->render_template('t/00-basic.t', {force => 1});
  $self;
}

sub _build_config_param_changelog_filename {
  (grep {-w} qw(CHANGELOG.md Changes))[0] || 'Changes';
}

sub _build_config_param_main_module_path {
  my $self = shift;
  return path($ENV{GIT_SHIP_MAIN_MODULE_PATH}) if $ENV{GIT_SHIP_MAIN_MODULE_PATH};

  my @project_name = split /-/, path->basename;
  my $path = path 'lib';

PATH_PART:
  for my $p (@project_name) {
    opendir my $DH, $path or $self->abort("Cannot find project name from $path: $!");

    for (sort { length $b <=> length $a } readdir $DH) {
      my $f = "$_";
      s!\.pm$!!;
      next unless lc eq lc $p;
      $path = path $path, $f;
      next PATH_PART;
    }
  }

  return $path;
}

sub _build_config_param_project_name {
  my $self = shift;
  my @name = @{$self->config('main_module_path')};
  shift @name if $name[0] eq 'lib';
  $name[-1] =~ s!\.pm$!!;
  return join '::', @name;
}

sub _changes_to_commit_message {
  my $self      = shift;
  my $changelog = $self->config('changelog_filename');
  my ($version, @message);

  close ARGV;    # reset <> iterator
  local @ARGV = $changelog;
  while (<>) {
    last if @message and /^$VERSION_RE\s+/;
    push @message, $_ if @message;
    push @message, $_ and $version = $1 if /^$VERSION_RE\s+/;
  }

  $self->abort("Could not find any changes in $changelog") unless @message;
  $message[0] =~ s!.*?\n!Released version $version\n\n!s;
  local $" = '';
  return "@message";
}

sub _dist_files {
  my $self = shift;
  my $name = $self->config('project_name') =~ s!::!-!gr;

  return path->list->grep(sub {m!\b$name.*\.tar!i});
}

sub _exe_files {
  my $self = shift;
  my @files;

  for my $d (qw(bin script)) {
    push @files, path($d)->list->grep(sub {-x})->each;
  }

  return @files;
}

sub _include_mskip_file {
  my ($self, $file) = @_;
  my @lines;

  $file ||= do { require ExtUtils::Manifest; $ExtUtils::Manifest::DEFAULT_MSKIP; };

  unless (-r $file) {
    warn "MANIFEST.SKIP included file '$file' not found - skipping\n";
    return '';
  }

  @lines = ("#!start included $file\n");
  local @ARGV = ($file);
  push @lines, $_ while <>;
  return join "", @lines, "#!end included $file\n";
}

sub _make {
  my ($self, @args) = @_;

  $self->_render_makefile_pl unless -e 'Makefile.PL';
  $self->system(perl => 'Makefile.PL') unless -e 'Makefile';
  $self->system(make => @args);
}

sub _render_makefile_pl {
  my $self    = shift;
  my $prereqs = Module::CPANfile->load->prereqs;
  my $args    = {force => 1};
  my $r;

  $args->{PREREQ_PM}      = $prereqs->requirements_for(qw(runtime requires))->as_string_hash;
  $r                      = $prereqs->requirements_for(qw(build requires))->as_string_hash;
  $args->{BUILD_REQUIRES} = $r;
  $r                      = $prereqs->requirements_for(qw(test requires))->as_string_hash;
  $args->{TEST_REQUIRES}  = $r;

  $self->render_template('Makefile.PL', $args);
  $self->system(qw(perl -c Makefile.PL));    # test Makefile.PL
}

sub _timestamp_to_changes {
  my $self      = shift;
  my $changelog = $self->config('changelog_filename');
  my $loc       = setlocale(LC_TIME);
  my $release_line;

  $release_line = sub {
    my $v = shift;
    my $str = $self->config('new_version_format') || '%v %Y-%m-%dT%H:%M:%S%z';
    $str =~ s!(%-?\d*)v!{ sprintf "${1}s", $v }!e;
    setlocale LC_TIME, 'C';
    $str = strftime $str, localtime;
    setlocale LC_TIME, $loc;
    return $str;
  };

  local @ARGV = $changelog;
  local $^I   = '';
  while (<>) {
    $self->config(next_version => $1)
      if s/^$VERSION_RE\x20*(?:Not Released)?\x20*([\r\n]+)/{ $release_line->($1) . $2 }/e;
    print;    # print back to same file
  }

  say '# Building version ', $self->config('next_version') unless $self->SILENT;
  $self->abort('Unable to add timestamp to ./%s', $changelog) unless $self->config('next_version');
}

sub _update_changes {
  my $self = shift;
  my $changes;

  unless (eval "require CPAN::Changes; 1") {
    say "# Cannot update './Changes' without CPAN::Changes. Install using cpanm CPAN::Changes"
      unless $self->SILENT;
    return;
  }

  $changes = CPAN::Changes->load('Changes');
  $changes->preamble(
    'Revision history for perl distribution ' . ($self->config('project_name') =~ s!::!-!gr));
  open my $FH, '>', 'Changes' or $self->abort("Could not write CPAN::Changes to Changes: $!");
  print $FH $changes->serialize;
  say "# Generated Changes" unless $self->SILENT;
}

sub _update_version_info {
  my $self    = shift;
  my $version = $self->config('next_version')
    or $self->abort('Internal error: Are you sure Changes has a timestamp?');

  local @ARGV = ($self->config('main_module_path'));
  local $^I   = '';
  my %r;
  while (<>) {
    $r{pod} ||= s/$VERSION_RE/$version/ if /^=head1 VERSION/ .. $r{pod} && /^=(cut|head1)/ || eof;
    $r{var} ||= s/((?:our)?\s*\$VERSION)\s*=.*/$1 = '$version';/;
    print;    # print back to same file
  }

  $self->abort('Could not update VERSION in %s', $self->config('main_module_path')) unless $r{var};
}

1;

=encoding utf8

=head1 NAME

App::git::ship::perl - Ship your Perl module

=head1 DESCRIPTION

L<App::git::ship::perl> is a module that can ship your Perl module.

See L<App::git::ship/SYNOPSIS>

=head1 METHODS

=head2 build

  $ git ship build

Used to build a Perl distribution by running through these steps:

=over 4

=item 1.

Call L</clean> to make sure the repository does not contain old build files.

=item 2.

Run L<prove|App::Prove> if C<build_test_options> is set in L</config>.

=item 3.

Run "before_build" L<hook|App::git::ship/Hooks>.

=item 4.

Render Makefile.PL

=item 5.

Add timestamp to changes file.

=item 6.

Update version in main module file.

=item 7.

Make MANIFEST

=item 8.

Make dist file (Your-App-0.42.tar.gz)

=item 9.

Run "after_build" L<hook|App::git::ship/Hooks>.

=back

=head2 can_handle_project

See L<App::git::ship/can_handle_project>.

=head2 clean

  $ git ship clean

Used to clean out build files:

Makefile, Makefile.old, MANIFEST, MYMETA.json, MYMETA.yml, Changes.bak, META.json
and META.yml.

=head2 ship

  $ git ship

Used to ship a Perl distribution by running through these steps:

=over 4

=item 1.

Find the dist file created by L</build> or abort if it could not be found.

=item 2.

Run "before_ship" L<hook|App::git::ship/Hooks>.

=item 3.

Add and commit the files changed in the L</build> step.

=item 4.

Use L<App::git::ship/next_version> to make a new tag and push all the changes
to the "origin" git repository.

=item 5.

Upload the dist file to CPAN.

=item 6.

Run "after_ship" L<hook|App::git::ship/Hooks>.

=back

=head2 start

  $ git ship start

Used to create main module file template and generate C<cpanfile>, C<Changes>,
C<MANIFEST.SKIP> and C<t/00-basic.t>.

=head2 test_coverage

Use L<Devel::Cover> to check test coverage for the distribution.

Set L<DEVEL_COVER_OPTIONS|https://metacpan.org/pod/Devel::Cover#OPTIONS> to
pass on options to L<Devel::Cover>. The default value will be set to:

  DEVEL_COVER_OPTIONS=+ignore,t

=head2 update

  $ git ship update

Action for updating the basic repo files.

=head1 SEE ALSO

L<App::git::ship>

=cut

__DATA__
@@ .gitignore
~$
*.bak
*.old
*.swp
/*.tar.gz
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
# You can install this project with curl -L http://cpanmin.us | perl - <%= $ship->config('repository') =~ s!\.git$!!r %>/archive/master.tar.gz
requires "perl" => "5.10.0";
test_requires "Test::More" => "0.88";
@@ Changes
Revision history for perl distribution <%= $ship->config('project_name') =~ s!::!-!gr %>

0.01 Not Released
 - Started project
@@ Makefile.PL
# Generated by git-ship. See 'git-ship --man' for help or https://github.com/jhthorsen/app-git-ship
use ExtUtils::MakeMaker;
my %WriteMakefileArgs = (
  NAME           => '<%= $ship->config('project_name') %>',
  AUTHOR         => '<%= $ship->config('author') %>',
  LICENSE        => '<%= $ship->config('license') %>',
  ABSTRACT_FROM  => '<%= $ship->config('main_module_path') %>',
  VERSION_FROM   => '<%= $ship->config('main_module_path') %>',
  EXE_FILES      => [qw(<%= join ' ', $ship->_exe_files %>)],
  BUILD_REQUIRES => <%= $ship->dump($BUILD_REQUIRES) %>,
  TEST_REQUIRES  => <%= $ship->dump($TEST_REQUIRES) %>,
  PREREQ_PM      => <%= $ship->dump($PREREQ_PM) %>,
  META_MERGE     => {
    'dynamic_config' => 0,
    'meta-spec'      => {version => 2},
    'resources'      => {
      bugtracker => {web => '<%= $ship->config('bugtracker') %>'},
      homepage   => '<%= $ship->config('homepage') %>',
      repository => {
        type => 'git',
        url  => '<%= $ship->config('repository') %>',
        web  => '<%= $ship->config('homepage') %>',
      },
    },
  },
  test => {TESTS => (-e 'META.yml' ? 't/*.t' : 't/*.t xt/*.t')},
);

unless (eval { ExtUtils::MakeMaker->VERSION('6.63_03') }) {
  my $test_requires = delete $WriteMakefileArgs{TEST_REQUIRES};
  @{$WriteMakefileArgs{PREREQ_PM}}{keys %$test_requires} = values %$test_requires;
}

WriteMakefile(%WriteMakefileArgs);
@@ MANIFEST.SKIP
<%= $ship->_include_mskip_file %>
\.swp$
^local/
^MANIFEST\.SKIP
^README\.md
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
if(!eval 'use Test::CPAN::Changes; 1') {
  *Test::CPAN::Changes::changes_file_ok = sub { SKIP: { skip "changes_ok(@_) (Test::CPAN::Changes is required)", 4 } };
}

find(
  {
    wanted => sub { /\.pm$/ and push @files, $File::Find::name },
    no_chdir => 1
  },
  -e 'blib' ? 'blib' : 'lib',
);

plan tests => @files * 3 + <%= $ship->config('changelog_filename') eq 'Changes' ? 4 : 0 %>;

for my $file (@files) {
  my $module = $file; $module =~ s,\.pm$,,; $module =~ s,.*/?lib/,,; $module =~ s,/,::,g;
  ok eval "use $module; 1", "use $module" or diag $@;
  Test::Pod::pod_file_ok($file);
  Test::Pod::Coverage::pod_coverage_ok($module, { also_private => [ qr/^[A-Z_]+$/ ], });
}

<%= $ship->config('changelog_filename') eq 'Changes' ? 'Test::CPAN::Changes::changes_file_ok();' : '' %>
