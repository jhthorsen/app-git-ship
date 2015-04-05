use t::Util;
use App::git::ship;

t::Util->goto_workdir('repository');

my $app = App::git::ship->new(silent => 1);
my $username = getpwuid $<;

is $app->repository, "https://github.com/jhthorsen/app-git-ship.git", 'app-git-ship.git';

delete $app->{repository};
$app->start;
is $app->repository, "https://github.com/$username/unknown", 'unknown repository';

delete $app->{repository};
system qw( git remote add origin https://github.com/harry-bix/mojo-MySQL5.git );
is $app->repository, "https://github.com/harry-bix/mojo-MySQL5.git", 'http repository';

done_testing;
