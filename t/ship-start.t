use lib '.';
use t::Util;
use App::git::ship;

t::Util->goto_workdir('ship-start');

my $app      = App::git::ship->new;
my $username = getpwuid $<;

{
  eval { $app->start('foo.unknown') };
  like $@, qr{Could not figure out what kind of project this is},
    'Could not figure out what kind of project this is';

  $app->start;
  ok -d '.git', '.git was created';
  is $app->config('bugtracker'), "https://github.com/$username/unknown/issues",
    'bugtracker is set up';
  is $app->config('homepage'), "https://github.com/$username/unknown", 'homepage is set up';
  is $app->config('license'), 'artistic_2', 'license is set up';

  t::Util->test_file('.gitignore', qr{^\~\$}m, qr{^\*\.bak}m, qr{^\*\.old}m, qr{^\*\.swp}m,
    qr{^/local}m,);
}

done_testing;
