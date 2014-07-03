use Test::More;
use App::git::ship::perl;

plan skip_all => 'Cannot test unless linux' unless $^O eq 'linux';

mkdir 'dummy-project';
chdir 'dummy-project' or plan skip_all => 'Could not chdir to test-repo';
system qw( git init ) and plan skip_all => "git: $?";
system qw( git remote add origin git@github.com:Nordaaker/convos.git );
system qw( mkdir -p lib/Dummy );
system qw( touch lib/Dummy/Project.pm );

my $app = App::git::ship::perl->new;

unlink $_ for qw( Changes MANIFEST.SKIP );

{
  eval { $app->init };
  ok !$@, 'init()' or diag $@;
  ok -e 'Changes', 'Changes was generated';
  ok -e 'MANIFEST.SKIP', 'MANIFEST.SKIP was generated';
}

done_testing;
