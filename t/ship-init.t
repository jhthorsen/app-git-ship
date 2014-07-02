use Test::More;
use App::git::ship;

mkdir 'ship-init-test-repo';
chdir 'ship-init-test-repo' or plan skip_all => 'Could not chdir to test-repo';
system qw( git init ) and plan skip_all => "git: $?";
system qw( git remote add origin git@github.com:Nordaaker/convos.git );

my $app = App::git::ship->new;

{
  $app->init;
  is $app->config->{bugtracker}, 'https://github.com/Nordaaker/convos/issues', 'bugtracker is set up';
  is $app->config->{homepage}, 'https://github.com/Nordaaker/convos', 'homepage is set up';
  is $app->config->{license_name}, 'artistic_2', 'license_name is set up';
  is $app->config->{license_url}, 'http://www.opensource.org/licenses/artistic-license-2.0', 'license_url is set up';
}

done_testing;
