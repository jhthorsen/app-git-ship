BEGIN { $ENV{GIT_SHIP_SILENT} //= 1 }
package t::Util;

use strict;
use warnings;
use File::Path 'remove_tree';
use Test::More;
use Cwd ();

sub mock_git {
  $ENV{PATH} ||= '';

  for my $p (split /:/, $ENV{PATH}) {
    next unless -x "$p/git";
    $ENV{GIT_REAL_BIN} = "$p/git";
    $ENV{PATH} = join ':', File::Spec->catdir(Cwd::getcwd, 't/bin'), $ENV{PATH};
    return 1 unless system 'git _'; # test t/bin/git
  }

  plan skip_all => 'Could not find git in PATH';
}

sub goto_workdir {
  my ($class, $workdir, $create) = @_;
  my $base = 'workdir';

  $class->mock_git unless $ENV{GIT_REAL_BIN};
  $create //= 1;

  mkdir $base unless -d $base;
  chdir $base or plan skip_all => "Could not chdir to $base";
  remove_tree $workdir if -d $workdir;

  if ($create) {
    mkdir $workdir;
    chdir $workdir or plan skip_all => "Could not chdir to $workdir";
    unlink 'git.log';
  }

  diag "Workdir is $base/$workdir";
}

sub test_file {
  my ($class, $file, @rules) = @_;
  my ($FH, $txt);

  unless (open $FH, '<', $file) {
    ok 0, "The file $file is missing";
    return;
  }

  $txt = do { local $/; <$FH>; };
  for my $rule (@rules) {
    like $txt, $rule, "File $file match $rule";
  }
}

sub test_file_lines {
  my ($class, $file) = (shift, shift);
  my %lines = map { $_ => 1 } @_;
  my ($FH, @extra);

  unless (open $FH, '<', $file) {
    ok 0, "The file $file is missing";
    return;
  }

  while (<$FH>) {
    chomp;
    delete $lines{$_} or push @extra, $_;
  }

  is_deeply \@extra, [], "The file $file has no extra lines";
  is_deeply [keys %lines], [], "The file $file has no missing lines";
}

sub import {
  my $class = shift;
  my $caller = caller;

  strict->import;
  warnings->import;
  eval "package $caller; use Test::More;1" or die $@;
}

1;
