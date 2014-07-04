use t::Util;
use App::git::ship::perl;

{
  my $app = App::git::ship::perl->new;
  like $app->_changes_to_commit_message, qr{Released version [\d\._]+\n\n\s+}, '_changes_to_commit_message()';
}

t::Util->goto_workdir('perl-ship', 0);

my $upload_file;
eval <<'DUMMY' or die $@;
package CPAN::Uploader;
sub new { bless $_[1], $_[0] }
sub read_config_file { {} }
sub upload_file { $upload_file = $_[1] }
$INC{'CPAN/Uploader.pm'} = 'dummy';
DUMMY

{
  my $app = App::git::ship->new;
  $app = $app->init('Perl/Init.pm', 0);

  eval { $app->ship };
  like $@, qr{perldoc -tT .* > README}, 'need code to ship';

  open my $MAIN_MODULE, '>', File::Spec->catfile(qw( lib Perl Init.pm ));
  print $MAIN_MODULE "package Perl::Init;\n=head1 NAME\n\nPerl::Init\n\n=cut\n\n1";
  close $MAIN_MODULE;

  $app->ship;

  is $upload_file, 'asd', 'CPAN::Uploader uploaded file';
}

done_testing;
