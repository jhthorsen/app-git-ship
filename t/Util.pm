BEGIN { $ENV{GIT_SHIP_SILENT} //= 1 }
package t::Util;

use strict;
use warnings;
use File::Path 'remove_tree';
use Test::More;

sub goto_workdir {
  my ($class, $workdir, $create) = @_;
  my $base = 'workdir';

  $create //= 1;

  mkdir $base unless -d $base;
  chdir $base or plan skip_all => "Could not chdir to $base";
  remove_tree $workdir if -d $workdir;

  if ($create) {
    mkdir $workdir;
    chdir $workdir or plan skip_all => "Could not chdir to $workdir";
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

sub import {
  my $class = shift;
  my $caller = caller;

  strict->import;
  warnings->import;
  eval "package $caller; use Test::More;1" or die $@;
}

1;
